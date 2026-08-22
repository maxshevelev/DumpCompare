import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §3.2: an open hex view re-lays out when the Appearance settings change. The
/// row-height factor changes the row pitch; the font family swaps the glyph
/// metrics the whole dump is measured in. Both paths flow through the settings
/// notification → `applyAppearance()` → `reloadData()`.
@MainActor
final class HexViewAppearanceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppearanceSettings.resetToDefaults()
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    override func tearDown() {
        AppearanceSettings.resetToDefaults()
        super.tearDown()
    }

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appearance-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    /// A real `HexView` backed by a real `PaneViewModel` (no window/scroll view
    /// needed — we only read layout metrics).
    private func makeHexView(_ bytes: [UInt8]) throws -> (HexView, PaneViewModel, URL) {
        let url = try tempFile(bytes)
        let pane = PaneViewModel()
        try pane.open(url: url)
        let hexView = HexView()
        hexView.dataSource = pane
        hexView.delegate = pane
        hexView.reloadData()
        return (hexView, pane, url)
    }

    /// The row pitch shrinks when the factor is lowered and grows when raised.
    func testRowHeightScaleChangesRowPitch() throws {
        let (hexView, pane, url) = try makeHexView([UInt8](repeating: 0xAB, count: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        _ = pane  // pane must stay alive (weak refs)

        let defaultPitch = hexView.hexLayout.rowHeight
        XCTAssertGreaterThan(defaultPitch, 0)

        AppearanceSettings.set(fontFamily: AppearanceSettings.fontFamily, rowHeightScale: 1.0)
        // The observer delivers on the main queue; give it a runloop turn.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let expanded = hexView.hexLayout.rowHeight
        XCTAssertGreaterThan(expanded, defaultPitch)

        AppearanceSettings.set(fontFamily: AppearanceSettings.fontFamily, rowHeightScale: 0.65)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let compact = hexView.hexLayout.rowHeight
        XCTAssertLessThan(compact, defaultPitch)
    }

    /// Setting a named family swaps the dump's font and re-derives the layout
    /// metrics from the new font (its char width and its own row height).
    func testFontFamilySwapsTheDumpFontAndRelaysOut() throws {
        let family = try XCTUnwrap(AppearanceSettings.monospacedFontFamilies().first)
        let (hexView, pane, url) = try makeHexView([UInt8](repeating: 0xAB, count: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        _ = pane

        AppearanceSettings.set(fontFamily: family, rowHeightScale: AppearanceSettings.rowHeightScale)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let newFont = AppearanceSettings.font(size: 13)
        XCTAssertEqual(hexView.hexFont.familyName, family)
        // The layout must be rebuilt from the resolved font, not stale metrics.
        let expectedCharWidth = ("0" as NSString).size(withAttributes: [.font: newFont]).width
        XCTAssertEqual(hexView.hexLayout.charWidth, expectedCharWidth, accuracy: 0.01)
    }

    // MARK: - Hex-column string shape (§ Option B)

    private func state(_ byte: UInt8, modified: Bool = false) -> HexByteState {
        HexByteState(byte: byte, isModified: modified)
    }

    /// The hex column is drawn as one attributed string whose fixed-width
    /// characters land on the same cell grid as the layout's per-byte geometry.
    /// Its length encodes the inter-cell spacing, so pin it against every word
    /// size: 16 bytes × 2 digits, plus the 1-character word gaps and the
    /// 2-character gap between the two 8-byte groups.
    func testHexColumnStringGapCountsForAllWordSizes() throws {
        let hexView = HexView()
        let states = [HexByteState](repeating: state(0x55), count: 16)
        let expected = [1: 48, 2: 40, 4: 36, 8: 34]  // 32 digits + gaps
        for (wordSize, count) in expected {
            let layout = HexLayout(charWidth: 8, rowHeight: 17, wordSize: wordSize)
            let s = hexView.hexColumnAttributedString(states: states, layout: layout)
            XCTAssertEqual(s.length, count, "wordSize \(wordSize)")
        }
    }

    /// EOF cells draw nothing and always trail (a file is a prefix), so the
    /// string simply ends at the first one.
    func testHexColumnStringStopsAtFirstEOF() throws {
        let hexView = HexView()
        var states = [HexByteState](repeating: state(0x55), count: 4)
        states += [HexByteState](repeating: HexByteState(isEOF: true), count: 12)
        let layout = HexLayout(charWidth: 8, rowHeight: 17, wordSize: 1)
        let s = hexView.hexColumnAttributedString(states: states, layout: layout)
        // 4 bytes × 2 digits, with the four single spaces that follow columns
        // 0–3 in the byte-per-cell layout.
        XCTAssertEqual(s.length, 8 + 4)
    }

    /// Adjacent bytes of the same colour merge into one run; a modified byte
    /// opens a red run. The string must split exactly at colour boundaries.
    func testHexColumnStringSplitsRunsPerColor() throws {
        let hexView = HexView()
        let states = (0..<16).map { state(0x55, modified: $0 == 5) }
        let layout = HexLayout(charWidth: 8, rowHeight: 17, wordSize: 1)
        let s = hexView.hexColumnAttributedString(states: states, layout: layout)

        var runs = 0
        var last: NSColor?
        for i in 0..<s.length {
            let c = s.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor
            if c !== last {
                runs += 1
                last = c
            }
        }
        XCTAssertEqual(runs, 3, "label run, the red run, label run")
    }
}
