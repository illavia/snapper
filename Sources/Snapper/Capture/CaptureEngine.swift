import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noPermission
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noPermission: return "Snapper does not have Screen Recording permission."
        case .noDisplay: return "Could not find the display to capture."
        }
    }
}

/// A still image of one display, in device pixels.
struct Frozen {
    let image: CGImage
    let screen: NSScreen
    /// Pixels per point.
    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
}

enum CaptureEngine {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Captures a whole display, leaving out Snapper's own windows.
    static func captureDisplay(_ screen: NSScreen) async throws -> Frozen {
        guard hasPermission else { throw CaptureError.noPermission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let id = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.noDisplay
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let mine = content.windows.filter { $0.owningApplication?.processID == pid }
        let filter = SCContentFilter(display: display, excludingWindows: mine)
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.width = Int((CGFloat(display.width) * scale).rounded())
        config.height = Int((CGFloat(display.height) * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Frozen(image: image, screen: screen)
    }

    /// Captures a rectangle of a display. `rect` is in points, top-left origin, relative to that display.
    static func captureRect(_ rect: CGRect, on screen: NSScreen) async throws -> (CGImage, CGFloat) {
        let frozen = try await captureDisplay(screen)
        guard let cropped = frozen.crop(rect) else { throw CaptureError.noDisplay }
        return (cropped, frozen.scale)
    }
}

extension Frozen {
    /// Crops using a rectangle in points, top-left origin, relative to the display.
    func crop(_ rect: CGRect) -> CGImage? {
        let s = scale
        let pixels = CGRect(x: (rect.minX * s).rounded(), y: (rect.minY * s).rounded(),
                            width: (rect.width * s).rounded(), height: (rect.height * s).rounded())
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        return image.cropping(to: pixels)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Top-left corner of this screen in global Quartz coordinates (origin top-left of the primary display).
    var quartzOrigin: CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return CGPoint(x: frame.minX, y: primaryHeight - frame.maxY)
    }

    static var underMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first(where: { $0.frame.contains(p) }) ?? main ?? screens[0]
    }
}
