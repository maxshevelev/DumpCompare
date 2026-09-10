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

    /// `CSE_Ext_05` Process Attributes (0x44 header + u16 group-id rows). A
    /// two-group module: Flags 0x78 (bits 3–6 set), MainThreadID 0x3000300,
    /// code 0x39000 / 0x2C45A, heaps 0x6280/0x22000, entry 0x39066, UID 0, and
    /// the two row GroupIDs 0x0008 / 0x000F (the real bup.met first rows).
    static func processAttributes(groupIDs: [UInt16]) -> Data {
        var b = block(tag: 0x05, headerLen: 0x44, tail: groupIDs.count * 2)
        wU32(0x0000_0078, 0x08, &b)                  // Flags
        wU32(0x0300_0300, 0x0C, &b)                  // MainThreadID
        wU32(0x0003_9000, 0x10, &b)                  // CodeBaseAddress
        wU32(0x0002_C45A, 0x14, &b)                  // CodeSizeUncomp
        wU32(0, 0x18, &b)                            // CM0HeapSize
        wU32(0x0000_6280, 0x1C, &b)                  // BSSSize
        wU32(0x0002_2000, 0x20, &b)                  // DefaultHeapSize
        wU32(0x0003_9066, 0x24, &b)                  // MainThreadEntry
        wU32(0x001F_C7FE, 0x28, &b)                  // AllowedSysCalls[0]
        wU32(0x0000_0000, 0x2C, &b)                  // AllowedSysCalls[1]
        wU32(0x0000_0000, 0x30, &b)                  // AllowedSysCalls[2]
        wU16(0, 0x34, &b)                            // UserID
        for (i, gid) in groupIDs.enumerated() {
            wU16(gid, 0x44 + i * 2, &b)              // _Mod GroupID
        }
        return b
    }

    /// `CSE_Ext_06` Thread Attributes (0x08 header + 0x10 thread rows). Two
    /// threads with the real bup.met profile: stack 0x2000, Flags 0x1
    /// (FlagsType Live), scheduling policy 0, reserved 0.
    static func threadAttributes(count: Int) -> Data {
        var b = block(tag: 0x06, headerLen: 0x08, tail: count * 0x10)
        for i in 0..<count {
            let r = 0x08 + i * 0x10
            wU32(0x2000, r + 0x00, &b)               // StackSize
            wU32(0x0000_0001, r + 0x04, &b)          // Flags
            wU32(0, r + 0x08, &b)                    // SchedulPolicy
            wU32(0, r + 0x0C, &b)                    // Reserved
        }
        return b
    }

    /// `CSE_Ext_07` Device Types (0x08 header + 0x08 device rows): DeviceIDs
    /// 0x00020000/0x00020008 (the real heci.met rows), Reserved 0.
    static func deviceTypes() -> Data {
        var b = block(tag: 0x07, headerLen: 0x08, tail: 2 * 0x08)
        wU32(0x0002_0000, 0x08, &b)
        wU32(0, 0x0C, &b)
        wU32(0x0002_0008, 0x10, &b)
        wU32(0, 0x14, &b)
        return b
    }

    /// `CSE_Ext_08` MMIO Ranges (0x08 header + 0x0C range rows). Three ranges
    /// echoing the real bup.met: 0xF7000000/0x400000 RW, 0xF00B4000/0x1000 RW,
    /// and a 0xF5038000 read-only (Flags 1).
    static func mmioRanges() -> Data {
        var b = block(tag: 0x08, headerLen: 0x08, tail: 3 * 0x0C)
        wU32(0xF700_0000, 0x08, &b); wU32(0x0040_0000, 0x0C, &b); wU32(0x3, 0x10, &b)
        wU32(0xF00B_4000, 0x14, &b); wU32(0x0000_1000, 0x18, &b); wU32(0x3, 0x1C, &b)
        wU32(0xF503_8000, 0x20, &b); wU32(0x0000_1000, 0x24, &b); wU32(0x1, 0x28, &b)
        return b
    }

    /// `CSE_Ext_09` Special File Producer (0x0C header + 0x18 definition rows):
    /// major 30, then a `heci1`-style row (name `heci1`, access 0x1F0, uid 0x2F,
    /// gid 0x5, minor 0).
    static func specialFiles() -> Data {
        var b = block(tag: 0x09, headerLen: 0x0C, tail: 0x18)
        wU16(30, 0x08, &b)                           // MajorNumber
        wU16(0, 0x0A, &b)                            // Flags
        for (j, byte) in "heci1".utf8.prefix(12).enumerated() {
            b[0x0C + j] = byte
        }                                            // Name char[12]
        wU16(0x1F0, 0x0C + 0x0C, &b)                 // AccessMode
        wU16(0x2F, 0x0C + 0x0E, &b)                  // UserID
        wU16(0x05, 0x0C + 0x10, &b)                  // GroupID
        wU8(0, 0x0C + 0x12, &b)                      // MinorNumber
        wU8(0, 0x0C + 0x13, &b)                      // Reserved0
        wU32(0, 0x0C + 0x14, &b)                     // Reserved1
        return b
    }

    /// `CSE_Ext_0B` Locked Ranges (0x08 header + 0x08 rows): one range
    /// base 0x9008 / size 0 (the real syslib.met row).
    static func lockedRanges() -> Data {
        var b = block(tag: 0x0B, headerLen: 0x08, tail: 0x08)
        wU32(0x9008, 0x08, &b)
        wU32(0, 0x0C, &b)
        return b
    }

    /// `CSE_Ext_0D` User Information (0x08 header + `_Mod_R2` 0x10 rows when
    /// `r2`, else `_Mod` 0x34 rows with a WorkingDir): the two real vfs.met
    /// first rows (uid 0x94 / 0x3, nv/ram/wop 0x2000 and 0x850/0x6000/0x850).
    static func userInfo(r2: Bool) -> Data {
        let stride = r2 ? 0x10 : 0x34
        var b = block(tag: 0x0D, headerLen: 0x08, tail: stride * 2)
        func row(_ i: Int, _ uid: UInt16, _ nv: UInt32, _ ram: UInt32, _ wop: UInt32,
                 _ dir: String) {
            let r = 0x08 + i * stride
            wU16(uid, r + 0x00, &b)
            wU16(0, r + 0x02, &b)
            wU32(nv, r + 0x04, &b)
            wU32(ram, r + 0x08, &b)
            wU32(wop, r + 0x0C, &b)
            // `_Mod_R2` rows (stride 0x10) carry no WorkingDir — only base `_Mod`
            // (0x34) rows do, at +0x10 over 36 bytes.
            if !r2 {
                for (j, byte) in dir.utf8.prefix(36).enumerated() { b[r + 0x10 + j] = byte }
            }
        }
        row(0, 0x0094, 0x2000, 0x2000, 0x2000, "/sys")
        row(1, 0x0003, 0x850, 0x6000, 0x850, "/tmp")
        return b
    }

    /// `CSE_Ext_04` Shared Library Attributes (0x1C, header-only): the real
    /// syslib.met block (ctx 0x268, virt 0x30000, reserved all-ones).
    static func sharedLibrary() -> Data {
        var b = block(tag: 0x04, headerLen: 0x1C)
        wU32(0x268, 0x08, &b)                        // ContextSize
        wU32(0x3_0000, 0x0C, &b)                     // TotAlocVirtSpc
        wU32(0, 0x10, &b)                            // CodeBaseAddress
        wU32(0, 0x14, &b)                            // TLSSize
        wU32(0xFFFF_FFFF, 0x18, &b)                  // Reserved
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

    // MARK: - `.met` row-bearing tags (0x04–0x0D)

    func testProcessAttributesDecodesHeaderAndGroupRows() {
        // bup.met's real block: Flags 0x78 → Trusted send/receive + public
        // receivers set, single GroupID row 0x0008.
        let exts = decode([ExtFixture.processAttributes(groupIDs: [0x0008])],
                          family: .csme12)

        let p = try! XCTUnwrap(exts.first?.processAttributes)
        XCTAssertFalse(p.faultTolerant)
        XCTAssertFalse(p.permanentProcess)
        XCTAssertFalse(p.singleInstance)
        XCTAssertTrue(p.trustedSendReceiveSender)
        XCTAssertTrue(p.trustedNotifySender)
        XCTAssertTrue(p.publicSendReceiveReceiver)
        XCTAssertTrue(p.publicNotifyReceiver)
        XCTAssertEqual(p.flagsReserved, 0)
        XCTAssertEqual(p.mainThreadID, 0x0300_0300)
        XCTAssertEqual(p.codeBaseAddress, 0x39000)
        XCTAssertEqual(p.codeSizeUncompressed, 0x2C45A)
        XCTAssertEqual(p.cm0HeapSize, 0)
        XCTAssertEqual(p.bssSize, 0x6280)
        XCTAssertEqual(p.defaultHeapSize, 0x22000)
        XCTAssertEqual(p.mainThreadEntry, 0x39066)
        XCTAssertEqual(p.allowedSysCalls, [0x1F_C7FE, 0, 0])
        XCTAssertEqual(p.userID, 0)
        XCTAssertEqual(p.rows.map(\.groupID), [0x0008])
        // Envelope Size covers header + the single u16 row.
        XCTAssertEqual(exts.first?.size, 0x46)
    }

    func testThreadDeviceMmioLockedBlocksDecodeRows() {
        let exts = decode([
            ExtFixture.threadAttributes(count: 3),
            ExtFixture.deviceTypes(),
            ExtFixture.mmioRanges(),
            ExtFixture.lockedRanges(),
        ], family: .csme12)

        XCTAssertEqual(exts.count, 4)
        XCTAssertEqual(exts.map(\.tag), [0x06, 0x07, 0x08, 0x0B])

        let threads = try! XCTUnwrap(exts[0].threadAttributes)
        XCTAssertEqual(threads.rows.count, 3)
        XCTAssertEqual(threads.rows[0].stackSize, 0x2000)
        XCTAssertEqual(threads.rows[0].flags, 1)         // FlagsType Live
        XCTAssertEqual(threads.rows[0].schedulingPolicy, 0)
        XCTAssertEqual(threads.rows.map(\.id), [0, 1, 2])
        XCTAssertEqual(exts[0].size, 0x08 + 3 * 0x10)

        let devices = try! XCTUnwrap(exts[1].deviceTypes)
        XCTAssertEqual(devices.rows.map(\.deviceID), [0x0002_0000, 0x0002_0008])
        XCTAssertEqual(devices.rows.map(\.reserved), [0, 0])

        let mmio = try! XCTUnwrap(exts[2].mmioRanges)
        XCTAssertEqual(mmio.rows.count, 3)
        XCTAssertEqual(mmio.rows[0].baseAddress, 0xF700_0000)
        XCTAssertEqual(mmio.rows[0].sizeLimit, 0x0040_0000)
        XCTAssertEqual(mmio.rows[0].flags, 0x3)          // Read & Write
        XCTAssertEqual(mmio.rows[2].flags, 0x1)          // Read Only

        let locked = try! XCTUnwrap(exts[3].lockedRanges)
        XCTAssertEqual(locked.rows.map(\.rangeBase), [0x9008])
        XCTAssertEqual(locked.rows.map(\.rangeSize), [0])
    }

    func testSpecialFilesDecodesHeaderAndNamedRows() {
        let exts = decode([ExtFixture.specialFiles()], family: .csme12)

        let sf = try! XCTUnwrap(exts.first?.specialFiles)
        XCTAssertEqual(sf.majorNumber, 30)
        XCTAssertEqual(sf.flags, 0)
        XCTAssertEqual(sf.rows.count, 1)
        let row = try! XCTUnwrap(sf.rows.first)
        XCTAssertEqual(row.name, "heci1")                // NUL-trimmed char[12]
        XCTAssertEqual(row.accessMode, 0x1F0)
        XCTAssertEqual(row.userID, 0x2F)
        XCTAssertEqual(row.groupID, 0x05)
        XCTAssertEqual(row.minorNumber, 0)
        XCTAssertEqual(exts.first?.size, 0x0C + 0x18)
    }

    func testSharedLibraryHeaderOnlyDecodes() {
        let exts = decode([ExtFixture.sharedLibrary()], family: .csme12)

        let sl = try! XCTUnwrap(exts.first?.sharedLibrary)
        XCTAssertEqual(sl.contextSize, 0x268)
        XCTAssertEqual(sl.totalAllocatedVirtSpace, 0x3_0000)
        XCTAssertEqual(sl.reserved, 0xFFFF_FFFF)
        XCTAssertNil(exts.first?.userInfo)
    }

    func testUserInfoRowsUseFamilyRevision() {
        // CSME 12/15 revise 0x0D `_Mod` → `_Mod_R2` (0x10 stride, no WorkingDir).
        let exts12 = decode([ExtFixture.userInfo(r2: true)], family: .csme12)
        let ui = try! XCTUnwrap(exts12.first?.userInfo)
        XCTAssertEqual(ui.rows.count, 2)
        XCTAssertEqual(ui.rows[0].userID, 0x0094)
        XCTAssertEqual(ui.rows[0].nvStorageQuota, 0x2000)
        XCTAssertEqual(ui.rows[0].ramStorageQuota, 0x2000)
        XCTAssertEqual(ui.rows[0].wopQuota, 0x2000)
        XCTAssertNil(ui.rows[0].workingDirectory)        // R2 row has no dir
        XCTAssertEqual(exts12.first?.size, 0x08 + 2 * 0x10)

        // The base family keeps `CSE_Ext_0D_Mod` (0x34 stride + WorkingDir).
        let extsBase = decode([ExtFixture.userInfo(r2: false)], family: .base)
        let base = try! XCTUnwrap(extsBase.first?.userInfo)
        XCTAssertEqual(base.rows.count, 2)
        XCTAssertEqual(base.rows[0].workingDirectory, "/sys")
        XCTAssertEqual(extsBase.first?.size, 0x08 + 2 * 0x34)
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

/// `CPDExtensionParser.hoist` — the default-output rows 9/10 facts (ARB
/// Security Version Number / Version Control Number) read off an extension
/// array, mirroring upstream's last-wins walk of CSE_Ext_0F/0x03 (6185/6245).
/// The payloads are built straight on the model structs (no bytes needed — the
/// decode that produces them is covered by `ExtensionWalkerTests`).
final class ExtensionHoistTests: XCTestCase {
    /// A CSE_Ext_0F block carrying `arbSvn` and `vcn` — and, for an `_R2`
    /// header, the NVM Compatibility field only that revision has.
    private func ext0F(id: Int, arbSvn: Int, vcn: Int,
                       nvm: Int? = nil) -> CPDExtension {
        CPDExtension(id: id, tag: 0x0F, size: 0x34, offset: 0,
                     signedPackage: SignedPackageExtension(
                        partitionName: "NVM0", vcn: vcn, usageBitmap: "",
                        arbSvn: arbSvn, fwType: nil, fwSku: nil,
                        nvmCompatibility: nvm))
    }

    /// A CSE_Ext_03 block carrying `vcn`.
    private func ext03(id: Int, vcn: Int) -> CPDExtension {
        CPDExtension(id: id, tag: 0x03, size: 0x58, offset: 0,
                     partitionInfo: PartitionInfoExtension(
                        partitionName: "FTPR", partitionSize: 0, vcn: vcn,
                        versionMajor: 0, versionMinor: 0, dataFormatMajor: 0,
                        dataFormatMinor: 0, instanceID: 0, flags: 0, hash: ""))
    }

    func testHoistReadsArbSvnFrom0FAndVcnFrom03() {
        // A chain with one 0x0F (arbSvn 5 / vcn 3) and one 0x03 (vcn 7): arbSvn
        // surfaces from the 0x0F, while the top-level VCN prefers the 0x03.
        let hoist = CPDExtensionParser.hoist([ext0F(id: 0, arbSvn: 5, vcn: 3),
                                              ext03(id: 1, vcn: 7)])
        XCTAssertEqual(hoist.arbSvn, 5)
        XCTAssertEqual(hoist.vcn03, 7)
        XCTAssertEqual(hoist.vcn0F, 3)
    }

    func testHoistFallsBackTo0FVcnWithout03() {
        let hoist = CPDExtensionParser.hoist([ext0F(id: 0, arbSvn: 9, vcn: 11)])
        XCTAssertEqual(hoist.arbSvn, 9)
        XCTAssertEqual(hoist.vcn03, nil)
        XCTAssertEqual(hoist.vcn0F, 11)
    }

    func testHoistKeepsLastOfEachTag() {
        // Multiple 0x0F/0x03 blocks — upstream reads the last of each source
        // (arbSvn is overwritten per 0x0F, 0x03 VCN overwrites per 0x03).
        let hoist = CPDExtensionParser.hoist([
            ext0F(id: 0, arbSvn: 5, vcn: 3),
            ext03(id: 1, vcn: 7),
            ext0F(id: 2, arbSvn: 6, vcn: 4),
            ext03(id: 3, vcn: 8),
        ])
        XCTAssertEqual(hoist.arbSvn, 6)
        XCTAssertEqual(hoist.vcn03, 8)
        XCTAssertEqual(hoist.vcn0F, 4)
    }

    /// Row 7: the NVM Compatibility of the last `_R2` signed package. An R1
    /// header has no such field, and upstream writes the fact from inside the
    /// R2 branch alone (6255) — so an R1 block after an R2 one leaves the
    /// medium the R2 block named rather than clearing it back to unknown.
    func testHoistKeepsTheLastNVMAnR2BlockNamed() {
        XCTAssertEqual(
            CPDExtensionParser.hoist([ext0F(id: 0, arbSvn: 1, vcn: 1, nvm: 1),
                                      ext0F(id: 1, arbSvn: 1, vcn: 1, nvm: 2)]).nvm,
            2, "the last R2 block wins, as it does for ARB SVN and VCN"
        )
        XCTAssertEqual(
            CPDExtensionParser.hoist([ext0F(id: 0, arbSvn: 1, vcn: 1, nvm: 2),
                                      ext0F(id: 1, arbSvn: 1, vcn: 1)]).nvm,
            2, "an R1 block carries no NVM field and cannot unsay one"
        )
        XCTAssertNil(
            CPDExtensionParser.hoist([ext0F(id: 0, arbSvn: 1, vcn: 1)]).nvm,
            "a chain of R1 blocks names no medium at all"
        )
    }

    func testHoistIgnores016AndEnvelopeOnlyBlocks() {
        // 0x16 partition info carries no VCN (vcn nil there) and envelope-only
        // blocks have no payload — neither contributes.
        let sixteen = CPDExtension(
            id: 0, tag: 0x16, size: 0x68, offset: 0,
            partitionInfo: PartitionInfoExtension(
                partitionName: "FTPR", partitionSize: 0, vcn: nil,
                versionMajor: 0, versionMinor: 0, dataFormatMajor: 0,
                dataFormatMinor: 0, instanceID: 0, flags: 0, hash: ""))
        let empty = CPDExtension(id: 1, tag: 0x00, size: 0x50, offset: 0)

        let hoist = CPDExtensionParser.hoist([sixteen, empty])
        XCTAssertNil(hoist.arbSvn)
        XCTAssertNil(hoist.vcn03)
        XCTAssertNil(hoist.vcn0F)
    }

    func testHoistEmptyChainIsAllNil() {
        let hoist = CPDExtensionParser.hoist([])
        XCTAssertNil(hoist.arbSvn)
        XCTAssertNil(hoist.vcn03)
        XCTAssertNil(hoist.vcn0F)
    }
}
