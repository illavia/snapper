import AppKit

/// Shows the capture with its annotations on top. Annotations stay editable until copy or save flattens them.
final class CanvasView: NSView, NSTextFieldDelegate {
    private(set) var image: CGImage
    let scale: CGFloat
    private(set) var annotations: [Annotation] = []
    private(set) var isModified = false

    var tool: Tool = .arrow { didSet { commitTextEditing(); selected = nil; window?.invalidateCursorRects(for: self); needsDisplay = true } }
    var color: NSColor = .systemRed
    var onToolKey: ((Tool) -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onChange: (() -> Void)?

    private var undoStack: [(CGImage, [Annotation])] = []
    private var redoStack: [(CGImage, [Annotation])] = []
    private var selected: Int?
    private var draft: Annotation?
    private var cropRect: CGRect?
    private var dragOrigin: CGPoint?
    private var lastDragPoint: CGPoint?
    private var didPushForMove = false
    private var textField: NSTextField?
    private var editingIndex: Int?

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        super.init(frame: NSRect(origin: .zero, size: Self.pointSize(image, scale)))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func pointSize(_ image: CGImage, _ scale: CGFloat) -> NSSize {
        NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { Self.pointSize(image, scale) }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .select ? .arrow : (tool == .text ? .iBeam : .crosshair))
    }

    // MARK: Undo

    private func pushUndo() {
        undoStack.append((image, annotations))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        isModified = true
        onChange?()
    }

    @objc func undo(_ sender: Any?) {
        commitTextEditing()
        guard let state = undoStack.popLast() else { return }
        redoStack.append((image, annotations))
        restore(state)
    }

    @objc func redo(_ sender: Any?) {
        guard let state = redoStack.popLast() else { return }
        undoStack.append((image, annotations))
        restore(state)
    }

    private func restore(_ state: (CGImage, [Annotation])) {
        image = state.0
        annotations = state.1
        selected = nil
        isModified = true
        resizeToImage()
        onChange?()
    }

    private func resizeToImage() {
        setFrameSize(Self.pointSize(image, scale))
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func markSaved() { isModified = false }

    // MARK: Menu actions

    @objc func copy(_ sender: Any?) { onCopy?() }
    @objc func saveDocument(_ sender: Any?) { onSave?() }

    // MARK: Mouse

    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if textField != nil { commitTextEditing(); return }
        let p = point(event)
        dragOrigin = p
        lastDragPoint = p
        didPushForMove = false

        switch tool {
        case .select:
            selected = annotations.indices.reversed().first(where: { annotations[$0].hit(p) })
            if event.clickCount == 2, let index = selected, annotations[index].kind == .text {
                beginTextEditing(at: annotations[index].start, existing: index)
            }
        case .arrow: draft = Annotation(kind: .arrow, start: p, end: p, color: color)
        case .box: draft = Annotation(kind: .box, start: p, end: p, color: color)
        case .highlight: draft = Annotation(kind: .highlight, start: p, end: p, color: color)
        case .step:
            pushUndo()
            let next = (annotations.filter { $0.kind == .step }.map(\.number).max() ?? 0) + 1
            annotations.append(Annotation(kind: .step, start: p, end: p, color: color, number: next))
        case .text:
            beginTextEditing(at: CGPoint(x: p.x, y: p.y - 11), existing: nil)
        case .crop:
            cropRect = CGRect(origin: p, size: .zero)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        guard let origin = dragOrigin else { return }
        switch tool {
        case .select:
            if let index = selected, let last = lastDragPoint {
                if !didPushForMove { pushUndo(); didPushForMove = true }
                annotations[index].move(by: CGPoint(x: p.x - last.x, y: p.y - last.y))
            }
        case .arrow, .box, .highlight:
            draft?.end = p
        case .crop:
            cropRect = CGRect(x: min(origin.x, p.x), y: min(origin.y, p.y),
                              width: abs(p.x - origin.x), height: abs(p.y - origin.y))
        default: break
        }
        lastDragPoint = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil; lastDragPoint = nil; needsDisplay = true }
        if let finished = draft {
            draft = nil
            let big = finished.kind == .arrow
                ? hypot(finished.end.x - finished.start.x, finished.end.y - finished.start.y) > 6
                : (finished.bounds.width > 4 && finished.bounds.height > 4)
            if big {
                pushUndo()
                annotations.append(finished)
            }
        }
        if tool == .crop, let rect = cropRect {
            cropRect = nil
            applyCrop(rect)
        }
    }

    private func applyCrop(_ rect: CGRect) {
        guard rect.width >= 8, rect.height >= 8 else { return }
        let pixels = CGRect(x: (rect.minX * scale).rounded(), y: (rect.minY * scale).rounded(),
                            width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixels.width >= 2, pixels.height >= 2, let cropped = image.cropping(to: pixels) else { return }
        pushUndo()
        image = cropped
        let shift = CGPoint(x: -pixels.minX / scale, y: -pixels.minY / scale)
        for index in annotations.indices { annotations[index].move(by: shift) }
        resizeToImage()
        onChange?()
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if event.keyCode == 51 || event.keyCode == 117, let index = selected { // delete
                pushUndo()
                annotations.remove(at: index)
                selected = nil
                needsDisplay = true
                return
            }
            if event.keyCode == 53 { // esc
                selected = nil; draft = nil; cropRect = nil
                needsDisplay = true
                return
            }
            if let characters = event.charactersIgnoringModifiers?.lowercased(),
               let match = Tool.allCases.first(where: { $0.key == characters }) {
                onToolKey?(match)
                return
            }
        }
        super.keyDown(with: event)
    }

    // MARK: Text

    private func beginTextEditing(at origin: CGPoint, existing: Int?) {
        let field = NSTextField(frame: NSRect(x: origin.x - 2, y: origin.y - 2, width: 260, height: 28))
        field.font = Annotation.textFont
        field.textColor = existing.map { annotations[$0].color } ?? color
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.85)
        field.focusRingType = .none
        field.delegate = self
        field.stringValue = existing.map { annotations[$0].text } ?? ""
        field.placeholderString = "Type, then press Return"
        addSubview(field)
        textField = field
        editingIndex = existing
        window?.makeFirstResponder(field)
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitTextEditing() }

    private func commitTextEditing() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = CGPoint(x: field.frame.minX + 2, y: field.frame.minY + 2)
        let fieldColor = field.textColor ?? color
        field.removeFromSuperview()
        if let index = editingIndex, index < annotations.count {
            if text != annotations[index].text {
                pushUndo()
                if text.isEmpty { annotations.remove(at: index) } else { annotations[index].text = text }
            }
        } else if !text.isEmpty {
            pushUndo()
            annotations.append(Annotation(kind: .text, start: origin, end: origin, color: fieldColor, text: text))
        }
        editingIndex = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size)
            .draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        for (index, annotation) in annotations.enumerated() where index != editingIndex { annotation.draw() }
        draft?.draw()

        if let index = selected, index < annotations.count {
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: annotations[index].bounds.insetBy(dx: -5, dy: -5))
            outline.lineWidth = 1
            outline.setLineDash([4, 3], count: 2, phase: 0)
            outline.stroke()
        }
        if let cropRect {
            let dim = NSBezierPath(rect: bounds)
            dim.append(NSBezierPath(rect: cropRect))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.45).setFill()
            dim.fill()
            NSColor.white.setStroke()
            NSBezierPath(rect: cropRect).stroke()
        }
    }

    /// The image with every annotation burned in, at full pixel size.
    func flattened() -> CGImage? {
        commitTextEditing()
        guard !annotations.isEmpty else { return image }
        let width = image.width, height = image.height
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for annotation in annotations { annotation.draw() }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
