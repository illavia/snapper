import AppKit
import Vision

/// Reads the text in an image with Apple's on-device recognition and puts it on the clipboard.
enum TextGrab {
    static func recognise(_ image: CGImage) async -> String {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do { try handler.perform([request]) } catch {
                Log.write("text: recognition failed: \(error.localizedDescription)")
                return ""
            }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }

    /// The first recognition after launch loads Apple's models and can take a long time.
    /// Doing a throwaway one in the background at launch keeps the first real use quick.
    static func warmUp() {
        Task.detached(priority: .utility) {
            let began = Date()
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let context = CGContext(data: nil, width: 200, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 60))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 30, y: 20, width: 140, height: 20))
            guard let image = context.makeImage() else { return }
            _ = await recognise(image)
            Log.write("text: warm-up took \(Int(Date().timeIntervalSince(began) * 1000)) ms")
        }
    }

    @discardableResult
    static func copy(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.string(forType: .string) == text
    }
}

/// A short message near the bottom right of the screen that fades by itself.
@MainActor
final class Toast {
    private static var panel: NSPanel?
    private static var work: DispatchWorkItem?

    static func show(_ title: String, detail: String? = nil, warn: Bool = false) {
        work?.cancel()
        panel?.orderOut(nil)

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        titleField.textColor = warn ? .systemYellow : .white
        var views: [NSView] = [titleField]
        if let detail, !detail.isEmpty {
            let detailField = NSTextField(wrappingLabelWithString: detail)
            detailField.font = .systemFont(ofSize: 12)
            detailField.textColor = NSColor(white: 0.85, alpha: 1)
            detailField.maximumNumberOfLines = 4
            detailField.isSelectable = false
            detailField.preferredMaxLayoutWidth = 300
            views.append(detailField)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let background = NSView()
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        background.layer?.borderWidth = 1
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        background.layoutSubtreeIfNeeded()
        let size = background.fittingSize

        let visible = NSScreen.underMouse.visibleFrame
        let frame = NSRect(x: visible.maxX - size.width - 20, y: visible.minY + 20, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.contentView = background
        panel.orderFrontRegardless()
        Self.panel = panel

        let dismiss = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        }
        work = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + (warn ? 5 : 3.5), execute: dismiss)
    }
}
