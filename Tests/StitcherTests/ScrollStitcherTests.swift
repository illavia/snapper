import XCTest
@testable import Stitcher

final class ScrollStitcherTests: XCTestCase {
    /// Deterministic noise so every row is distinct.
    private func makePage(width: Int, height: Int, seed: UInt64) -> PixelFrame {
        var state = seed
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let v = UInt8(truncatingIfNeeded: state >> 33)
            data[i * 4] = v
            data[i * 4 + 1] = UInt8(truncatingIfNeeded: state >> 41)
            data[i * 4 + 2] = UInt8(truncatingIfNeeded: state >> 49)
        }
        return PixelFrame(width: width, height: height, data: data)
    }

    private func rows(_ frame: PixelFrame, _ range: Range<Int>) -> [UInt8] {
        Array(frame.data[(range.lowerBound * frame.width * 4)..<(range.upperBound * frame.width * 4)])
    }

    /// What a viewport of `viewHeight` rows shows at scroll position `offset`,
    /// with optional sticky header and footer bars painted over the content.
    private func view(_ page: PixelFrame, offset: Int, viewHeight: Int,
                      header: PixelFrame? = nil, footer: PixelFrame? = nil) -> PixelFrame {
        var data = rows(page, offset..<(offset + viewHeight))
        let rowBytes = page.width * 4
        if let header { data.replaceSubrange(0..<(header.height * rowBytes), with: header.data) }
        if let footer {
            data.replaceSubrange(((viewHeight - footer.height) * rowBytes)..<(viewHeight * rowBytes), with: footer.data)
        }
        return PixelFrame(width: page.width, height: viewHeight, data: data)
    }

    func testPlainScrollRebuildsThePageExactly() {
        let page = makePage(width: 200, height: 3000, seed: 1)
        let stitcher = ScrollStitcher()
        var offset = 0
        let steps = [37, 120, 5, 260, 1, 199, 88, 300, 310, 42, 150, 275, 64, 290, 231, 228]
        XCTAssertEqual(stitcher.add(view(page, offset: 0, viewHeight: 400)), .first)
        for step in steps {
            offset += step
            XCTAssertEqual(stitcher.add(view(page, offset: offset, viewHeight: 400)), .appended(rows: step))
        }
        XCTAssertEqual(offset + 400, 3000)
        XCTAssertTrue(stitcher.result() == page, "stitched image differs from the page")
    }

    func testStickyHeaderAndFooterAreKeptOnce() {
        let page = makePage(width: 240, height: 2400, seed: 2)
        let header = makePage(width: 240, height: 50, seed: 3)
        let footer = makePage(width: 240, height: 30, seed: 4)
        let viewHeight = 500
        let stitcher = ScrollStitcher()
        var offset = 0
        stitcher.add(view(page, offset: 0, viewHeight: viewHeight, header: header, footer: footer))
        for step in [90, 210, 15, 300, 333, 127, 280, 199, 346] {
            offset += step
            let outcome = stitcher.add(view(page, offset: offset, viewHeight: viewHeight, header: header, footer: footer))
            XCTAssertEqual(outcome, .appended(rows: step))
        }
        XCTAssertEqual(offset + viewHeight, 2400)

        var expected = page.data
        let rowBytes = 240 * 4
        expected.replaceSubrange(0..<(50 * rowBytes), with: header.data)
        expected.replaceSubrange(((2400 - 30) * rowBytes)..<(2400 * rowBytes), with: footer.data)
        XCTAssertTrue(stitcher.result() == PixelFrame(width: 240, height: 2400, data: expected), "stitched image differs")
    }

    func testRepeatedFramesAndScrollingBackUpAreHarmless() {
        let page = makePage(width: 160, height: 1500, seed: 5)
        let stitcher = ScrollStitcher()
        let positions = [0, 0, 100, 100, 250, 180, 60, 250, 400, 400, 650, 500, 750, 950, 1200]
        var furthest = 0
        for (index, offset) in positions.enumerated() {
            let outcome = stitcher.add(view(page, offset: offset, viewHeight: 300))
            if index == 0 { XCTAssertEqual(outcome, .first); continue }
            let previous = positions[index - 1]
            if offset == previous {
                XCTAssertEqual(outcome, .unchanged)
            } else if offset > furthest {
                XCTAssertEqual(outcome, .appended(rows: offset - furthest))
            } else {
                XCTAssertEqual(outcome, .moved(offset: offset - previous))
            }
            furthest = max(furthest, offset)
        }
        XCTAssertTrue(stitcher.result() == page, "stitched image differs from the page")
    }

    func testUnrelatedFrameIsIgnored() {
        let page = makePage(width: 160, height: 900, seed: 6)
        let other = makePage(width: 160, height: 300, seed: 7)
        let stitcher = ScrollStitcher()
        stitcher.add(view(page, offset: 0, viewHeight: 300))
        XCTAssertEqual(stitcher.add(other), .noMatch)
        XCTAssertEqual(stitcher.add(view(page, offset: 150, viewHeight: 300)), .appended(rows: 150))
        XCTAssertEqual(stitcher.totalHeight, 450)
    }

    func testBlankContentIsNotGuessed() {
        let blank = PixelFrame(width: 100, height: 200, data: [UInt8](repeating: 255, count: 100 * 200 * 4))
        var changed = blank
        changed.data[0] = 0 // one pixel differs, no detail to align on
        for i in 0..<(100 * 4 * 3) { changed.data[i] = 0 }
        let stitcher = ScrollStitcher()
        stitcher.add(blank)
        XCTAssertEqual(stitcher.add(changed), .noMatch)
        XCTAssertEqual(stitcher.totalHeight, 200)
    }

    func testBadFirstFrameIsReplacedBeforeAnythingIsStitched() {
        let stale = makePage(width: 160, height: 300, seed: 8)
        let page = makePage(width: 160, height: 900, seed: 9)
        let stitcher = ScrollStitcher()
        stitcher.add(stale)
        var outcomes: [ScrollStitcher.Outcome] = []
        for _ in 0..<8 { outcomes.append(stitcher.add(view(page, offset: 0, viewHeight: 300))) }
        XCTAssertEqual(outcomes.last, .first)
        XCTAssertEqual(stitcher.add(view(page, offset: 200, viewHeight: 300)), .appended(rows: 200))
        XCTAssertEqual(stitcher.add(view(page, offset: 400, viewHeight: 300)), .appended(rows: 200))
        XCTAssertEqual(stitcher.add(view(page, offset: 600, viewHeight: 300)), .appended(rows: 200))
        XCTAssertTrue(stitcher.result() == page, "stitched image differs from the page")
    }
}
