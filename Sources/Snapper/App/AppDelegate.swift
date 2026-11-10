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

        HotKeyCenter.shared.register(id: 1, keyCode: HotKey.keyC, modifiers: HotKey.optionShift) { [weak self] in
            self?.captureInteractive()
        }
        HotKeyCenter.shared.register(id: 2, keyCode: HotKey.keyF, modifiers: HotKey.optionShift) { [weak self] in
            self?.captureFullScreen()
        }
        HotKeyCenter.shared.register(id: 3, keyCode: HotKey.keyS, modifiers: HotKey.optionShift) { [weak self] in
            self?.captureScrolling()
        }

        // One-key capture: plain § with nothing held. Shift-§ still types ±.
        let sectionOK = HotKeyCenter.shared.register(id: 6, keyCode: HotKey.keySection, modifiers: 0) { [weak self] in
            self?.captureInteractive()
        }
        Log.write("section key shortcut registered: \(sectionOK)")
        HotKeyCenter.shared.register(id: 4, keyCode: HotKey.keyT, modifiers: HotKey.optionShift) { [weak self] in
            self?.captureText()
        }
        HotKeyCenter.shared.register(id: 5, keyCode: HotKey.keyP, modifiers: HotKey.optionShift) { [weak self] in
            self?.capturePin()
        }

        if !CaptureEngine.hasPermission { CGRequestScreenCaptureAccess() }
        Log.write("launched, screen permission: \(CaptureEngine.hasPermission)")
        TextGrab.warmUp()
        EditStore.prune()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("About Snapper", #selector(menuAbout)))
        menu.addItem(.separator())
        menu.addItem(item("Capture Region or Window   (or §)", #selector(menuCapture), key: "c"))
        menu.addItem(item("Capture Full Screen", #selector(menuFullScreen), key: "f"))
        menu.addItem(item("Scrolling Capture", #selector(menuScrolling), key: "s"))
        menu.addItem(item("Grab Text", #selector(menuText), key: "t"))
        menu.addItem(item("Pin Region to Screen", #selector(menuPin), key: "p"))
        if PinController.shared.count > 0 {
            menu.addItem(item("Close All Pins (\(PinController.shared.count))", #selector(menuClosePins)))
        }
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
                      modifiers: NSEvent.ModifierFlags = [.option, .shift]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    @objc private func menuCapture() { afterMenuCloses { self.captureInteractive() } }
    @objc private func menuFullScreen() { afterMenuCloses { self.captureFullScreen() } }
    @objc private func menuScrolling() { afterMenuCloses { self.captureScrolling() } }
    @objc private func menuText() { afterMenuCloses { self.captureText() } }
    @objc private func menuPin() { afterMenuCloses { self.capturePin() } }
    @objc private func menuClosePins() { PinController.shared.closeAll() }
    @objc private func menuHistory() { HistoryWindowController.shared.show() }
    @objc private func menuOpenFolder() {
        try? FileManager.default.createDirectory(at: FileStore.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(FileStore.folder)
    }
    @objc private func menuOpenRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { EditorWindowController.open(file: url) }
    }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuAbout() {
        let body = NSMutableParagraphStyle()
        body.alignment = .center
        body.paragraphSpacing = 4
        let credits = NSAttributedString(
            string: "Developed by Jawaz Illavia\n\nScreenshots straight to the clipboard:\nregion, window, full screen and scrolling.\n\nBuilt with Claude Code.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: body])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Snapper", .credits: credits])
    }

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

    /// Pick an area and copy the text in it.
    func captureText() {
        guard !OverlayController.isActive, !ScrollSession.isActive else { return }
        Task {
            do {
                guard let picked = try await OverlayController.pick(hint: "Drag over the text to copy") else { return }
                guard let image = picked.frozen.crop(picked.rect) else { return }
                await deliverText(from: image)
            } catch { report(error) }
        }
    }

    func deliverText(from image: CGImage) async {
        let began = Date()
        let text = await TextGrab.recognise(image)
        Log.write("text: recognition took \(Int(Date().timeIntervalSince(began) * 1000)) ms")
        guard !text.isEmpty else {
            Log.write("text: nothing recognised in \(image.width)x\(image.height)")
            Toast.show("No text found", detail: "Try a tighter or larger selection.", warn: true)
            return
        }
        let copied = TextGrab.copy(text)
        Log.write("text: \(text.count) characters, clipboard=\(copied)")
        Toast.show(copied ? "Text copied" : "Could not copy text", detail: String(text.prefix(160)), warn: !copied)
    }

    /// Pick an area and keep it floating on screen where it was.
    func capturePin() {
        guard !OverlayController.isActive, !ScrollSession.isActive else { return }
        Task {
            do {
                guard let picked = try await OverlayController.pick(hint: "Drag over the area to pin") else { return }
                pin(picked.rect, of: picked.frozen)
            } catch { report(error) }
        }
    }

    private func pin(_ rect: CGRect, of frozen: Frozen) {
        guard let image = frozen.crop(rect), let shot = Shot(image: image, scale: frozen.scale) else { return }
        let screen = frozen.screen
        let origin = NSPoint(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY)
        PinController.shared.pin(shot, at: origin)
    }

    /// Direct rectangle capture with no overlay, used by the snapper:// URL hook.
    func captureRect(_ rect: CGRect, on screen: NSScreen) {
        Task {
            do {
                let (image, scale) = try await CaptureEngine.captureRect(rect, on: screen)
                CaptureEngine.includeOwnWindows = false
                deliver(image, scale: scale, kind: "rect")
            } catch { report(error) }
        }
    }

    func deliver(_ image: CGImage, scale: CGFloat, kind: String) {
        let began = Date()
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
        Log.write("\(kind): encode, clipboard and save took \(Int(Date().timeIntervalSince(began) * 1000)) ms")

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

    /// Opens Snapper's own menu and photographs it, since a menu closes the moment any shortcut is pressed.
    private func menuShot(to path: String) {
        let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                defer { self?.statusItem.menu?.cancelTracking() }
                let pid = Int(ProcessInfo.processInfo.processIdentifier)
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                var area = CGRect.null
                for info in list where (info[kCGWindowOwnerPID as String] as? Int) == pid
                    && (info[kCGWindowLayer as String] as? Int ?? 0) >= 25 {
                    if let dict = info[kCGWindowBounds as String] as? NSDictionary,
                       let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) { area = area.union(bounds) }
                }
                guard !area.isNull else { Log.write("menushot: menu not found"); return }
                let screen = NSScreen.screens.first(where: {
                    CGRect(origin: $0.quartzOrigin, size: $0.frame.size).contains(CGPoint(x: area.midX, y: area.midY))
                }) ?? NSScreen.screens[0]
                var local = area.offsetBy(dx: -screen.quartzOrigin.x, dy: -screen.quartzOrigin.y).insetBy(dx: -14, dy: -14)
                local = CGRect(x: local.minX, y: 0, width: local.width, height: local.maxY)
                CaptureEngine.includeOwnWindows = true
                defer { CaptureEngine.includeOwnWindows = false }
                guard let frozen = try? await CaptureEngine.captureDisplay(screen), let image = frozen.crop(local),
                      let shot = Shot(image: image, scale: frozen.scale) else { return }
                try? shot.png.write(to: URL(fileURLWithPath: path))
                Log.write("menushot: \(image.width)x\(image.height)")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusItem.button?.performClick(nil)
    }

    // MARK: URL hook (snapper://capture, snapper://fullscreen, snapper://scroll, snapper://rect?x=&y=&w=&h=)

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "snapper" {
            switch url.host {
            case "capture": captureInteractive()
            case "fullscreen": captureFullScreen()
            case "scroll": captureScrolling()
            case "history": HistoryWindowController.shared.show()
            case "about": menuAbout()
            case "scrolldone": ScrollSession.finishCurrent()
            case "selftest":
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                SelfTest.run(kind: items.first(where: { $0.name == "kind" })?.value ?? "", items: items, delegate: self)
            case "open":
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if let path = items.first(where: { $0.name == "path" })?.value {
                    EditorWindowController.open(file: URL(fileURLWithPath: path))
                }
            case "text": captureText()
            case "menushot":
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if let path = items.first(where: { $0.name == "path" })?.value { menuShot(to: path) }
            case "pin": capturePin()
            case "closepins": PinController.shared.closeAll()
            case "rect", "scrollrect", "textrect", "pinrect":
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                func value(_ name: String) -> CGFloat {
                    CGFloat(Double(items.first(where: { $0.name == name })?.value ?? "") ?? 0)
                }
                // Coordinates are global, top-left origin of the primary display.
                let global = CGRect(x: value("x"), y: value("y"), width: value("w"), height: value("h"))
                guard global.width > 0, global.height > 0 else { break }
                let screen = NSScreen.screens.first(where: {
                    CGRect(origin: $0.quartzOrigin, size: $0.frame.size).contains(CGPoint(x: global.midX, y: global.midY))
                }) ?? NSScreen.screens[0]
                let rect = global.offsetBy(dx: -screen.quartzOrigin.x, dy: -screen.quartzOrigin.y)
                if url.host == "rect" {
                    CaptureEngine.includeOwnWindows = items.contains(where: { $0.name == "own" })
                    captureRect(rect, on: screen)
                } else if url.host == "textrect" || url.host == "pinrect" {
                    let wantsText = url.host == "textrect"
                    Task {
                        guard let frozen = try? await CaptureEngine.captureDisplay(screen) else { return }
                        if wantsText {
                            if let image = frozen.crop(rect) { await self.deliverText(from: image) }
                        } else {
                            self.pin(rect, of: frozen)
                        }
                    }
                } else {
                    ScrollSession.start(rect: rect, screen: screen) { [weak self] image, scale in
                        self?.deliver(image, scale: scale, kind: "scrolling")
                    }
                }
            default: break
            }
        }
    }
}
