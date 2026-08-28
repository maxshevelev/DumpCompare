import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §21.3 the tint, measured off a real `HexView`'s pixels rather than described:
/// a piece's rows carry a pale band edge to edge — from the panel's own left
/// edge, the Offset column included — gaps included, split at the mid-gap
/// between the two bytes a cut separates, and stopping at EOF. The band is the bottom of the layering stack — the
/// offset column, a difference, and a selection are all drawn over it, so what
/// a byte *is* outranks which piece it belongs to, and a bookmark's arrow is
/// never buried under the band.
///
/// The view is pinned to Aqua so the dynamic colours resolve to fixed values and
/// the sampling is deterministic. The background is `textBackgroundColor` (white
/// in Aqua), and the tints are opaque fills, so a tinted pixel is the tint and a
/// non-tinted one is the paper.
@MainActor
final class SegmentTintRenderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    /// A standalone hex view over a real pane, pinned to Aqua. No window, so no
    /// active-pane caret bar and no selection: the pixels are the tint, the
    /// difference, and the paper, and nothing else.
    private func makeHexView(_ bytes: [UInt8]) throws -> (HexView, PaneViewModel, URL) {
        let url = try tempFile(bytes)
        let pane = PaneViewModel()
        try pane.open(url: url)
        let hexView = HexView()
        hexView.appearance = NSAppearance(named: .aqua)
        hexView.dataSource = pane
        hexView.delegate = pane
        hexView.reloadData()
        return (hexView, pane, url)
    }

    /// Snapshots the view via `cacheDisplay`, which drives the real flipped
    /// `draw(_:)` path onto a bitmap at the backing scale.
    private func render(_ view: HexView) -> NSBitmapImageRep {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("no bitmap rep")
            return NSBitmapImageRep()
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The pixel at a point-space location, in deviceRGB.
    private func pixel(_ hexView: HexView, x: CGFloat, y: CGFloat) throws -> NSColor {
        let rep = render(hexView)
        let scale = CGFloat(rep.pixelsWide) / hexView.bounds.width
        let px = min(max(Int(x * scale), 0), rep.pixelsWide - 1)
        let py = min(max(Int(y * scale), 0), rep.pixelsHigh - 1)
        return rep.colorAt(x: px, y: py)!.usingColorSpace(.deviceRGB)!
    }

    /// Sum of per-channel absolute differences between two colours — 0 for
    /// identical, ~1 per channel apart at most. The tints sit 0.3+ off the
    /// paper, so a threshold of 0.15 separates "tinted" from "paper" with room
    /// for the sRGB → deviceRGB shift.
    private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let ca = a.usingColorSpace(.deviceRGB)!
        let cb = b.usingColorSpace(.deviceRGB)!
        return abs(ca.redComponent - cb.redComponent)
             + abs(ca.greenComponent - cb.greenComponent)
             + abs(ca.blueComponent - cb.blueComponent)
    }

    /// Two pixels are the same tint when they are close to each other and both
    /// measurably off the paper.
    private func sameTint(_ a: NSColor, _ b: NSColor) -> Bool {
        distance(a, b) < 0.12 && distance(a, .white) > 0.15
    }

    /// Near the top of `row`, clear of the glyph ink (centred lower) and of the
    /// caret underline (at the row's bottom edge) — so the pixel read is the
    /// row's background, whatever it is.
    private func topY(_ layout: HexLayout, row: Int) -> CGFloat {
        layout.rowFrame(row: row).minY + 2
    }

    // MARK: - The gaps are the rule, not a side effect

    /// A cut at a row boundary leaves row 0 one whole piece (S0), so the band
    /// runs the full width of the row. The two gaps the plan calls out — between
    /// the 8-byte groups and before the decoded text — carry the piece's colour
    /// rather than a slit of paper.
    func testTheTintFillsTheGapsBetweenTheGroupsAndBeforeTheText() throws {
        let (hexView, pane, url) = try makeHexView([UInt8](repeating: 0x41, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(pane.segmentStore.addCut(at: 16), "a cut at the row boundary")
        hexView.reloadData()
        let layout = hexView.hexLayout
        let y = topY(layout, row: 0)

        // The gap between the two 8-byte groups: between byte 7's cell and byte 8's.
        let groupGapX = (layout.hexByteX(column: 7) + layout.hexByteWidth
                         + layout.hexByteX(column: 8)) / 2
        // The gap before the decoded-text column: between the hex column's right
        // edge and the ASCII column's left edge.
        let asciiGapX = (layout.hexByteX(column: 15) + layout.hexByteWidth
                         + layout.asciiX(column: 0)) / 2

        let groupGap = try pixel(hexView, x: groupGapX, y: y)
        let asciiGap = try pixel(hexView, x: asciiGapX, y: y)
        let byteCell = try pixel(hexView, x: layout.hexByteX(column: 3) + layout.hexByteWidth / 2, y: y)

        XCTAssertGreaterThan(distance(groupGap, .white), 0.15,
                             "the between-groups gap is tinted, not a slit of paper")
        XCTAssertGreaterThan(distance(asciiGap, .white), 0.15,
                             "the gap before the decoded text is tinted, not a slit of paper")
        XCTAssertTrue(sameTint(groupGap, byteCell),
                      "the gap takes the colour of the piece beside it")
        XCTAssertTrue(sameTint(asciiGap, byteCell),
                      "the before-text gap takes the piece's colour too")
    }

    /// The band is edge to edge (§21.3): it reaches the panel's own left edge,
    /// so the strip before the Offset column — and the column itself — stand on
    /// the piece's colour rather than the paper.
    func testTheBandReachesThePanelsEdge() throws {
        let (hexView, pane, url) = try makeHexView([UInt8](repeating: 0x41, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(pane.segmentStore.addCut(at: 16))
        hexView.reloadData()
        let layout = hexView.hexLayout
        let y = topY(layout, row: 0)

        // The strip between the panel's edge and the Offset column's first
        // glyph: paper before, the piece's colour now.
        let stripX = layout.leftPadding / 2
        let stripPixel = try pixel(hexView, x: stripX, y: y)
        let offsetPixel = try pixel(hexView, x: layout.leftPadding + 2, y: y)
        let tintedPixel = try pixel(hexView, x: layout.hexByteX(column: 3) + layout.hexByteWidth / 2, y: y)

        XCTAssertGreaterThan(distance(stripPixel, .white), 0.15,
                             "the band reaches the panel's edge, not the offset column's start")
        XCTAssertTrue(sameTint(stripPixel, tintedPixel),
                      "the strip before the Offset column takes the piece's colour")
        XCTAssertGreaterThan(distance(offsetPixel, .white), 0.15,
                             "the Offset column is tinted, edge to edge")
        XCTAssertTrue(sameTint(offsetPixel, tintedPixel),
                      "the Offset column takes the colour of the piece beside it")
    }

    // MARK: - The mid-row split

    /// A cut inside a row steps the colour at the byte, in both columns — the
    /// case a line down the side of the row could not draw. Bytes 0–4 keep S0's
    /// green, bytes 5–15 take S1's pink, and the two are plainly different.
    func testAMidRowCutSplitsTheTintAtTheByte() throws {
        let (hexView, pane, url) = try makeHexView([UInt8](repeating: 0x41, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(pane.segmentStore.addCut(at: 5), "a cut mid-row, at byte 5")
        hexView.reloadData()
        let layout = hexView.hexLayout
        let y = topY(layout, row: 0)

        let left = try pixel(hexView, x: layout.hexByteX(column: 4) + layout.hexByteWidth / 2, y: y)
        let right = try pixel(hexView, x: layout.hexByteX(column: 6) + layout.hexByteWidth / 2, y: y)

        XCTAssertGreaterThan(distance(left, .white), 0.15, "the byte left of the cut is tinted")
        XCTAssertGreaterThan(distance(right, .white), 0.15, "the byte right of the cut is tinted")
        XCTAssertGreaterThan(distance(left, right), 0.12,
                             "the two sides of the cut are different tints")
    }

    /// The boundary between two pieces falls at the middle of the gap between
    /// the two bytes it separates (§21.3) — and the two fills meet at exactly
    /// that point, so there is no slit of paper between them. A run of pixels
    /// across the whole gap must read as tint, never the paper.
    func testTheMidRowBoundaryLeavesNoPaperSlit() throws {
        let (hexView, pane, url) = try makeHexView([UInt8](repeating: 0x41, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(pane.segmentStore.addCut(at: 5), "a cut mid-row, at byte 5")
        hexView.reloadData()
        let layout = hexView.hexLayout
        let y = topY(layout, row: 0)

        // The gap the cut separates: from byte 4's cell right edge to byte 5's
        // cell left edge. Every pixel across it is a tint — the left half S0,
        // the right half S1 — and none is the paper.
        let gapStart = layout.hexByteX(column: 4) + layout.hexByteWidth
        let gapEnd = layout.hexByteX(column: 5)
        let step = (gapEnd - gapStart) / 8
        var x = gapStart
        while x < gapEnd {
            let pixel = try pixel(hexView, x: x, y: y)
            XCTAssertGreaterThan(distance(pixel, .white), 0.15,
                                 "no paper slit at x=\(x) across the cut's gap")
            x += step
        }
    }

    /// A bookmark's arrow is drawn over the segment tint (§21.3): its tip
    /// reaches into the gap past the Offset column, and that tip keeps the
    /// bookmark's purple rather than being buried under the piece's band.
    /// Sampled at the tip's widest point — the row's middle.
    func testTheBookmarkTipIsDrawnOverTheTint() throws {
        let (hexView, pane, url) = try makeHexView([UInt8](repeating: 0x41, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(pane.segmentStore.addCut(at: 16))
        let store = BookmarkStore()
        pane.bookmarkStore = store
        store.add(rowContaining: 0)
        hexView.reloadData()
        let layout = hexView.hexLayout
        let rowFrame = layout.rowFrame(row: 0)
        let y = rowFrame.midY

        // The tip: from the mark body's right edge into the gap past the Offset
        // column, widest at the row's middle.
        let bodyRight = layout.leftPadding + layout.offsetColumnWidth + HexView.mirrorContourPadding
        let tipReach = HexView.bookmarkTipReach(height: rowFrame.height, gap: layout.gapAfterOffset)
        let tip = try pixel(hexView, x: bodyRight + tipReach / 2, y: y)
        let tint = try pixel(hexView, x: layout.hexByteX(column: 3) + layout.hexByteWidth / 2, y: y)

        XCTAssertGreaterThan(distance(tip, tint), 0.12,
                             "the bookmark's tip is not buried under the piece's tint")
    }

    // MARK: - Layering: the tint is the bottom of the stack

    /// A difference is drawn over the tint, so a differing byte still reads
    /// orange — warmer than the pale piece it stands on (§6).
    func testADifferenceStillReadsOrangeOverTheTint() throws {
        let urlA = try tempFile([UInt8](repeating: 0x00, count: 32))
        let urlB = try tempFile([UInt8](repeating: 0xFF, count: 32))
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        let paneA = PaneViewModel()
        let paneB = PaneViewModel()
        try paneA.open(url: urlA)
        try paneB.open(url: urlB)
        paneA.companion = paneB
        paneB.companion = paneA
        XCTAssertTrue(paneA.segmentStore.addCut(at: 16))

        let hexView = HexView()
        hexView.appearance = NSAppearance(named: .aqua)
        hexView.dataSource = paneA
        hexView.delegate = paneA
        hexView.reloadData()
        let layout = hexView.hexLayout
        let y = topY(layout, row: 0)

        // Every byte differs, so every byte stands on the difference fill. The
        // fill is orange: much warmer (red − blue) than the green tint under it.
        let x = layout.hexByteX(column: 3) + layout.hexByteWidth / 2
        let colour = try pixel(hexView, x: x, y: y).usingColorSpace(.deviceRGB)!
        let warmth = colour.redComponent - colour.blueComponent
        XCTAssertGreaterThan(warmth, 0.1,
                             "a differing byte reads orange over the tint")
    }

    /// The difference fill is per-byte, so the gaps between differing bytes keep
    /// the tint showing through — the band is not wiped where the fill is absent.
    func testTheTintShowsThroughADifferencesGaps() throws {
        // Only byte 3 differs: the rest of the row is the same, so the difference
        // fill is a single cell and the gaps around it are tint, not paper.
        var a = [UInt8](repeating: 0x11, count: 32)
        let b = [UInt8](repeating: 0x11, count: 32)
        a[3] = 0x22
        let urlA = try tempFile(a)
        let urlB = try tempFile(b)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        let paneA = PaneViewModel()
        let paneB = PaneViewModel()
        try paneA.open(url: urlA)
        try paneB.open(url: urlB)
        paneA.companion = paneB
        paneB.companion = paneA
        XCTAssertTrue(paneA.segmentStore.addCut(at: 16))

        let hexView = HexView()
        hexView.appearance = NSAppearance(named: .aqua)
        hexView.dataSource = paneA
        hexView.delegate = paneA
        hexView.reloadData()
        let layout = hexView.hexLayout
        let y = topY(layout, row: 0)

        // The gap between the groups (bytes 7/8 are the same, so no difference
        // fill there) must still carry the tint.
        let groupGapX = (layout.hexByteX(column: 7) + layout.hexByteWidth
                         + layout.hexByteX(column: 8)) / 2
        let gap = try pixel(hexView, x: groupGapX, y: y)
        XCTAssertGreaterThan(distance(gap, .white), 0.15,
                             "the tint shows through where the difference fill is absent")
    }

    /// A selection is drawn over the tint, so a selected byte reads as the
    /// selection's blue, not the piece's colour (§6).
    func testASelectionCoversTheTint() throws {
        let (hexView, pane, url) = try makeHexView([UInt8](repeating: 0x41, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(pane.segmentStore.addCut(at: 16))
        pane.setSelection(SelectionModel(start: 2, end: 6, fileSize: 32))
        hexView.reloadData()
        let layout = hexView.hexLayout
        let y = topY(layout, row: 0)

        // A selected byte (3) reads blue; an unselected byte in the same piece
        // (10) reads the tint. The selection covers the tint on the selected byte.
        let selected = try pixel(hexView, x: layout.hexByteX(column: 3) + layout.hexByteWidth / 2, y: y)
        let unselected = try pixel(hexView, x: layout.hexByteX(column: 10) + layout.hexByteWidth / 2, y: y)
        let selBlue = selected.usingColorSpace(.deviceRGB)!
        let selWarmth = selBlue.blueComponent - selBlue.redComponent
        XCTAssertGreaterThan(selWarmth, 0.05,
                             "a selected byte reads as the selection's blue over the tint")
        XCTAssertGreaterThan(distance(unselected, .white), 0.15,
                             "the unselected byte keeps the tint")
        XCTAssertGreaterThan(distance(selected, unselected), 0.08,
                             "selection and tint are not the same colour")
    }

    // MARK: - Stopping at EOF

    /// Past the file's end there is no tint — no bytes, no piece. A file that
    /// ends mid-row leaves its trailing placeholder cells to the EOF fill, a
    /// neutral gray, rather than the piece's colour.
    func testTheTintStopsAtEOF() throws {
        // 20 bytes: row 0 is full, row 1 holds bytes 16–19 and placeholders 20–31.
        let (hexView, pane, url) = try makeHexView([UInt8](repeating: 0x41, count: 20))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(pane.segmentStore.addCut(at: 16))
        hexView.reloadData()
        let layout = hexView.hexLayout
        let y = topY(layout, row: 1)

        // Byte 17 is present (tinted); byte 24 is past EOF.
        let present = try pixel(hexView, x: layout.hexByteX(column: 1) + layout.hexByteWidth / 2, y: y)
        let pastEOF = try pixel(hexView, x: layout.hexByteX(column: 8) + layout.hexByteWidth / 2, y: y)

        XCTAssertGreaterThan(distance(present, .white), 0.15,
                             "a present byte past the cut is tinted")

        // The tints are colours — their channels differ. The EOF fill is a
        // neutral gray — its channels are equal. A past-EOF cell that took the
        // tint would carry the tint's channel spread; the neutral fill does not.
        let eof = pastEOF.usingColorSpace(.deviceRGB)!
        let channelSpread = max(abs(eof.redComponent - eof.greenComponent),
                                abs(eof.greenComponent - eof.blueComponent),
                                abs(eof.redComponent - eof.blueComponent))
        XCTAssertLessThan(channelSpread, 0.05,
                          "a placeholder past EOF is the neutral EOF fill, not the tint's colour")
        XCTAssertGreaterThan(distance(pastEOF, present), 0.08,
                             "the past-EOF cell is not the piece's tint")
    }
}
