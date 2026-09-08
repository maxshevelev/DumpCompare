import XCTest
import Foundation
@testable import MEFirmware

/// Builds synthetic CSE extension blocks (`CSE_Ext_*`) whose headers mirror the
/// layouts `CPDExtensionParser` decodes. Each block is a self-contained chain
/// element: `Tag` u32 @0, `Size` u32 @4 (= whole block), header bytes @8+.
/// Field positions are header-relative (offset within the block *after* the
/// 8-byte envelope), matching `Extensions.swift`.
enum ExtFixture {
    static func wU8(_ v: UInt8, _ i: Int, _ d: inout Data) { d[i] = v }
    static func wU16(_ v: UInt16, _ i: Int, _ d: inout Data) {
        d[i] = UInt8(v & 0xFF); d[i + 1] = UInt8(v >> 8)
    }
    static func wU32(_ v: UInt32, _ i: Int, _ d: inout Data) {
        d[i] = UInt8(v & 0xFF); d[i + 1] = UInt8((v >> 8) & 0xFF)
        d[i + 2] = UInt8((v >> 16) & 0xFF); d[i + 3] = UInt8((v >> 24) & 0xFF)
    }
    static func wU64(_ v: UInt64, _ i: Int, _ d: inout Data) {
        wU32(UInt32(v & 0xFFFF_FFFF), i, &d); wU32(UInt32(v >> 32), i + 4, &d)
    }
    static func wAscii(_ s: String, _ i: Int, _ d: inout Data) {
        for (j, b) in s.utf8.prefix(4).enumerated() { d[i + j] = b }
    }
    /// Fill `range` with `UInt8(offset)` from 0 — a deterministic byte ramp.
    static func ramp(_ range: Range<Int>, _ d: inout Data) {
        for (k, i) in range.enumerated() { d[i] = UInt8(k) }
    }

    static func concat(_ blocks: [Data]) -> Data {
        blocks.reduce(into: Data()) { $0.append($1) }
    }

    /// An empty extension of `headerLen` bytes total (Tag@0 + Size@4 are fields
    /// of the block, exactly as the decoder reads them — the envelope is *inside*
    /// the header span, e.g. CSE_Ext_00 is 0x50 bytes end to end). `tail` extra
    /// bytes stand in for the deferred `_Mod` rows (kept undecoded but covered by
    /// Size so the walk advances past them).
    static func block(tag: UInt32, headerLen: Int, tail: Int = 0) -> Data {
        var b = Data(repeating: 0, count: headerLen + tail)
        wU32(tag, 0, &b)
        wU32(UInt32(b.count), 4, &b)
        return b
    }

    /// `CSE_Ext_00` System Information (0x40 R1 / 0x50 R2). Distinguishable
    /// constants: MinUMASize 0x11223344, ChipsetVersion 0x0C0D0E0F, imageHash a
    /// byte ramp (32B R1 / 48B R2) at 0x10, PageableUMASize 0x55667788 at
    /// 0x30 (R1) / 0x40 (R2).
    static func systemInfo(r2: Bool) -> Data {
        let headerLen = r2 ? 0x50 : 0x40
        let hashLen = r2 ? 48 : 32
        var b = block(tag: 0x00, headerLen: headerLen)
        wU32(0x1122_3344, 0x08, &b)                 // MinUMASize
        wU32(0x0C0D_0E0F, 0x0C, &b)                 // ChipsetVersion
        ramp(0x10..<(0x10 + hashLen), &b)           // IMGDefaultHash
        wU32(0x5566_7788, r2 ? 0x40 : 0x30, &b)     // PageableUMASize
        return b
    }

    /// `CSE_Ext_02` Feature Permissions (0x0C). ModuleCount u32 @0x08;
    /// `rowCount` `_02_Mod` feature rows (4B each) follow undecoded.
    static func featurePermissions(moduleCount: UInt32, rowCount: Int = 0) -> Data {
        var b = block(tag: 0x02, headerLen: 0x0C, tail: rowCount * 4)
        wU32(moduleCount, 0x08, &b)
        return b
    }

    /// `CSE_Ext_0C` Client System Information (0x30, single block). FWSKUCaps
    /// u32 @0x08; FWSKUAttrib u64 @0x28 fixed to bitfields CSESize 7 / SKUType 3 /
    /// Workstation 1 / M3 0 / M0 1 / SKUPlatform 2 / SiClass 5 → attrib 0x5AB7.
    static func clientSystemInfo() -> Data {
        var b = block(tag: 0x0C, headerLen: 0x30)
        wU32(0x0001_00FE, 0x08, &b)                 // FWSKUCaps
        wU64(0x5AB7, 0x28, &b)                      // FWSKUAttrib
        return b
    }

    /// `CSE_Ext_0F` Signed Package Information (0x34 both revisions). Name/VCN,
    /// 16-byte usage ramp 0x80..0x8F at 0x10, ARBSVN 5; `_R2` adds FWType 3
    /// @0x24, FWSKU 5 @0x25, NVMCompatibility 1 @0x26.
    static func signedPackage(r2: Bool) -> Data {
        var b = block(tag: 0x0F, headerLen: 0x34)
        wAscii("NVM0", 0x08, &b)
        wU32(3, 0x0C, &b)                            // VCN
        for (k, i) in (0x10..<0x20).enumerated() { b[i] = UInt8(0x80 + k) }  // usage
        wU32(5, 0x20, &b)                            // ARBSVN
        if r2 {
            wU8(3, 0x24, &b)                         // FWType
            wU8(5, 0x25, &b)                         // FWSKU
            wU32(1, 0x26, &b)                        // NVMCompatibility
        }
        return b
    }

    /// `CSE_Ext_03`/`CSE_Ext_16` Partition Information (0x58 R1 / 0x68 R2).
    /// Constants: PartitionName "FTPR", PartitionSize 0x00100020, a version
    /// quadruple (Min 0x0102 / Maj 0x0304 / DFMin 0x0506 / DFMaj 0x0708),
    /// InstanceID 0x10203040, Flags 0x0F0F0F0F, and a hash ramp. 0x03 writes VCN
    /// 3 and its hash at 0x10 (R1/R2 variants at 0x30/0x40); 0x16 has no VCN and
    /// stores its hash at 0x24.
    static func partitionInfo(tag: UInt32, r2: Bool) -> Data {
        let headerLen = r2 ? 0x68 : 0x58
        let hashLen = r2 ? 48 : 32
        var b = block(tag: tag, headerLen: headerLen)
        wAscii("FTPR", 0x08, &b)
        wU32(0x0010_0020, 0x0C, &b)                  // PartitionSize

        let vcnAt = r2 ? 0x40 : 0x30
        let hashAt: Int
        let versionBase: Int
        let instanceAt: Int
        let flagsAt: Int
        if tag == 0x03 {
            wU32(3, vcnAt, &b)                       // VCN
            hashAt = 0x10
            versionBase = r2 ? 0x44 : 0x34
            instanceAt = r2 ? 0x4C : 0x3C
            flagsAt = r2 ? 0x50 : 0x40
        } else {
            hashAt = 0x24
            versionBase = 0x10
            instanceAt = 0x18
            flagsAt = 0x1C
        }
        ramp(hashAt..<(hashAt + hashLen), &b)        // stored partition hash
        wU16(0x0102, versionBase, &b)                // PartitionVerMin
        wU16(0x0304, versionBase + 2, &b)            // PartitionVerMaj
        wU16(0x0506, versionBase + 4, &b)            // DataFormatMin
        wU16(0x0708, versionBase + 6, &b)            // DataFormatMaj
        wU32(0x1020_3040, instanceAt, &b)            // InstanceID
        wU32(0x0F0F_0F0F, flagsAt, &b)               // Flags
        return b
    }

    /// `CSE_Ext_0A` Module Attributes (0x38 R1 / 0x48 R2, single block) — the
    /// universal first block of a `.met` chain. Constants: Compression Huffman
    /// (1), Encryption None (0), SizeUncomp 0x15000, SizeComp 0xDDD4, DEV_ID 2,
    /// VEN_ID 0x8086, Hash a byte ramp (32B R1 / 48B R2) at 0x18.
    static func moduleAttributes(r2: Bool) -> Data {
        let headerLen = r2 ? 0x48 : 0x38
        let hashLen = r2 ? 48 : 32
        var b = block(tag: 0x0A, headerLen: headerLen)
        b[0x08] = 1                                  // Compression: Huffman
        b[0x09] = 0                                  // Encryption: None
        wU32(0x0001_5000, 0x0C, &b)                  // SizeUncomp
        wU32(0x0000_DDD4, 0x10, &b)                  // SizeComp
        wU16(0x0002, 0x14, &b)                       // DEV_ID
        wU16(0x8086, 0x16, &b)                       // VEN_ID
        ramp(0x18..<(0x18 + hashLen), &b)            // Hash
        return b
    }
}

final class ExtensionWalkerTests: XCTestCase {
    /// Walk a chain that starts at region offset 0, matching a manifest whose
    /// module exactly fills the region. Offsets are shifted by `baseOffset`.
    private func decode(_ blocks: [Data], family: CPDExtensionParser.Family,
                        baseOffset: Int = 0x400) -> [CPDExtension] {
        let region = ExtFixture.concat(blocks)
        return CPDExtensionParser.decode(in: region,
                                         moduleContentBase: 0,
                                         moduleSize: region.count,
                                         chainStart: 0,
                                         family: family,
                                         baseOffset: baseOffset)
    }

    // MARK: - Family selection

    func testFamilyFromManifestFacts() {
        // 3072-bit key overrides everything → csme15, even on a CSME-12 major.
        XCTAssertEqual(CPDExtensionParser.family(
            major: 12, minor: 3, hotfix: 0, build: 100, year: 2018, month: 1,
            keyLength: 0x180), .csme15)
        // major 15 / 16 → csme15 regardless of key length.
        XCTAssertEqual(CPDExtensionParser.family(
            major: 15, minor: 0, hotfix: 0, build: 0, year: 2021, month: 3,
            keyLength: 0x100), .csme15)
        XCTAssertEqual(CPDExtensionParser.family(
            major: 16, minor: 0, hotfix: 0, build: 0, year: 2021, month: 3,
            keyLength: nil), .csme15)
        // CSME 12 non-alpha / 13 / 14 → csme12.
        XCTAssertEqual(CPDExtensionParser.family(
            major: 12, minor: 0, hotfix: 0, build: 100, year: 2019, month: 1,
            keyLength: 0x100), .csme12)
        XCTAssertEqual(CPDExtensionParser.family(
            major: 13, minor: 0, hotfix: 0, build: 0, year: 2021, month: 3,
            keyLength: 0x100), .csme12)
        XCTAssertEqual(CPDExtensionParser.family(
            major: 14, minor: 0, hotfix: 0, build: 0, year: 2021, month: 3,
            keyLength: 0x100), .csme12)
        // CSME 12 alpha carve-out → base structs.
        XCTAssertEqual(CPDExtensionParser.family(
            major: 12, minor: 0, hotfix: 0, build: 7000, year: 2017, month: 3,
            keyLength: 0x100), .base)
        // Older CSE with an unremarkable key → base.
        XCTAssertEqual(CPDExtensionParser.family(
            major: 11, minor: 0, hotfix: 0, build: 0, year: 2014, month: 1,
            keyLength: 0x100), .base)
    }

    func testHeaderRevTagPerFamily() {
        XCTAssertEqual(CPDExtensionParser.headerRevTag(0x00, .csme15), "_R2")
        XCTAssertEqual(CPDExtensionParser.headerRevTag(0x03, .csme15), "_R2")
        XCTAssertEqual(CPDExtensionParser.headerRevTag(0x0A, .csme15), "_R2")  // .met module attrs
        XCTAssertEqual(CPDExtensionParser.headerRevTag(0x0F, .csme15), "_R2")
        XCTAssertEqual(CPDExtensionParser.headerRevTag(0x16, .csme15), "_R2")
        XCTAssertEqual(CPDExtensionParser.headerRevTag(0x02, .csme15), "")  // never revised
        XCTAssertEqual(CPDExtensionParser.headerRevTag(0x0C, .csme15), "")
        XCTAssertEqual(CPDExtensionParser.headerRevTag(0x0F, .csme12), "_R2")  // 0xF→_R2
        XCTAssertEqual(CPDExtensionParser.headerRevTag(0x00, .csme12), "")
        XCTAssertEqual(CPDExtensionParser.headerRevTag(0x0A, .csme12), "")  // csme12 .met stays R1
        XCTAssertEqual(CPDExtensionParser.headerRevTag(0x16, .csme12), "")
        XCTAssertEqual(CPDExtensionParser.headerRevTag(0x0F, .base), "")
    }

    // MARK: - Walk

    func testCsme15ChainDecodesHeaders() {
        let exts = decode([
            ExtFixture.systemInfo(r2: true),
            ExtFixture.clientSystemInfo(),
            ExtFixture.featurePermissions(moduleCount: 6, rowCount: 4),
            ExtFixture.signedPackage(r2: true),
            ExtFixture.partitionInfo(tag: 0x16, r2: true),
        ], family: .csme15)

        XCTAssertEqual(exts.count, 5)
        XCTAssertEqual(exts.map(\.tag), [0x00, 0x0C, 0x02, 0x0F, 0x16])
        XCTAssertEqual(exts.map(\.id), [0, 1, 2, 3, 4])
        // Envelope offset = baseOffset + running chain position.
        XCTAssertEqual(exts[0].offset, 0x400)
        XCTAssertTrue(exts[1].offset > exts[0].offset)
        XCTAssertEqual(exts[1].offset, exts[0].offset + exts[0].size)

        // 0x00 _R2: image hash is SHA-384 → 48 bytes → 96 hex chars.
        let si = try! XCTUnwrap(exts[0].systemInfo)
        XCTAssertEqual(si.minUMASize, 0x1122_3344)
        XCTAssertEqual(si.chipsetVersion, 0x0C0D_0E0F)
        XCTAssertEqual(si.pageableUMASize, 0x5566_7788)
        XCTAssertEqual(si.imageHash.count, 96)
        XCTAssertEqual(si.imageHash, rampHex(48))

        // 0x0C bitfields.
        let csi = try! XCTUnwrap(exts[1].clientSystemInfo)
        XCTAssertEqual(csi.skuCaps, 0x0001_00FE)
        XCTAssertEqual(csi.cseSize, 7)
        XCTAssertEqual(csi.skuType, 3)
        XCTAssertTrue(csi.workstation)
        XCTAssertFalse(csi.m3)
        XCTAssertTrue(csi.m0)
        XCTAssertEqual(csi.skuPlatform, 2)
        XCTAssertEqual(csi.siClass, 5)

        // 0x02 header only — the 4 trailing rows stay undecoded but the block's
        // Size covers them (0x0C header + 4×4 rows = 0x1C).
        let fp = try! XCTUnwrap(exts[2].featurePermissions)
        XCTAssertEqual(fp.moduleCount, 6)
        XCTAssertEqual(exts[2].size, 0x1C)

        // 0x0F _R2: R2-only scalars present.
        let sp = try! XCTUnwrap(exts[3].signedPackage)
        XCTAssertEqual(sp.partitionName, "NVM0")
        XCTAssertEqual(sp.vcn, 3)
        XCTAssertEqual(sp.arbSvn, 5)
        XCTAssertEqual(sp.usageBitmap, usageHex())
        XCTAssertEqual(sp.fwType, 3)
        XCTAssertEqual(sp.fwSku, 5)
        XCTAssertEqual(sp.nvmCompatibility, 1)

        // 0x16 _R2 (no VCN).
        let pi = try! XCTUnwrap(exts[4].partitionInfo)
        XCTAssertEqual(pi.partitionName, "FTPR")
        XCTAssertEqual(pi.partitionSize, 0x0010_0020)
        XCTAssertNil(pi.vcn)
        XCTAssertEqual(pi.versionMinor, 0x0102)
        XCTAssertEqual(pi.versionMajor, 0x0304)
        XCTAssertEqual(pi.dataFormatMinor, 0x0506)
        XCTAssertEqual(pi.dataFormatMajor, 0x0708)
        XCTAssertEqual(pi.instanceID, 0x1020_3040)
        XCTAssertEqual(pi.flags, 0x0F0F_0F0F)
        XCTAssertEqual(pi.hash.count, 96)
    }

    func testBaseFamilyUsesR1Layouts() {
        let exts = decode([
            ExtFixture.systemInfo(r2: false),
            ExtFixture.signedPackage(r2: false),
            ExtFixture.partitionInfo(tag: 0x16, r2: false),
            ExtFixture.partitionInfo(tag: 0x03, r2: false),
        ], family: .base)

        XCTAssertEqual(exts.count, 4)
        let si = try! XCTUnwrap(exts[0].systemInfo)
        XCTAssertEqual(si.imageHash.count, 64)           // R1: SHA-256
        XCTAssertEqual(si.pageableUMASize, 0x5566_7788)  // R1 pageable at +0x30

        let sp = try! XCTUnwrap(exts[1].signedPackage)
        XCTAssertNil(sp.fwType)                          // R1: no R2 scalars
        XCTAssertNil(sp.fwSku)
        XCTAssertNil(sp.nvmCompatibility)

        let pi16 = try! XCTUnwrap(exts[2].partitionInfo)
        XCTAssertNil(pi16.vcn)
        XCTAssertEqual(pi16.hash.count, 64)
        XCTAssertEqual(pi16.instanceID, 0x1020_3040)

        let pi03 = try! XCTUnwrap(exts[3].partitionInfo)
        XCTAssertEqual(pi03.vcn, 3)                      // 0x03 R1 VCN @+0x30
        XCTAssertEqual(pi03.hash.count, 64)
    }

    func testCsme12RevisesOnly0F() {
        // csme12 dict = {0x0F: _R2}; 0x00/0x16 keep R1 layouts.
        let exts = decode([
            ExtFixture.systemInfo(r2: false),
            ExtFixture.signedPackage(r2: true),
            ExtFixture.partitionInfo(tag: 0x16, r2: false),
        ], family: .csme12)

        XCTAssertEqual(exts.count, 3)
        XCTAssertEqual(exts[0].systemInfo?.imageHash.count, 64)  // 0x00 stays R1
        XCTAssertEqual(exts[1].signedPackage?.fwType, 3)          // 0x0F → _R2
        XCTAssertEqual(exts[2].partitionInfo?.hash.count, 64)     // 0x16 stays R1
    }

    func testInitScriptAndUnknownTagsAreOpaque() {
        let exts = decode([
            ExtFixture.block(tag: 0x01, headerLen: 0x40, tail: 0x20),  // Init Script
            ExtFixture.block(tag: 0x77, headerLen: 0x20),              // unknown
        ], family: .csme15)

        XCTAssertEqual(exts.count, 2)
        XCTAssertEqual(exts[0].tag, 0x01)
        XCTAssertNil(exts[0].systemInfo)
        XCTAssertNil(exts[0].featurePermissions)
        XCTAssertNil(exts[0].signedPackage)
        XCTAssertNil(exts[0].clientSystemInfo)
        XCTAssertNil(exts[0].partitionInfo)
        XCTAssertEqual(exts[0].size, 0x40 + 0x20)
        XCTAssertEqual(exts[1].tag, 0x77)
        XCTAssertNil(exts[1].partitionInfo)
    }

    func testNullSizeStopsWalk() {
        // A well-formed block followed by a null-size block: the walk stops
        // without emitting a zero-size entry.
        var region = ExtFixture.concat([ExtFixture.systemInfo(r2: true)])
        region.append(Data(repeating: 0, count: 8))      // null Tag+Size tail
        let exts = CPDExtensionParser.decode(in: region,
                                             moduleContentBase: 0,
                                             moduleSize: region.count,
                                             chainStart: 0,
                                             family: .csme15,
                                             baseOffset: 0)
        XCTAssertEqual(exts.count, 1)
        XCTAssertEqual(exts[0].tag, 0x00)

        // A chain that is entirely zeroes yields no entries.
        let empty = CPDExtensionParser.decode(in: Data(repeating: 0, count: 16),
                                              moduleContentBase: 0,
                                              moduleSize: 16,
                                              chainStart: 0,
                                              family: .csme15,
                                              baseOffset: 0)
        XCTAssertTrue(empty.isEmpty)
    }

    func testOverflowingBlockIsEnvelopeOnlyAndStops() {
        // A block whose Size extends past the module end cannot be trusted to
        // hold a header — it surfaces as an envelope and the walk ends (the
        // advance has left the module). The module is declared smaller than the
        // block's own Size (0x58).
        let block = ExtFixture.systemInfo(r2: true)
        let exts = CPDExtensionParser.decode(in: block,
                                             moduleContentBase: 0,
                                             moduleSize: 0x40,
                                             chainStart: 0,
                                             family: .csme15,
                                             baseOffset: 0)
        XCTAssertEqual(exts.count, 1)
        XCTAssertEqual(exts[0].tag, 0x00)
        XCTAssertNil(exts[0].systemInfo)   // block overflows the module → no header
    }

    func testDecodeBoundsByModuleNotRegionTail() {
        // Trailing bytes beyond the module (the next partition) are ignored.
        let chain = ExtFixture.concat([ExtFixture.systemInfo(r2: true),
                                       ExtFixture.signedPackage(r2: true)])
        var region = chain
        region.append(Data(repeating: 0xEE, count: 0x100))  // next partition
        let exts = CPDExtensionParser.decode(in: region,
                                             moduleContentBase: 0,
                                             moduleSize: chain.count,
                                             chainStart: 0,
                                             family: .csme15,
                                             baseOffset: 0x100)
        XCTAssertEqual(exts.count, 2)
        XCTAssertEqual(exts[0].offset, 0x100)
        XCTAssertEqual(exts[1].offset, 0x100 + ExtFixture.systemInfo(r2: true).count)
        XCTAssertEqual(exts[1].signedPackage?.fwType, 3)
    }

    // MARK: - Module Attributes (0x0A) & .met chains

    /// 0x0A decodes with a 48-byte SHA-384 hash on csme15 (_R2) and 32-byte
    /// SHA-256 on csme12/base (R1), in a `.man`-style chain too.
    func testModuleAttributesDecodePerRevision() {
        let r2 = decode([ExtFixture.moduleAttributes(r2: true)], family: .csme15)
        let attrs2 = try! XCTUnwrap(r2[0].moduleAttributes)
        XCTAssertEqual(r2[0].tag, 0x0A)
        XCTAssertEqual(attrs2.compression, 1)            // Huffman
        XCTAssertEqual(attrs2.encryption, 0)             // None
        XCTAssertEqual(attrs2.uncompressedSize, 0x15000)
        XCTAssertEqual(attrs2.compressedSize, 0xDDD4)
        XCTAssertEqual(attrs2.deviceID, 2)
        XCTAssertEqual(attrs2.vendorID, 0x8086)
        XCTAssertEqual(attrs2.moduleHash.count, 96)      // SHA-384
        XCTAssertEqual(attrs2.moduleHash, rampHex(48))

        let r1 = decode([ExtFixture.moduleAttributes(r2: false)], family: .csme12)
        let attrs1 = try! XCTUnwrap(r1[0].moduleAttributes)
        XCTAssertEqual(attrs1.moduleHash.count, 64)      // SHA-256
        XCTAssertEqual(attrs1.uncompressedSize, 0x15000)
    }

    /// A `.met` body is its own chain — the walk starts at the content base (no
    /// `HeaderLength*4` skip) and bounds itself by the body size. Multi-row tags
    /// (here 0x09 Special File Producer with rows) stay envelopes.
    func testDecodeMetBodyWalksFromBodyBase() {
        let chain = ExtFixture.concat([
            ExtFixture.moduleAttributes(r2: false),
            ExtFixture.block(tag: 0x09, headerLen: 0x0C, tail: 0x18),  // special-file producer
            ExtFixture.block(tag: 0x0B, headerLen: 0x08, tail: 0x10),  // locked range
        ])
        var region = Data(repeating: 0xEE, count: 8)      // bytes before the body
        region.append(chain)

        let exts = CPDExtensionParser.decodeMetBody(in: region,
                                                    contentBase: 8,
                                                    bodySize: chain.count,
                                                    family: .csme12,
                                                    baseOffset: 0x1000)
        XCTAssertEqual(exts.count, 3)
        // Chain starts exactly at the content base: first block at offset 8 →
        // reported 0x1008. A `.man` decode would have skipped a header length here.
        XCTAssertEqual(exts[0].offset, 0x1008)
        XCTAssertEqual(exts.map(\.tag), [0x0A, 0x09, 0x0B])

        let attrs = try! XCTUnwrap(exts[0].moduleAttributes)   // csme12: R1, SHA-256
        XCTAssertEqual(attrs.compression, 1)
        XCTAssertEqual(attrs.moduleHash.count, 64)
        XCTAssertEqual(exts[1].offset, exts[0].offset + exts[0].size)
        XCTAssertNil(exts[1].moduleAttributes)                 // row-tag: envelope only
        XCTAssertEqual(exts[1].size, 0x0C + 0x18)
        XCTAssertEqual(exts[2].tag, 0x0B)
        XCTAssertNil(exts[2].featurePermissions)
    }

    func testDecodeMetBodyEmptyOrTruncatedYieldsNoBlocks() {
        XCTAssertTrue(CPDExtensionParser.decodeMetBody(
            in: Data(repeating: 0, count: 4), contentBase: 0, bodySize: 4,
            family: .csme15, baseOffset: 0).isEmpty)      // body too small for an envelope
        let body = ExtFixture.moduleAttributes(r2: true)
        // Declared body shorter than the block's own Size → no header, envelope only.
        let exts = CPDExtensionParser.decodeMetBody(in: body, contentBase: 0,
                                                    bodySize: 0x40, family: .csme15,
                                                    baseOffset: 0)
        XCTAssertEqual(exts.count, 1)
        XCTAssertNil(exts[0].moduleAttributes)
    }

    // MARK: - Helpers (expected values)

    private func rampHex(_ count: Int) -> String {
        (0..<count).map { String(format: "%02X", $0) }.joined()
    }
    private func usageHex() -> String {
        (0..<16).map { String(format: "%02X", 0x80 + $0) }.joined()
    }
}
