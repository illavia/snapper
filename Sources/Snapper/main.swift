import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.mainMenu = MainMenu.build()
    // The delegate must outlive this closure; NSApplication holds it weakly.
    withExtendedLifetime(delegate) { app.run() }
}
