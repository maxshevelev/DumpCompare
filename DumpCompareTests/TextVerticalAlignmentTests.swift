import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §3.2 glyph alignment: the baseline is chosen so the glyph ink sits vertically
/// centered in the row, not pushed low by the font's large ascender. Selection
/// and difference backgrounds span the whole row, so a low glyph reads as a
/// background rectangle shifted up beneath it. The regression to guard against:
/// a baseline computed from the ascent box alone (which the flipped-view text
/// anchor inherits) lands the ink ~3.5pt below center.
///
/// Rendered through the real `HexView`'s `draw(_:)` via `cacheDisplay` (a white
/// backing at the backing scale), then sampled: the ink's vertical extent
/// inside a hex cell of row 0 must center on the row's own center.
@MainActor
final class TextVerticalAlignmentTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("align-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    /// A real `HexView` backed by a real `PaneViewModel`, rendered straight to a
    /// bitmap without a window or scroll view, so the test measures the hex
    /// view's own drawing rather than the window's compositing.
    private func makeHexView(_ bytes: [UInt8]) throws -> (HexView, PaneViewModel, URL) {
        let url = try tempFile(bytes)
        let pane = PaneViewModel()
        try pane.open(url: url)
        let hexView = HexView()
        hexView.appearance = NSAppearance(named: .aqua)  // labelColor resolves to black
        hexView.dataSource = pane
        hexView.delegate = pane
        hexView.reloadData()
        return (hexView, pane, url)
    }

    /// Snapshots the view via `cacheDisplay`, which drives the view's real
    /// flipped `draw(_:)` path (the same context the app paints into) onto a
    /// white backing at the backing scale.
    private func render(_ view: HexView) -> NSBitmapImageRep {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("no bitmap rep")
            return NSBitmapImageRep()
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The vertical span, in points, of dark (ink) pixels inside `pixelRect`
    /// (a point-space rect) of a white-backed rendering at `scale` pixels/pt.
    private func inkSpanPoints(_ rep: NSBitmapImageRep, in pointRect: NSRect, scale: CGFloat) -> (CGFloat, CGFloat) {
        let data = rep.bitmapData!
        let startX = max(0, Int(floor(pointRect.minX * scale)))
        let endX = min(rep.pixelsWide - 1, Int(ceil(pointRect.maxX * scale)))
        let startY = max(0, Int(floor(pointRect.minY * scale)))
        let endY = min(rep.pixelsHigh - 1, Int(ceil(pointRect.maxY * scale)))
        var minY = Int.max
        var maxY = -1
        for y in startY...endY {
            for x in startX...endX {
                let p = data.advanced(by: y * rep.bytesPerRow + x * rep.samplesPerPixel)
                if Int(p[0]) < 128 {  // dark ink on the white background
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        if minY > maxY { return (0, 0) }
        return (CGFloat(minY) / scale, CGFloat(maxY) / scale)
    }

    /// The glyph ink inside a byte's hex cell is vertically centered on the row.
    func testHexDigitInkIsCenteredInRow() throws {
        let (hexView, pane, url) = try makeHexView([UInt8](repeating: 0x55, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNotNil(hexView.dataSource)  // pane must stay alive (weak refs)
        _ = pane

        let layout = hexView.hexLayout
        // Column 8: the caret sits at column 0's left edge (full row height) and
        // would pollute the measurement, so sample a caret-free cell.
        let cell = layout.hexByteFrame(row: 0, column: 8)
        let rowHeight = layout.rowHeight
        let rep = render(hexView)
        let scale = CGFloat(rep.pixelsWide) / hexView.bounds.width

        let (inkMin, inkMax) = inkSpanPoints(rep, in: cell, scale: scale)
        let inkCenter = (inkMin + inkMax) / 2

        XCTAssertGreaterThan(inkMax, inkMin, "the cell must contain drawn ink")
        XCTAssertEqual(inkCenter, rowHeight / 2, accuracy: 2,
                       "glyph ink must be vertically centered in the row")
    }
}
