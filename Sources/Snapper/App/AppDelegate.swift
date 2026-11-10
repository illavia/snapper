import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snapper")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        HotKeyCenter.shared.register(id: 1, keyCode: HotKey.keyC, modifiers: HotKey.controlShift) { [weak self] in
            self?.captureInteractive()
        }
        HotKeyCenter.shared.register(id: 2, keyCode: HotKey.keyF, modifiers: HotKey.controlShift) { [weak self] in
            self?.captureFullScreen()
        }
        HotKeyCenter.shared.register(id: 3, keyCode: HotKey.keyS, modifiers: HotKey.controlShift) { [weak self] in
            self?.captureScrolling()
        }

        if !CaptureEngine.hasPermission { CGRequestScreenCaptureAccess() }
        Log.write("launched, screen permission: \(CaptureEngine.hasPermission)")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Capture Region or Window", #selector(menuCapture), key: "c"))
        menu.addItem(item("Capture Full Screen", #selector(menuFullScreen), key: "f"))
        menu.addItem(item("Scrolling Capture", #selector(menuScrolling), key: "s"))
        menu.addItem(.separator())

        let recent = FileStore.recent(limit: 8)
        let recentItem = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        if recent.isEmpty {
            recentMenu.addItem(NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: ""))
        }
        for url in recent {
            let entry = NSMenuItem(title: url.deletingPathExtension().lastPathComponent,
                                   action: #selector(menuOpenRecent(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = url
            recentMenu.addItem(entry)
        }
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)
        menu.addItem(item("Show All Captures…", #selector(menuHistory)))
        menu.addItem(item("Open Screenshots Folder", #selector(menuOpenFolder)))
        menu.addItem(.separator())
        menu.addItem(item("Change Save Folder…", #selector(menuChooseFolder)))
        let login = item("Launch at Login", #selector(menuToggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit Snapper", #selector(menuQuit), key: "q", modifiers: [.command]))
    }

    private func item(_ title: String, _ action: Selector, key: String = "",
                      modifiers: NSEvent.ModifierFlags = [.control, .shift]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    @objc private func menuCapture() { afterMenuCloses { self.captureInteractive() } }
    @objc private func menuFullScreen() { afterMenuCloses { self.captureFullScreen() } }
    @objc private func menuScrolling() { afterMenuCloses { self.captureScrolling() } }
    @objc private func menuHistory() { HistoryWindowController.shared.show() }
    @objc private func menuOpenFolder() {
        try? FileManager.default.createDirectory(at: FileStore.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(FileStore.folder)
    }
    @objc private func menuOpenRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { EditorWindowController.open(file: url) }
    }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuChooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = FileStore.folder
        panel.prompt = "Save Captures Here"
        if panel.runModal() == .OK, let url = panel.url { FileStore.folder = url }
    }

    @objc private func menuToggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.write("launch at login failed: \(error.localizedDescription)")
        }
    }

    /// Lets the menu finish closing so it is not in the screenshot.
    private func afterMenuCloses(_ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: Captures

    func captureInteractive() {
        guard !OverlayController.isActive, !ScrollSession.isActive else { return }
        Task {
            do {
                guard let picked = try await OverlayController.pick() else { return }
                guard let image = picked.frozen.crop(picked.rect) else { return }
                deliver(image, scale: picked.frozen.scale, kind: "region")
            } catch { report(error) }
        }
    }

    func captureFullScreen() {
        guard !OverlayController.isActive, !ScrollSession.isActive else { return }
        Task {
            do {
                let frozen = try await CaptureEngine.captureDisplay(NSScreen.underMouse)
                deliver(frozen.image, scale: frozen.scale, kind: "fullscreen")
            } catch { report(error) }
        }
    }

    func captureScrolling() {
        guard !OverlayController.isActive, !ScrollSession.isActive else { return }
        Task {
            do {
                let hint = "Drag over the area that scrolls, then scroll down slowly"
                guard let picked = try await OverlayController.pick(allowWindows: true, hint: hint) else { return }
                try await Task.sleep(nanoseconds: 250_000_000)
                ScrollSession.start(rect: picked.rect, screen: picked.frozen.screen) { [weak self] image, scale in
                    self?.deliver(image, scale: scale, kind: "scrolling")
                }
            } catch { report(error) }
        }
    }

    /// Direct rectangle capture with no overlay, used by the snapper:// URL hook.
    func captureRect(_ rect: CGRect) {
        Task {
            do {
                let screen = NSScreen.screens.first ?? NSScreen.underMouse
                let (image, scale) = try await CaptureEngine.captureRect(rect, on: screen)
                deliver(image, scale: scale, kind: "rect")
            } catch { report(error) }
        }
    }

    func deliver(_ image: CGImage, scale: CGFloat, kind: String) {
        guard let shot = Shot(image: image, scale: scale) else {
            Log.write("\(kind): could not encode image")
            return
        }
        let copied = Clipboard.copy(shot)
        var saved: URL?
        do { saved = try FileStore.save(shot) } catch {
            Log.write("\(kind): save failed: \(error.localizedDescription)")
        }
        Log.write("\(kind): \(image.width)x\(image.height) clipboard=\(copied) file=\(saved?.path ?? "none")")

        var warning: String?
        if !copied { warning = "Not copied to clipboard" } else if saved == nil { warning = "Copied, but not saved" }
        ThumbnailController.shared.show(image: shot.nsImage, file: saved, warning: warning) {
            EditorWindowController.open(shot: shot, file: saved)
        }
        HistoryWindowController.shared.reloadIfVisible()
    }

    private func report(_ error: Error) {
        Log.write("capture failed: \(error.localizedDescription)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if case CaptureError.noPermission = error {
            alert.messageText = "Snapper needs Screen Recording permission"
            alert.informativeText = "Turn on Snapper under Privacy & Security › Screen & System Audio Recording, then quit and reopen Snapper."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        } else {
            alert.messageText = "Capture failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: URL hook (snapper://capture, snapper://fullscreen, snapper://scroll, snapper://rect?x=&y=&w=&h=)

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "snapper" {
            switch url.host {
            case "capture": captureInteractive()
            case "fullscreen": captureFullScreen()
            case "scroll": captureScrolling()
            case "history": HistoryWindowController.shared.show()
            case "rect":
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                func value(_ name: String) -> CGFloat {
                    CGFloat(Double(items.first(where: { $0.name == name })?.value ?? "") ?? 0)
                }
                let rect = CGRect(x: value("x"), y: value("y"), width: value("w"), height: value("h"))
                if rect.width > 0, rect.height > 0 { captureRect(rect) }
            default: break
            }
        }
    }
}
