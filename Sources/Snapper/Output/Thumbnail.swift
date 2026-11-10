import AppKit

/// Small floating preview after a capture. Click opens it, drag drops the file, otherwise it fades.
@MainActor
final class ThumbnailController {
    static let shared = ThumbnailController()

    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?

    func show(image: NSImage, file: URL?, warning: String? = nil, onClick: @escaping () -> Void) {
        dismiss(animated: false)

        let maxSize = NSSize(width: 240, height: 160)
        let ratio = min(maxSize.width / max(image.size.width, 1), maxSize.height / max(image.size.height, 1), 1)
        let size = NSSize(width: max(image.size.width * ratio, 60), height: max(image.size.height * ratio, 40))
        let padding: CGFloat = 6
        let footer: CGFloat = warning == nil ? 0 : 20
        let frameSize = NSSize(width: size.width + padding * 2, height: size.height + padding * 2 + footer)

        let visible = NSScreen.underMouse.visibleFrame
        let origin = NSPoint(x: visible.maxX - frameSize.width - 20, y: visible.minY + 20)

        let panel = NSPanel(contentRect: NSRect(origin: origin, size: frameSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false

        let view = ThumbnailView(frame: NSRect(origin: .zero, size: frameSize))
        view.image = image
        view.imageRect = NSRect(x: padding, y: padding + footer, width: size.width, height: size.height)
        view.file = file
        view.warning = warning
        view.onClick = { [weak self] in
            self?.dismiss(animated: false)
            onClick()
        }
        view.onHover = { [weak self] inside in
            if inside { self?.dismissWork?.cancel() } else { self?.scheduleDismiss(after: 3) }
        }
        view.onDragEnded = { [weak self] in self?.dismiss(animated: true) }
        panel.contentView = view

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        scheduleDismiss(after: warning == nil ? 6 : 12)
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss(animated: true) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func dismiss(animated: Bool) {
        dismissWork?.cancel()
        dismissWork = nil
        guard let panel else { return }
        self.panel = nil
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}

private final class ThumbnailView: NSView, NSDraggingSource {
    var image: NSImage?
    var imageRect: NSRect = .zero
    var file: URL?
    var warning: String?
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDragEnded: (() -> Void)?

    private var downPoint: NSPoint?
    private var didDrag = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        background.fill()
        NSColor.separatorColor.setStroke()
        background.stroke()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: imageRect, xRadius: 4, yRadius: 4).addClip()
        image?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        if let warning {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.systemRed,
            ]
            NSAttributedString(string: warning, attributes: attributes).draw(at: NSPoint(x: 8, y: 6))
        }
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag, let down = downPoint, let file, let image else { return }
        let p = event.locationInWindow
        guard hypot(p.x - down.x, p.y - down.y) > 4 else { return }
        didDrag = true
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        item.setDraggingFrame(imageRect, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { onClick?() }
        downPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] { onDragEnded?() }
    }
}
