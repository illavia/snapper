import AppKit

/// Drives the picker and the editor with synthetic mouse events so they can be checked without a person.
/// Reached through snapper://selftest?kind=region|window|editor.
@MainActor
enum SelfTest {
    static func run(kind: String, items: [URLQueryItem], delegate: AppDelegate) {
        func number(_ name: String, _ fallback: CGFloat) -> CGFloat {
            items.first(where: { $0.name == name })?.value.flatMap(Double.init).map { CGFloat($0) } ?? fallback
        }
        let snapshot = items.first(where: { $0.name == "snapshot" })?.value

        switch kind {
        case "region", "window":
            delegate.captureInteractive()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                // x and y are global, top-left origin of the primary display.
                let gx = number("x", 300), gy = number("y", 200), w = number("w", 500), h = number("h", 300)
                let screen = NSScreen.screens.first(where: {
                    CGRect(origin: $0.quartzOrigin, size: $0.frame.size).contains(CGPoint(x: gx, y: gy))
                }) ?? NSScreen.screens[0]
                guard let window = NSApp.windows.first(where: { $0.level == .screenSaver && $0.frame == screen.frame }),
                      let view = window.contentView?.subviews.first else {
                    Log.write("selftest: overlay did not appear")
                    return
                }
                let x = gx - screen.quartzOrigin.x, y = gy - screen.quartzOrigin.y
                let height = view.bounds.height
                func event(_ type: NSEvent.EventType, _ px: CGFloat, _ py: CGFloat) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: NSPoint(x: px, y: height - py), modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                view.mouseMoved(with: event(.mouseMoved, x, y))
                if kind == "region" {
                    view.mouseDown(with: event(.leftMouseDown, x, y))
                    view.mouseDragged(with: event(.leftMouseDragged, x + w / 2, y + h / 2))
                    view.mouseDragged(with: event(.leftMouseDragged, x + w, y + h))
                }
                view.display()
                if let snapshot { save(view: window.contentView!, to: snapshot) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if kind == "region" {
                        view.mouseUp(with: event(.leftMouseUp, x + w, y + h))
                    } else {
                        view.mouseDown(with: event(.leftMouseDown, x, y))
                        view.mouseUp(with: event(.leftMouseUp, x, y))
                    }
                }
            }

        case "editor":
            guard let path = items.first(where: { $0.name == "path" })?.value else { return }
            EditorWindowController.open(file: URL(fileURLWithPath: path))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let window = NSApp.windows.first(where: { $0.isVisible && findCanvas(in: $0.contentView) != nil }),
                      let canvas = findCanvas(in: window.contentView) else {
                    Log.write("selftest: editor did not open")
                    return
                }
                func event(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) -> NSEvent {
                    let inWindow = canvas.convert(p, to: nil)
                    return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: clicks, pressure: 1)!
                }
                func drag(_ tool: Tool, _ a: CGPoint, _ b: CGPoint) {
                    canvas.tool = tool
                    canvas.mouseDown(with: event(.leftMouseDown, a))
                    canvas.mouseDragged(with: event(.leftMouseDragged, b))
                    canvas.mouseUp(with: event(.leftMouseUp, b))
                }
                let size = canvas.bounds.size
                func at(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: size.width * fx, y: size.height * fy) }

                drag(.arrow, at(0.15, 0.2), at(0.4, 0.4))
                drag(.box, at(0.5, 0.15), at(0.85, 0.4))
                drag(.highlight, at(0.1, 0.55), at(0.6, 0.65))
                drag(.blur, at(0.3, 0.05), at(0.75, 0.13))
                canvas.tool = .step
                for p in [at(0.7, 0.6), at(0.8, 0.6), at(0.9, 0.6)] {
                    canvas.mouseDown(with: event(.leftMouseDown, p))
                    canvas.mouseUp(with: event(.leftMouseUp, p))
                }
                canvas.tool = .text
                canvas.mouseDown(with: event(.leftMouseDown, at(0.15, 0.8)))
                if let field = canvas.subviews.compactMap({ $0 as? NSTextField }).first {
                    field.stringValue = "Snapper text"
                    window.makeFirstResponder(canvas) // ends editing, which commits the text
                }
                // Move the box, undo the move, then crop a little off every edge.
                canvas.tool = .select
                canvas.mouseDown(with: event(.leftMouseDown, at(0.5, 0.25)))
                canvas.mouseDragged(with: event(.leftMouseDragged, at(0.55, 0.3)))
                canvas.mouseUp(with: event(.leftMouseUp, at(0.55, 0.3)))
                canvas.undo(nil)
                drag(.crop, at(0.03, 0.03), at(0.97, 0.97))
                canvas.tool = .select
                canvas.display()

                Log.write("selftest: editor annotations=\(canvas.annotations.count) size=\(canvas.image.width)x\(canvas.image.height)")
                if let snapshot { save(view: window.contentView!, to: snapshot) }
                canvas.copy(nil)
                if items.contains(where: { $0.name == "close" }) { window.performClose(nil) }
            }
        case "reopen":
            // Reopen an edited capture: the marks should be back and still editable.
            guard let path = items.first(where: { $0.name == "path" })?.value else { return }
            EditorWindowController.open(file: URL(fileURLWithPath: path))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let window = NSApp.windows.first(where: { $0.isVisible && findCanvas(in: $0.contentView) != nil }),
                      let canvas = findCanvas(in: window.contentView) else {
                    Log.write("selftest: editor did not open")
                    return
                }
                Log.write("selftest: reopened with \(canvas.annotations.count) marks, crop=\(canvas.crop != nil), size=\(canvas.image.width)x\(canvas.image.height)")
                if items.contains(where: { $0.name == "deletefirst" }), let first = canvas.annotations.first {
                    canvas.tool = .select
                    let p = first.kind == .arrow ? first.start : CGPoint(x: first.bounds.midX, y: first.bounds.midY)
                    let inWindow = canvas.convert(p, to: nil)
                    func event(_ type: NSEvent.EventType) -> NSEvent {
                        NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: 1)!
                    }
                    canvas.mouseDown(with: event(.leftMouseDown))
                    canvas.mouseUp(with: event(.leftMouseUp))
                    if let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, characters: "\u{7F}",
                                                     charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51) {
                        canvas.keyDown(with: delete)
                    }
                    Log.write("selftest: after deleting one, \(canvas.annotations.count) marks")
                }
                if items.contains(where: { $0.name == "revert" }) {
                    for case let button as NSButton in allViews(in: window.contentView) where button.title == "Revert" {
                        button.performClick(nil)
                    }
                    Log.write("selftest: after revert, \(canvas.annotations.count) marks, crop=\(canvas.crop != nil), size=\(canvas.image.width)x\(canvas.image.height)")
                }
                if let snapshot { save(view: window.contentView!, to: snapshot) }
                window.performClose(nil)
            }
        default: break
        }
    }

    private static func allViews(in view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { allViews(in: $0) }
    }

    private static func findCanvas(in view: NSView?) -> CanvasView? {
        guard let view else { return nil }
        if let canvas = view as? CanvasView { return canvas }
        for sub in view.subviews { if let found = findCanvas(in: sub) { return found } }
        return nil
    }

    private static func save(view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
