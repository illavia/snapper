import AppKit

/// A menu bar app still needs a main menu so Cmd+C, Cmd+Z, Cmd+S and friends work in its windows.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: Selector(("showSettings:")), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Snapper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, to: main, title: "Snapper")

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Save", action: Selector(("saveDocument:")), keyEquivalent: "s")
        // Answered by the editor (the canvas) and by the history window. Greyed out anywhere else.
        file.addItem(withTitle: "Print…", action: Selector(("printDocument:")), keyEquivalent: "p")
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, to: main, title: "File")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, to: main, title: "Edit")

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Zoom In", action: Selector(("snapperZoomIn:")), keyEquivalent: "=")
        view.addItem(withTitle: "Zoom Out", action: Selector(("snapperZoomOut:")), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: Selector(("snapperZoomActual:")), keyEquivalent: "0")
        view.addItem(withTitle: "Fit to Window", action: Selector(("snapperZoomFit:")), keyEquivalent: "9")
        add(view, to: main, title: "View")

        return main
    }

    private static func add(_ menu: NSMenu, to main: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}

/// Shows a Dock icon only while an editor or history window is open.
@MainActor
enum DockPresence {
    private static var count = 0

    static func windowOpened() {
        count += 1
        if count == 1 { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func windowClosed() {
        count = max(count - 1, 0)
        if count == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}
