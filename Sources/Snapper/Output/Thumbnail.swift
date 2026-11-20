import AppKit

/// Small floating preview after a capture. Click opens the editor, drag drops the file,
/// hover shows Trash on the left and Edit, Pin and Close on the right, otherwise it fades.
@MainActor
final class ThumbnailController {
    static let shared = ThumbnailController()

    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?

    func show(image: NSImage, file: URL?, warning: String? = nil,
              onEdit: @escaping () -> Void, onPin: @escaping () -> Void) {
        dismiss(animated: false)

        let maxSize = NSSize(width: 240, height: 160)
        let ratio = min(maxSize.width / max(image.size.width, 1), maxSize.height / max(image.size.height, 1), 1)
        let size = NSSize(width: max(image.size.width * ratio, 150), height: max(image.size.height * ratio, 60))
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
            onEdit()
        }
        view.onPin = { [weak self] in
            self?.dismiss(animated: false)
            onPin()
        }
        view.onClose = { [weak self] in self?.dismiss(animated: true) }
        view.onTrash = { [weak self] in
            guard let file else { return }
            self?.dismiss(animated: false)
            Self.moveToTrash(file)
        }
        view.onHover = { [weak self] inside in
            if inside { self?.dismissWork?.cancel() } else { self?.scheduleDismiss(after: 3) }
        }
        view.onDragEnded = { [weak self] in self?.dismiss(animated: true) }
        view.buildButtons()
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

    /// The capture stays on the clipboard; only the saved file goes.
    static func moveToTrash(_ file: URL) {
        do {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
            EditStore.remove(for: file)
            Log.write("thumbnail: moved to Trash \(file.lastPathComponent)")
            Toast.show("Moved to Trash", warn: false)
        } catch {
            Log.write("thumbnail: could not move to Trash \(file.lastPathComponent): \(error.localizedDescription)")
            Toast.show("Could not move to Trash", warn: true)
        }
        HistoryWindowController.shared.reloadIfVisible()
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

/// A small round icon button drawn over an image.
final class OverlayIconButton: NSButton {
    init(symbol: String, tip: String, target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.88).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        layer?.borderWidth = 1
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(config)
        contentTintColor = .white
        imagePosition = .imageOnly
        toolTip = tip
        setAccessibilityLabel(tip)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

private final class ThumbnailView: NSView, NSDraggingSource {
    var image: NSImage?
    var imageRect: NSRect = .zero
    var file: URL?
    var warning: String?
    var onClick: (() -> Void)?
    var onPin: (() -> Void)?
    var onClose: (() -> Void)?
    var onTrash: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDragEnded: (() -> Void)?

    private var downPoint: NSPoint?
    private var didDrag = false
    private var buttons: [NSButton] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        setAccessibilityLabel("Latest capture. Click to edit, drag to drop the file.")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func buildButtons() {
        let specs: [(String, String, Selector)] = [
            ("pencil", "Edit", #selector(editClicked)),
            ("pin.fill", "Pin to screen", #selector(pinClicked)),
            ("xmark", "Close", #selector(closeClicked)),
        ]
        var x = imageRect.maxX - 6 - CGFloat(specs.count) * 28 - CGFloat(specs.count - 1) * 6
        for (symbol, tip, action) in specs {
            let button = OverlayIconButton(symbol: symbol, tip: tip, target: self, action: action)
            button.frame.origin = NSPoint(x: x, y: imageRect.maxY - 6 - 28)
            button.isHidden = true
            addSubview(button)
            buttons.append(button)
            x += 34
        }
        // Trash sits alone on the left, away from Close, so one is not hit for the other.
        guard file != nil else { return }
        let trash = OverlayIconButton(symbol: "trash", tip: "Move to Trash", target: self, action: #selector(trashClicked))
        trash.frame.origin = NSPoint(x: imageRect.minX + 6, y: imageRect.maxY - 6 - 28)
        trash.isHidden = true
        addSubview(trash)
        buttons.append(trash)
    }

    /// Test hook: press the Trash button as a click would.
    func pressTrashForTest() { buttons.first(where: { $0.toolTip == "Move to Trash" })?.performClick(nil) }

    @objc private func editClicked() { onClick?() }
    @objc private func pinClicked() { onPin?() }
    @objc private func closeClicked() { onClose?() }
    @objc private func trashClicked() { onTrash?() }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor(white: 0.1, alpha: 1).setFill()
        background.fill()
        NSColor.white.withAlphaComponent(0.3).setStroke()
        background.stroke()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: imageRect, xRadius: 5, yRadius: 5).addClip()
        NSColor(white: 0.18, alpha: 1).setFill()
        imageRect.fill()
        if let image {
            // Keep the picture's shape inside the frame.
            let scale = min(imageRect.width / image.size.width, imageRect.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = NSRect(x: imageRect.midX - size.width / 2, y: imageRect.midY - size.height / 2,
                              width: size.width, height: size.height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()

        if let warning {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.systemYellow,
            ]
            NSAttributedString(string: warning, attributes: attributes).draw(at: NSPoint(x: 9, y: 6))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        buttons.forEach { $0.isHidden = false }
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        buttons.forEach { $0.isHidden = true }
        onHover?(false)
    }

    /// Test hook: show the buttons as if hovered.
    func showButtonsForSnapshot() { buttons.forEach { $0.isHidden = false } }

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

extension ThumbnailController {
    /// Test hook: reveal the hover buttons so they can be photographed.
    func revealButtonsForSnapshot() {
        (panel?.contentView as? ThumbnailView)?.showButtonsForSnapshot()
    }

    /// Test hook: show the thumbnail for a file with no capture, optionally save a picture of it, then press Trash.
    func showForTest(file: URL, snapshot: String?, trash: Bool) {
        guard let image = NSImage(contentsOf: file) else { return }
        show(image: image, file: file, onEdit: {}, onPin: {})
        revealButtonsForSnapshot()
        guard let view = panel?.contentView as? ThumbnailView else { return }
        view.display()
        if let snapshot, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snapshot))
        }
        if trash { view.pressTrashForTest() }
    }
}
