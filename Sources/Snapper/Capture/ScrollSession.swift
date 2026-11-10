import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import Stitcher

/// Grabs frames of one region repeatedly. The content filter is built once, which keeps each grab fast.
final class RegionGrabber {
    private let filter: SCContentFilter
    private let config: SCStreamConfiguration

    /// `rect` is in points, top-left origin, relative to the display. Snapper's own windows are left out.
    init(rect: CGRect, screen: NSScreen) async throws {
        guard CaptureEngine.hasPermission else { throw CaptureError.noPermission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let id = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.noDisplay }
        let pid = ProcessInfo.processInfo.processIdentifier
        let mine = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer != 0 }
        filter = SCContentFilter(display: display, excludingWindows: mine)
        config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.sourceRect = rect
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
    }

    func grab() async throws -> CGImage {
        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

extension PixelFrame {
    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        self.init(width: width, height: height, data: data)
    }

    func cgImage(colorSpace: CGColorSpace?) -> CGImage? {
        let space = colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Scrolling capture: the user scrolls, frames of the chosen region are stitched as they arrive.
@MainActor
final class ScrollSession {
    private static var current: ScrollSession?
    static var isActive: Bool { current != nil }

    /// Stop before the image becomes unusably tall.
    private static let maxHeight = 40_000

    private let rect: CGRect
    private let screen: NSScreen
    private let completion: (CGImage, CGFloat) -> Void
    private let stitcher = ScrollStitcher()
    private var colorSpace: CGColorSpace?
    private var loop: Task<Void, Never>?
    private var border: NSWindow?
    private var hud: NSPanel?
    private var label: NSTextField?
    private var misses = 0
    private var failures = 0
    private var grabber: RegionGrabber?
    private var frames = 0
    private var lost = 0
    private var busy: TimeInterval = 0

    static func start(rect: CGRect, screen: NSScreen, completion: @escaping (CGImage, CGFloat) -> Void) {
        guard current == nil else { return }
        let session = ScrollSession(rect: rect, screen: screen, completion: completion)
        current = session
        session.begin()
    }

    /// Test hook and safety net.
    static func finishCurrent() { current?.finish(deliver: true) }
    static func cancelCurrent() { current?.finish(deliver: false) }

    private init(rect: CGRect, screen: NSScreen, completion: @escaping (CGImage, CGFloat) -> Void) {
        self.rect = rect
        self.screen = screen
        self.completion = completion
    }

    private func begin() {
        showChrome()
        HotKeyCenter.shared.register(id: 101, keyCode: UInt32(kVK_Return), modifiers: 0) { ScrollSession.finishCurrent() }
        HotKeyCenter.shared.register(id: 102, keyCode: UInt32(kVK_Escape), modifiers: 0) { ScrollSession.cancelCurrent() }
        Log.write("scrolling: started \(Int(rect.width))x\(Int(rect.height)) pt")

        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.step()
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
        }
    }

    private func step() async {
        let image: CGImage
        let began = Date()
        do {
            if grabber == nil { grabber = try await RegionGrabber(rect: rect, screen: screen) }
            image = try await grabber!.grab()
        } catch {
            failures += 1
            if failures == 1 { Log.write("scrolling: frame capture failed: \(error.localizedDescription)") }
            if failures >= 3 { setStatus("Cannot capture this area", warn: true) }
            return
        }
        failures = 0
        if colorSpace == nil { colorSpace = image.colorSpace }
        let stitcher = self.stitcher
        let outcome = await Task.detached(priority: .userInitiated) { () -> ScrollStitcher.Outcome? in
            guard let frame = PixelFrame(image) else { return nil }
            return stitcher.add(frame)
        }.value
        guard !Task.isCancelled, let outcome else { return }
        frames += 1
        if case .noMatch = outcome { lost += 1 }
        busy += Date().timeIntervalSince(began)

        switch outcome {
        case .noMatch:
            misses += 1
            if misses >= 12 { setStatus("Lost my place. Scroll back up a little, then continue slowly", warn: true) }
        case .first, .appended, .moved:
            misses = 0
            setStatus("Scroll down slowly · \(stitcher.totalHeight) px tall", warn: false)
        case .unchanged:
            if misses == 0 { setStatus("Scroll down slowly · \(stitcher.totalHeight) px tall", warn: false) }
        }
        if stitcher.totalHeight >= Self.maxHeight { finish(deliver: true) }
    }

    private func finish(deliver: Bool) {
        guard Self.current === self else { return }
        Self.current = nil
        loop?.cancel()
        HotKeyCenter.shared.unregister(id: 101)
        HotKeyCenter.shared.unregister(id: 102)
        border?.orderOut(nil)
        hud?.orderOut(nil)

        guard deliver else {
            Log.write("scrolling: cancelled")
            return
        }
        let stitcher = self.stitcher, space = colorSpace, rect = self.rect, completion = self.completion
        Task {
            // Let an in-flight frame finish before reading the result.
            _ = await loop?.value
            guard let frame = stitcher.result(), let image = frame.cgImage(colorSpace: space) else {
                Log.write("scrolling: nothing captured")
                return
            }
            Log.write("scrolling: \(self.frames) frames, \(self.lost) not matched, \(Int(self.busy / Double(max(self.frames, 1)) * 1000)) ms per frame")
            completion(image, CGFloat(frame.width) / rect.width)
        }
    }

    // MARK: On-screen chrome (left out of the capture because it belongs to Snapper)

    private func showChrome() {
        // rect is top-left based; AppKit windows are bottom-left based.
        let frame = CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY,
                           width: rect.width, height: rect.height)

        let border = NSWindow(contentRect: frame.insetBy(dx: -3, dy: -3), styleMask: .borderless,
                              backing: .buffered, defer: false)
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.ignoresMouseEvents = true
        border.level = .statusBar
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        border.isReleasedWhenClosed = false
        border.contentView = BorderView(frame: NSRect(origin: .zero, size: border.frame.size))
        border.orderFrontRegardless()
        self.border = border

        let size = NSSize(width: 680, height: 68)
        var origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY - size.height - 12)
        if origin.y < screen.visibleFrame.minY + 4 { origin.y = frame.maxY + 10 }
        if origin.y + size.height > screen.frame.maxY - 4 { origin.y = frame.minY + 10 }
        origin.x = min(max(origin.x, screen.frame.minX + 4), screen.frame.maxX - size.width - 4)

        let hud = NSPanel(contentRect: NSRect(origin: origin, size: size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hasShadow = true
        hud.level = .statusBar
        hud.hidesOnDeactivate = false
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hud.isReleasedWhenClosed = false

        let background = NSView(frame: NSRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        background.layer?.borderWidth = 1

        let label = NSTextField(wrappingLabelWithString: "Scroll down slowly")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.maximumNumberOfLines = 2
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: size.width - 20 - 12 - 150 - 140 - 24).isActive = true
        let done = PillButton(title: "Done  ⏎", fill: .systemGreen, width: 150,
                              target: self, action: #selector(doneClicked))
        let cancel = PillButton(title: "Cancel  esc", fill: NSColor(white: 0.38, alpha: 1), width: 140,
                                target: self, action: #selector(cancelClicked))

        let stack = NSStackView(views: [label, done, cancel])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.distribution = .fill
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 12)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            done.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            cancel.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        hud.contentView = background
        hud.orderFrontRegardless()
        self.hud = hud
        self.label = label
    }

    private func setStatus(_ text: String, warn: Bool) {
        label?.stringValue = text
        label?.textColor = warn ? .systemYellow : .white
    }

    @objc private func doneClicked() { finish(deliver: true) }
    @objc private func cancelClicked() { finish(deliver: false) }
}

/// A large, solid, clearly clickable button for the scrolling bar.
private final class PillButton: NSButton {
    private let fill: NSColor

    init(title: String, fill: NSColor, width: CGFloat, target: AnyObject, action: Selector) {
        self.fill = fill
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = fill.cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 46).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = (fill.blended(withFraction: 0.18, of: .white) ?? fill).cgColor
    }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = fill.cgColor }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

private final class BorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.stroke()
    }
}
