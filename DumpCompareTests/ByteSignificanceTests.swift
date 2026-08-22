import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §6 significance accent: "fill" bytes (0x00, 0xFF) are drawn paler so the
/// significant bytes around them read more contrasty. The rule lives in
/// `HexTheme.textColor(for:)`; the drawing layer consumes it per byte.
final class ByteSignificanceTests: XCTestCase {
    /// The colour is chosen per byte state and returned as one of the theme's
    /// singletons, so identity (`===`) is the right comparison.
    private func color(for byte: UInt8, modified: Bool = false) -> NSColor {
        HexTheme.textColor(for: HexByteState(byte: byte, isModified: modified))
    }

    func testFillBytesAreMuted() {
        XCTAssertTrue(color(for: 0x00) === HexTheme.mutedByteText)
        XCTAssertTrue(color(for: 0xFF) === HexTheme.mutedByteText)
    }

    func testOtherBytesKeepFullContrast() {
        XCTAssertTrue(color(for: 0x01) === HexTheme.byteText)
        XCTAssertTrue(color(for: 0x7F) === HexTheme.byteText)
        XCTAssertTrue(color(for: 0x80) === HexTheme.byteText)
        XCTAssertTrue(color(for: 0xFE) === HexTheme.byteText)
    }

    /// A modified byte stays red even when its value is a fill byte — the
    /// unsaved-change warning outranks the significance accent.
    func testModifiedOverridesSignificance() {
        XCTAssertTrue(color(for: 0x00, modified: true) === HexTheme.modifiedText)
        XCTAssertTrue(color(for: 0xFF, modified: true) === HexTheme.modifiedText)
        XCTAssertTrue(color(for: 0x41, modified: true) === HexTheme.modifiedText)
    }

    /// The muted colour must actually read dimmer than the full-contrast one.
    ///
    /// The dimming is alpha (0x00/0xFF bytes are drawn at part opacity), so the
    /// test resolves both colours in a pinned appearance and compares that. The
    /// previous version asked whether the two were `isEqual`, and a dynamic
    /// `NSColor(name: nil)` never equals a semantic one — so it passed even for a
    /// "muted" colour identical to the ink beside it.
    func testMutedTextIsDimmer() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var muted: CGFloat = -1
            var full: CGFloat = -1
            appearance.performAsCurrentDrawingAppearance {
                muted = HexTheme.mutedByteText.usingColorSpace(.sRGB)?.alphaComponent ?? -1
                full = HexTheme.byteText.usingColorSpace(.sRGB)?.alphaComponent ?? -1
            }
            // labelColor itself resolves at ~0.85 alpha, so "full strength" is
            // that, not 1.0; muted is a deliberate 0.4.
            XCTAssertGreaterThan(full, 0.8, "significant bytes keep the label's own strength (\(name.rawValue))")
            XCTAssertLessThan(muted, 0.6, "0x00/0xFF must read clearly dimmer (\(name.rawValue))")
            XCTAssertGreaterThan(muted, 0.25, "…but still be readable (\(name.rawValue))")
        }
    }
}
