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

    /// The change reaches an open pane as a whole: the pane's ideal content
    /// height (rows × row pitch) grows when the factor is raised.
    func testRowHeightScaleChangesAnOpenPanesContentHeight() throws {
        let url = try tempFile([UInt8](repeating: 0xAB, count: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = PaneViewModel()
        try vm.open(url: url)
        let pane = FilePaneView(viewModel: vm)
        let defaultHeight = pane.hexContentHeight

        AppearanceSettings.set(fontFamily: AppearanceSettings.fontFamily, rowHeightScale: 1.0)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertGreaterThan(pane.hexContentHeight, defaultHeight)
    }
}
