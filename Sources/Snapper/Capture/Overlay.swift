import AppKit

/// Full-screen picker shown over a frozen image of each display.
/// Hover highlights a window, click takes it, drag takes a region, Esc cancels.
@MainActor
final class OverlayController {
    struct Result {
        let frozen: Frozen
        /// Points, top-left origin, relative to the display.
        let rect: CGRect
    }

    private static var active: OverlayController?
    static var isActive: Bool { active != nil }

    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<Result?, Never>?
    private var previousApp: NSRunningApplication?

    static func pick(allowWindows: Bool = true, hint: String? = nil) async throws -> Result? {
        guard active == nil else { return nil }
        let controller = OverlayController()
        active = controller
        defer { active = nil }
        let windowFrames = allowWindows ? WindowFinder.visibleWindowFrames() : []
        var frozens: [Frozen] = []
        for screen in NSScreen.screens {
            frozens.append(try await CaptureEngine.captureDisplay(screen))
        }
        return await controller.show(frozens, windowFrames: windowFrames, hint: hint)
    }

    private func show(_ frozens: [Frozen], windowFrames: [CGRect], hint: String?) async -> Result? {
        previousApp = NSWorkspace.shared.frontmostApplication
        let mouseScreen = NSScreen.underMouse
        for frozen in frozens {
            let screen = frozen.screen
            let origin = screen.quartzOrigin
            let bounds = CGRect(origin: .zero, size: screen.frame.size)
            let local = windowFrames
                .map { $0.offsetBy(dx: -origin.x, dy: -origin.y).intersection(bounds) }
                .filter { !$0.isNull && $0.width >= 40 && $0.height >= 30 }

            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false

            let container = NSView(frame: bounds)
            container.wantsLayer = true
            container.layer?.contents = frozen.image
            container.layer?.contentsGravity = .resize

            let view = OverlayView(frame: bounds, frozen: frozen, windowRects: local, hint: hint)
            view.autoresizingMask = [.width, .height]
            view.onFinish = { [weak self] rect in
                self?.finish(rect.map { Result(frozen: frozen, rect: $0) })
            }
            container.addSubview(view)
            window.contentView = container
            window.initialFirstResponder = view
            windows.append(window)
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            NSApp.activate(ignoringOtherApps: true)
            for window in windows where window.screen != mouseScreen { window.orderFrontRegardless() }
            let key = windows.first(where: { $0.frame == mouseScreen.frame }) ?? windows.first
            key?.makeKeyAndOrderFront(nil)
            if let view = key?.contentView?.subviews.first { key?.makeFirstResponder(view) }
        }
    }

    private func finish(_ result: Result?) {
        guard let continuation else { return }
        self.continuation = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        previousApp?.activate()
        continuation.resume(returning: result)
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class OverlayView: NSView {
    var onFinish: ((CGRect?) -> Void)?

    private let frozen: Frozen
    private let windowRects: [CGRect]
    private let hint: String?
    private var mouse: CGPoint?
    private var dragStart: CGPoint?
    private var isDragging = false

    init(frame: CGRect, frozen: Frozen, windowRects: [CGRect], hint: String?) {
        self.frozen = frozen
        self.windowRects = windowRects
        self.hint = hint
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    // MARK: State

    private var hoverRect: CGRect? {
        guard let mouse else { return nil }
        return windowRects.first(where: { $0.contains(mouse) })
    }

    private var dragRect: CGRect? {
        guard isDragging, let start = dragStart, let mouse else { return nil }
        return CGRect(x: min(start.x, mouse.x), y: min(start.y, mouse.y),
                      width: abs(mouse.x - start.x), height: abs(mouse.y - start.y))
            .intersection(bounds)
    }

    private var currentRect: CGRect? { isDragging ? dragRect : (dragStart == nil ? hoverRect : nil) }

    // MARK: Events

    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = point(event)
        if window?.isKeyWindow == false { window?.makeKey() }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        if dragStart == nil { mouse = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        mouse = point(event)
        dragStart = mouse
        isDragging = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        mouse = point(event)
        if let start = dragStart, let mouse, hypot(mouse.x - start.x, mouse.y - start.y) > 4 { isDragging = true }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouse = point(event)
        if let rect = dragRect, rect.width >= 3, rect.height >= 3 {
            onFinish?(pixelAligned(rect))
            return
        }
        dragStart = nil
        isDragging = false
        if let rect = hoverRect {
            onFinish?(rect)
            return
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) { onFinish?(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } // Esc
    }

    private func pixelAligned(_ rect: CGRect) -> CGRect {
        let s = frozen.scale
        let x0 = (rect.minX * s).rounded() / s, y0 = (rect.minY * s).rounded() / s
        let x1 = (rect.maxX * s).rounded() / s, y1 = (rect.maxY * s).rounded() / s
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let hole = currentRect
        let dim = NSBezierPath(rect: bounds)
        if let hole {
            dim.append(NSBezierPath(rect: hole))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.35).setFill()
        dim.fill()

        if let hole {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: hole.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
            let s = frozen.scale
            drawLabel("\(Int((hole.width * s).rounded())) × \(Int((hole.height * s).rounded()))",
                      near: CGPoint(x: hole.minX, y: hole.maxY + 6), fallbackInside: hole)
        }

        if let mouse {
            if !isDragging {
                NSColor.white.withAlphaComponent(0.6).setFill()
                NSRect(x: mouse.x, y: 0, width: 0.5, height: bounds.height).fill()
                NSRect(x: 0, y: mouse.y, width: bounds.width, height: 0.5).fill()
            }
            drawLoupe(at: mouse)
        }

        if let hint, dragStart == nil {
            drawLabel(hint, near: CGPoint(x: bounds.midX - 150, y: 40), fallbackInside: nil, size: 14)
        }
    }

    private func drawLabel(_ text: String, near point: CGPoint, fallbackInside rect: CGRect?, size: CGFloat = 11) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        var box = CGRect(x: point.x, y: point.y, width: textSize.width + 12, height: textSize.height + 6)
        if box.maxY > bounds.maxY - 4, let rect { box.origin.y = rect.maxY - box.height - 6; box.origin.x = rect.minX + 6 }
        if box.maxX > bounds.maxX - 4 { box.origin.x = bounds.maxX - box.width - 4 }
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        string.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3))
    }

    /// Magnified view of the pixels under the cursor, for accurate edges.
    private func drawLoupe(at mouse: CGPoint) {
        let pixelsAcross = 15
        let side: CGFloat = 120
        let s = frozen.scale
        let centre = CGPoint(x: (mouse.x * s).rounded(.down), y: (mouse.y * s).rounded(.down))
        let source = CGRect(x: centre.x - CGFloat(pixelsAcross / 2), y: centre.y - CGFloat(pixelsAcross / 2),
                            width: CGFloat(pixelsAcross), height: CGFloat(pixelsAcross))

        var box = CGRect(x: mouse.x + 18, y: mouse.y + 18, width: side, height: side)
        if box.maxX > bounds.maxX - 4 { box.origin.x = mouse.x - 18 - side }
        if box.maxY > bounds.maxY - 26 { box.origin.y = mouse.y - 18 - side }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).addClip()
        NSColor.black.setFill()
        box.fill()
        let imageBounds = CGRect(x: 0, y: 0, width: frozen.image.width, height: frozen.image.height)
        let clipped = source.intersection(imageBounds)
        if !clipped.isNull, clipped.width >= 1, clipped.height >= 1, let crop = frozen.image.cropping(to: clipped) {
            let cell = side / CGFloat(pixelsAcross)
            let dest = CGRect(x: box.minX + (clipped.minX - source.minX) * cell,
                              y: box.minY + (clipped.minY - source.minY) * cell,
                              width: clipped.width * cell, height: clipped.height * cell)
            NSImage(cgImage: crop, size: clipped.size)
                .draw(in: dest, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                      hints: [.interpolation: NSNumber(value: NSImageInterpolation.none.rawValue)])
        }
        let cell = side / CGFloat(pixelsAcross)
        NSColor.white.setStroke()
        let middle = NSBezierPath(rect: CGRect(x: box.midX - cell / 2, y: box.midY - cell / 2, width: cell, height: cell))
        middle.lineWidth = 1
        middle.stroke()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let outline = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        outline.lineWidth = 1
        outline.stroke()

        if !isDragging {
            drawLabel("\(Int(centre.x)), \(Int(centre.y))", near: CGPoint(x: box.minX, y: box.maxY + 4),
                      fallbackInside: nil, size: 10)
        }
    }
}
