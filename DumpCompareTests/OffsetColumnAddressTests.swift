import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §6 offset column: the address's leading zeros are dimmed so the significant
/// part of the address stands out. The split is at the first non-zero digit, so
/// an all-zero address (row 0) is muted in full. The rule lives in
/// `HexView.offsetAddress`; the drawing layer consumes it per row.
@MainActor
final class OffsetColumnAddressTests: XCTestCase {
    /// The offset column's address as `HexView` builds it: the leading zeros in
    /// the muted colour, the significant part in the full ink.
    private func address(_ text: String) -> NSAttributedString {
        HexView().offsetAddress(text, normal: HexTheme.inkBlue, muted: HexTheme.mutedInkBlue)
    }

    /// The colour at a character, which resolves to one of the theme's singletons,
    /// so identity (`===`) is the right comparison.
    private func color(_ attributed: NSAttributedString, at index: Int) -> NSColor? {
        attributed.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    /// The leading zeros are muted and the significant part is the full ink: the
    /// split is at the first non-zero digit.
    func testLeadingZerosAreMutedAndTheSignificantPartIsFullInk() {
        let attributed = address("00000010")
        XCTAssertTrue(color(attributed, at: 0) === HexTheme.mutedInkBlue,
                      "the leading zero is muted")
        XCTAssertTrue(color(attributed, at: 5) === HexTheme.mutedInkBlue,
                      "the last leading zero is muted")
        XCTAssertTrue(color(attributed, at: 6) === HexTheme.inkBlue,
                      "the first significant digit is the full ink")
        XCTAssertTrue(color(attributed, at: 7) === HexTheme.inkBlue,
                      "the rest of the address is the full ink")
    }

    /// An all-zero address (row 0) has no significant part, so it is muted in
    /// full.
    func testAnAllZeroAddressIsMutedInFull() {
        let attributed = address("00000000")
        for index in 0..<8 {
            XCTAssertTrue(color(attributed, at: index) === HexTheme.mutedInkBlue,
                          "every character of row 0's address is muted")
        }
    }

    /// An address whose first digit is non-zero has no leading zeros, so it is
    /// the full ink throughout.
    func testAnAddressWithNoLeadingZerosIsFullInk() {
        let attributed = address("10000000")
        for index in 0..<8 {
            XCTAssertTrue(color(attributed, at: index) === HexTheme.inkBlue,
                          "an address with no leading zeros is the full ink")
        }
    }
}
