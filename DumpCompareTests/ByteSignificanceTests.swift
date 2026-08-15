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
    func testMutedTextIsDimmer() {
        XCTAssertFalse(HexTheme.mutedByteText.isEqual(to: HexTheme.byteText))
    }
}
