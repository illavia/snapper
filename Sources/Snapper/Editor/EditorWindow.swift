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

    static func open(shot: Shot, file: URL?) {
        let controller = EditorWindowController(image: shot.image, scale: shot.scale, file: file)
        open.append(controller)
        controller.show()
    }

    static func open(file: URL) {
        if let existing = open.first(where: { $0.file == file }) {
            NSApp.activate(ignoringOtherApps: true)
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            NSWorkspace.shared.open(file)
            return
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        let controller = EditorWindowController(image: image, scale: dpi >= 140 ? 2 : 1, file: file)
        open.append(controller)
        controller.show()
    }

    private init(image: CGImage, scale: CGFloat, file: URL?) {
        self.file = file
        canvas = CanvasView(image: image, scale: scale)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = file?.deletingPathExtension().lastPathComponent ?? "Capture"
        buildContent()

        canvas.onToolKey = { [weak self] tool in self?.select(tool) }
        canvas.onCopy = { [weak self] in self?.copyImage() }
        canvas.onSave = { [weak self] in self?.save() }
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
        colorWell.toolTip = "Colour"

        let undo = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo")!,
                            target: canvas, action: #selector(CanvasView.undo(_:)))
        undo.bezelStyle = .texturedRounded
        undo.toolTip = "Undo (⌘Z)"
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyClicked))
        copy.bezelStyle = .texturedRounded
        copy.toolTip = "Copy the marked-up image (⌘C)"
        copy.keyEquivalent = "\r"
        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        save.bezelStyle = .texturedRounded
        save.toolTip = "Save over the capture file (⌘S)"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [tools, colorWell, undo, spacer, save, copy])
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
        let available = scrollView.contentSize
        let fit = min(available.width / max(imageSize.width, 1), available.height / max(imageSize.height, 1), 1)
        scrollView.magnification = max(fit * 0.98, scrollView.minMagnification)
        window.makeFirstResponder(canvas)
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

    private func currentShot() -> Shot? {
        canvas.flattened().flatMap { Shot(image: $0, scale: canvas.scale) }
    }

    private func copyImage() {
        guard let shot = currentShot() else { return }
        let copied = Clipboard.copy(shot)
        Log.write("editor: copy \(shot.image.width)x\(shot.image.height) clipboard=\(copied)")
        flashTitle(copied ? "Copied" : "Could not copy")
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
        // Keep the marked-up version rather than lose it; the edit is undoable until this point.
        if canvas.isModified { save() }
        Self.open.removeAll { $0 === self }
        DockPresence.windowClosed()
    }
}

/// Keeps a small image centred in the scroll view.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if document.frame.width < rect.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if document.frame.height < rect.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}
