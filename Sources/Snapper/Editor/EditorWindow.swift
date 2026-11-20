import AppKit

@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    private static var open: [EditorWindowController] = []

    private let window: NSWindow
    private let canvas: CanvasView
    private let scrollView = NSScrollView()
    private let tools = NSSegmentedControl()
    private let colorWell = NSColorWell()
    private var file: URL?
    private var colourObservation: NSKeyValueObservation?
    private let zoomPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private var zoomObservers: [NSObjectProtocol] = []
    /// The capture before any marks or crop.
    private let original: CGImage
    private var originalNeedsStoring: Bool

    static func open(shot: Shot, file: URL?) {
        let controller = EditorWindowController(original: shot.image, scale: shot.scale, file: file, saved: nil)
        open.append(controller)
        controller.show()
    }

    static func open(file: URL) {
        if let existing = open.first(where: { $0.file == file }) {
            NSApp.activate(ignoringOtherApps: true)
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        if let saved = EditStore.load(file: file) {
            let controller = EditorWindowController(original: saved.original, scale: saved.scale, file: file, saved: saved)
            open.append(controller)
            controller.show()
            return
        }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)?.inMemoryCopy() else {
            NSWorkspace.shared.open(file)
            return
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        let controller = EditorWindowController(original: image, scale: dpi >= 140 ? 2 : 1, file: file, saved: nil)
        open.append(controller)
        controller.show()
    }

    private init(original: CGImage, scale: CGFloat, file: URL?, saved: EditStore.Saved?) {
        self.file = file
        self.original = original
        originalNeedsStoring = saved == nil
        canvas = CanvasView(image: original, scale: scale, annotations: saved?.annotations ?? [], crop: saved?.crop)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = file?.deletingPathExtension().lastPathComponent ?? "Capture"
        buildContent()

        canvas.onToolKey = { [weak self] tool in self?.select(tool) }
        canvas.onZoom = { [weak self] command in self?.zoom(command) }
        canvas.onSelectColor = { [weak self] colour in self?.colorWell.color = colour }
        canvas.onCopy = { [weak self] in self?.copyImage() }
        canvas.onSave = { [weak self] in self?.save() }
        canvas.onPrint = { [weak self] in self?.printImage() }
        canvas.onChange = { [weak self] in self?.window.isDocumentEdited = self?.canvas.isModified ?? false }
    }

    private func buildContent() {
        tools.segmentCount = Tool.allCases.count
        tools.trackingMode = .selectOne
        tools.segmentStyle = .texturedRounded
        for tool in Tool.allCases {
            tools.setImage(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.label), forSegment: tool.rawValue)
            tools.setToolTip(tool.label, forSegment: tool.rawValue)
            tools.setWidth(36, forSegment: tool.rawValue)
        }
        tools.target = self
        tools.action = #selector(toolChanged)
        select(.arrow)

        colorWell.color = .systemRed
        colorWell.colorWellStyle = .minimal
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorWell.isContinuous = true
        colourObservation = colorWell.observe(\.color, options: [.new]) { [weak self] well, _ in
            // Some ways of picking a colour do not send the action, so watch the value as well.
            DispatchQueue.main.async { if self?.canvas.color != well.color { self?.canvas.color = well.color } }
        }
        colorWell.toolTip = "Colour"

        let undo = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo")!,
                            target: canvas, action: #selector(CanvasView.undo(_:)))
        undo.bezelStyle = .texturedRounded
        undo.toolTip = "Undo (⌘Z)"
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyClicked))
        copy.bezelStyle = .rounded
        copy.controlSize = .large
        copy.bezelColor = .controlAccentColor
        copy.toolTip = "Copy the marked-up image (⌘C or Return)"
        copy.keyEquivalent = "\r"
        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        save.bezelStyle = .texturedRounded
        save.toolTip = "Save (⌘S). The original is kept, so marks stay editable when you reopen it"

        let print = NSButton(title: "Print", target: self, action: #selector(printClicked))
        print.bezelStyle = .texturedRounded
        print.toolTip = "Print the marked-up image (⌘P)"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let revert = NSButton(title: "Revert", target: self, action: #selector(revertClicked))
        revert.bezelStyle = .texturedRounded
        revert.toolTip = "Remove every mark and crop, back to the original capture"
        zoomPopup.bezelStyle = .texturedRounded
        zoomPopup.toolTip = "Zoom. Pinch, or use ⌘= and ⌘-"
        zoomPopup.addItem(withTitle: "100%") // shown as the button's label
        for (title, tag, key) in [("Zoom In", 1, "⌘="), ("Zoom Out", -1, "⌘-"), ("Actual Size (100%)", 0, "⌘0"),
                                  ("Fit to Window", 2, "⌘9")] {
            zoomPopup.addItem(withTitle: "\(title)    \(key)")
            zoomPopup.lastItem?.tag = tag
            zoomPopup.lastItem?.target = self
            zoomPopup.lastItem?.action = #selector(zoomMenuChosen(_:))
        }
        zoomPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        let bar = NSStackView(views: [tools, colorWell, undo, zoomPopup, spacer, revert, print, save, copy])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 38).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 8
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(bar)
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    private func show() {
        let visible = (NSScreen.underMouse).visibleFrame
        let imageSize = canvas.frame.size
        let width = min(max(imageSize.width + 40, 620), visible.width * 0.85)
        let height = min(max(imageSize.height + 100, 420), visible.height * 0.85)
        window.setContentSize(NSSize(width: width, height: height))
        window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
        DockPresence.windowOpened()
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        zoom(2)
        watchZoom()
        window.makeFirstResponder(canvas)
    }

    // MARK: Zoom

    /// The magnification at which the whole image fits, never above 100%.
    private var fitMagnification: CGFloat {
        let available = scrollView.contentSize
        let size = canvas.frame.size
        let fit = min(available.width / max(size.width, 1), available.height / max(size.height, 1), 1)
        return max(fit * 0.98, scrollView.minMagnification)
    }

    /// 1 zoom in, -1 zoom out, 0 actual size, 2 fit to window.
    private func zoom(_ command: Int) {
        let current = scrollView.magnification
        let target: CGFloat
        switch command {
        case 1: target = current * 1.25
        case -1: target = current / 1.25
        case 0: target = 1
        default: target = fitMagnification
        }
        let clamped = min(max(target, scrollView.minMagnification), scrollView.maxMagnification)
        let visible = scrollView.documentVisibleRect
        scrollView.setMagnification(clamped, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        updateZoomLabel()
    }

    @objc private func zoomMenuChosen(_ sender: NSMenuItem) {
        zoom(sender.tag)
        window.makeFirstResponder(canvas)
    }

    private func updateZoomLabel() {
        zoomPopup.item(at: 0)?.title = "\(Int((scrollView.magnification * 100).rounded()))%"
    }

    /// Pinching changes the zoom without going through `zoom`, so watch the view for it.
    private func watchZoom() {
        scrollView.contentView.postsBoundsChangedNotifications = true
        let centre = NotificationCenter.default
        for (name, object) in [(NSView.boundsDidChangeNotification, scrollView.contentView as AnyObject),
                               (NSScrollView.didEndLiveMagnifyNotification, scrollView as AnyObject)] {
            zoomObservers.append(centre.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateZoomLabel() }
            })
        }
    }

    private func select(_ tool: Tool) {
        tools.selectedSegment = tool.rawValue
        canvas.tool = tool
    }

    @objc private func toolChanged() {
        if let tool = Tool(rawValue: tools.selectedSegment) { canvas.tool = tool }
        window.makeFirstResponder(canvas)
    }

    @objc private func colorChanged() { canvas.color = colorWell.color }
    @objc private func copyClicked() { copyImage() }
    @objc private func saveClicked() { save() }
    @objc private func printClicked() { printImage() }
    @objc private func revertClicked() {
        canvas.revert(to: original)
        window.makeFirstResponder(canvas)
    }

    private func currentShot() -> Shot? {
        canvas.flattened().flatMap { Shot(image: $0, scale: canvas.scale) }
    }

    private func copyImage() {
        guard let shot = currentShot() else { return }
        let copied = Clipboard.copy(shot)
        Log.write("editor: copy \(shot.image.width)x\(shot.image.height) clipboard=\(copied)")
        Toast.show(copied ? "Copied to clipboard" : "Could not copy", warn: !copied)
    }

    /// Prints what is on screen now, saved or not.
    private func printImage() {
        guard let image = canvas.flattened() else { return }
        Printer.print(image, scale: canvas.scale, title: window.title, window: window)
    }

    @discardableResult
    private func save() -> Bool {
        guard let shot = currentShot() else { return false }
        do {
            if let file {
                try shot.png.write(to: file, options: .atomic)
            } else {
                file = try FileStore.save(shot)
            }
            if let file {
                EditStore.save(file: file, original: original, writeOriginal: originalNeedsStoring, scale: canvas.scale,
                               annotations: canvas.annotations, crop: canvas.crop)
                originalNeedsStoring = false
            }
            canvas.markSaved()
            window.isDocumentEdited = false
            Log.write("editor: saved \(file?.path ?? "")")
            flashTitle("Saved")
            HistoryWindowController.shared.reloadIfVisible()
            return true
        } catch {
            Log.write("editor: save failed: \(error.localizedDescription)")
            flashTitle("Could not save")
            return false
        }
    }

    private func flashTitle(_ text: String) {
        let base = file?.deletingPathExtension().lastPathComponent ?? "Capture"
        window.title = "\(base) — \(text)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.window.title = base }
    }

    func windowWillClose(_ notification: Notification) {
        // Save on close. Nothing is lost: the original and the marks are kept, so it can be reopened and changed.
        if canvas.isModified { save() }
        zoomObservers.forEach { NotificationCenter.default.removeObserver($0) }
        zoomObservers.removeAll()
        Self.open.removeAll { $0 === self }
        DockPresence.windowClosed()
    }
}

/// Keeps a small image centred in the scroll view.
private final class CenteringClipView: NSClipView {
    /// A click on the empty area around the image deselects, like clicking empty space inside it.
    override func mouseDown(with event: NSEvent) {
        if let canvas = documentView as? CanvasView {
            canvas.clearSelection()
            window?.makeFirstResponder(canvas)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if document.frame.width < rect.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if document.frame.height < rect.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}
