import XCTest
import Foundation
@testable import MEFirmware

/// Pre-CSE (classic ME 2–10) `$SKU` SKU_Attributes decode (upstream-map row 50).
///
/// The byte semantics are pinned to the real Lenovo T450 oracle: an R0 ME10
/// manifest whose `$SKU` FWSKUAttrib is `cf fa ff ff 0a 43 00 00` decodes (via
/// upstream's ctypes BigEndianStructure bitfields) to Value1=0xCFFAFF,
/// slim=true, Patsburg=false, SKUType=0, SKUSize=10 (=5.0 MB), Value10=0x430000
/// → summary rows `sku` "5MB" / `platform` "WPT-LP", and its manifest VCN=2.
final class PreCSEDecodeTests: XCTestCase {
    // MARK: - Fixtures

    /// The eight `FWSKUAttrib` bytes of the real T450 ME10 `$SKU`.
    private let t450Attrib: [UInt8] = [0xCF, 0xFA, 0xFF, 0xFF, 0x0A, 0x43, 0x00, 0x00]

    /// Region with a `$SKU` SKU_Attributes block starting at `blockOffset`
    /// (`manifestBase` ≤ blockOffset ≤ region end). 0xFF filler before it and
    /// trailing filler after so the scan has room to read the header.
    private func skuRegion(blockOffset: Int,
                           sizeByte: UInt8 = 4,
                           attrib: [UInt8]) -> Data {
        var data = Data(repeating: 0xFF, count: blockOffset)
        data.append(Data("$SKU".utf8))
        data.append(sizeByte)                          // Size (dwords): 3 (ME2-6) / 4 (ME7-10)
        data.append(contentsOf: [0, 0, 0])             // Size hi bytes
        precondition(attrib.count == 8)
        data.append(contentsOf: attrib)                // FWSKUAttrib u64
        data.append(Data(repeating: 0xFF, count: 32))  // room beyond the block
        return data
    }

    private func summary(in region: Data, at manifestBase: Int,
                         major: Int, minor: Int, hotfix: Int = 0, build: Int = 0)
        -> PreCSEME.Summary? {
        PreCSEME.summary(in: region, manifestBase: manifestBase,
                         major: major, minor: minor, hotfix: hotfix, build: build)
    }

    /// Row 13 and row 21 — the two things only an ME 7 image says.
    ///
    /// The Patsburg bit rides in the same `$SKU` byte as the SKU size, and the
    /// blacklist entries sit at fixed offsets from the manifest's tag, which is
    /// upstream's `start_man_match` (the byte before the tag) — the manifest
    /// base plus 0x1B here.
    func testME7SaysPatsburgSupportAndItsDowngradeBlacklist() throws {
        // SKUSize 3 (1.5 MB) with the Patsburg bit set: byte 4 = 0x83.
        let patsburg = skuRegion(blockOffset: 0x40,
                                 attrib: [0, 0, 0, 0, 0x83, 0, 0, 0])
        let supported = try XCTUnwrap(summary(in: patsburg, at: 0, major: 7, minor: 1))
        XCTAssertEqual(supported.patsburgSupport, true)
        XCTAssertEqual(supported.platform, "CPT/PBG", "and the platform says so too")

        let plain = skuRegion(blockOffset: 0x40, attrib: [0, 0, 0, 0, 0x03, 0, 0, 0])
        let unsupported = try XCTUnwrap(summary(in: plain, at: 0, major: 7, minor: 1))
        XCTAssertEqual(unsupported.patsburgSupport, false)
        XCTAssertEqual(unsupported.platform, "CPT")

        // A major whose `$SKU` byte means something else says nothing about
        // Patsburg.
        XCTAssertNil(try XCTUnwrap(summary(in: patsburg, at: 0, major: 10, minor: 0))
            .patsburgSupport)
    }

    /// The blacklist words: minor/hotfix/build at 0x6DF and 0x6EB past the
    /// manifest's tag, and a zero build is the "Empty" line upstream prints.
    func testTheDowngradeBlacklistReadsBothLines() {
        var region = Data(repeating: 0, count: 0x2000)
        func write(_ words: [Int], at offset: Int) {
            for (index, word) in words.enumerated() {
                region[offset + index * 2] = UInt8(word & 0xFF)
                region[offset + index * 2 + 1] = UInt8((word >> 8) & 0xFF)
            }
        }
        let base = 0x100
        let tag = base + 0x1B
        write([1, 2, 1000], at: tag + 0x6DF)   // <= 7.1.2.1000
        write([0, 0, 0], at: tag + 0x6EB)      // Empty

        let entries = PreCSEME.downgradeBlacklist(in: region, manifestBase: base)
        XCTAssertEqual(entries.sevenZero,
                       PreCSEME.BlacklistEntry(minor: 1, hotfix: 2, build: 1000))
        XCTAssertNil(entries.sevenOne, "a zero build word blacklists nothing")

        // Past the end of the region there is nothing to read, and nothing is
        // claimed.
        let short = PreCSEME.downgradeBlacklist(in: Data(repeating: 0, count: 0x100),
                                                manifestBase: 0)
        XCTAssertNil(short.sevenZero)
        XCTAssertNil(short.sevenOne)
    }

    // MARK: - Byte split (scan)

    func testScanSplitsT450OracleBytesExactly() throws {
        // `cf fa ff ff 0a 43 00 00` is the oracle read back big-endian, matching
        // upstream's ctypes BigEndianStructure over the 8 bytes.
        let region = skuRegion(blockOffset: 0x100, attrib: t450Attrib)
        let a = try XCTUnwrap(PreCSEME.scan(in: region, manifestBase: 0x100))
        XCTAssertEqual(a.offset, 0x100)
        XCTAssertEqual(a.sizeDwords, 4)
        XCTAssertEqual(a.skuMe, 0xCFFA_FFFF)     // bytes 0–3 big-endian (ME 2–6 path)
        XCTAssertEqual(a.value1, 0xCFFAFF)       // bytes 0–2
        XCTAssertEqual(a.slim, true)             // byte 3 bit 7 (0xFF)
        XCTAssertEqual(a.patsburg, false)        // byte 4 bit 7 (0x0A)
        XCTAssertEqual(a.skuType, 0)             // byte 4 bits 6–4
        XCTAssertEqual(a.skuSize, 10)            // byte 4 bits 3–0 → 5.0 MB
        XCTAssertEqual(a.value10, 0x430000)      // bytes 5–7
    }

    func testScanAllowsSize3AndSmallSKUSize() throws {
        // ME 2–6 SKUs carry Size 3 dwords; an ME7 `$SKU` can have skuSize 1.
        let region = skuRegion(blockOffset: 0, sizeByte: 3,
                               attrib: [0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00])
        let a = try XCTUnwrap(PreCSEME.scan(in: region, manifestBase: 0))
        XCTAssertEqual(a.sizeDwords, 3)
        XCTAssertEqual(a.skuSize, 1)
        XCTAssertEqual(a.slim, false)
    }

    func testScanSkipsMalformedHeaderToReachValidBlock() throws {
        // A `$SKU` tag whose Size byte is not 3/4 must not be decoded; the scan
        // keeps going and finds the real SKU_Attributes later.
        var data = Data(repeating: 0xFF, count: 0x80)
        data.append(Data("$SKU".utf8))
        data.append(0x05)                             // bad Size
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let realBase = data.count                     // the valid block follows
        data.append(skuRegion(blockOffset: 0, attrib: t450Attrib))
        let a = try XCTUnwrap(PreCSEME.scan(in: data, manifestBase: 0x80))
        XCTAssertEqual(a.offset, realBase)
    }

    func testScanReturnsNilWithoutSKU() {
        let region = Data(repeating: 0xFF, count: 0x200)
        XCTAssertNil(PreCSEME.scan(in: region, manifestBase: 0))
        XCTAssertNil(summary(in: region, at: 0, major: 10, minor: 0))
    }

    // MARK: - ME 7–10 bitfield mapping

    func testME10T450OracleMapsTo5MBWPTLP() throws {
        let region = skuRegion(blockOffset: 0x100, attrib: t450Attrib)
        let s = try XCTUnwrap(summary(in: region, at: 0x100, major: 10, minor: 0))
        XCTAssertEqual(s.sku, "5MB")
        XCTAssertEqual(s.platform, "WPT-LP")
    }

    func testME10SlimSKUType2() throws {
        // SKUType 2 → Slim; byte 4 = (2 << 4) with skuSize 0.
        let region = skuRegion(blockOffset: 0, attrib: [0, 0, 0, 0, 0x20, 0, 0, 0])
        let s = try XCTUnwrap(summary(in: region, at: 0, major: 10, minor: 0))
        XCTAssertEqual(s.sku, "Slim")
        XCTAssertEqual(s.platform, "WPT-LP")
    }

    func testME10SKUType1Is15MB() throws {
        let region = skuRegion(blockOffset: 0, attrib: [0, 0, 0, 0, 0x10, 0, 0, 0])
        XCTAssertEqual(summary(in: region, at: 0, major: 10, minor: 0)?.sku, "1.5MB")
    }

    func testME10PlatformNilForNonzeroMinor() throws {
        // WPT-LP platform label is only emitted at minor 0 (upstream WPT-LP arm).
        let region = skuRegion(blockOffset: 0, attrib: t450Attrib)
        let s = try XCTUnwrap(summary(in: region, at: 0, major: 10, minor: 1))
        XCTAssertEqual(s.sku, "5MB")
        XCTAssertNil(s.platform)
    }

    func testME9PlatformByMinor() throws {
        let region = skuRegion(blockOffset: 0, attrib: [0, 0, 0, 0, 0x10, 0, 0, 0])  // 1.5MB
        XCTAssertEqual(summary(in: region, at: 0, major: 9, minor: 0)?.platform, "LPT")
        XCTAssertEqual(summary(in: region, at: 0, major: 9, minor: 1)?.platform, "LPT/WPT")
        XCTAssertEqual(summary(in: region, at: 0, major: 9, minor: 5)?.platform, "LPT-LP")
        XCTAssertEqual(summary(in: region, at: 0, major: 9, minor: 6)?.platform, "LPT-LP")
        XCTAssertNil(summary(in: region, at: 0, major: 9, minor: 7)?.platform)
        // The SKU itself (SKUType 1) holds across the platform minors.
        XCTAssertEqual(summary(in: region, at: 0, major: 9, minor: 0)?.sku, "1.5MB")
    }

    func testME8SKUSizeInHalfMB() throws {
        // skuSize is in 0.5 MB units: 3 → 1.5 MB, 10 → 5 MB.
        let slim = skuRegion(blockOffset: 0, attrib: [0, 0, 0, 0, 0x03, 0, 0, 0])
        XCTAssertEqual(summary(in: slim, at: 0, major: 8, minor: 0)?.sku, "1.5MB")
        XCTAssertEqual(summary(in: slim, at: 0, major: 8, minor: 0)?.platform, "CPT/PBG/PPT")
        let big = skuRegion(blockOffset: 0, attrib: [0, 0, 0, 0, 0x0A, 0, 0, 0])
        XCTAssertEqual(summary(in: big, at: 0, major: 8, minor: 0)?.sku, "5MB")
    }

    func testME7SlimAndPatsburg() throws {
        // slim = byte 3 bit 7 (Value2); Patsburg = byte 4 bit 7.
        let plain = skuRegion(blockOffset: 0, attrib: [0, 0, 0, 0, 0x0A, 0, 0, 0])   // 5MB, not Patsburg
        XCTAssertEqual(summary(in: plain, at: 0, major: 7, minor: 0)?.sku, "5MB")
        XCTAssertEqual(summary(in: plain, at: 0, major: 7, minor: 0)?.platform, "CPT")

        let slim = skuRegion(blockOffset: 0, attrib: [0, 0, 0, 0x80, 0x0A, 0, 0, 0])  // slim + 5MB
        XCTAssertEqual(summary(in: slim, at: 0, major: 7, minor: 0)?.sku, "Slim")

        let patsburg = skuRegion(blockOffset: 0, attrib: [0, 0, 0, 0, 0x8A, 0, 0, 0])  // Patsburg + 5MB
        XCTAssertEqual(summary(in: patsburg, at: 0, major: 7, minor: 0)?.platform, "CPT/PBG")

        let both = skuRegion(blockOffset: 0, attrib: [0, 0, 0, 0x80, 0x8A, 0, 0, 0])
        XCTAssertEqual(summary(in: both, at: 0, major: 7, minor: 0)?.sku, "Slim")
        XCTAssertEqual(summary(in: both, at: 0, major: 7, minor: 0)?.platform, "CPT/PBG")

        let small = skuRegion(blockOffset: 0, attrib: [0, 0, 0, 0, 0x03, 0, 0, 0])    // 1.5 MB
        XCTAssertEqual(summary(in: small, at: 0, major: 7, minor: 0)?.sku, "1.5MB")
    }

    func testME7Special5MBBuildCase() throws {
        // The odd 5MB special-case: build 1041, hotfix 0, minor 0, skuSize 1.
        let edge = skuRegion(blockOffset: 0, attrib: [0, 0, 0, 0, 0x01, 0, 0, 0])
        XCTAssertNil(summary(in: edge, at: 0, major: 7, minor: 0, hotfix: 0, build: 1040)?.sku)
        XCTAssertEqual(summary(in: edge, at: 0, major: 7, minor: 0, hotfix: 0, build: 1041)?.sku, "5MB")
    }

    // MARK: - ME 2–6 sku_me constants

    func testME2ICH8SKUBySkuMe() throws {
        // skuMe = the top four FWSKUAttrib bytes read big-endian.
        let amt = skuRegion(blockOffset: 0, attrib: [0x00, 0x00, 0x00, 0x00, 0, 0, 0, 0])
        XCTAssertEqual(summary(in: amt, at: 0, major: 2, minor: 0)?.sku, "AMT")
        XCTAssertEqual(summary(in: amt, at: 0, major: 2, minor: 0)?.platform, "ICH8")
        let qst = skuRegion(blockOffset: 0, attrib: [0x02, 0x00, 0x00, 0x00, 0, 0, 0, 0])
        XCTAssertEqual(summary(in: qst, at: 0, major: 2, minor: 0)?.sku, "QST")
        // minor ≥ 5 names the ICH8M PCH.
        XCTAssertEqual(summary(in: amt, at: 0, major: 2, minor: 5)?.platform, "ICH8M")
    }

    func testME3AndME4Constants() throws {
        let asf = skuRegion(blockOffset: 0, attrib: [0x06, 0x00, 0x00, 0x00, 0, 0, 0, 0])
        XCTAssertEqual(summary(in: asf, at: 0, major: 3, minor: 0)?.sku, "ASF")
        XCTAssertEqual(summary(in: asf, at: 0, major: 3, minor: 0)?.platform, "ICH9")

        let amtTPM = skuRegion(blockOffset: 0, attrib: [0xAC, 0x20, 0x00, 0x00, 0, 0, 0, 0])
        XCTAssertEqual(summary(in: amtTPM, at: 0, major: 4, minor: 0)?.sku, "AMT + TPM")
        XCTAssertEqual(summary(in: amtTPM, at: 0, major: 4, minor: 0)?.platform, "ICH9M")
    }

    func testME5DigitalOfficeConstant() throws {
        let sku = skuRegion(blockOffset: 0, attrib: [0x3E, 0x08, 0x00, 0x00, 0, 0, 0, 0])
        XCTAssertEqual(summary(in: sku, at: 0, major: 5, minor: 0)?.sku, "Digital Office")
        XCTAssertEqual(summary(in: sku, at: 0, major: 5, minor: 0)?.platform, "ICH10")
    }

    func testME6IgnitionAndSizes() throws {
        let ignition = skuRegion(blockOffset: 0, attrib: [0, 0, 0, 0, 0, 0, 0, 0])
        // skuMe == 0 → Ignition; the CCK/IBX split is by hotfix 50.
        XCTAssertEqual(summary(in: ignition, at: 0, major: 6, minor: 0, hotfix: 50)?.sku, "Ignition CCK")
        XCTAssertEqual(summary(in: ignition, at: 0, major: 6, minor: 0, hotfix: 50)?.platform, "CCK")
        XCTAssertEqual(summary(in: ignition, at: 0, major: 6, minor: 0, hotfix: 49)?.sku, "Ignition IBX")
        XCTAssertEqual(summary(in: ignition, at: 0, major: 6, minor: 0, hotfix: 49)?.platform, "IBX")

        let fifteen = skuRegion(blockOffset: 0, attrib: [0x70, 0x1C, 0x00, 0x00, 0, 0, 0, 0])
        XCTAssertEqual(summary(in: fifteen, at: 0, major: 6, minor: 0)?.sku, "1.5MB")
        let bigDT = skuRegion(blockOffset: 0, attrib: [0x77, 0xFC, 0x6E, 0x00, 0, 0, 0, 0])
        XCTAssertEqual(summary(in: bigDT, at: 0, major: 6, minor: 0)?.sku, "5MB DT")
        let bigMB = skuRegion(blockOffset: 0, attrib: [0x77, 0xDC, 0xEE, 0x00, 0, 0, 0, 0])
        XCTAssertEqual(summary(in: bigMB, at: 0, major: 6, minor: 0)?.sku, "5MB MB")
    }

    // MARK: - Unknown / out of range

    func testUnhandledMajorYieldsNilRows() throws {
        // ME 11+ is CSME, not the classic pre-CSE `$SKU` decode — no rows.
        let region = skuRegion(blockOffset: 0, attrib: t450Attrib)
        let s = try XCTUnwrap(summary(in: region, at: 0, major: 11, minor: 0))
        XCTAssertNil(s.sku)
        XCTAssertNil(s.platform)
    }
}

/// Analyzer-level: an R0 ME10 manifest region that carries a `$SKU` block after
/// the operational FTPR manifest resolves its identity to `.me` (via a DB line
/// keyed on the manifest RSA key) and fills top-level `sku`/`platform` plus the
/// R0 manifest VCN.
final class PreCSEAnalyzerTests: XCTestCase {
    private struct StubSource: MEADataSource {
        let databaseResult: Result<MEADatabase, MEADataError>
        func database() async throws -> MEADatabase { try databaseResult.get() }
    }

    /// The real T450 `FWSKUAttrib` (cf fa ff ff 0a 43 00 00).
    private static let t450Attrib: [UInt8] = [0xCF, 0xFA, 0xFF, 0xFF, 0x0A, 0x43, 0x00, 0x00]

    func testAnalyzeFillsSKUPlatformAndVCNForME10R0() async throws {
        // A pre-CSE region: $FPT with an FTPR partition whose manifest is an R0
        // ME 10.0 build, followed by the SKU_Attributes block the scan finds.
        var params = ManifestFixture.Params()
        params.format = .r0
        params.major = 10
        params.minor = 0
        params.vcn = 2
        let fpt = FPTFixture.fptRegion(entries: [("FTPR", 0x1000, 0x4000, 0)])
        var region = fpt
        region.append(Data(repeating: 0xFF, count: 0x1000 - fpt.count))  // manifest at 0x1000
        region.append(ManifestFixture.manifest(params))
        region.append(Data("$SKU".utf8))
        region.append(contentsOf: [0x04, 0, 0, 0])
        region.append(contentsOf: Self.t450Attrib)

        // Identity to `.me` via a synthetic DB row keyed on the fixture key hash.
        let keyHash = Digest.sha256Hex(Data(params.key))
        let db = MEADatabase(revision: 378, lines: ["RSAPKEY_ME_\(keyHash)"])
        let analyzer = MEFirmwareAnalyzer(data: StubSource(databaseResult: .success(db)))

        let result = try await analyzer.analyze(region: region, baseOffset: 0)

        XCTAssertEqual(result.family, .me)
        XCTAssertEqual(result.sku, "5MB")
        XCTAssertEqual(result.platform, "WPT-LP")
        XCTAssertEqual(result.manifest?.vcn, 2)
        XCTAssertEqual(result.manifest?.major, 10)
        XCTAssertEqual(result.manifest?.format, .r0)
        // No $CPD for pre-CSE (no code partition is ever reported).
        XCTAssertNil(result.codePartition)
    }

    func testAnalyzeLeavesSKUEmptyWhenFamilyIsNotME() async throws {
        // A CSME (family resolved from a CSME DB row) region must not take the
        // pre-CSE SKU path — its empty SKU stays empty (Phase 10 handles CSME).
        var params = ManifestFixture.Params()
        params.format = .r0
        params.major = 10
        params.minor = 0
        params.vcn = 2
        let fpt = FPTFixture.fptRegion(entries: [("FTPR", 0x1000, 0x4000, 0)])
        var region = fpt
        region.append(Data(repeating: 0xFF, count: 0x1000 - fpt.count))
        region.append(ManifestFixture.manifest(params))
        region.append(Data("$SKU".utf8))
        region.append(contentsOf: [0x04, 0, 0, 0])
        region.append(contentsOf: Self.t450Attrib)

        let keyHash = Digest.sha256Hex(Data(params.key))
        let db = MEADatabase(revision: 378, lines: ["RSAPKEY_CSME_\(keyHash)"])
        let analyzer = MEFirmwareAnalyzer(data: StubSource(databaseResult: .success(db)))

        let result = try await analyzer.analyze(region: region, baseOffset: 0)

        XCTAssertEqual(result.family, .csme)
        XCTAssertEqual(result.sku, "")      // pre-CSE decode not applied to .csme
        XCTAssertEqual(result.manifest?.vcn, 2)
    }
}
