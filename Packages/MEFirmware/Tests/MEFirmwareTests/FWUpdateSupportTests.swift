import XCTest
import Foundation
@testable import MEFirmware

/// `FWUpdateSupportDecider` — row 15: whether Intel's FWUpdate tool can
/// rewrite the image in place. The answer turns on where the independent
/// firmware sits (only the region's own `$FPT` counts) and on which of them
/// the platform requires.
final class FWUpdateSupportTests: XCTestCase {
    private func layout(uncharted: Bool = true, probeHit: Bool = false,
                        alignment: Int = 0) -> FirmwareEndCalculator.Layout {
        FirmwareEndCalculator.Layout(firmwareSize: 0x1000,
                                     hasUnchartedPartition: uncharted,
                                     unchartedProbeHit: probeHit,
                                     alignmentPresent: alignment)
    }

    private func result(major: Int, minor: Int,
                        sku: String = "Consumer H",
                        type: FirmwareType = .extracted,
                        pmc: Bool = false, pchc: Bool = false, phy: Bool = false,
                        family: FirmwareFamily = .csme,
                        layout: FirmwareEndCalculator.Layout? = nil,
                        fptStart: Int = 0x1000) -> FWUpdateSupport? {
        var presence = FWUpdateSupportDecider.IUPPresence()
        presence.pmc = pmc
        presence.pchc = pchc
        presence.phy = phy
        return FWUpdateSupportDecider.result(
            family: family, major: major, minor: minor, type: type, sku: sku,
            iup: presence, layout: layout ?? self.layout(), fptStart: fptStart)
    }

    /// The row belongs to CSME 12 and newer, and to no one else.
    func testOnlyCSME12AndNewerGetAnAnswer() {
        XCTAssertNil(result(major: 11, minor: 8))
        XCTAssertNil(result(major: 12, minor: 0, family: .cssps))
        XCTAssertNil(result(major: 7, minor: 1, family: .me))
        XCTAssertNotNil(result(major: 12, minor: 0))
    }

    /// CSME 12 asks for the Power Management Controller alone.
    func testCSME12NeedsThePMCOnly() {
        XCTAssertEqual(result(major: 12, minor: 0, pmc: true), .yes)
        XCTAssertEqual(result(major: 12, minor: 0), .no)
        // The others make no difference to it.
        XCTAssertEqual(result(major: 12, minor: 0, pmc: true, pchc: true, phy: true),
                       .yes)
    }

    /// The platforms that stitch a Platform Controller Hub Configuration ask
    /// for it too, and those with a USB Type C Physical for all three.
    func testThePerPlatformRequirements() {
        for version in [(13, 0), (13, 50), (14, 0), (14, 5), (15, 40), (16, 0)] {
            XCTAssertEqual(result(major: version.0, minor: version.1,
                                  pmc: true, pchc: true), .yes,
                           "\(version.0).\(version.1)")
            XCTAssertEqual(result(major: version.0, minor: version.1, pmc: true), .no,
                           "\(version.0).\(version.1)")
        }
        for version in [(13, 30), (14, 1)] {
            XCTAssertEqual(result(major: version.0, minor: version.1,
                                  pmc: true, pchc: true, phy: true), .yes)
            XCTAssertEqual(result(major: version.0, minor: version.1,
                                  pmc: true, pchc: true), .no)
        }
        // A version outside the table asks for all three.
        XCTAssertEqual(result(major: 16, minor: 1, pmc: true, pchc: true), .no)
        XCTAssertEqual(result(major: 16, minor: 1,
                              pmc: true, pchc: true, phy: true), .yes)
    }

    /// CSME 15.0 splits on the SKU letters: an LP part needs no Physical, an H
    /// one does.
    func testTheTigerPointSplitOnTheSKU() {
        XCTAssertEqual(result(major: 15, minor: 0, sku: "Consumer LP",
                              pmc: true, pchc: true), .yes)
        XCTAssertEqual(result(major: 15, minor: 0, sku: "Consumer H",
                              pmc: true, pchc: true), .no)
        XCTAssertEqual(result(major: 15, minor: 0, sku: "Consumer H",
                              pmc: true, pchc: true, phy: true), .yes)
    }

    /// A Corporate extracted image with no uncharted partition cannot be made
    /// updatable by adding one — upstream's third answer.
    func testImpossibleForACorporateExtractedImageWithNothingUncharted() {
        XCTAssertEqual(result(major: 12, minor: 0, sku: "Corporate H",
                              pmc: true, layout: layout(uncharted: false)),
                       .impossible)
        // The probe finding one past the padding rather than at the end is the
        // same verdict.
        XCTAssertEqual(result(major: 12, minor: 0, sku: "Corporate H", pmc: true,
                              layout: layout(uncharted: true, probeHit: true)),
                       .impossible)
        // A Consumer image, or one that is not extracted, is judged on its
        // partitions like any other.
        XCTAssertEqual(result(major: 12, minor: 0, sku: "Consumer H", pmc: true,
                              layout: layout(uncharted: false)), .yes)
        XCTAssertEqual(result(major: 12, minor: 0, sku: "Corporate H",
                              type: .stock, pmc: true,
                              layout: layout(uncharted: false)), .yes)
    }

    /// A CSME 16 image at the very start of what was handed over, carrying the
    /// 4 KiB padding its own builder leaves off: FWUpdate will not take it.
    func testImpossibleForAPaddedCSME16AtOffsetZero() {
        XCTAssertEqual(result(major: 16, minor: 0, pmc: true, pchc: true,
                              layout: layout(alignment: 0x800), fptStart: 0),
                       .impossible)
        // Padding present but the firmware is not at the start, or no padding
        // at all: the ordinary answer.
        XCTAssertEqual(result(major: 16, minor: 0, pmc: true, pchc: true,
                              layout: layout(alignment: 0x800), fptStart: 0x1000),
                       .yes)
        XCTAssertEqual(result(major: 16, minor: 0, pmc: true, pchc: true,
                              layout: layout(alignment: 0), fptStart: 0), .yes)
    }

    /// The presence flags read a partition inventory the way upstream's `$FPT`
    /// walk does: every name each family goes by, and never an empty one.
    func testThePresenceFlagsReadTheFPTInventory() {
        func part(_ name: String, empty: Bool = false) -> FPTParser.Partition {
            FPTParser.Partition(name: name, offset: 0x1000, size: 0x1000,
                                flags: 0, empty: empty)
        }
        let all = FWUpdateSupportDecider.IUPPresence(partitions: [
            part("FTPR"), part("PCOD"), part("PCHC"), part("SPHY"),
        ])
        XCTAssertEqual(all, {
            var expected = FWUpdateSupportDecider.IUPPresence()
            expected.pmc = true
            expected.pchc = true
            expected.phy = true
            return expected
        }())

        let empties = FWUpdateSupportDecider.IUPPresence(partitions: [
            part("PMCP", empty: true), part("PCHC", empty: true),
        ])
        XCTAssertEqual(empties, FWUpdateSupportDecider.IUPPresence())
    }
}
