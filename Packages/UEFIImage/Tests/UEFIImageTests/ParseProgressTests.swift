import XCTest
@testable import UEFIImage

/// The progress a caller asks the scan to report while it parses
/// (`UEFIParser.parse(progress:)`): fractions of the image the scan has
/// crossed, going forward. A tool-module turns them into a moving bar, so this
/// is where "the bar must actually move" is guaranteed.
final class ParseProgressTests: XCTestCase {
    /// A raw image has no descriptor, so the whole thing is walked byte by
    /// byte — the one slow path in a UEFI parse, and the only one that needs
    /// progress. 2 MiB spans several of the scan's 1 MiB windows.
    func testScanReportsMonotonicProgressAcrossTheImage() {
        let image = [UInt8](repeating: 0xFF, count: 2 << 20)
        var seen: [Double] = []
        let parsed = UEFIParser.parse(image, progress: { seen.append($0) })

        XCTAssertGreaterThanOrEqual(seen.count, 3,
                                    "the scan should report more than once across several windows")
        XCTAssertTrue(seen.allSatisfy { $0 > 0 && $0 <= 1 },
                      "fractions live in (0, 1]")
        var previous = 0.0
        for fraction in seen {
            XCTAssertGreaterThanOrEqual(fraction, previous,
                                        "progress must never walk backwards: \(seen)")
            previous = fraction
        }
        XCTAssertEqual(seen.last, 1,
                       "a scan that reads to the end of the image reports having done so")
        XCTAssertEqual(parsed.roots.map(\.kind), [.padding])
    }

    /// Reporting is opt-in: no callback, no overhead, and — importantly — the
    /// parse still behaves identically. Guarded because a regression that made
    /// progress reporting interfere with parsing would be easy to miss while
    /// every progress test still passes.
    func testParseWithoutProgressStillParses() {
        let image = [UInt8](repeating: 0xFF, count: 0x200)

        let parsed = UEFIParser.parse(image)

        XCTAssertEqual(parsed.roots.map(\.kind), [.padding])
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }
}
