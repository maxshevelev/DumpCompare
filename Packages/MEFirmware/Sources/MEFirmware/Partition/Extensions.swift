import Foundation

/// CSE extension-block decode for the operational partition's manifest module —
/// the chain of `CSE_Ext_*` blocks that follows the `$MN2`/`$MAN` manifest
/// inside the module (upstream `ext_anl`, `MEA.py` 5826). A `.man` module holds
/// the partition manifest *plus* its extensions; `.met` module bodies are
/// Huffman blobs and only a manifest's own module carries this chain.
///
/// This is Stage 1 of the `CSE_Ext_*` port: the fixed header + scalars of the
/// six tags present on real FTPR chains (`0x00` System Info, `0x02` Feature
/// Permissions, `0x03`/`0x16` Partition Info, `0x0C` Client SysInfo, `0x0F`
/// Signed Package). Repeated `_Mod` row sub-tables (per-feature / per-module /
/// per-signed-package rows), `.met` metadata chains (tags `0x0A`/`05`/`06`…)
/// and the bitfield label dictionaries are deferred — such a block still
/// surfaces its envelope (`tag`/`size`/`offset`) so the UI sees the whole chain.
///
/// Faithful to upstream `ext_anl` (lines 6067–6105):
/// - the chain starts at `moduleContentBase + HeaderLength*4` — the manifest
///   struct's `HeaderLength` (u32 @ +0x04, in dwords) is skipped;
/// - envelope: `Tag` u32 @0, `Size` u32 @4 (tag `0x544F4F46` "FOOT" sizes at
///   @8); the next block begins at `offset + Size`;
/// - a null `Size` is a false positive and stops the walk; an advance that
///   leaves fewer than 4 bytes has reached the module end (upstream breaks when
///   `offset + 0x4 > entry offset + entry size`);
/// - the header struct revision (R1 base vs `_R2`) is chosen per tag from the
///   per-family `ext_tag_rev_hdr_*` dicts (lines 10490–10499), driven by the
///   manifest's own facts — no database.
enum CPDExtensionParser {
    /// Header-revision family, chosen from manifest facts alone (stage 1, no
    /// DB). Mirrors the upstream revision branch (lines 6111–6130) minus the
    /// `variant`/`variant_p` dimension, which stage 1 cannot know:
    /// - 3072-bit RSA key (0x180 bytes) or major 15/16 → the CSME15/16/CSSPS6
    ///   tables (`ext_tag_rev_hdr_csme15`);
    /// - CSME 12 (non-alpha) / 13 / 14 → `ext_tag_rev_hdr_csme12`; the 12-alpha
    ///   carve-out (minor==hotfix==0, build≥7000, year<2018, month<8 — upstream
    ///   compares `year<0x2018` on the BCD value, ~our decoded `year<2018`) uses
    ///   the base structs;
    /// - anything else (older CSE, GSC with major < 100 in our slice) → base
    ///   R1 structs.
    enum Family: Equatable {
        case base, csme12, csme15
    }

    static func family(major: Int, minor: Int, hotfix: Int, build: Int,
                       year: Int, month: Int, keyLength: Int?) -> Family {
        if keyLength == 0x180 || major == 15 || major == 16 { return .csme15 }
        let csme12Alpha = minor == 0 && hotfix == 0 && build >= 7000
            && year < 2018 && month < 8
        if (major == 12 && !csme12Alpha) || major == 13 || major == 14 {
            return .csme12
        }
        return .base
    }

    /// Decode the extension chain of the operational manifest's module.
    ///
    /// `moduleContentBase` is the module's start inside the region (its `$CPD`
    /// entry's content base, equal to the manifest base) and `moduleSize` its
    /// uncompressed size — the chain is bounded by `moduleContentBase + size`.
    /// `chainStart` is where extensions begin (`manifest.base + HeaderLength*4`).
    /// Region-relative block offsets are shifted by `baseOffset` so the reported
    /// `offset` is absolute (matching `CodePartition.offset`).
    static func decode(in region: Data,
                       moduleContentBase: Int,
                       moduleSize: Int,
                       chainStart: Int,
                       family: Family,
                       baseOffset: Int) -> [CPDExtension] {
        guard moduleSize > 0 else { return [] }
        let moduleEnd = min(moduleContentBase + moduleSize, region.count)
        // Each block needs a full envelope (tag u32 @0 + size u32 @4) to be read.
        guard moduleEnd >= moduleContentBase,
              chainStart >= moduleContentBase,
              chainStart + 8 <= moduleEnd else { return [] }

        var out: [CPDExtension] = []
        var offset = chainStart
        var loops = 0
        while offset + 8 <= moduleEnd {
            loops += 1
            if loops > 100 { break }   // forced-break backstop, mirrors upstream
            let tag = Int(u32le(region, offset))
            let size = Int(u32le(region, offset + 4))
            guard size > 0 else { break }   // null-size false positive
            let blockEnd = offset + size

            var systemInfo: SystemInfoExtension?
            var partitionInfo: PartitionInfoExtension?
            var signedPackage: SignedPackageExtension?
            var clientSystemInfo: ClientSystemInfoExtension?
            var featurePermissions: FeaturePermissionsExtension?

            // Decode the header only for a self-contained block fully inside its
            // module (upstream warns on overflow; we keep the envelope instead).
            if blockEnd <= moduleEnd {
                let revTag = headerRevTag(tag, family)
                switch (tag, revTag) {
                case (0x00, ""):
                    systemInfo = decodeSystemInfo(region, at: offset, r2: false)
                case (0x00, "_R2"):
                    systemInfo = decodeSystemInfo(region, at: offset, r2: true)
                case (0x02, ""):
                    featurePermissions = decodeFeaturePermissions(region, at: offset)
                case (0x03, ""):
                    partitionInfo = decodePartitionInfo(region, at: offset, tag: 0x03, r2: false)
                case (0x03, "_R2"):
                    partitionInfo = decodePartitionInfo(region, at: offset, tag: 0x03, r2: true)
                case (0x0C, ""):
                    clientSystemInfo = decodeClientSystemInfo(region, at: offset)
                case (0x0F, ""):
                    signedPackage = decodeSignedPackage(region, at: offset, r2: false)
                case (0x0F, "_R2"):
                    signedPackage = decodeSignedPackage(region, at: offset, r2: true)
                case (0x16, ""):
                    partitionInfo = decodePartitionInfo(region, at: offset, tag: 0x16, r2: false)
                case (0x16, "_R2"):
                    partitionInfo = decodePartitionInfo(region, at: offset, tag: 0x16, r2: true)
                default:
                    break   // 0x01 Init Script & unknown tags: envelope only
                }
            }

            out.append(CPDExtension(
                id: out.count,
                tag: tag,
                size: size,
                offset: baseOffset + offset,
                systemInfo: systemInfo,
                partitionInfo: partitionInfo,
                signedPackage: signedPackage,
                clientSystemInfo: clientSystemInfo,
                featurePermissions: featurePermissions))
            offset = blockEnd
        }
        return out
    }

    // MARK: - Header revision tag

    /// Header revision suffix ("" = original R1 struct) per upstream's
    /// per-family `ext_tag_rev_hdr_*` dicts (MEA.py 10490–10499), truncated to
    /// the tags whose headers this stage decodes. csme15 revises 0x00/0x03/0x0F/
    /// 0x16 (among others not decoded here); csme12 revises only 0x0F.
    static func headerRevTag(_ tag: Int, _ family: Family) -> String {
        switch family {
        case .csme15:
            return [0x00: "_R2", 0x03: "_R2", 0x0F: "_R2", 0x16: "_R2"][tag] ?? ""
        case .csme12:
            return [0x0F: "_R2"][tag] ?? ""
        case .base:
            return ""
        }
    }

    // MARK: - Per-tag header decoders (fixed header + scalars, rows skipped)

    /// `CSE_Ext_00` System Information — R1 0x40 / R2 0x50; IMGDefaultHash is
    /// SHA-256 (32B) in R1, SHA-384 (48B) in R2.
    private static func decodeSystemInfo(_ region: Data, at p: Int, r2: Bool)
        -> SystemInfoExtension? {
        let headerLen = r2 ? 0x50 : 0x40
        let hashLen = r2 ? 48 : 32
        guard p + headerLen <= region.count else { return nil }
        return SystemInfoExtension(
            minUMASize: Int(u32le(region, p + 0x08)),
            chipsetVersion: Int(u32le(region, p + 0x0C)),
            pageableUMASize: Int(u32le(region, p + (r2 ? 0x40 : 0x30))),
            imageHash: hexUpper(region, p + 0x10, hashLen))
    }

    /// `CSE_Ext_02` Feature Permissions — 0x0C header. Only ModuleCount is read;
    /// the `_02_Mod` feature rows fill `Size − 0x0C`.
    private static func decodeFeaturePermissions(_ region: Data, at p: Int)
        -> FeaturePermissionsExtension? {
        guard p + 0x0C <= region.count else { return nil }
        return FeaturePermissionsExtension(moduleCount: Int(u32le(region, p + 0x08)))
    }

    /// `CSE_Ext_03` (0x58 R1 / 0x68 R2) and `CSE_Ext_16` (same sizes) Partition
    /// Information. Both carry PartitionName/Size, version + data-format
    /// quadruple, InstanceID, Flags and a stored partition hash (`$CPD - $MN2 +
    /// Data`, SHA-256 R1 / SHA-384 R2). Only 0x03 has a VCN (0x30/0x40); 0x16
    /// puts its fields before the hash instead.
    private static func decodePartitionInfo(_ region: Data, at p: Int,
                                            tag: Int, r2: Bool)
        -> PartitionInfoExtension? {
        let headerLen = r2 ? 0x68 : 0x58
        guard p + headerLen <= region.count else { return nil }

        let hashLen = r2 ? 48 : 32
        let versionBase: Int
        let hashAt: Int
        let vcn: Int?
        if tag == 0x03 {
            versionBase = r2 ? 0x44 : 0x34   // PartitionVerMin u16 at base
            hashAt = 0x10
            vcn = Int(u32le(region, p + (r2 ? 0x40 : 0x30)))
        } else {
            versionBase = 0x10               // same for both 0x16 revisions
            hashAt = 0x24
            vcn = nil
        }
        return PartitionInfoExtension(
            partitionName: ascii4(region, p + 0x08),
            partitionSize: Int(u32le(region, p + 0x0C)),
            vcn: vcn,
            versionMajor: Int(u16le(region, p + versionBase + 2)),
            versionMinor: Int(u16le(region, p + versionBase)),
            dataFormatMajor: Int(u16le(region, p + versionBase + 6)),
            dataFormatMinor: Int(u16le(region, p + versionBase + 4)),
            instanceID: Int(u32le(region, p + (tag == 0x03 ? (r2 ? 0x4C : 0x3C) : 0x18))),
            flags: Int(u32le(region, p + (tag == 0x03 ? (r2 ? 0x50 : 0x40) : 0x1C))),
            hash: hexUpper(region, p + hashAt, hashLen))
    }

    /// `CSE_Ext_0C` Client System Information — 0x30, a single block (upstream
    /// requires Size == 0x30). FWSKUCaps bitmask @8; FWSKUAttrib u64 @0x28 with
    /// bitfields CSESize(4)/SKUType(3)/Workstation(1)/M3(1)/M0(1)/SKUPlatform(2)/
    /// SiClass(4)/Reserved(50) (lines 3101–3111). Raw ints only.
    private static func decodeClientSystemInfo(_ region: Data, at p: Int)
        -> ClientSystemInfoExtension? {
        guard p + 0x30 <= region.count else { return nil }
        let attrib = u64le(region, p + 0x28)
        return ClientSystemInfoExtension(
            skuCaps: Int(u32le(region, p + 0x08)),
            cseSize: Int((attrib >> 0) & 0xF),
            skuType: Int((attrib >> 4) & 0x7),
            workstation: (attrib >> 7) & 1 != 0,
            m3: (attrib >> 8) & 1 != 0,
            m0: (attrib >> 9) & 1 != 0,
            skuPlatform: Int((attrib >> 10) & 0x3),
            siClass: Int((attrib >> 12) & 0xF))
    }

    /// `CSE_Ext_0F` Signed Package Information — 0x34 header in both revisions;
    /// `_R2` reuses the R1 reserved bytes as FWType u8 @0x24 (bits 0–2), FWSKU
    /// u8 @0x25 (bits 0–2), NVMCompatibility u32 @0x26 (bits 0–1). The
    /// `_0F_Mod` signed-package rows fill the rest.
    private static func decodeSignedPackage(_ region: Data, at p: Int, r2: Bool)
        -> SignedPackageExtension? {
        guard p + 0x34 <= region.count else { return nil }
        return SignedPackageExtension(
            partitionName: ascii4(region, p + 0x08),
            vcn: Int(u32le(region, p + 0x0C)),
            usageBitmap: hexUpper(region, p + 0x10, 16),
            arbSvn: Int(u32le(region, p + 0x20)),
            fwType: r2 ? Int(UInt8(region[p + 0x24]) & 0x7) : nil,
            fwSku: r2 ? Int(UInt8(region[p + 0x25]) & 0x7) : nil,
            nvmCompatibility: r2 ? Int(u32le(region, p + 0x26) & 0x3) : nil)
    }

    // MARK: - Byte readers

    /// 4-char NUL-padded ASCII name (e.g. "FTPR"), like `CPD_Entry.Name`.
    private static func ascii4(_ data: Data, _ p: Int) -> String {
        guard p + 4 <= data.count else { return "" }
        let bytes = data.subdata(in: (data.startIndex + p)..<(data.startIndex + p + 4))
        return String(data: bytes, encoding: .ascii)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
    }

    /// Uppercase hex of `len` raw bytes at `p` — stored hashes / usage bitmaps.
    private static func hexUpper(_ data: Data, _ p: Int, _ len: Int) -> String {
        guard len > 0, p + len <= data.count else { return "" }
        return data.subdata(in: (data.startIndex + p)..<(data.startIndex + p + len))
            .map { String(format: "%02X", $0) }.joined()
    }

    private static func u16le(_ data: Data, _ p: Int) -> UInt16 {
        UInt16(data[p]) | (UInt16(data[p + 1]) << 8)
    }

    private static func u32le(_ data: Data, _ p: Int) -> UInt32 {
        UInt32(data[p])
            | (UInt32(data[p + 1]) << 8)
            | (UInt32(data[p + 2]) << 16)
            | (UInt32(data[p + 3]) << 24)
    }

    private static func u64le(_ data: Data, _ p: Int) -> UInt64 {
        UInt64(u32le(data, p)) | (UInt64(u32le(data, p + 4)) << 32)
    }
}
