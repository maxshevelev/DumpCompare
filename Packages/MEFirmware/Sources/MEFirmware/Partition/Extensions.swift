import Foundation

/// CSE extension-block decode for the operational partition's manifest module —
/// the chain of `CSE_Ext_*` blocks that follows the `$MN2`/`$MAN` manifest
/// inside the module (upstream `ext_anl`, `MEA.py` 5826). A `.man` module holds
/// the partition manifest *plus* its extensions; `.met` module bodies are
/// Huffman blobs and only a manifest's own module carries this chain.
///
/// This covers the fixed headers and, for the row-bearing `.met` tags, their
/// `_Mod` row sub-tables: `0x00` System Info, `0x02` Feature Permissions (count
/// only), `0x03`/`0x16` Partition Info, `0x0C` Client SysInfo, `0x0F` Signed
/// Package (a `.man` body), `0x0A` Module Attributes (the universal first block
/// of a `.met` body), and the `.met` row tags `0x04` Shared Library, `0x05`
/// Process, `0x06` Threads, `0x07` Devices, `0x08` MMIO, `0x09` Special Files,
/// `0x0B` Locked Ranges and `0x0D` User Info (each header + `_Mod` rows sized
/// `(Size − header) / rowStride`, revision-aware for `0x0D`). The `_02_Mod`
/// feature rows, the `_0F_Mod` signed-package rows and the bitfield label
/// dictionaries stay deferred, and `0x01` Init Script + unknown tags surface as
/// an envelope (`tag`/`size`/`offset`) so the UI still sees the whole chain.
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
        return walkBlocks(in: region, from: chainStart, moduleEnd: moduleEnd,
                          family: family, baseOffset: baseOffset)
    }

    /// Decode the extension chain of a `.met` companion module (upstream ext_anl
    /// `.met`). Unlike a `.man` body — which begins with the `$MN2`/`$MAN`
    /// manifest struct, so its chain starts `HeaderLength*4` bytes in — a `.met`
    /// body *is* its chain: it is always uncompressed and the walk starts at its
    /// content base (`$CPD` entry offset, `bodySize` = entry size). Its first
    /// block is almost always the `0x0A` Module Attributes extension.
    static func decodeMetBody(in region: Data,
                              contentBase: Int,
                              bodySize: Int,
                              family: Family,
                              baseOffset: Int) -> [CPDExtension] {
        guard bodySize > 0 else { return [] }
        let bodyEnd = min(contentBase + bodySize, region.count)
        guard bodyEnd >= contentBase, contentBase + 8 <= bodyEnd else { return [] }
        return walkBlocks(in: region, from: contentBase, moduleEnd: bodyEnd,
                          family: family, baseOffset: baseOffset)
    }

    /// Shared chain walk: emit one `CPDExtension` per `Tag`/`Size` block from
    /// `from` up to `moduleEnd`, decoding a self-contained header for the tags
    /// this stage understands and surfacing every other block as an envelope.
    private static func walkBlocks(in region: Data, from start: Int,
                                   moduleEnd: Int, family: Family,
                                   baseOffset: Int) -> [CPDExtension] {
        var out: [CPDExtension] = []
        var offset = start
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
            var moduleAttributes: ModuleAttributesExtension?
            var sharedLibrary: SharedLibraryExtension?
            var processAttributes: ProcessAttributesExtension?
            var threadAttributes: ThreadAttributesExtension?
            var deviceTypes: DeviceTypesExtension?
            var mmioRanges: MmioRangesExtension?
            var specialFiles: SpecialFilesExtension?
            var lockedRanges: LockedRangesExtension?
            var userInfo: UserInfoExtension?

            // Decode the header + `_Mod` rows only for a self-contained block
            // fully inside its module (upstream warns on overflow; we keep the
            // envelope instead).
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
                case (0x0A, ""):
                    moduleAttributes = decodeModuleAttributes(region, at: offset, r2: false)
                case (0x0A, "_R2"):
                    moduleAttributes = decodeModuleAttributes(region, at: offset, r2: true)
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
                case (0x04, ""):
                    sharedLibrary = decodeSharedLibrary(region, at: offset)
                case (0x05, ""):
                    processAttributes = decodeProcessAttributes(region, at: offset, size: size)
                case (0x06, ""):
                    threadAttributes = decodeThreadAttributes(region, at: offset, size: size)
                case (0x07, ""):
                    deviceTypes = decodeDeviceTypes(region, at: offset, size: size)
                case (0x08, ""):
                    mmioRanges = decodeMmioRanges(region, at: offset, size: size)
                case (0x09, ""):
                    specialFiles = decodeSpecialFiles(region, at: offset, size: size)
                case (0x0B, ""):
                    lockedRanges = decodeLockedRanges(region, at: offset, size: size)
                case (0x0D, ""):
                    userInfo = decodeUserInfo(region, at: offset, size: size, family: family)
                default:
                    break   // 0x01 Init Script and unknown tags: envelope only
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
                featurePermissions: featurePermissions,
                moduleAttributes: moduleAttributes,
                sharedLibrary: sharedLibrary,
                processAttributes: processAttributes,
                threadAttributes: threadAttributes,
                deviceTypes: deviceTypes,
                mmioRanges: mmioRanges,
                specialFiles: specialFiles,
                lockedRanges: lockedRanges,
                userInfo: userInfo))
            offset = blockEnd
        }
        return out
    }

    // MARK: - Chain fact hoist (default-output rows 9/10)

    /// Last-seen hoisted facts of an extension chain, read like upstream's
    /// main-flow walk (rows 9/10 of the default-output map): the ARB SVN and VCN
    /// of the last `CSE_Ext_0F` (`SignedPackageExtension.arbSvn`/`.vcn`) and the
    /// VCN of the last `CSE_Ext_03` (`PartitionInfoExtension.vcn` — 0x03 only;
    /// the 0x16 variant carries no VCN).
    struct Hoist: Equatable {
        var arbSvn: Int?
        var vcn03: Int?
        var vcn0F: Int?
    }

    /// Walk `extensions` keeping the last 0x0F/0x03 of each — the same
    /// last-wins iteration `skuText` uses for its 0x0C/0x0F payloads.
    static func hoist(_ extensions: [CPDExtension]) -> Hoist {
        var out = Hoist()
        for ext in extensions {
            if let sp = ext.signedPackage {
                out.arbSvn = sp.arbSvn
                out.vcn0F = sp.vcn
            }
            if let pi = ext.partitionInfo, ext.tag == 0x03, let v = pi.vcn {
                out.vcn03 = v
            }
        }
        return out
    }

    // MARK: - Header revision tag

    /// Header revision suffix ("" = original R1 struct) per upstream's
    /// per-family `ext_tag_rev_hdr_*` dicts (MEA.py 10490–10499), truncated to
    /// the tags whose headers this stage decodes. csme15 revises 0x00/0x03/0x0A/
    /// 0x0F/0x16 (among others not decoded here); csme12 revises only 0x0F (its
    /// `.met` headers — incl. 0x0A — keep the R1 structs).
    static func headerRevTag(_ tag: Int, _ family: Family) -> String {
        switch family {
        case .csme15:
            return [0x00: "_R2", 0x03: "_R2", 0x0A: "_R2", 0x0F: "_R2", 0x16: "_R2"][tag] ?? ""
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

    /// `CSE_Ext_0A` Module Attributes (MOD_ATTR_EXTENSION) — a single
    /// self-contained block (0x38 R1 / 0x48 R2) and the universal first block of
    /// a `.met` chain. It describes the *owner* module of that `.met`: the
    /// compression/encryption of its body, its uncompressed & compressed sizes,
    /// DEV_ID/VEN_ID and the stored body hash (SHA-256 R1 / SHA-384 R2, as
    /// uppercase hex). Raw ints; the compression/encryption label *sets* differ
    /// between revisions (compression 0 None/1 Huffman/2 LZMA; encryption R1
    /// 0 None/1 AES-CBC vs R2 0 None/1 AES-ECB/2 AES-CTR), so name mapping is a
    /// display-layer concern.
    private static func decodeModuleAttributes(_ region: Data, at p: Int, r2: Bool)
        -> ModuleAttributesExtension? {
        let hashLen = r2 ? 48 : 32
        guard p + 0x18 + hashLen <= region.count else { return nil }
        return ModuleAttributesExtension(
            compression: Int(region[p + 0x08]),
            encryption: Int(region[p + 0x09]),
            uncompressedSize: Int(u32le(region, p + 0x0C)),
            compressedSize: Int(u32le(region, p + 0x10)),
            deviceID: Int(u16le(region, p + 0x14)),
            vendorID: Int(u16le(region, p + 0x16)),
            moduleHash: hexUpper(region, p + 0x18, hashLen))
    }

    // MARK: - Row-bearing `.met` headers + `_Mod` sub-tables

    /// `CSE_Ext_04` Shared Library Attributes (0x1C) — a header-only block; it
    /// has no `_Mod` rows, so the whole block is the header.
    private static func decodeSharedLibrary(_ region: Data, at p: Int)
        -> SharedLibraryExtension? {
        guard p + 0x1C <= region.count else { return nil }
        return SharedLibraryExtension(
            contextSize: Int(u32le(region, p + 0x08)),
            totalAllocatedVirtSpace: Int(u32le(region, p + 0x0C)),
            codeBaseAddress: Int(u32le(region, p + 0x10)),
            tlsSize: Int(u32le(region, p + 0x14)),
            reserved: Int(u32le(region, p + 0x18)))
    }

    /// `CSE_Ext_05` Process Attributes (0x44 header). Flags u32 @0x08 holds the
    /// seven 1-bit capabilities of `CSE_Ext_05_Flags` (FaultTolerant bit0 …
    /// PublicNotifyReceiver bit6 — little-endian ctypes bit order); the rest of
    /// the header mirrors the process scalars. `rows` are the trailing
    /// `CSE_Ext_05_Mod` PROCESS_GROUP_ID entries (u16, stride 0x02) filling
    /// `Size − 0x44`.
    private static func decodeProcessAttributes(_ region: Data, at p: Int, size: Int)
        -> ProcessAttributesExtension? {
        let headerLen = 0x44
        guard p + headerLen <= region.count, size >= headerLen else { return nil }
        let flags = u32le(region, p + 0x08)
        var rows: [ProcessGroupIDRow] = []
        let rowCount = (size - headerLen) / 2
        for r in 0..<rowCount {
            rows.append(ProcessGroupIDRow(
                id: r,
                groupID: Int(u16le(region, p + headerLen + r * 2))))
        }
        func bit(_ b: Int) -> Bool { (flags >> b) & 1 != 0 }
        return ProcessAttributesExtension(
            faultTolerant: bit(0),
            permanentProcess: bit(1),
            singleInstance: bit(2),
            trustedSendReceiveSender: bit(3),
            trustedNotifySender: bit(4),
            publicSendReceiveReceiver: bit(5),
            publicNotifyReceiver: bit(6),
            flagsReserved: Int(flags >> 7),
            mainThreadID: Int(u32le(region, p + 0x0C)),
            codeBaseAddress: Int(u32le(region, p + 0x10)),
            codeSizeUncompressed: Int(u32le(region, p + 0x14)),
            cm0HeapSize: Int(u32le(region, p + 0x18)),
            bssSize: Int(u32le(region, p + 0x1C)),
            defaultHeapSize: Int(u32le(region, p + 0x20)),
            mainThreadEntry: Int(u32le(region, p + 0x24)),
            allowedSysCalls: (0..<3).map { Int(u32le(region, p + 0x28 + $0 * 4)) },
            userID: Int(u16le(region, p + 0x34)),
            rows: rows)
    }

    /// `CSE_Ext_06` Thread Attributes (0x08 header). `rows` are the
    /// `CSE_Ext_06_Mod` thread entries (stride 0x10) filling `Size − 0x08`.
    private static func decodeThreadAttributes(_ region: Data, at p: Int, size: Int)
        -> ThreadAttributesExtension? {
        let headerLen = 0x08, stride = 0x10
        guard p + headerLen <= region.count, size >= headerLen else { return nil }
        var rows: [ThreadRow] = []
        let rowCount = (size - headerLen) / stride
        for r in 0..<rowCount {
            let b = p + headerLen + r * stride
            rows.append(ThreadRow(
                id: r,
                stackSize: Int(u32le(region, b + 0x00)),
                flags: Int(u32le(region, b + 0x04)),
                schedulingPolicy: Int(u32le(region, b + 0x08)),
                reserved: Int(u32le(region, b + 0x0C))))
        }
        return ThreadAttributesExtension(rows: rows)
    }

    /// `CSE_Ext_07` Device Types (0x08 header). `rows` are the `CSE_Ext_07_Mod`
    /// device entries (DeviceID + Reserved, stride 0x08). The 4-byte `_Mod_R2`
    /// row is GSC/OROM-100 only — none of this engine's families revise 0x07.
    private static func decodeDeviceTypes(_ region: Data, at p: Int, size: Int)
        -> DeviceTypesExtension? {
        let headerLen = 0x08, stride = 0x08
        guard p + headerLen <= region.count, size >= headerLen else { return nil }
        var rows: [DeviceRow] = []
        let rowCount = (size - headerLen) / stride
        for r in 0..<rowCount {
            let b = p + headerLen + r * stride
            rows.append(DeviceRow(
                id: r,
                deviceID: Int(u32le(region, b + 0x00)),
                reserved: Int(u32le(region, b + 0x04))))
        }
        return DeviceTypesExtension(rows: rows)
    }

    /// `CSE_Ext_08` MMIO Ranges (0x08 header). `rows` are the `CSE_Ext_08_Mod`
    /// range entries (BaseAddress/SizeLimit/Flags MmioAccess, stride 0x0C).
    private static func decodeMmioRanges(_ region: Data, at p: Int, size: Int)
        -> MmioRangesExtension? {
        let headerLen = 0x08, stride = 0x0C
        guard p + headerLen <= region.count, size >= headerLen else { return nil }
        var rows: [MmioRangeRow] = []
        let rowCount = (size - headerLen) / stride
        for r in 0..<rowCount {
            let b = p + headerLen + r * stride
            rows.append(MmioRangeRow(
                id: r,
                baseAddress: Int(u32le(region, b + 0x00)),
                sizeLimit: Int(u32le(region, b + 0x04)),
                flags: Int(u32le(region, b + 0x08))))
        }
        return MmioRangesExtension(rows: rows)
    }

    /// `CSE_Ext_09` Special File Producer (0x0C header). Header carries
    /// MajorNumber u16 + Flags u16 @0x0A; `rows` are the `CSE_Ext_09_Mod`
    /// SPECIAL_FILE_DEF entries (stride 0x18) with their NUL-padded char[12]
    /// `Name`.
    private static func decodeSpecialFiles(_ region: Data, at p: Int, size: Int)
        -> SpecialFilesExtension? {
        let headerLen = 0x0C, stride = 0x18
        guard p + headerLen <= region.count, size >= headerLen else { return nil }
        var rows: [SpecialFileRow] = []
        let rowCount = (size - headerLen) / stride
        for r in 0..<rowCount {
            let b = p + headerLen + r * stride
            rows.append(SpecialFileRow(
                id: r,
                name: asciiName(region, b + 0x00, 12),
                accessMode: Int(u16le(region, b + 0x0C)),
                userID: Int(u16le(region, b + 0x0E)),
                groupID: Int(u16le(region, b + 0x10)),
                minorNumber: Int(region[b + 0x12]),
                reserved0: Int(region[b + 0x13]),
                reserved1: Int(u32le(region, b + 0x14))))
        }
        return SpecialFilesExtension(
            majorNumber: Int(u16le(region, p + 0x08)),
            flags: Int(u16le(region, p + 0x0A)),
            rows: rows)
    }

    /// `CSE_Ext_0B` Locked Ranges (0x08 header). `rows` are the
    /// `CSE_Ext_0B_Mod` locked-range entries (RangeBase/RangeSize, stride 0x08).
    private static func decodeLockedRanges(_ region: Data, at p: Int, size: Int)
        -> LockedRangesExtension? {
        let headerLen = 0x08, stride = 0x08
        guard p + headerLen <= region.count, size >= headerLen else { return nil }
        var rows: [LockedRangeRow] = []
        let rowCount = (size - headerLen) / stride
        for r in 0..<rowCount {
            let b = p + headerLen + r * stride
            rows.append(LockedRangeRow(
                id: r,
                rangeBase: Int(u32le(region, b + 0x00)),
                rangeSize: Int(u32le(region, b + 0x04))))
        }
        return LockedRangesExtension(rows: rows)
    }

    /// `CSE_Ext_0D` User Information (0x08 header). The `_Mod` row layout is
    /// family-dependent (mirrors `ext_tag_rev_mod_csme12/15 = {0xD:'_R2'}`,
    /// MEA.py 10494/10501): CSME 12/15 rows are `CSE_Ext_0D_Mod_R2` (stride
    /// 0x10, quotas only); the base family uses `CSE_Ext_0D_Mod` (stride 0x34,
    /// with a char[36] `WorkingDir` @0x10).
    private static func decodeUserInfo(_ region: Data, at p: Int, size: Int,
                                       family: Family)
        -> UserInfoExtension? {
        let r2 = family == .csme12 || family == .csme15
        let headerLen = 0x08, stride = r2 ? 0x10 : 0x34
        guard p + headerLen <= region.count, size >= headerLen else { return nil }
        var rows: [UserInfoRow] = []
        let rowCount = (size - headerLen) / stride
        for r in 0..<rowCount {
            let b = p + headerLen + r * stride
            rows.append(UserInfoRow(
                id: r,
                userID: Int(u16le(region, b + 0x00)),
                reserved: Int(u16le(region, b + 0x02)),
                nvStorageQuota: Int(u32le(region, b + 0x04)),
                ramStorageQuota: Int(u32le(region, b + 0x08)),
                wopQuota: Int(u32le(region, b + 0x0C)),
                workingDirectory: r2 ? nil : asciiName(region, b + 0x10, 36)))
        }
        return UserInfoExtension(rows: rows)
    }

    // MARK: - Byte readers

    /// 4-char NUL-padded ASCII name (e.g. "FTPR"), like `CPD_Entry.Name`.
    private static func ascii4(_ data: Data, _ p: Int) -> String {
        guard p + 4 <= data.count else { return "" }
        let bytes = data.subdata(in: (data.startIndex + p)..<(data.startIndex + p + 4))
        return String(data: bytes, encoding: .ascii)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
    }

    /// `len`-char NUL-padded ASCII name (e.g. the char[12] special-file `Name`,
    /// the char[36] user `WorkingDir`). Trailing NULs and the pad are dropped.
    private static func asciiName(_ data: Data, _ p: Int, _ len: Int) -> String {
        guard p + len <= data.count else { return "" }
        let bytes = data.subdata(in: (data.startIndex + p)..<(data.startIndex + p + len))
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
