import AppKit

/// Prints a capture. An ordinary capture is shrunk to fit one page and never enlarged. A long
/// scrolling capture is fitted to the page width and runs over as many pages as it needs.
@MainActor
enum Printer {
    /// Shows the print panel as a sheet on `window`, or on its own if there is no window.
    static func print(_ image: CGImage, scale: CGFloat, title: String, window: NSWindow?) {
        let operation = makeOperation(image, scale: scale, title: title)
        Log.write("print: \(title) \(image.width)x\(image.height)")
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    static func print(file: URL, window: NSWindow?) {
        guard let loaded = load(file) else {
            Toast.show("Could not print", warn: true)
            return
        }
        print(loaded.image, scale: loaded.scale, title: file.deletingPathExtension().lastPathComponent, window: window)
    }

    /// Test hook: runs the same print job with no panel and saves it as a PDF.
    @discardableResult
    static func savePDF(file: URL, to output: URL) -> Bool {
        guard let loaded = load(file) else { return false }
        let operation = makeOperation(loaded.image, scale: loaded.scale, title: file.lastPathComponent)
        operation.printInfo.jobDisposition = .save
        operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        let done = operation.run()
        Log.write("print: pdf \(output.path) ok=\(done) landscape=\(operation.printInfo.orientation == .landscape)")
        return done
    }

    private static func load(_ file: URL) -> (image: CGImage, scale: CGFloat)? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)?.inMemoryCopy() else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        return (image, dpi >= 140 ? 2 : 1)
    }

    private static func makeOperation(_ image: CGImage, scale: CGFloat, title: String) -> NSPrintOperation {
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        let margin: CGFloat = 28 // about 1 cm
        info.leftMargin = margin
        info.rightMargin = margin
        info.topMargin = margin
        info.bottomMargin = margin
        // Wide captures print across the page. More than three times as tall as wide is a scrolling capture.
        let isLong = size.height > size.width * 3
        info.orientation = size.width > size.height ? .landscape : .portrait
        info.horizontalPagination = .fit
        info.verticalPagination = isLong ? .automatic : .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = !isLong

        let view = PrintView(image: image, size: size)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = title
        operation.printPanel.options.insert([.showsOrientation, .showsPaperSize, .showsScaling])
        return operation
    }
}

/// Draws the image top down, so a long capture breaks into pages from the top.
private final class PrintView: NSView {
    private let image: CGImage

    init(image: CGImage, size: NSSize) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        context.restoreGState()
    }
}
