import XCTest
import Foundation
@testable import MEFirmware

/// Builds synthetic pre-CSE R0 `$MME` directories for the decoder/analyzer tests.
/// A directory starts at `manifestBase + 0x284 + 0xC` (the R0 manifest is 0x284
/// bytes / 0xA1 dwords; the 0xC is the gap upstream skips, MEA.py 12256). New
/// headers (ME 6–10, after `$MN2`) stride 0x60; old headers (ME 2–5, after
/// `$MAN`) stride 0x50. `$MCP` sits one stride past the declared directory.
enum MMEFixture {
    static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
         UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    static func fixed(_ s: String, _ count: Int) -> [UInt8] {
        var b = Array(s.utf8)
        if b.count < count { b += [UInt8](repeating: 0, count: count - b.count) }
        return Array(b.prefix(count))
    }
    static func fixed(_ bytes: [UInt8], _ count: Int) -> [UInt8] {
        bytes.count >= count ? Array(bytes.prefix(count))
                             : bytes + [UInt8](repeating: 0, count: count - bytes.count)
    }

    /// A 0x60-byte `MME_Header_New` row (field offsets per MEA.py 1125).
    static func newRow(name: String, hash: [UInt8],
                       modBase: UInt32, offsetMN2: UInt32,
                       sizeUncomp: UInt32, sizeComp: UInt32,
                       memory: UInt32 = 0, preUma: UInt32 = 0,
                       entryPoint: UInt32 = 0, flags: UInt32 = 0) -> Data {
        var b = [UInt8](repeating: 0, count: 0x60)
        b.replaceSubrange(0..<4, with: Array("$MME".utf8))
        b.replaceSubrange(0x04..<(0x04 + 16), with: fixed(name, 16))
        b.replaceSubrange(0x14..<(0x14 + 32), with: fixed(hash, 32))
        b.replaceSubrange(0x34..<(0x34 + 4), with: u32(modBase))
        b.replaceSubrange(0x38..<(0x38 + 4), with: u32(offsetMN2))
        b.replaceSubrange(0x3C..<(0x3C + 4), with: u32(sizeUncomp))
        b.replaceSubrange(0x40..<(0x40 + 4), with: u32(sizeComp))
        b.replaceSubrange(0x44..<(0x44 + 4), with: u32(memory))
        b.replaceSubrange(0x48..<(0x48 + 4), with: u32(preUma))
        b.replaceSubrange(0x4C..<(0x4C + 4), with: u32(entryPoint))
        b.replaceSubrange(0x50..<(0x50 + 4), with: u32(flags))
        return Data(b)
    }

    /// A 0x50-byte `MME_Header_Old` row (field offsets per MEA.py 1107).
    static func oldRow(name: String, guid: [UInt8], major: UInt16, minor: UInt16,
                       hotfix: UInt16, build: UInt16, hash: [UInt8],
                       size: UInt32, flags: UInt32 = 0) -> Data {
        var b = [UInt8](repeating: 0, count: 0x50)
        b.replaceSubrange(0..<4, with: Array("$MME".utf8))
        b.replaceSubrange(0x04..<(0x04 + 16), with: fixed(guid, 16))
        b.replaceSubrange(0x14..<(0x14 + 2), with: u16(major))
        b.replaceSubrange(0x16..<(0x16 + 2), with: u16(minor))
        b.replaceSubrange(0x18..<(0x18 + 2), with: u16(hotfix))
        b.replaceSubrange(0x1A..<(0x1A + 2), with: u16(build))
        b.replaceSubrange(0x1C..<(0x1C + 16), with: fixed(name, 16))
        b.replaceSubrange(0x2C..<(0x2C + 20), with: fixed(hash, 20))
        b.replaceSubrange(0x40..<(0x40 + 4), with: u32(size))
        b.replaceSubrange(0x44..<(0x44 + 4), with: u32(flags))
        return Data(b)
    }

    /// A `$MCP` header (ME 8–10, `MCP_Header`; hash at +0x14).
    static func mcp(headerSize: UInt32 = 0x11, codeSize: UInt32, offCodeMN2: UInt32,
                    offPartFPT: UInt32, hash: [UInt8]) -> Data {
        var b = [UInt8](repeating: 0, count: 0x44)
        b.replaceSubrange(0..<4, with: Array("$MCP".utf8))
        b.replaceSubrange(0x04..<(0x04 + 4), with: u32(headerSize))
        b.replaceSubrange(0x08..<(0x08 + 4), with: u32(codeSize))
        b.replaceSubrange(0x0C..<(0x0C + 4), with: u32(offCodeMN2))
        b.replaceSubrange(0x10..<(0x10 + 4), with: u32(offPartFPT))
        b.replaceSubrange(0x14..<(0x14 + 32), with: fixed(hash, 32))
        return Data(b)
    }

    /// A region whose `$MME` directory sits at the canonical head 0x290 (an R0
    /// manifest at base 0 fills 0x284, then the 0xC gap). Rows fill `declared`
    /// strides (short region = truncation); an optional `$MCP` follows one more
    /// stride of padding.
    static func directoryRegion(declared: Int, rows: [Data], stride: Int,
                                mcp: Data? = nil) -> Data {
        var region = Data(repeating: 0, count: 0x290)
        for i in 0..<declared {
            region.append(i < rows.count ? rows[i] : Data(repeating: 0, count: stride))
        }
        if let mcp {
            region.append(Data(repeating: 0, count: stride))   // padding row before $MCP
            region.append(mcp)
        }
        return region
    }
}

/// Decoder-level tests for the pre-CSE `$MME` module directory + `$MCP`
/// (upstream-map rows 51/52). Field offsets are pinned to the ctypes structs
/// (MEA.py 1107–1159); names/sizes mirror the real Lenovo T450 ME10 directory
/// (oracle) where noted.
final class PreCSEModuleDecodeTests: XCTestCase {
    private static func decodeDirectory(_ region: Data, tag: String = "$MN2",
                               declared: Int, stride: Int = 0x60) -> MMEModuleDirectory? {
        PreCSEModule.decode(in: region, manifestBase: 0,
                            headerLengthBytes: 0x284, manifestTag: tag,
                            declaredModules: declared)
    }

    func testDecodesNewHeaderDirectoryWithMCP() throws {
        let hash = [UInt8](repeating: 0xAB, count: 32)
        let rows = [
            MMEFixture.newRow(name: "UPDATE", hash: hash, modBase: 0x2000,
                              offsetMN2: 0x6E04D, sizeUncomp: 0x1000, sizeComp: 0x1AB),
            // Real T450 BUP row (size/offset pinned to the oracle bytes).
            MMEFixture.newRow(name: "BUP", hash: hash, modBase: 0x2000,
                              offsetMN2: 0x940, sizeUncomp: 0x1D000, sizeComp: 0x15700,
                              memory: 0x1D000, preUma: 0x1D000, entryPoint: 0x3FC0),
            MMEFixture.newRow(name: "KERNEL", hash: hash, modBase: 0x2000,
                              offsetMN2: 0x940, sizeUncomp: 0x56000, sizeComp: 0x3C59D),
        ]
        let region = MMEFixture.directoryRegion(
            declared: 3, rows: rows, stride: 0x60,
            mcp: MMEFixture.mcp(codeSize: 0xAF6F4, offCodeMN2: 0x90C,
                                offPartFPT: 0x160000, hash: hash))

        let dir = try XCTUnwrap(Self.decodeDirectory(region, declared: 3))
        XCTAssertEqual(dir.offset, 0x290)            // base 0 + 0x284 + 0xC
        XCTAssertEqual(dir.manifestTag, "$MN2")
        XCTAssertEqual(dir.declaredModules, 3)
        XCTAssertEqual(dir.modules.count, 3)
        XCTAssertEqual(dir.modules.map(\.name), ["UPDATE", "BUP", "KERNEL"])

        let bup = dir.modules[1]
        XCTAssertEqual(bup.offsetMN2, 0x940)          // pinned to the T450 oracle
        XCTAssertEqual(bup.sizeUncompressed, 0x1D000)
        XCTAssertEqual(bup.sizeCompressed, 0x15700)
        XCTAssertEqual(bup.memorySize, 0x1D000)
        XCTAssertEqual(bup.preUmaSize, 0x1D000)
        XCTAssertEqual(bup.entryPoint, 0x3FC0)
        XCTAssertEqual(bup.modBase, 0x2000)
        XCTAssertEqual(bup.flags, 0)
        XCTAssertEqual(bup.hashHex, String(repeating: "AB", count: 32))
        // New-header rows carry no old-header (ME 2-5) fields.
        XCTAssertNil(bup.guidHex)
        XCTAssertNil(bup.majorVersion)
        XCTAssertNil(bup.size)

        let mcp = try XCTUnwrap(dir.mcp)
        XCTAssertEqual(mcp.offset, 0x290 + 3 * 0x60 + 0x60)   // one stride past directory
        XCTAssertEqual(mcp.headerSize, 0x11)          // ME 8-10 header (dwords)
        XCTAssertEqual(mcp.codeSize, 0xAF6F4)         // pinned to the T450 oracle
        XCTAssertEqual(mcp.offsetCodeMN2, 0x90C)
        XCTAssertEqual(mcp.offsetPartFPT, 0x160000)
    }

    func testBaseOffsetAdjustsReportedAnchors() throws {
        let region = MMEFixture.directoryRegion(
            declared: 1,
            rows: [MMEFixture.newRow(name: "ROMP", hash: [UInt8](repeating: 0x11, count: 32),
                                     modBase: 0, offsetMN2: 0x940,
                                     sizeUncomp: 0x1000, sizeComp: 0x3C2)],
            stride: 0x60)
        let dir = PreCSEModule.decode(in: region, manifestBase: 0,
                                      headerLengthBytes: 0x284, manifestTag: "$MN2",
                                      declaredModules: 1, baseOffset: 0x1000)
        XCTAssertEqual(dir?.offset, 0x1290)
        XCTAssertNil(dir?.mcp)
    }

    func testDecodesOldHeaderDirectoryWithoutMCP() throws {
        // ME 2-5 ($MAN) old-header rows stride 0x50 and never read a $MCP.
        let hash = [UInt8](repeating: 0x22, count: 20)
        let rows = [
            MMEFixture.oldRow(name: "ROMP", guid: [UInt8](repeating: 0x01, count: 16),
                              major: 4, minor: 1, hotfix: 0, build: 1052,
                              hash: hash, size: 0x1000, flags: 0x3),
            MMEFixture.oldRow(name: "BUP", guid: [UInt8](repeating: 0x02, count: 16),
                              major: 4, minor: 1, hotfix: 0, build: 1052,
                              hash: hash, size: 0x2A000),
        ]
        let region = MMEFixture.directoryRegion(declared: 2, rows: rows, stride: 0x50)

        let dir = try XCTUnwrap(Self.decodeDirectory(region, tag: "$MAN", declared: 2, stride: 0x50))
        XCTAssertEqual(dir.manifestTag, "$MAN")
        XCTAssertEqual(dir.modules.map(\.name), ["ROMP", "BUP"])
        XCTAssertNil(dir.mcp)                          // $MAN path never probes $MCP

        let romp = dir.modules[0]
        XCTAssertEqual(romp.majorVersion, 4)
        XCTAssertEqual(romp.minorVersion, 1)
        XCTAssertEqual(romp.hotfixVersion, 0)
        XCTAssertEqual(romp.buildVersion, 1052)
        XCTAssertEqual(romp.size, 0x1000)
        XCTAssertEqual(romp.flags, 0x3)
        XCTAssertEqual(romp.guidHex, String(repeating: "01", count: 16))
        XCTAssertEqual(romp.hashHex, String(repeating: "22", count: 20))
        // Old-header rows carry no new-header (ME 6-10) fields.
        XCTAssertNil(romp.modBase)
        XCTAssertNil(romp.offsetMN2)
        XCTAssertNil(romp.sizeCompressed)
    }

    func testStopsAtDeclaredCountBeyondActualRows() throws {
        // Directory declares 4, but only 2 real $MME rows are present: the loop
        // hits the sanity break after 2 (upstream 12263), returning what decoded.
        let rows = [
            MMEFixture.newRow(name: "A", hash: [UInt8](repeating: 0xAA, count: 32),
                              modBase: 0, offsetMN2: 0x100, sizeUncomp: 1, sizeComp: 1),
            MMEFixture.newRow(name: "B", hash: [UInt8](repeating: 0xBB, count: 32),
                              modBase: 0, offsetMN2: 0x200, sizeUncomp: 1, sizeComp: 1),
        ]
        let region = MMEFixture.directoryRegion(declared: 4, rows: rows, stride: 0x60)
        let dir = try XCTUnwrap(Self.decodeDirectory(region, declared: 4))
        XCTAssertEqual(dir.declaredModules, 4)
        XCTAssertEqual(dir.modules.count, 2)
    }

    func testReturnsNilWhenNoPlausibleDirectory() {
        // Not a $MME directory (R1/R2-style bytes after the header).
        var bogus = Data(repeating: 0, count: 0x290)
        bogus.append(Data(repeating: 0xFF, count: 0x60))
        XCTAssertNil(Self.decodeDirectory(bogus, declared: 4))

        // Declared zero / negative-head regions also yield nil.
        XCTAssertNil(Self.decodeDirectory(MMEFixture.directoryRegion(declared: 0, rows: [], stride: 0x60),
                            declared: 0))
        XCTAssertNil(PreCSEModule.decode(in: Data(repeating: 0, count: 0x10),
                                         manifestBase: 0, headerLengthBytes: 0x284,
                                         manifestTag: "$MN2", declaredModules: 2))
    }
}

/// Analyzer-level: an R0 ME manifest region whose `$MME` directory + `$MCP`
/// resolve after identification to `.me`, filling `FirmwareAnalysis.mmeDirectory`.
final class PreCSEModuleAnalyzerTests: XCTestCase {
    private struct StubSource: MEADataSource {
        let databaseResult: Result<MEADatabase, MEADataError>
        func database() async throws -> MEADatabase { try databaseResult.get() }
    }

    private static let t450Attrib: [UInt8] = [0xCF, 0xFA, 0xFF, 0xFF, 0x0A, 0x43, 0x00, 0x00]

    /// A region that identifies to `.me` (ME10 R0): $FPT + manifest at 0x1000
    /// declaring `numModules`, the `$MME` rows after base+0x284+0xC, an optional
    /// `$MCP`, then the `$SKU` SKU_Attributes block.
    private func meRegion(numModules: UInt32, rows: [Data], mcp: Data?) -> Data {
        var params = ManifestFixture.Params()
        params.format = .r0
        params.major = 10
        params.minor = 0
        params.vcn = 2
        params.numModules = numModules
        let fpt = FPTFixture.fptRegion(entries: [("FTPR", 0x1000, 0x4000, 0)])
        var region = fpt
        region.append(Data(repeating: 0xFF, count: 0x1000 - fpt.count))  // manifest at 0x1000
        region.append(ManifestFixture.manifest(params))
        region.append(Data(repeating: 0, count: 0xC))                    // head gap
        for row in rows { region.append(row) }
        if let mcp {
            region.append(Data(repeating: 0, count: 0x60))               // padding
            region.append(mcp)
        }
        region.append(Data("$SKU".utf8))
        region.append(contentsOf: [0x04, 0, 0, 0])
        region.append(contentsOf: Self.t450Attrib)
        return region
    }

    private func analyze(_ region: Data, dbLine: String) async throws -> FirmwareAnalysis {
        let keyHash = Digest.sha256Hex(Data(Array(0..<0x100).map { UInt8($0 % 0x100) }))
        let db = MEADatabase(revision: 378, lines: ["\(dbLine)_\(keyHash)"])
        let analyzer = MEFirmwareAnalyzer(data: StubSource(databaseResult: .success(db)))
        return try await analyzer.analyze(region: region, baseOffset: 0)
    }

    func testAnalyzeSurfacesMMEDirectoryAndMCP() async throws {
        let hash = [UInt8](repeating: 0xAB, count: 32)
        let rows = [
            MMEFixture.newRow(name: "UPDATE", hash: hash, modBase: 0x2000,
                              offsetMN2: 0x6E04D, sizeUncomp: 0x1000, sizeComp: 0x1AB),
            MMEFixture.newRow(name: "BUP", hash: hash, modBase: 0x2000,
                              offsetMN2: 0x940, sizeUncomp: 0x1D000, sizeComp: 0x15700),
            MMEFixture.newRow(name: "KERNEL", hash: hash, modBase: 0x2000,
                              offsetMN2: 0x940, sizeUncomp: 0x56000, sizeComp: 0x3C59D),
        ]
        let region = meRegion(
            numModules: 3, rows: rows,
            mcp: MMEFixture.mcp(codeSize: 0xAF6F4, offCodeMN2: 0x90C,
                                offPartFPT: 0x160000, hash: hash))

        let result = try await analyze(region, dbLine: "RSAPKEY_ME")

        XCTAssertEqual(result.family, .me)
        XCTAssertEqual(result.sku, "5MB")               // $SKU decode still works
        XCTAssertEqual(result.platform, "WPT-LP")
        XCTAssertEqual(result.manifest?.vcn, 2)

        let dir = try XCTUnwrap(result.mmeDirectory)
        XCTAssertEqual(dir.offset, 0x1000 + 0x284 + 0xC)
        XCTAssertEqual(dir.manifestTag, "$MN2")
        XCTAssertEqual(dir.declaredModules, 3)
        XCTAssertEqual(dir.modules.map(\.name), ["UPDATE", "BUP", "KERNEL"])
        XCTAssertEqual(dir.modules[1].sizeUncompressed, 0x1D000)
        let mcp = try XCTUnwrap(dir.mcp)
        XCTAssertEqual(mcp.codeSize, 0xAF6F4)
        XCTAssertEqual(mcp.offsetPartFPT, 0x160000)
        // A full directory raises no truncation note (the id-3 "not in the
        // database" note from the synthetic DB line is expected and unrelated).
        XCTAssertFalse(result.issues.contains { $0.id == 11 })
    }

    func testAnalyzeNotesTruncatedDirectory() async throws {
        // Directory declares 4 but only 2 rows follow: the analyzer keeps the two
        // decoded rows and raises the id-11 note (upstream's sanity break).
        let rows = [
            MMEFixture.newRow(name: "A", hash: [UInt8](repeating: 0xAA, count: 32),
                              modBase: 0, offsetMN2: 0x100, sizeUncomp: 1, sizeComp: 1),
            MMEFixture.newRow(name: "B", hash: [UInt8](repeating: 0xBB, count: 32),
                              modBase: 0, offsetMN2: 0x200, sizeUncomp: 1, sizeComp: 1),
        ]
        let region = meRegion(numModules: 4, rows: rows, mcp: nil)

        let result = try await analyze(region, dbLine: "RSAPKEY_ME")

        XCTAssertEqual(result.mmeDirectory?.declaredModules, 4)
        XCTAssertEqual(result.mmeDirectory?.modules.count, 2)
        XCTAssertTrue(result.issues.contains { $0.id == 11 && $0.severity == .note })
    }

    func testAnalyzeLeavesMMEInventoryNilForCSME() async throws {
        // A CSME-identified region (R0 manifest, same layout) must not take the
        // pre-CSE $MME path — the directory is only decoded for the `.me` family.
        let rows = [MMEFixture.newRow(name: "KERNEL", hash: [UInt8](repeating: 0x11, count: 32),
                                      modBase: 0x2000, offsetMN2: 0x940,
                                      sizeUncomp: 0x56000, sizeComp: 0x3C59D)]
        let region = meRegion(numModules: 1, rows: rows, mcp: nil)

        let result = try await analyze(region, dbLine: "RSAPKEY_CSME")

        XCTAssertEqual(result.family, .csme)
        XCTAssertNil(result.mmeDirectory)
    }
}
