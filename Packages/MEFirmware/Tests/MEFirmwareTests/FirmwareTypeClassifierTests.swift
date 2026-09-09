import XCTest
import Foundation
@testable import MEFirmware

/// `FirmwareTypeClassifier` — the Stock / Update / Extracted port of upstream
/// `fw_type` (MEA.py 12538–12588). Fixtures are synthetic `FPTParser.Result`s
/// built directly (not decoded), so each test pins one classifier branch to the
/// exact partition inventory and region bytes that branch keys off.
final class FirmwareTypeClassifierTests: XCTestCase {
    // MARK: - Fixture builders

    private func partition(_ name: String, offset: Int, size: Int,
                           empty: Bool = false) -> FPTParser.Partition {
        FPTParser.Partition(name: name, offset: offset, size: size,
                            flags: 0, empty: empty)
    }

    private func fpt(partitions: [FPTParser.Partition], fitBuild: Int = 0,
                     fptStart: Int = 0) -> FPTParser.Result {
        FPTParser.Result(headerVersion: 0x20, resolvedVersion: 0x20,
                         fptStart: fptStart,
                         fitMajor: 0, fitMinor: 0, fitHotfix: 0,
                         fitBuild: fitBuild,
                         partitions: partitions, cseLayout: nil)
    }

    /// A not-erased region: 0x00 fill, so the erased-window checks upstream uses
    /// to spot placeholders / ROM-Bypass vectors read *not* erased.
    private func liveRegion(_ size: Int = 0x4000) -> Data {
        Data(repeating: 0x00, count: size)
    }

    // MARK: - The axis

    /// An IFWI image is always Extracted (12541–12547), whatever its `$FPT`.
    func testIFWIIsExtracted() {
        let result = FirmwareTypeClassifier.classify(
            family: .csme, major: 15, isIFWI: true,
            fpt: fpt(partitions: [partition("FTPR", offset: 0x1000, size: 0x1000)]),
            region: liveRegion())
        XCTAssertEqual(result, .extracted)
    }

    /// No `$FPT` region at all → upstream's final Update (12588).
    func testNoRegionIsUpdate() {
        let result = FirmwareTypeClassifier.classify(
            family: .csme, major: 12, isIFWI: false, fpt: nil,
            region: liveRegion())
        XCTAssertEqual(result, .update)
    }

    /// SPS 1–3 are hand-built, never flashed with the FIT → Extracted (12548).
    func testSPSIsExtracted() {
        let result = FirmwareTypeClassifier.classify(
            family: .sps, major: 3, isIFWI: false,
            fpt: fpt(partitions: [partition("SPS0", offset: 0x1000, size: 0x1000)]),
            region: liveRegion())
        XCTAssertEqual(result, .extracted)
    }

    /// A non-IFWI independent family does not sit on this axis → Unknown.
    func testIndependentFamilyIsUnknown() {
        let result = FirmwareTypeClassifier.classify(
            family: .pmc, major: 1, isIFWI: false,
            fpt: fpt(partitions: [partition("PMCP", offset: 0x1000, size: 0x1000)]),
            region: liveRegion())
        XCTAssertEqual(result, .unknown)
    }

    // MARK: - ME 2–7 (fixture-only)

    /// A dirty FOVD (ME 3+) marks an Extracted image before anything else.
    func testME2to7DirtyFOVDIsExtracted() {
        let result = FirmwareTypeClassifier.classify(
            family: .me, major: 5, isIFWI: false,
            fpt: fpt(partitions: [partition("FOVD", offset: 0x1000, size: 0x1000)]),
            region: liveRegion())
        XCTAssertEqual(result, .extracted)
    }

    /// Clean FOVD and no `KRND\x00` string → a stock pre-CSE ME (12558).
    func testME2to7CleanNoKRNDIsStock() {
        let result = FirmwareTypeClassifier.classify(
            family: .me, major: 5, isIFWI: false,
            fpt: fpt(partitions: [partition("FOVD", offset: 0x1000, size: 0x1000,
                                            empty: true)]),
            region: liveRegion())
        XCTAssertEqual(result, .stock)
    }

    /// A `KRND\x00` string anywhere marks an Extracted image (12556).
    func testME2to7KRNDStringIsExtracted() {
        var region = liveRegion()
        region.replaceSubrange(0x200..<0x206, with: Data("KRND\0".utf8))
        let result = FirmwareTypeClassifier.classify(
            family: .me, major: 6, isIFWI: false,
            fpt: fpt(partitions: [partition("FOVD", offset: 0x1000, size: 0x1000,
                                            empty: true)]),
            region: region)
        XCTAssertEqual(result, .extracted)
    }

    // MARK: - CSME-like (ME 8+, CSME/CSTXE/CSSPS/TXE/GSC)

    /// An Update image's `$FPT` lists exactly the non-empty FTPR/FTUP/NFTP trio
    /// (12564) — checked before any FIT reading, so even a no-FIT header is
    /// Update.
    func testExactlyFTUPTrioIsUpdate() {
        let result = FirmwareTypeClassifier.classify(
            family: .csme, major: 12, isIFWI: false,
            fpt: fpt(partitions: [
                partition("FTPR", offset: 0x1000, size: 0x1000),
                partition("FTUP", offset: 0x2000, size: 0x1000),
                partition("NFTP", offset: 0x3000, size: 0x1000),
            ]),
            region: liveRegion())
        XCTAssertEqual(result, .update)
    }

    /// A clean stock (CS)ME `$FPT` carries the no-FIT build marker and no dirty
    /// FOVD → Stock (12567/12577). The CSME 11 whole-flash model (old.bin) sits
    /// here: no CSE-LT Boot BPDT (isIFWI false), marker FIT, clean FOVD.
    func testCleanStockMarkerFITIsStock() {
        let result = FirmwareTypeClassifier.classify(
            family: .csme, major: 11, isIFWI: false,
            fpt: fpt(partitions: [
                partition("FTPR", offset: 0x1000, size: 0x1000),
                partition("FOVD", offset: 0x2000, size: 0x1000, empty: true),
            ]),
            region: liveRegion())
        XCTAssertEqual(result, .stock)
    }

    /// A real FIT build in the header means the image was built with the Flash
    /// Image Tool → Extracted (12581–12586), whatever the partition inventory.
    func testRealFITIsExtracted() {
        let result = FirmwareTypeClassifier.classify(
            family: .csme, major: 12, isIFWI: false,
            fpt: fpt(partitions: [partition("FTPR", offset: 0x1000, size: 0x1000)],
                     fitBuild: 1091),
            region: liveRegion())
        XCTAssertEqual(result, .extracted)
    }

    /// CSME 13+ Update images carry placeholder `$FPT` ROM-Bypass vectors: the
    /// 0x10 erased window before the marker. Here the tail window (which would
    /// trigger the CSTXE placeholder branch) stays live, isolating the CSME 13
    /// leg (12578).
    func testCSME13ErasedHeaderVectorsIsExtracted() {
        // Region: FF up to fptStart+0x10 (the erased head), then live content so
        // the head+tail CSTXE check does not fire first.
        var region = Data(repeating: 0xFF, count: 0x4000)
        region.replaceSubrange(0x10..<0x20, with: Data(repeating: 0x00, count: 0x10))
        let result = FirmwareTypeClassifier.classify(
            family: .csme, major: 13, isIFWI: false,
            fpt: fpt(partitions: [partition("FTPR", offset: 0x1000, size: 0x1000)],
                     fptStart: 0),
            region: region)
        XCTAssertEqual(result, .extracted)
    }

    /// A dirty FOVD overrides even a no-FIT stock-looking header → Extracted
    /// (12576).
    func testDirtyFOVDBeatsStockMarker() {
        let result = FirmwareTypeClassifier.classify(
            family: .csme, major: 12, isIFWI: false,
            fpt: fpt(partitions: [partition("FOVD", offset: 0x1000, size: 0x1000)]),
            region: liveRegion())
        XCTAssertEqual(result, .extracted)
    }

}
