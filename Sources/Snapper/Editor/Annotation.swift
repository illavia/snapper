import AppKit

enum Tool: Int, CaseIterable {
    case select, arrow, box, text, highlight, step, crop

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .box: return "rectangle"
        case .text: return "textformat"
        case .highlight: return "highlighter"
        case .step: return "1.circle"
        case .crop: return "crop"
        }
    }

    var label: String {
        switch self {
        case .select: return "Select and move (V)"
        case .arrow: return "Arrow (A)"
        case .box: return "Box (B)"
        case .text: return "Text (T)"
        case .highlight: return "Highlight (H)"
        case .step: return "Numbered step (N)"
        case .crop: return "Crop (C)"
        }
    }

    var key: String {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .box: return "b"
        case .text: return "t"
        case .highlight: return "h"
        case .step: return "n"
        case .crop: return "c"
        }
    }
}

/// One mark on the image. Coordinates are image points, origin top-left.
struct Annotation {
    enum Kind { case arrow, box, text, highlight, step }

    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var color: NSColor
    var text: String = ""
    var number: Int = 0

    static let textFont = NSFont.systemFont(ofSize: 18, weight: .semibold)
    static let stepRadius: CGFloat = 13

    var textAttributes: [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.white.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        return [.font: Self.textFont, .foregroundColor: color, .shadow: shadow]
    }

    var bounds: CGRect {
        switch kind {
        case .arrow, .box, .highlight:
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        case .step:
            let r = Self.stepRadius
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        case .text:
            let size = NSAttributedString(string: text.isEmpty ? " " : text, attributes: textAttributes).size()
            return CGRect(origin: start, size: size)
        }
    }

    func hit(_ point: CGPoint) -> Bool {
        switch kind {
        case .arrow:
            return Self.distance(from: point, toSegment: start, end) <= 8
        case .box:
            let outer = bounds.insetBy(dx: -6, dy: -6), inner = bounds.insetBy(dx: 8, dy: 8)
            return outer.contains(point) && !(inner.width > 0 && inner.height > 0 && inner.contains(point))
        default:
            return bounds.insetBy(dx: -4, dy: -4).contains(point)
        }
    }

    mutating func move(by delta: CGPoint) {
        start.x += delta.x; start.y += delta.y
        end.x += delta.x; end.y += delta.y
    }

    /// Draws into the current (flipped) graphics context.
    func draw() {
        switch kind {
        case .arrow:
            let length = hypot(end.x - start.x, end.y - start.y)
            guard length > 1 else { return }
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = min(max(length * 0.25, 10), 18)
            let base = CGPoint(x: end.x - cos(angle) * head * 0.8, y: end.y - sin(angle) * head * 0.8)
            color.setStroke()
            color.setFill()
            let shaft = NSBezierPath()
            shaft.lineWidth = 4
            shaft.lineCapStyle = .round
            shaft.move(to: start)
            shaft.line(to: base)
            shaft.stroke()
            let tip = NSBezierPath()
            tip.move(to: end)
            tip.line(to: CGPoint(x: end.x - cos(angle - 0.45) * head, y: end.y - sin(angle - 0.45) * head))
            tip.line(to: CGPoint(x: end.x - cos(angle + 0.45) * head, y: end.y - sin(angle + 0.45) * head))
            tip.close()
            tip.fill()
        case .box:
            color.setStroke()
            let path = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
            path.lineWidth = 3
            path.stroke()
        case .highlight:
            NSGraphicsContext.current?.cgContext.setBlendMode(.multiply)
            NSColor.systemYellow.withAlphaComponent(0.55).setFill()
            NSBezierPath(rect: bounds).fill()
            NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
        case .step:
            color.setFill()
            NSBezierPath(ovalIn: bounds).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            ring.stroke()
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: NSColor.white,
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        case .text:
            NSAttributedString(string: text, attributes: textAttributes).draw(at: start)
        }
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
