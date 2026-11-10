import Foundation

/// One captured frame, RGBA or BGRA, 4 bytes per pixel, tightly packed rows.
public struct PixelFrame: Equatable {
    public let width: Int
    public let height: Int
    public var data: [UInt8]

    public init(width: Int, height: Int, data: [UInt8]) {
        precondition(data.count == width * height * 4, "frame data must be width * height * 4 bytes")
        self.width = width
        self.height = height
        self.data = data
    }
}

/// Builds one tall image from frames of the same region taken while the content scrolls.
///
/// Each new frame is compared with the last accepted one to find how many rows the content moved.
/// Rows that never change at the top or bottom (sticky headers and footers) are left out of the
/// comparison, kept once, and the footer always ends up at the very bottom.
public final class ScrollStitcher {
    public enum Outcome: Equatable {
        case first
        /// Nothing moved.
        case unchanged
        /// Content moved and this many new rows were added.
        case appended(rows: Int)
        /// Content moved (for example back up) but nothing new was revealed.
        case moved(offset: Int)
        /// Could not line this frame up with the previous one; it was ignored.
        case noMatch
    }

    public private(set) var width = 0
    public private(set) var totalHeight = 0

    private var frameHeight = 0
    private var canvas: [UInt8] = []
    private var previous: [Int32] = []
    /// Canvas row where the top of the previous frame sits.
    private var position = 0
    /// Rows at the bottom of the canvas that may be a sticky footer.
    private var tailFooter = 0
    private var misses = 0
    private let restartAfterMisses = 8

    private let blocks = 16
    /// Mean luminance difference per pixel under which two rows count as the same.
    private let rowTolerance = 0.5
    private let matchTolerance = 1.0

    public init() {}

    public func result() -> PixelFrame? {
        guard totalHeight > 0 else { return nil }
        return PixelFrame(width: width, height: totalHeight, data: canvas)
    }

    @discardableResult
    public func add(_ frame: PixelFrame) -> Outcome {
        if totalHeight == 0 {
            width = frame.width
            frameHeight = frame.height
            canvas = frame.data
            totalHeight = frame.height
            previous = signature(of: frame)
            position = 0
            tailFooter = 0
            return .first
        }
        guard frame.width == width, frame.height == frameHeight else { return .noMatch }

        let current = signature(of: frame)
        let h = frameHeight

        var top = 0
        while top < h, rowDistance(previous, top, current, top) <= rowTolerance { top += 1 }
        if top == h { return .unchanged }
        var bottom = 0
        while bottom < h - top, rowDistance(previous, h - 1 - bottom, current, h - 1 - bottom) <= rowTolerance {
            bottom += 1
        }

        guard let offset = findOffset(previous: previous, current: current, top: top, bottom: bottom) else {
            // If nothing has been stitched yet and the view keeps disagreeing with the first frame,
            // the first frame was probably taken mid-change (page still loading). Start again from here.
            misses += 1
            if totalHeight == frameHeight, misses >= restartAfterMisses {
                totalHeight = 0
                misses = 0
                return add(frame)
            }
            return .noMatch
        }
        misses = 0

        previous = current
        position += offset
        let newEnd = position + h
        guard newEnd > totalHeight else { return .moved(offset: offset) }

        // Rewrite the part of the canvas that may be a footer, then extend.
        let footer = max(tailFooter, bottom)
        var startRow = totalHeight - footer
        var frameRow = startRow - position
        if frameRow < top {
            frameRow = min(top, h)
            startRow = position + frameRow
        }
        if startRow > totalHeight {
            // Scrolled further than one frame of overlap allows; cannot fill the gap.
            position -= offset
            return .noMatch
        }
        let rowBytes = width * 4
        canvas.removeSubrange((startRow * rowBytes)...)
        canvas.append(contentsOf: frame.data[(frameRow * rowBytes)...])
        let added = newEnd - totalHeight
        totalHeight = newEnd
        tailFooter = bottom
        return .appended(rows: added)
    }

    // MARK: Matching

    /// Per row, `blocks` sums of luminance. The right edge is left out so a moving scroll bar is ignored.
    private func signature(of frame: PixelFrame) -> [Int32] {
        let usable = max(blocks, frame.width - max(frame.width / 25, 0))
        let blockWidth = max(usable / blocks, 1)
        var out = [Int32](repeating: 0, count: frame.height * blocks)
        frame.data.withUnsafeBufferPointer { pixels in
            for y in 0..<frame.height {
                let rowStart = y * frame.width * 4
                for b in 0..<blocks {
                    var sum: Int32 = 0
                    let x0 = b * blockWidth
                    let x1 = min(x0 + blockWidth, frame.width)
                    var i = rowStart + x0 * 4
                    for _ in x0..<x1 {
                        sum += Int32(pixels[i]) + 2 * Int32(pixels[i + 1]) + Int32(pixels[i + 2])
                        i += 4
                    }
                    out[y * blocks + b] = sum
                }
            }
        }
        signatureScale = Double(blockWidth * blocks * 4)
        return out
    }

    private var signatureScale = 1.0

    private func rowDistance(_ a: [Int32], _ rowA: Int, _ b: [Int32], _ rowB: Int) -> Double {
        var total: Int32 = 0
        let ia = rowA * blocks, ib = rowB * blocks
        for k in 0..<blocks { total += abs(a[ia + k] - b[ib + k]) }
        return Double(total) / signatureScale
    }

    /// Finds `d` such that current[y] == previous[y + d] inside the moving band. Positive means scrolled down.
    private func findOffset(previous: [Int32], current: [Int32], top: Int, bottom: Int) -> Int? {
        let h = frameHeight
        let bandStart = top, bandEnd = h - bottom
        let band = bandEnd - bandStart
        guard band >= 24 else { return nil }

        // The band needs some detail, otherwise any offset would look right.
        var distinct = 0
        for y in (bandStart + 1)..<bandEnd where rowDistance(current, y, current, y - 1) > rowTolerance { distinct += 1 }
        guard distinct >= 6 else { return nil }

        let minOverlap = max(16, band / 10)
        let maxShift = band - minOverlap
        guard maxShift >= 1 else { return nil }
        let step = max(1, band / 240)

        func score(_ d: Int, step: Int) -> Double {
            // current rows y in [lo, hi) compare with previous rows y + d
            let lo = max(bandStart, bandStart - d)
            let hi = min(bandEnd, bandEnd - d)
            guard hi - lo >= minOverlap else { return .infinity }
            var total = 0.0
            var count = 0
            var y = lo
            while y < hi {
                total += rowDistance(current, y, previous, y + d)
                count += 1
                y += step
            }
            return total / Double(count)
        }

        var best: (d: Int, score: Double)?
        for magnitude in 1...maxShift {
            for d in [magnitude, -magnitude] {
                let s = score(d, step: step)
                if s <= matchTolerance, best == nil || s < best!.score - 0.02 { best = (d, s) }
            }
        }
        guard let candidate = best else { return nil }
        return score(candidate.d, step: 1) <= matchTolerance ? candidate.d : nil
    }
}
