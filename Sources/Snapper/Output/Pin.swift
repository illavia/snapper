import AppKit

/// Keeps a capture floating above every other window as a reference.
/// Drag to move, scroll to resize, double-click or Esc to close, right-click for more.
@MainActor
final class PinController {
    static let shared = PinController()

    private var pins: [PinWindow] = []
    var count: Int { pins.count }

    /// `origin` is the bottom-left corner in AppKit screen coordinates; nil centres it under the mouse.
    func pin(_ shot: Shot, at origin: NSPoint?) {
        let size = shot.nsImage.size
        let screen = NSScreen.underMouse.visibleFrame
        let position = origin ?? NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
        let window = PinWindow(shot: shot, frame: NSRect(origin: position, size: size))
        window.onClose = { [weak self, weak window] in
            self?.pins.removeAll { $0 === window }
        }
        pins.append(window)
        window.orderFrontRegardless()
        Log.write("pin: \(shot.image.width)x\(shot.image.height), \(pins.count) pinned")
    }

    func closeAll() {
        for pin in pins { pin.orderOut(nil) }
        pins.removeAll()
    }
}

private final class PinWindow: NSPanel {
    var onClose: (() -> Void)?
    private let shot: Shot

    init(shot: Shot, frame: NSRect) {
        self.shot = shot
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        aspectRatio = frame.size
        let view = PinView(frame: NSRect(origin: .zero, size: frame.size))
        view.image = shot.nsImage
        view.autoresizingMask = [.width, .height]
        view.owner = self
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    func closePin() {
        orderOut(nil)
        onClose?()
    }

    func copyImage() {
        let copied = Clipboard.copy(shot)
        Toast.show(copied ? "Copied" : "Could not copy", warn: !copied)
    }

    func openInEditor() {
        EditorWindowController.open(shot: shot, file: nil)
    }

    func resize(by factor: CGFloat) {
        let base = shot.nsImage.size
        let width = min(max(frame.width * factor, max(base.width * 0.2, 60)), base.width * 4)
        let height = width * base.height / base.width
        // Grow and shrink around the centre.
        let origin = NSPoint(x: frame.midX - width / 2, y: frame.midY - height / 2)
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closePin() } else { super.keyDown(with: event) }
    }
}

private final class PinView: NSView {
    var image: NSImage?
    weak var owner: PinWindow?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            owner?.closePin()
        } else {
            owner?.makeKey()
            super.mouseDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }
        owner?.resize(by: 1 + max(min(event.scrollingDeltaY, 20), -20) * 0.01)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = menu.addItem(withTitle: "Copy", action: #selector(copyClicked), keyEquivalent: "")
        copy.target = self
        let edit = menu.addItem(withTitle: "Open in Editor", action: #selector(editClicked), keyEquivalent: "")
        edit.target = self
        menu.addItem(.separator())
        let close = menu.addItem(withTitle: "Close Pin", action: #selector(closeClicked), keyEquivalent: "")
        close.target = self
        return menu
    }

    @objc private func copyClicked() { owner?.copyImage() }
    @objc private func editClicked() { owner?.openInEditor() }
    @objc private func closeClicked() { owner?.closePin() }
}
