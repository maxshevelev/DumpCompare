import Foundation

/// The UI-facing result of an ME/engine analysis — the single typed, `Codable`
/// tree DumpCompare renders after the module analyses a region. This is the
/// "structured output for UI" of the `sync-mea-engine` skill; its contract
/// (`Skills/sync-mea-engine/reference/result-model.md`) must not be broken:
///
/// - **Codable and additive-only.** The UI binds by field name. A sync may add
///   fields, enum cases or nested structs; it must never rename, retype or
///   remove an existing field.
/// - **Enums are `String`-raw** so serialized values stay stable across Swift
///   versions.
/// - **No DB-derived text lives here.** The model carries parsed facts (version
///   numbers, dates, sizes, booleans). Human labels ("Management Engine",
///   "Production", the firmware's display name) belong to the DB layer and the
///   UI, not to this file.
public struct FirmwareAnalysis: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(family.rawValue)-\(variant)-\(version.text)" }

    public var family: FirmwareFamily
    public var variant: String
    public var version: Version
    public var securityVersion: String?
    public var release: ReleaseType
    public var type: FirmwareType
    public var sku: String
    public var platform: String
    /// PMC chipset stepping letter ("B"), derived like upstream `pmc_anl`.
    /// nil for families that derive none (PCHC/PHY) or when it is unknown.
    public var chipsetStepping: String? = nil
    public var manufactureDate: Date?
    public var sizeBytes: Int
    public var databaseName: String?          // unique name when found in MEA.dat
    public var rsaSignatureValid: Bool?       // nil when not checkable
    public var checksums: Checksums?
    public var regions: [FPTRegion]           // FPT / partition table if present
    public var manifest: ManifestSummary?     // $MN2/$MAN facts + security fields
    public var codePartition: CodePartition?  // $CPD: entries, extensions, modules
    public var mfsVolume: MFSVolume?          // MFS volume facts, when an FPT "MFS" region decodes
    public var mfsBackup: MFSBackup? = nil    // MFS *backup*-state area decode (FPT "MFSB",
                                              // or a main "MFS" region in backup state)
    public var cseLayoutTable: CSELayoutTable? = nil  // IFWI 1.6/1.7 CSE Layout Table inventory
    public var bootPartitions: [BPDT]? = nil          // BPDT of each non-empty CSE-LT Boot partition
    public var mmeDirectory: MMEModuleDirectory? = nil  // pre-CSE R0 $MME inventory (ME 2–10)
    public var gscInfo: GSCInfo? = nil                  // GSC "INFO" $FPT partition decode (GSC_Info_FWI/IUP)
    public var oromImages: [GSCOROMImage]? = nil        // GSC OROM/PCIR images decoded by orom_pat (row 30/80)
    public var rbePmMetadata: [RBE_PMMetadata]? = nil  // FTPR `pm` / RBEP `rbe` module "Metadata" table (rows 54/55)
    public var efsVolume: EFSVolume? = nil            // EFS paged-volume structural facts (FPT "EFS" region)
    public var oemConfiguration: OEMConfiguration? = nil  // FITC "OEM Configuration" facts (FPT "FITC" region)
    /// ARB Security Version Number (row 9): hoisted from the operational chain's
    /// CSE_Ext_0F `SignedPackageExtension.arbSvn` (last such tag seen), nil when
    /// the chain carries none.
    public var arbSvn: Int? = nil
    /// Version Control Number (row 10): CSE_Ext_03 `vcn` preferred, CSE_Ext_0F
    /// fallback, then a pre-CSE R0 manifest's +0x34 (which already surfaces as
    /// `ManifestSummary.vcn`).
    public var vcn: Int? = nil
    /// File System State (row 17, upstream `mfs_state`): Initialized / Configured
    /// when a legacy-MFS file-index set says so, else Unconfigured. nil when no
    /// MFS region was found at all.
    public var mfsState: MFSState? = nil
    public var issues: [Issue]
}

/// Firmware family, as identified from the manifest RSA public key. `.unknown`
/// is the honest answer of the current bootstrap spine: family joins once the
/// `get_variant` identification step is ported (see `reference/upstream-map.md`,
/// "Identification & database layer").
public enum FirmwareFamily: String, Codable, Sendable, CaseIterable {
    case me, csme, txe, cstxe, sps, cssps, gsc, pmc, pchc, phy, orom, unknown
}

public struct Version: Codable, Sendable, Equatable {
    public var major: Int
    public var minor: Int
    public var hotfix: Int
    public var build: Int
    public var meMajor: Int?   // MEU fields, when present
    public var meMinor: Int?
    public var meHotfix: Int?
    public var meBuild: Int?

    public var text: String { "\(major).\(minor).\(hotfix).\(build)" }
}

public enum ReleaseType: String, Codable, Sendable {
    case production, preProduction, romBypass, unknown
}

public enum FirmwareType: String, Codable, Sendable {
    case region, extracted, update, unknown
}

/// File System State (upstream `mfs_state`, `MEA.py` 7489–7493): `.initialized`
/// once a reserved/indexed file set appears (any of indices 0–5/8), `.configured`
/// when the configuration/home files (7/9) do, `.unconfigured` as the default.
/// `.error` is reserved for a decode upstream would treat as failed — never
/// produced by the current decoders, kept for enum completeness.
public enum MFSState: String, Codable, Sendable {
    case unconfigured, initialized, configured, error
}

/// One Flash Partition Table row (upstream `FPT_Entry`, `MEA.py` ~0x20 layout).
/// `offset` is relative to the start of the region handed to `analyze`; a caller
/// that analysed a slice of a larger file adds its own `baseOffset`.
public struct FPTRegion: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String        // e.g. "FTUE", "rbe", "FTPR"; "" when erased
    public var offset: Int
    public var size: Int
    public var flags: UInt32
}

/// Manifest structural revision (upstream `MN2_Manifest_R0`/`_R1`/`_R2`).
/// `.unknown` is not produced by the parser (decode rejects what it cannot
/// classify) — it exists so the additive model can represent future revisions.
public enum ManifestFormat: String, Codable, Sendable, CaseIterable {
    case r0, r1, r2, unknown
}

/// Facts parsed from the *operational* `$MN2`/`$MAN` manifest — the copy the
/// engine identified against the database (see `ManifestSelection`). `offset` is
/// the absolute position of the manifest struct base (region `baseOffset` +
/// region-relative base), matching `FPTRegion.offset` semantics. `keyHash` /
/// `signatureHash` are the uppercase SHA-256 hex digests that key MEA.dat rows.
public struct ManifestSummary: Codable, Sendable, Equatable {
    public var offset: Int
    public var tag: String                 // "$MN2" or "$MAN"
    public var format: ManifestFormat
    public var major: Int
    public var minor: Int
    public var hotfix: Int
    public var build: Int
    public var svn: Int
    public var day: Int
    public var month: Int
    public var year: Int
    public var keyHash: String?            // SHA-256 of the RSA public key
    public var signatureHash: String?      // SHA-256 of the RSA signature
    /// Version Control Number (`VCN` u32 @ +0x34) of a pre-CSE R0 manifest
    /// (ME 7–10, TXE); nil for R1/R2, whose +0x34 is inside the MEU block.
    public var vcn: Int?
    /// Production Ready (row 11, upstream `pvbit`): manifest Flags bit 0 for an
    /// R1/R2 operational manifest; nil for pre-CSE R0, where upstream reads it
    /// from a different probe (no oracle here).
    public var productionReady: Bool?

    public init(offset: Int, tag: String, format: ManifestFormat,
                major: Int, minor: Int, hotfix: Int, build: Int, svn: Int,
                day: Int, month: Int, year: Int,
                keyHash: String?, signatureHash: String?,
                vcn: Int? = nil, productionReady: Bool? = nil) {
        self.offset = offset
        self.tag = tag
        self.format = format
        self.major = major
        self.minor = minor
        self.hotfix = hotfix
        self.build = build
        self.svn = svn
        self.day = day
        self.month = month
        self.year = year
        self.keyHash = keyHash
        self.signatureHash = signatureHash
        self.vcn = vcn
        self.productionReady = productionReady
    }
}

/// One row of a `$CPD` module directory (upstream `CPD_Entry`, 0x18). `offset`
/// is the 25-bit `OffsetCPD` — the module's position *relative to the `$CPD`
/// base* (the first module of a boot partition is usually the `$MN2`/`$MAN`
/// manifest). `size` is the uncompressed module size. `extensions` is the
/// module's own CSE extension chain when its body is a metadata carrier: a
/// `.met` companion's body *is* a chain (its leading `0x0A` block carries the
/// owner module's compression/encryption/sizes/hash), and the manifest module's
/// `.man` row repeats `CodePartition.extensions`.
public struct CPDModule: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String      // NUL-stripped 12-byte Name, e.g. "$MN2", "kernel.met"
    public var offset: Int
    public var isHuffman: Bool   // OffsetAttrib bit 25
    public var size: Int
    public var extensions: [CPDExtension]?

    public init(id: Int, name: String, offset: Int, isHuffman: Bool, size: Int,
                extensions: [CPDExtension]? = nil) {
        self.id = id
        self.name = name
        self.offset = offset
        self.isHuffman = isHuffman
        self.size = size
        self.extensions = extensions
    }
}

/// Code Partition Directory facts for the *operational* partition — the one
/// whose `$MN2`/`$MAN` the engine identified (upstream `CPD_Header_R1`/`_R2` +
/// its `CPD_Entry` module list). Header fields are set from the `$CPD` header;
/// `modules` is the decoded module directory. `extensions` is the CSE extension
/// chain (`CSE_Ext_*`) of the manifest module — fixed header + scalars only,
/// `_Mod` row sub-tables and `.met` metadata are deferred. Nil when no manifest
/// module (whose content base holds the chosen manifest) could be located.
public struct CodePartition: Codable, Sendable, Equatable {
    public var name: String            // PartitionName, e.g. "FTPR", "RBEP"
    public var offset: Int             // absolute $CPD header offset (region baseOffset + CPD base)
    public var headerVersion: Int      // 1 = R1, 2 = R2
    public var headerLength: Int       // 0x10 (R1) / 0x14 (R2)
    public var entryCount: Int         // declared NumModules (may exceed modules.count when the buffer truncates)
    public var checksumValid: Bool?    // R1 Checksum-8 / R2 CRC-32 result; nil only when the directory is truncated
    public var modules: [CPDModule]
    public var extensions: [CPDExtension]?

    public init(name: String, offset: Int, headerVersion: Int, headerLength: Int,
                entryCount: Int, checksumValid: Bool?, modules: [CPDModule],
                extensions: [CPDExtension]? = nil) {
        self.name = name
        self.offset = offset
        self.headerVersion = headerVersion
        self.headerLength = headerLength
        self.entryCount = entryCount
        self.checksumValid = checksumValid
        self.modules = modules
        self.extensions = extensions
    }
}

/// One CSE extension block of the operational partition's manifest module
/// (upstream `CSE_Ext_XX`, walked by `ext_anl`). The envelope — `tag`, `size`
/// and `offset` — is present on every block; exactly one payload group is set
/// for the tags decoded in this stage, and none for `0x01` Init Script / unknown
/// tags (which surface as an opaque envelope). `offset` is the absolute position
/// of the block (region `baseOffset` + region-relative), matching
/// `CodePartition.offset`. `id` is the chain index (blocks in file order).
public struct CPDExtension: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var tag: Int
    public var size: Int
    public var offset: Int
    public var systemInfo: SystemInfoExtension?          // tag 0x00
    public var partitionInfo: PartitionInfoExtension?    // tags 0x03 / 0x16
    public var signedPackage: SignedPackageExtension?    // tag 0x0F
    public var clientSystemInfo: ClientSystemInfoExtension?  // tag 0x0C
    public var featurePermissions: FeaturePermissionsExtension?  // tag 0x02
    public var moduleAttributes: ModuleAttributesExtension?  // tag 0x0A (universal on .met chains)
    public var sharedLibrary: SharedLibraryExtension?            // tag 0x04 (header-only)
    public var processAttributes: ProcessAttributesExtension?    // tag 0x05
    public var threadAttributes: ThreadAttributesExtension?      // tag 0x06
    public var deviceTypes: DeviceTypesExtension?                // tag 0x07
    public var mmioRanges: MmioRangesExtension?                  // tag 0x08
    public var specialFiles: SpecialFilesExtension?              // tag 0x09
    public var lockedRanges: LockedRangesExtension?              // tag 0x0B
    public var userInfo: UserInfoExtension?                      // tag 0x0D

    public init(id: Int, tag: Int, size: Int, offset: Int,
                systemInfo: SystemInfoExtension? = nil,
                partitionInfo: PartitionInfoExtension? = nil,
                signedPackage: SignedPackageExtension? = nil,
                clientSystemInfo: ClientSystemInfoExtension? = nil,
                featurePermissions: FeaturePermissionsExtension? = nil,
                moduleAttributes: ModuleAttributesExtension? = nil,
                sharedLibrary: SharedLibraryExtension? = nil,
                processAttributes: ProcessAttributesExtension? = nil,
                threadAttributes: ThreadAttributesExtension? = nil,
                deviceTypes: DeviceTypesExtension? = nil,
                mmioRanges: MmioRangesExtension? = nil,
                specialFiles: SpecialFilesExtension? = nil,
                lockedRanges: LockedRangesExtension? = nil,
                userInfo: UserInfoExtension? = nil) {
        self.id = id
        self.tag = tag
        self.size = size
        self.offset = offset
        self.systemInfo = systemInfo
        self.partitionInfo = partitionInfo
        self.signedPackage = signedPackage
        self.clientSystemInfo = clientSystemInfo
        self.featurePermissions = featurePermissions
        self.moduleAttributes = moduleAttributes
        self.sharedLibrary = sharedLibrary
        self.processAttributes = processAttributes
        self.threadAttributes = threadAttributes
        self.deviceTypes = deviceTypes
        self.mmioRanges = mmioRanges
        self.specialFiles = specialFiles
        self.lockedRanges = lockedRanges
        self.userInfo = userInfo
    }
}

/// Tag `0x00` System Information (`CSE_Ext_00`). `imageHash` is the stored
/// "Intel Config" hash (SHA-256 in R1, SHA-384 in R2) as uppercase hex.
public struct SystemInfoExtension: Codable, Sendable, Equatable {
    public var minUMASize: Int
    public var chipsetVersion: Int
    public var pageableUMASize: Int
    public var imageHash: String

    public init(minUMASize: Int, chipsetVersion: Int, pageableUMASize: Int,
                imageHash: String) {
        self.minUMASize = minUMASize
        self.chipsetVersion = chipsetVersion
        self.pageableUMASize = pageableUMASize
        self.imageHash = imageHash
    }
}

/// Tags `0x03`/`0x16` Partition Information (`CSE_Ext_03`/`CSE_Ext_16`). 0x03
/// additionally carries `vcn`; `hash` is the stored partition hash over
/// `$CPD - $MN2 + Data` (uppercase hex, SHA-256 R1 / SHA-384 R2).
public struct PartitionInfoExtension: Codable, Sendable, Equatable {
    public var partitionName: String
    public var partitionSize: Int
    public var vcn: Int?               // 0x03 only; 0x16 has no VCN
    public var versionMajor: Int       // PartitionVerMaj
    public var versionMinor: Int       // PartitionVerMin
    public var dataFormatMajor: Int
    public var dataFormatMinor: Int
    public var instanceID: Int
    public var flags: Int
    public var hash: String

    public init(partitionName: String, partitionSize: Int, vcn: Int?,
                versionMajor: Int, versionMinor: Int, dataFormatMajor: Int,
                dataFormatMinor: Int, instanceID: Int, flags: Int, hash: String) {
        self.partitionName = partitionName
        self.partitionSize = partitionSize
        self.vcn = vcn
        self.versionMajor = versionMajor
        self.versionMinor = versionMinor
        self.dataFormatMajor = dataFormatMajor
        self.dataFormatMinor = dataFormatMinor
        self.instanceID = instanceID
        self.flags = flags
        self.hash = hash
    }
}

/// Tag `0x0F` Signed Package Information (`CSE_Ext_0F`). `usageBitmap` is the
/// 16-byte KeyManifestHashUsages bitmap as uppercase hex. `fwType`/`fwSku`/
/// `nvmCompatibility` are the raw 3/3/2-bit fields present only in the `_R2`
/// header. `partitionName`/`vcn` prefer 0x03 when both appear.
public struct SignedPackageExtension: Codable, Sendable, Equatable {
    public var partitionName: String
    public var vcn: Int
    public var usageBitmap: String
    public var arbSvn: Int
    public var fwType: Int?            // _R2 only
    public var fwSku: Int?             // _R2 only
    public var nvmCompatibility: Int?  // _R2 only

    public init(partitionName: String, vcn: Int, usageBitmap: String,
                arbSvn: Int, fwType: Int?, fwSku: Int?, nvmCompatibility: Int?) {
        self.partitionName = partitionName
        self.vcn = vcn
        self.usageBitmap = usageBitmap
        self.arbSvn = arbSvn
        self.fwType = fwType
        self.fwSku = fwSku
        self.nvmCompatibility = nvmCompatibility
    }
}

/// Tag `0x0C` Client System Information (`CSE_Ext_0C`). `skuCaps` is the
/// `FWSKUCaps` capabilities bitmask (raw; label mapping is a display-layer
/// concern). The remaining fields are the `FWSKUAttrib` bitfields as raw ints
/// (no CSESize*0.5MB scaling, no SKU/H/LP label tables).
public struct ClientSystemInfoExtension: Codable, Sendable, Equatable {
    public var skuCaps: Int
    public var cseSize: Int            // 4 bits
    public var skuType: Int            // 3 bits
    public var workstation: Bool
    public var m3: Bool
    public var m0: Bool
    public var skuPlatform: Int        // 2 bits
    public var siClass: Int            // 4 bits

    public init(skuCaps: Int, cseSize: Int, skuType: Int, workstation: Bool,
                m3: Bool, m0: Bool, skuPlatform: Int, siClass: Int) {
        self.skuCaps = skuCaps
        self.cseSize = cseSize
        self.skuType = skuType
        self.workstation = workstation
        self.m3 = m3
        self.m0 = m0
        self.skuPlatform = skuPlatform
        self.siClass = siClass
    }
}

/// Tag `0x02` Feature Permissions (`CSE_Ext_02`). Only the `ModuleCount` scalar
/// is decoded; the per-feature `_02_Mod` rows are deferred.
public struct FeaturePermissionsExtension: Codable, Sendable, Equatable {
    public var moduleCount: Int

    public init(moduleCount: Int) {
        self.moduleCount = moduleCount
    }
}

/// Tag `0x0A` Module Attributes (`CSE_Ext_0A`) — the first block of a `.met`
/// chain, describing the module that `.met` accompanies. Raw scalars. The
/// row-based tags `0x04`–`0x0D` each get their own payload (`sharedLibrary` …
/// `userInfo`); `0x01` Init Script and unknown tags surface as an opaque
/// envelope only. `moduleHash` is the owner body's stored hash as uppercase
/// hex — SHA-256 (64 chars) in R1, SHA-384 (96 chars) in R2.
public struct ModuleAttributesExtension: Codable, Sendable, Equatable {
    public var compression: Int      // 0 None, 1 Huffman, 2 LZMA (R1 & R2)
    public var encryption: Int       // R1: 0 None, 1 AES-CBC; R2: 0 None, 1 AES-ECB, 2 AES-CTR
    public var uncompressedSize: Int
    public var compressedSize: Int   // LZMA & Huffman, without EOM alignment
    public var deviceID: Int
    public var vendorID: Int         // 0x8086 for Intel
    public var moduleHash: String

    public init(compression: Int, encryption: Int, uncompressedSize: Int,
                compressedSize: Int, deviceID: Int, vendorID: Int, moduleHash: String) {
        self.compression = compression
        self.encryption = encryption
        self.uncompressedSize = uncompressedSize
        self.compressedSize = compressedSize
        self.deviceID = deviceID
        self.vendorID = vendorID
        self.moduleHash = moduleHash
    }
}

/// Tag `0x04` Shared Library Attributes (`CSE_Ext_04`) — a header-only block
/// (0x1C): it has no `_Mod` rows. Raw scalars, exactly as upstream prints them.
public struct SharedLibraryExtension: Codable, Sendable, Equatable {
    public var contextSize: Int              // u32 @ 0x08
    public var totalAllocatedVirtSpace: Int  // u32 @ 0x0C
    public var codeBaseAddress: Int          // u32 @ 0x10
    public var tlsSize: Int                  // u32 @ 0x14
    public var reserved: Int                 // u32 @ 0x18

    public init(contextSize: Int, totalAllocatedVirtSpace: Int,
                codeBaseAddress: Int, tlsSize: Int, reserved: Int) {
        self.contextSize = contextSize
        self.totalAllocatedVirtSpace = totalAllocatedVirtSpace
        self.codeBaseAddress = codeBaseAddress
        self.tlsSize = tlsSize
        self.reserved = reserved
    }
}

/// Tag `0x05` Process Attributes (`CSE_Ext_05`, 0x44 header) — the block that
/// opens almost every `.met` chain and describes the process the module belongs
/// to. `Flags` u32 @0x08 is split into the seven 1-bit capabilities of
/// `CSE_Ext_05_Flags` (FaultTolerant … PublicNotifyReceiver, little-endian
/// bit0..6) plus the 25-bit reserved word; the remaining fields are the raw
/// process scalars (`AllowedSysCalls` kept as three raw u32). `rows` are the
/// trailing `CSE_Ext_05_Mod` PROCESS_GROUP_ID entries (u16 each).
public struct ProcessAttributesExtension: Codable, Sendable, Equatable {
    public var faultTolerant: Bool                // Flags bit 0
    public var permanentProcess: Bool             // bit 1
    public var singleInstance: Bool               // bit 2
    public var trustedSendReceiveSender: Bool     // bit 3
    public var trustedNotifySender: Bool          // bit 4
    public var publicSendReceiveReceiver: Bool    // bit 5
    public var publicNotifyReceiver: Bool         // bit 6
    public var flagsReserved: Int                 // bits 7–31
    public var mainThreadID: Int                  // u32 @ 0x0C
    public var codeBaseAddress: Int               // u32 @ 0x10
    public var codeSizeUncompressed: Int          // u32 @ 0x14
    public var cm0HeapSize: Int                   // u32 @ 0x18
    public var bssSize: Int                       // u32 @ 0x1C
    public var defaultHeapSize: Int               // u32 @ 0x20
    public var mainThreadEntry: Int               // u32 @ 0x24
    public var allowedSysCalls: [Int]             // AllowedSysCalls u32[3] @ 0x28
    public var userID: Int                        // u16 @ 0x34
    public var rows: [ProcessGroupIDRow]

    public init(faultTolerant: Bool, permanentProcess: Bool,
                singleInstance: Bool, trustedSendReceiveSender: Bool,
                trustedNotifySender: Bool, publicSendReceiveReceiver: Bool,
                publicNotifyReceiver: Bool, flagsReserved: Int,
                mainThreadID: Int, codeBaseAddress: Int,
                codeSizeUncompressed: Int, cm0HeapSize: Int, bssSize: Int,
                defaultHeapSize: Int, mainThreadEntry: Int,
                allowedSysCalls: [Int], userID: Int, rows: [ProcessGroupIDRow]) {
        self.faultTolerant = faultTolerant
        self.permanentProcess = permanentProcess
        self.singleInstance = singleInstance
        self.trustedSendReceiveSender = trustedSendReceiveSender
        self.trustedNotifySender = trustedNotifySender
        self.publicSendReceiveReceiver = publicSendReceiveReceiver
        self.publicNotifyReceiver = publicNotifyReceiver
        self.flagsReserved = flagsReserved
        self.mainThreadID = mainThreadID
        self.codeBaseAddress = codeBaseAddress
        self.codeSizeUncompressed = codeSizeUncompressed
        self.cm0HeapSize = cm0HeapSize
        self.bssSize = bssSize
        self.defaultHeapSize = defaultHeapSize
        self.mainThreadEntry = mainThreadEntry
        self.allowedSysCalls = allowedSysCalls
        self.userID = userID
        self.rows = rows
    }
}

/// One `CSE_Ext_05_Mod` PROCESS_GROUP_ID row (u16, stride 0x02).
public struct ProcessGroupIDRow: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var groupID: Int

    public init(id: Int, groupID: Int) {
        self.id = id
        self.groupID = groupID
    }
}

/// Tag `0x06` Thread Attributes (`CSE_Ext_06`, 0x08 header) — one block per `.met`
/// whose `rows` (each `CSE_Ext_06_Mod`, stride 0x10) are the module's threads.
/// `flags`/`schedulingPolicy` stay raw (the FlagsType bit0 / PolicyFixedPriority
/// bit0 label mapping is a display concern).
public struct ThreadAttributesExtension: Codable, Sendable, Equatable {
    public var rows: [ThreadRow]

    public init(rows: [ThreadRow]) {
        self.rows = rows
    }
}

/// One `CSE_Ext_06_Mod` thread row.
public struct ThreadRow: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var stackSize: Int            // u32 @ 0x00
    public var flags: Int                // u32 @ 0x04
    public var schedulingPolicy: Int     // SchedulPolicy u32 @ 0x08
    public var reserved: Int             // u32 @ 0x0C

    public init(id: Int, stackSize: Int, flags: Int, schedulingPolicy: Int,
                reserved: Int) {
        self.id = id
        self.stackSize = stackSize
        self.flags = flags
        self.schedulingPolicy = schedulingPolicy
        self.reserved = reserved
    }
}

/// Tag `0x07` Device Types (`CSE_Ext_07`, 0x08 header) — the module's devices,
/// one `CSE_Ext_07_Mod` row (DeviceID + Reserved, stride 0x08) per device. (The
/// 4-byte `_Mod_R2` row is GSC/OROM-100 only — outside this engine slice.)
public struct DeviceTypesExtension: Codable, Sendable, Equatable {
    public var rows: [DeviceRow]

    public init(rows: [DeviceRow]) {
        self.rows = rows
    }
}

/// One `CSE_Ext_07_Mod` device row.
public struct DeviceRow: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var deviceID: Int            // u32 @ 0x00
    public var reserved: Int            // u32 @ 0x04

    public init(id: Int, deviceID: Int, reserved: Int) {
        self.id = id
        self.deviceID = deviceID
        self.reserved = reserved
    }
}

/// Tag `0x08` MMIO Ranges (`CSE_Ext_08`, 0x08 header) — the module's mapped
/// MMIO regions, one `CSE_Ext_08_Mod` row (stride 0x0C) per range. `flags` is
/// the raw MmioAccess value (upstream prints 0 N/A / 1 RO / 2 WO / 3 RW).
public struct MmioRangesExtension: Codable, Sendable, Equatable {
    public var rows: [MmioRangeRow]

    public init(rows: [MmioRangeRow]) {
        self.rows = rows
    }
}

/// One `CSE_Ext_08_Mod` MMIO range row.
public struct MmioRangeRow: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var baseAddress: Int         // u32 @ 0x00
    public var sizeLimit: Int           // u32 @ 0x04
    public var flags: Int               // MmioAccess u32 @ 0x08

    public init(id: Int, baseAddress: Int, sizeLimit: Int, flags: Int) {
        self.id = id
        self.baseAddress = baseAddress
        self.sizeLimit = sizeLimit
        self.flags = flags
    }
}

/// Tag `0x09` Special File Producer (`CSE_Ext_09`, 0x0C header) — a char-device
/// producer whose `rows` (each `CSE_Ext_09_Mod` SPECIAL_FILE_DEF, stride 0x18)
/// name the special files it exposes. `name` is the NUL-padded char[12].
public struct SpecialFilesExtension: Codable, Sendable, Equatable {
    public var majorNumber: Int         // u16 @ 0x08
    public var flags: Int               // u16 @ 0x0A (unknown/unused)
    public var rows: [SpecialFileRow]

    public init(majorNumber: Int, flags: Int, rows: [SpecialFileRow]) {
        self.majorNumber = majorNumber
        self.flags = flags
        self.rows = rows
    }
}

/// One `CSE_Ext_09_Mod` special-file definition row.
public struct SpecialFileRow: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String             // char[12] @ 0x00
    public var accessMode: Int          // u16 @ 0x0C
    public var userID: Int              // u16 @ 0x0E
    public var groupID: Int             // u16 @ 0x10
    public var minorNumber: Int         // u8 @ 0x12
    public var reserved0: Int           // u8 @ 0x13
    public var reserved1: Int           // u32 @ 0x14

    public init(id: Int, name: String, accessMode: Int, userID: Int, groupID: Int,
                minorNumber: Int, reserved0: Int, reserved1: Int) {
        self.id = id
        self.name = name
        self.accessMode = accessMode
        self.userID = userID
        self.groupID = groupID
        self.minorNumber = minorNumber
        self.reserved0 = reserved0
        self.reserved1 = reserved1
    }
}

/// Tag `0x0B` Locked Ranges (`CSE_Ext_0B`, 0x08 header) — regions locked out of
/// access, one `CSE_Ext_0B_Mod` row (stride 0x08) per range.
public struct LockedRangesExtension: Codable, Sendable, Equatable {
    public var rows: [LockedRangeRow]

    public init(rows: [LockedRangeRow]) {
        self.rows = rows
    }
}

/// One `CSE_Ext_0B_Mod` locked-range row.
public struct LockedRangeRow: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var rangeBase: Int           // u32 @ 0x00
    public var rangeSize: Int           // u32 @ 0x04

    public init(id: Int, rangeBase: Int, rangeSize: Int) {
        self.id = id
        self.rangeBase = rangeBase
        self.rangeSize = rangeSize
    }
}

/// Tag `0x0D` User Information (`CSE_Ext_0D`, 0x08 header) — NV/RAM storage
/// quotas per user. Rows are `CSE_Ext_0D_Mod` (R1, stride 0x34, with a char[36]
/// `workingDirectory`) for the base family and `CSE_Ext_0D_Mod_R2` (stride 0x10,
/// no working directory) for CSME 12/15 — the engine's `_R2` families. Quota
/// fields are raw u32; `wopQuota` is the wear-out-prevention quota.
public struct UserInfoExtension: Codable, Sendable, Equatable {
    public var rows: [UserInfoRow]

    public init(rows: [UserInfoRow]) {
        self.rows = rows
    }
}

/// One `CSE_Ext_0D_Mod` / `_Mod_R2` user-information row. `workingDirectory` is
/// set only on the R1 row (which this engine's families never reach).
public struct UserInfoRow: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var userID: Int              // u16 @ 0x00
    public var reserved: Int            // u16 @ 0x02
    public var nvStorageQuota: Int      // u32 @ 0x04
    public var ramStorageQuota: Int     // u32 @ 0x08
    public var wopQuota: Int            // u32 @ 0x0C
    public var workingDirectory: String?  // char[36] @ 0x10 (R1 only)

    public init(id: Int, userID: Int, reserved: Int, nvStorageQuota: Int,
                ramStorageQuota: Int, wopQuota: Int, workingDirectory: String?) {
        self.id = id
        self.userID = userID
        self.reserved = reserved
        self.nvStorageQuota = nvStorageQuota
        self.ramStorageQuota = ramStorageQuota
        self.wopQuota = wopQuota
        self.workingDirectory = workingDirectory
    }
}

public struct Checksums: Codable, Sendable, Equatable {
    public var sha256: String?
    public var sha384: String?
    public var crc32: UInt32?
}

/// One row of the FTPR `pm` / RBEP `rbe` module "Metadata" table (upstream
/// `RBE_PM_Metadata` / `_R2` / `_R3` / `_R4`, MEA.py 5161–5295) — decoded by
/// `get_rbe_pm_met` (MEA.py 9711) from the module's decompressed body. Each row
/// opens with `Unknown0`, DEV_ID and VEN_ID 0x8086; `variant` picks the struct:
/// `r1`/`r3` carry the six extended fields (`bssSize` … `unknown2`), `r2`/`r4`
/// stop after `SizeComp`. `hash` is the row's stored digest (SHA-256 for r1/r2,
/// SHA-384 for r3/r4) as the raw LE-int uppercase hex exactly as upstream prints
/// it. Surfaced as `FirmwareAnalysis.rbePmMetadata`.
public struct RBE_PMMetadata: Codable, Sendable, Equatable, Identifiable {
    public var id: Int                 // row index within the table
    public var variant: RBE_PMVariant
    public var unknown0: Int           // u32 @ +0x00
    public var deviceID: Int           // u16 @ +0x04
    public var vendorID: Int           // u16 @ +0x06 = 0x8086
    public var sizeUncompressed: Int   // u32 @ +0x08
    public var sizeCompressed: Int     // u32 @ +0x0C
    public var bssSize: Int?                 // u32 @ +0x10 (r1/r3)
    public var codeSizeUncompressed: Int?    // u32 @ +0x14 (r1/r3)
    public var codeBaseAddress: Int?         // u32 @ +0x18 (r1/r3)
    public var mainThreadEntry: Int?         // u32 @ +0x1C (r1/r3)
    public var unknown1: Int?                // u32 @ +0x20 (r1/r3)
    public var unknown2: Int?                // u32 @ +0x24 (r1/r3)
    public var hash: String            // digest hex; uppercase LE-int (row +0x28 r1/r3, +0x10 r2/r4)

    public init(id: Int, variant: RBE_PMVariant, unknown0: Int, deviceID: Int,
                vendorID: Int, sizeUncompressed: Int, sizeCompressed: Int,
                bssSize: Int?, codeSizeUncompressed: Int?, codeBaseAddress: Int?,
                mainThreadEntry: Int?, unknown1: Int?, unknown2: Int?, hash: String) {
        self.id = id
        self.variant = variant
        self.unknown0 = unknown0
        self.deviceID = deviceID
        self.vendorID = vendorID
        self.sizeUncompressed = sizeUncompressed
        self.sizeCompressed = sizeCompressed
        self.bssSize = bssSize
        self.codeSizeUncompressed = codeSizeUncompressed
        self.codeBaseAddress = codeBaseAddress
        self.mainThreadEntry = mainThreadEntry
        self.unknown1 = unknown1
        self.unknown2 = unknown2
        self.hash = hash
    }
}

/// The `RBE_PM_Metadata` struct variant picked by the spaced-VEN_ID pattern
/// (`get_rbe_pm_met` tries R1 → R2 → R3 → R4): R1 (0x48, SHA-256, extended) —
/// gap 70, R2 (0x30, SHA-256, compact) — gap 46, R3 (0x58, SHA-384, extended) —
/// gap 86, R4 (0x40, SHA-384, compact) — gap 62. Names match the upstream struct.
public enum RBE_PMVariant: String, Codable, Sendable, CaseIterable {
    case r1, r2, r3, r4
}

/// MFS volume facts — the oldest CSE file system layout: a paged flash area
/// whose logical volume header (FTBL dictionary / platform ids, declared size,
/// file-record count) lives in the assembled System chunk 0, and whose present
/// low-level *files* are assembled by walking the FAT chunk chains (see
/// `MFSFile`). Decoded from an FPT region named "MFS", present on both real
/// dumps (CSME 12.0.3: FTBL dict 1/plat 0 → `usesFTBL` false, old-style; CSME
/// 15.0.30: dict 0x0A/plat 4 → `usesFTBL` true). `signatureValid` is false when
/// the region carries MFS pages but chunk 0 is not a valid volume header (a
/// corrupt or hot volume); nil `mfsVolume` on `FirmwareAnalysis` means no
/// decodable MFS region was found.
public struct MFSVolume: Codable, Sendable, Equatable {
    public var offset: Int        // absolute volume start (baseOffset + region offset)
    public var pageSize: Int
    public var pageCount: Int
    public var systemPageCount: Int
    public var dataPageCount: Int
    public var signatureValid: Bool     // assembled System chunk 0 signature == 0x724F6201
    public var volumeSize: Int          // declared (VolumeSize: system + data)
    public var computedVolumeSize: Int  // system+data chunk payload area actually present
    public var fileRecordCount: Int
    public var usedFileCount: Int
    public var ftblDictionary: Int
    public var ftblPlatform: Int
    public var ftblReserved: Int
    public var usesFTBL: Bool
    public var presentFileCount: Int    // used records that walked to real content
    public var fileBytes: Int           // total bytes across present files
    public var files: [MFSFile]         // present low-level files, by index
    public var configurations: [MFSConfiguration]  // decoded legacy (non-FTBL)
                                          // Intel/OEM Configuration record streams
    public var homeDirectory: MFSHomeDirectory?   // file-8 Home Directory decode
                                          // (upstream mfs_home_anl), when the volume
                                          // is a legacy layout whose files don't
                                          // start at 0 (identity-gated — get_vfs_start_0)
    public var reservedIntegrity: [MFSReservedFileIntegrity]  // trailing Integrity
                                          // headers of reserved low-level files
                                          // 1–5 (upstream 7901–7929)
    public var pchInit: MFSPCHInit?       // file-6 Intel Configuration > Chipset
                                          // Initialization Table decode (upstream
                                          // mphytbl/pch_init_anl), when the volume
                                          // carries mphytbl* records and the
                                          // identity-gated stepping rules apply

    public init(offset: Int, pageSize: Int, pageCount: Int,
                systemPageCount: Int, dataPageCount: Int,
                signatureValid: Bool, volumeSize: Int, computedVolumeSize: Int,
                fileRecordCount: Int, usedFileCount: Int,
                ftblDictionary: Int, ftblPlatform: Int, ftblReserved: Int,
                usesFTBL: Bool, presentFileCount: Int = 0, fileBytes: Int = 0,
                files: [MFSFile] = [], configurations: [MFSConfiguration] = [],
                homeDirectory: MFSHomeDirectory? = nil,
                reservedIntegrity: [MFSReservedFileIntegrity] = [],
                pchInit: MFSPCHInit? = nil) {
        self.offset = offset
        self.pageSize = pageSize
        self.pageCount = pageCount
        self.systemPageCount = systemPageCount
        self.dataPageCount = dataPageCount
        self.signatureValid = signatureValid
        self.volumeSize = volumeSize
        self.computedVolumeSize = computedVolumeSize
        self.fileRecordCount = fileRecordCount
        self.usedFileCount = usedFileCount
        self.ftblDictionary = ftblDictionary
        self.ftblPlatform = ftblPlatform
        self.ftblReserved = ftblReserved
        self.usesFTBL = usesFTBL
        self.presentFileCount = presentFileCount
        self.fileBytes = fileBytes
        self.files = files
        self.configurations = configurations
        self.homeDirectory = homeDirectory
        self.reservedIntegrity = reservedIntegrity
        self.pchInit = pchInit
    }
}

/// The decoded Chipset Initialization Tables carried by a legacy MFS volume's
/// Intel Configuration (low-level file 6, upstream `mphytbl` MEA.py 8956). Its
/// file records named `mphytbl*` each hold an initialization-table blob whose
/// bytes name a chipset platform, its stepping(s) and the table's revision;
/// those stepping letters are aggregated per unique chipset (`pch_init_anl`,
/// MEA.py 9097). The stepping *letters* are identity-gated — upstream decides
/// between absolute/bitfield/build rules from `variant`/`major`/`minor` and the
/// manifest date — so the decode runs after identification. `records` carries
/// one entry per mphytbl* table (chipset label, stepping letters, revision);
/// `chipsets` is the deduplicated per-chipset stepping summary upstream uses
/// for the CSE Chipset Platform row. `pch_dict` labels (MEA.py 10839) are
/// compile-time constants, like IUPDescriptor's.
public struct MFSPCHInit: Codable, Sendable, Equatable {
    public var records: [MFSPCHInitRecord]
    public var chipsets: [MFSPCHInitChipset]

    public init(records: [MFSPCHInitRecord], chipsets: [MFSPCHInitChipset]) {
        self.records = records
        self.chipsets = chipsets
    }
}

/// One decoded `mphytbl*` table (upstream `mphytbl` row `[mfs_file, chipset,
/// stepping, revision]`, MEA.py 9022). `chipset` is the `pch_dict` platform
/// label of the table's chipset-ID byte (nibble on the old layout), with the
/// identity-gated renames applied ('WTL' at CSSPS 4.4, 'CMP-V' at CSME 14.5)
/// or 'Unknown' when the ID has no entry. `stepping` is the table's decoded
/// stepping letters — absolute letter, bitfield letters (e.g. "CB" = C+B), or
/// a build-derived letter — and stays empty when the identity's stepping is
/// unreliable (pre-2015-05-19 CSME 11 / CSSPS 4). `revision` is the table's
/// own init-table Revision byte (new layout @+6, old @+2).
public struct MFSPCHInitRecord: Codable, Sendable, Equatable {
    public var chipset: String
    public var stepping: String
    public var revision: Int

    public init(chipset: String, stepping: String, revision: Int) {
        self.chipset = chipset
        self.stepping = stepping
        self.revision = revision
    }
}

/// One row of the per-chipset aggregation (upstream `pch_init_anl` MEA.py
/// 9097, dropping its trailing display-only total cell): each unique chipset
/// platform that appeared among the mphytbl* tables, with the concatenation of
/// every stepping string that tables of that chipset decoded, deduplicated and
/// sorted in reverse order (e.g. "CB" + "A" → "CBA"). Empty when the first
/// table's stepping was unreliable (upstream's early return).
public struct MFSPCHInitChipset: Codable, Sendable, Equatable {
    public var chipset: String
    public var steppings: String

    public init(chipset: String, steppings: String) {
        self.chipset = chipset
        self.steppings = steppings
    }
}

/// On-flash format of a CSE MFS *backup* area (upstream `mfs_anl` MEA.py
/// 7528/7554): a compacted snapshot of an MFS volume used for recovery. An FPT
/// partition literally named "MFSB" holds one (`mfsb_found`, MEA.py 11764); a
/// main "MFS" region whose first bytes are the backup signature is itself in
/// backup state (a hot/corrupt volume) and decodes the same way.
public enum MFSBackupFormat: String, Codable, Sendable {
    /// `MFS_Backup_Header_R0`: the reserved bytes [0x8:0x20] are all 0xFF — that
    /// IS the R0 dispatch. The area after the 0x20 header is a single CRC-32
    /// (IV-0 raw) protected body of 0x01030204-terminated chunks that
    /// reconstruct into a normal paged MFS image.
    case r0
    /// `MFS_Backup_Header_R1`: a 0x24 header (Revision 1, plain-CRC-32 header
    /// checksum) giving the offsets/sizes of three low-level-file entries —
    /// 6 Intel Configuration, 9 Manifest Backup, 7 OEM Configuration — each an
    /// `MFSBackupEntry` (`MFS_Backup_Entry`).
    case r1
}

/// Facts about a decoded CSE MFS backup area. The `.r0` branch carries the
/// reserved-0xFF marker and whether its compacted body reconstructs into a
/// paged MFS volume that re-parses with a valid header; the `.r1` branch
/// carries the header Revision and the per-entry decode (`entries`). Every CRC
/// is validated against the on-flash bytes; no FileTable.dat involvement.
public struct MFSBackup: Codable, Sendable, Equatable {
    public var offset: Int            // absolute region start
    public var format: MFSBackupFormat
    public var headerCRCStored: UInt32
    public var headerCRCValid: Bool
    /// `.r0`: the R0 Reserved field (6 × u32 @ +0x8) is all 0xFF.
    public var reservedAllFF: Bool?
    /// `.r0`: the 0x01030204-terminated body reconstructs (erased 0xFF padding
    /// reinserted, aligned to the 0x2000 page size) into an image that re-parses
    /// as a valid MFS volume. nil when the body is too short to reconstruct.
    public var reconstructedVolumeParses: Bool?
    /// `.r1`: the header Revision field — must be 1.
    public var headerRevision: UInt32?
    public var headerRevisionValid: Bool?
    /// `.r1`: the decoded low-level-file entries in header order (6, 9, 7).
    public var entries: [MFSBackupEntry] = []

    public init(offset: Int, format: MFSBackupFormat, headerCRCStored: UInt32,
                headerCRCValid: Bool, reservedAllFF: Bool?,
                reconstructedVolumeParses: Bool?, headerRevision: UInt32?,
                headerRevisionValid: Bool?, entries: [MFSBackupEntry]) {
        self.offset = offset
        self.format = format
        self.headerCRCStored = headerCRCStored
        self.headerCRCValid = headerCRCValid
        self.reservedAllFF = reservedAllFF
        self.reconstructedVolumeParses = reconstructedVolumeParses
        self.headerRevision = headerRevision
        self.headerRevisionValid = headerRevisionValid
        self.entries = entries
    }
}

/// One `.r1` backup entry (`MFS_Backup_Entry`, MEA.py 1765): the R1 header gives
/// the blob's `blobOffset`/`blobSize` within the backup area; the blob opens
/// with its own 0x10 header — Revision (1), EntryCRC32 (plain CRC-32 over the
/// header with EntryCRC32 zeroed and DataCRC32 excluded), the entry's own Size
/// (file-data length after the header) and DataCRC32 (plain CRC-32 over the file
/// data). `fileIndex` is the low-level-file index: 6 Intel Configuration, 7 OEM
/// Configuration, 9 Manifest Backup.
public struct MFSBackupEntry: Codable, Sendable, Equatable {
    public var fileIndex: Int      // 6 / 7 / 9
    public var blobOffset: Int     // from the R1 header (Entry{6,9,7}Offset)
    public var blobSize: Int       // from the R1 header (Entry{6,9,7}Size)
    public var revision: UInt32    // entry header Revision — must be 1
    public var revisionValid: Bool
    public var headerCRCStored: UInt32
    public var headerCRCValid: Bool
    public var dataSize: Int       // entry Size: file-data length after the 0x10 header
    public var dataCRCStored: UInt32
    public var dataCRCValid: Bool

    public init(fileIndex: Int, blobOffset: Int, blobSize: Int, revision: UInt32,
                revisionValid: Bool, headerCRCStored: UInt32, headerCRCValid: Bool,
                dataSize: Int, dataCRCStored: UInt32, dataCRCValid: Bool) {
        self.fileIndex = fileIndex
        self.blobOffset = blobOffset
        self.blobSize = blobSize
        self.revision = revision
        self.revisionValid = revisionValid
        self.headerCRCStored = headerCRCStored
        self.headerCRCValid = headerCRCValid
        self.dataSize = dataSize
        self.dataCRCStored = dataCRCStored
        self.dataCRCValid = dataCRCValid
    }
}

/// Facts about a CSE EFS (Extended File System) partition — the paged store of
/// an MFS volume's low-level files that ships alongside MFS on the newer
/// (CSME 15) layouts, decoded from an FPT region named "EFS". Surfaced here is
/// the *structural* decode only (upstream `efs_anl`, MEA.py 8621): the page
/// inventory, the System Page header fields and the CRC-32 validations of the
/// page header / index area / Data Page headers and footers. The EFS file
/// *contents* (names, per-file integrity split) are assembled from the external
/// FileTable.dat EFST rows — a parked DB-naming increment, never carried here.
///
/// The System Page header is self-describing: `dictionary` is its File Table id
/// and must equal the owning MFS volume's (0x0A on the CSME 15.0.30 dump), and
/// `dataPageOrder` is the System index permutation mapping each logical Data
/// page to its physical page. Byte-verified on 1.bin's EFS (dict 0x0A, Revision
/// 1/Unknown1 2, 14 Data pages == committed+reserved, all CRCs valid).
public struct EFSVolume: Codable, Sendable, Equatable {
    public var offset: Int            // absolute volume start
    public var pageSize: Int          // 0x1000
    public var systemPageCount: Int   // 1 on real volumes
    public var dataPageCount: Int
    public var scratchPageCount: Int
    public var scratchPagesEmpty: Bool      // Scratch pages must be all 0xFF
    public var dataPageCountMatchesSystem: Bool  // Data pages == Committed + Reserved
    public var dictionary: UInt16           // System Page File Table id
    public var revision: UInt32
    public var unknown1: UInt8
    public var dictionaryRevision: UInt8
    public var dataPagesCommitted: UInt8
    public var dataPagesReserved: UInt8
    public var systemHeaderCRCValid: Bool   // CRC-32 (IV 0 raw) over header minus its field
    public var indexesCRCValid: Bool        // System index area CRC-32
    public var firstIndexPaddingEmpty: Bool // the 8 zero bytes after the index area
    public var dataPageOrder: [UInt8]       // System index permutation (logical order)
    public var dataPageHeaderCRCsValid: Bool
    public var dataPageFooterCRCsValid: Bool
    public var matchesMFSDictionary: Bool?  // nil when no MFS volume decoded alongside

    public init(offset: Int, pageSize: Int, systemPageCount: Int,
                dataPageCount: Int, scratchPageCount: Int,
                scratchPagesEmpty: Bool, dataPageCountMatchesSystem: Bool,
                dictionary: UInt16, revision: UInt32, unknown1: UInt8,
                dictionaryRevision: UInt8, dataPagesCommitted: UInt8,
                dataPagesReserved: UInt8, systemHeaderCRCValid: Bool,
                indexesCRCValid: Bool, firstIndexPaddingEmpty: Bool,
                dataPageOrder: [UInt8], dataPageHeaderCRCsValid: Bool,
                dataPageFooterCRCsValid: Bool, matchesMFSDictionary: Bool?) {
        self.offset = offset
        self.pageSize = pageSize
        self.systemPageCount = systemPageCount
        self.dataPageCount = dataPageCount
        self.scratchPageCount = scratchPageCount
        self.scratchPagesEmpty = scratchPagesEmpty
        self.dataPageCountMatchesSystem = dataPageCountMatchesSystem
        self.dictionary = dictionary
        self.revision = revision
        self.unknown1 = unknown1
        self.dictionaryRevision = dictionaryRevision
        self.dataPagesCommitted = dataPagesCommitted
        self.dataPagesReserved = dataPagesReserved
        self.systemHeaderCRCValid = systemHeaderCRCValid
        self.indexesCRCValid = indexesCRCValid
        self.firstIndexPaddingEmpty = firstIndexPaddingEmpty
        self.dataPageOrder = dataPageOrder
        self.dataPageHeaderCRCsValid = dataPageHeaderCRCsValid
        self.dataPageFooterCRCsValid = dataPageFooterCRCsValid
        self.matchesMFSDictionary = matchesMFSDictionary
    }
}

/// Facts about the FITC ("OEM Configuration") partition — the on-flash OEM
/// Configuration store of the newer layouts, decoded from an FPT region named
/// "FITC". Upstream `fitc_anl` (MEA.py 8572) reads a `FITC_Header` (revision 1)
/// whose header and data are each protected by a plain CRC-32, then parses the
/// data as MFS config *records* — a FileTable.dat-named step that is parked,
/// never carried here. Only the header/length/integrity facts are on-flash
/// bytes. A revision ≠ 1 layout (CSME 15 TGP alpha) carries no checksums: the
/// config length comes from the first u32 and the tail must be 0xFF padding.
/// Byte-verified on 1.bin's FITC (revision 1, header and data CRC-32 valid).
public struct OEMConfiguration: Codable, Sendable, Equatable {
    public var offset: Int
    public var headerRevision: UInt32
    /// rev == 1: `DataLength` — config data length at +0x10.
    public var dataLength: Int?
    public var headerCRCStored: UInt32?
    public var headerCRCValid: Bool?
    public var dataCRCStored: UInt32?
    public var dataCRCValid: Bool?
    /// rev != 1: config length from the first u32 and whether the tail is 0xFF.
    public var configLength: Int?
    public var paddingAllFF: Bool?

    public init(offset: Int, headerRevision: UInt32, dataLength: Int?,
                headerCRCStored: UInt32?, headerCRCValid: Bool?,
                dataCRCStored: UInt32?, dataCRCValid: Bool?,
                configLength: Int?, paddingAllFF: Bool?) {
        self.offset = offset
        self.headerRevision = headerRevision
        self.dataLength = dataLength
        self.headerCRCStored = headerCRCStored
        self.headerCRCValid = headerCRCValid
        self.dataCRCStored = dataCRCStored
        self.dataCRCValid = dataCRCValid
        self.configLength = configLength
        self.paddingAllFF = paddingAllFF
    }
}

/// A decoded legacy MFS Configuration stream (upstream `mfs_cfg_anl` MEA.py
/// 8467, `MFS_Config_Record_0x1C` MEA.py 1319): the Intel Configuration (low-
/// level file 6) or OEM Configuration (file 7) of an old-style (non-FTBL) MFS.
/// `owningFile` is the low-level file index the records came from. Records are
/// a flat ordered list — folder entries nest by name and pop back out on ".." —
/// with file content living at `record.offset..<offset+size` inside that
/// owning file. Only decoded for `usesFTBL == false` volumes (CSME ≤ 12): the
/// FTBL layout's 0xC records name files through FileTable.dat, a later
/// increment. CSME 12.0.3 carries an Intel Configuration (file 6) of 152
/// records whose folders include bup/chipsetinit/cls/dal_ivm/…; no OEM
/// Configuration (file 7) is present on that dump.
public struct MFSConfiguration: Codable, Sendable, Equatable {
    public var owningFile: Int
    public var records: [MFSConfigRecord]

    public init(owningFile: Int, records: [MFSConfigRecord]) {
        self.owningFile = owningFile
        self.records = records
    }
}

/// One decoded `MFS_Config_Record_0x1C` — a file or folder entry of a legacy
/// Intel/OEM Configuration tree. `isFolder` mirrors AccessMode.RecordType
/// (0 File, 1 Folder); `offset`/`size` locate a file's content within the
/// owning low-level file, `unixRights` is the 9-bit rwx bitmap, and the
/// protection/option fields come from the AccessMode/DeployOptions bitfields.
public struct MFSConfigRecord: Codable, Sendable, Equatable {
    public var name: String
    public var isFolder: Bool
    public var size: Int
    public var offset: Int
    public var unixRights: Int
    public var integrityProtection: Bool
    public var encryptionProtection: Bool
    public var antiReplayProtection: Bool
    public var oemConfigurable: Bool
    public var mcaConfigurable: Bool
    public var reserved: Int
    public var ownerUserID: Int
    public var ownerGroupID: Int

    public init(name: String, isFolder: Bool, size: Int, offset: Int,
                unixRights: Int, integrityProtection: Bool,
                encryptionProtection: Bool, antiReplayProtection: Bool,
                oemConfigurable: Bool, mcaConfigurable: Bool,
                reserved: Int, ownerUserID: Int, ownerGroupID: Int) {
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.offset = offset
        self.unixRights = unixRights
        self.integrityProtection = integrityProtection
        self.encryptionProtection = encryptionProtection
        self.antiReplayProtection = antiReplayProtection
        self.oemConfigurable = oemConfigurable
        self.mcaConfigurable = mcaConfigurable
        self.reserved = reserved
        self.ownerUserID = ownerUserID
        self.ownerGroupID = ownerGroupID
    }
}

/// One present low-level MFS file (upstream `mfs_anl` FAT chain walk, MEA.py
/// 7849–7884): a file record whose first Data-FAT slot is used. The reserved
/// roles upstream assigns by index (0–9: Anti-Replay, SVN Migration, Quota
/// Storage, Intel/OEM Configuration, Manifest Backup — `mfs_dict`, MEA.py
/// 10859) belong to the config/home-record decode layer, a later increment;
/// here each present file is its index and the byte size of its assembled FAT
/// chain. CSME 12.0.3 carries 210 present files (record 6 = Intel Configuration
/// is 0x4A97 bytes); CSME 15.0.30 (FTBL layout) carries 136.
public struct MFSFile: Codable, Sendable, Equatable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var size: Int

    public init(index: Int, size: Int) {
        self.index = index
        self.size = size
    }
}

/// The decoded file-8 Home Directory of a legacy (non-FTBL) MFS volume (upstream
/// `mfs_home_anl`, MEA.py 8152). File 8 of such a volume names the *home*
/// file-system tree: its raw content (minus its own trailing Integrity table)
/// is a sequence of `homeRecordSize`-byte `MFS_Home_Record_0x18`/`0x1C` rows
/// (MEA.py 1445/1499), each a file or folder entry pointing at another low-level
/// file; a Folder row's pointed-to file holds that folder's own rows, so the
/// decode recurses into a tree. `entries` is that tree's top level (Current
/// `'.'`/Parent `'..'` marker rows are omitted). Only decoded when the identity's
/// layout starts its files at a non-zero offset (`vfs_starts_at_0` false, MEA.py
/// 7467) and the volume carries files — on CSME 15 (`vfs_starts_at_0` true) the
/// FTBL/EFST naming (`mfs_home13_anl`) owns this region instead.
///
/// Two documented divergences from a literal upstream transcription, both needed
/// for the decode to terminate: `FileName` is truncated at its first NUL before
/// the `'.'`/`'..'` marker test and before naming (a literal `.decode('utf-8')`
/// keeps the trailing NULs and misclassifies a dirty row such as CSME 12 file-25
/// record 0 — a self-referencing folder whose name is `.\0faults…` — as a real
/// folder, recursing forever); and folder recursion carries a path cycle-guard so
/// a folder whose referenced file is already on the active recursion stack is
/// logged with empty children rather than re-walked. Termination was verified
/// against both oracles (CSME 12: 204 records, CSME 11: 552; 0 guards fired).
public struct MFSHomeDirectory: Codable, Sendable, Equatable {
    public var homeRecordSize: Int          // detected record struct size (0x18/0x1C)
    public var rootRecordCount: Int         // file-8 record rows (after its own Integrity tail)
    public var integrity: MFSIntegrityTable?  // file-8's own trailing Integrity (the root folder's)
    public var entries: [MFSHomeRecord]     // top-level rows under home (markers skipped)

    public init(homeRecordSize: Int, rootRecordCount: Int,
                integrity: MFSIntegrityTable?, entries: [MFSHomeRecord]) {
        self.homeRecordSize = homeRecordSize
        self.rootRecordCount = rootRecordCount
        self.integrity = integrity
        self.entries = entries
    }
}

/// One decoded `MFS_Home_Record_0x18`/`0x1C` — a file or folder entry of the MFS
/// Home Directory. `fileIndex` is the low-level file the row names; for a file
/// row, `size` is that file's decoded content length (its raw content minus the
/// trailing Integrity when `integrityProtection`); for a folder row, `children`
/// are the rows decoded from that folder file's own content. `integrity` is the
/// pointed-to file's trailing `MFS_Integrity_Table`, decoded when the row is
/// Integrity-protected and the file is long enough to carry one.
public struct MFSHomeRecord: Codable, Sendable, Equatable {
    public var fileIndex: Int
    public var name: String                  // NUL-truncated FileName
    public var isFolder: Bool                // AccessMode.RecordType (0 File, 1 Folder)
    public var fileSystemID: Int             // FileInfo.FileSystemID (0 root, 1 home, …)
    public var unixRights: Int               // AccessMode.UnixRights (9-bit)
    public var ownerUserID: Int
    public var ownerGroupID: Int
    public var integrityProtection: Bool     // AccessMode.Integrity (HMAC)
    public var encryptionProtection: Bool    // AccessMode.Encryption
    public var antiReplayProtection: Bool    // AccessMode.AntiReplay
    public var accessUnknown0: Bool          // AccessMode.Unknown0
    public var accessUnknown1: Bool          // AccessMode.Unknown1
    public var keyType: Int                  // AccessMode.KeyType: 0 Intel, 1 Other
    public var integritySalt: Int            // FileInfo.IntegritySalt (16-bit)
    public var unknownSalt: Int              // UnknownSalt (u16 at 0x18, u16[3] LE at 0x1C)
    public var size: Int                     // decoded content length of the pointed-to file
    public var integrity: MFSIntegrityTable? // pointed-to file's trailing Integrity, if any
    public var children: [MFSHomeRecord]     // folder rows decoded from the folder file

    public init(fileIndex: Int, name: String, isFolder: Bool, fileSystemID: Int,
                unixRights: Int, ownerUserID: Int, ownerGroupID: Int,
                integrityProtection: Bool, encryptionProtection: Bool,
                antiReplayProtection: Bool, accessUnknown0: Bool, accessUnknown1: Bool,
                keyType: Int, integritySalt: Int, unknownSalt: Int, size: Int,
                integrity: MFSIntegrityTable?, children: [MFSHomeRecord]) {
        self.fileIndex = fileIndex
        self.name = name
        self.isFolder = isFolder
        self.fileSystemID = fileSystemID
        self.unixRights = unixRights
        self.ownerUserID = ownerUserID
        self.ownerGroupID = ownerGroupID
        self.integrityProtection = integrityProtection
        self.encryptionProtection = encryptionProtection
        self.antiReplayProtection = antiReplayProtection
        self.accessUnknown0 = accessUnknown0
        self.accessUnknown1 = accessUnknown1
        self.keyType = keyType
        self.integritySalt = integritySalt
        self.unknownSalt = unknownSalt
        self.size = size
        self.integrity = integrity
        self.children = children
    }
}

/// A decoded `MFS_Integrity_Table` — the trailing security header carried by an
/// MFS low-level file that is Integrity-protected (a reserved file such as
/// Anti-Replay, or a Home Directory file/folder row with `integrityProtection`).
/// The structure is either `0x28` (HMAC-MD5, AES-GCM nonce — CSME ≥ 12) or
/// `0x34` (HMAC-SHA-256, 128-bit AR/CTR nonce — CSME 11). `hmacHex`/`nonceHex`
/// are the raw stored bytes as uppercase natural-order hex; the Integrity value
/// itself is a keyed HMAC over file content + table + FileInfo, unverifiable
/// without Intel's secret key. Flags: Unknown0(1b), AntiReplay, Encryption,
/// then layout-specific unknown runs, ARIndex (10b), SVN (8b). `arRandom`/
/// `arCounter` are the raw u32s of the AR nonce region (0x28: dedicated fields
/// @+0x14/0x18; 0x34: first two words of the @+0x24 region) — meaningful only
/// when `antiReplayProtection`.
public struct MFSIntegrityTable: Codable, Sendable, Equatable {
    public var size: Int                    // 0x28 or 0x34 (the header length)
    public var hmacHex: String              // HMAC MD5/SHA-256 bytes, uppercase hex
    public var flagsRaw: Int                // raw Flags u32
    public var antiReplayProtection: Bool   // Flags bit 1
    public var encryptionProtection: Bool   // Flags bit 2 (0x34) / bit 3 (0x28)
    public var antiReplayIndex: Int         // 10-bit AR Index
    public var securityVersion: Int         // 8-bit SVN
    public var arRandom: Int                // AR random value (u32 LE)
    public var arCounter: Int               // AR counter value (u32 LE)
    public var nonceHex: String             // AES-GCM/CTR nonce bytes, uppercase hex

    public init(size: Int, hmacHex: String, flagsRaw: Int,
                antiReplayProtection: Bool, encryptionProtection: Bool,
                antiReplayIndex: Int, securityVersion: Int,
                arRandom: Int, arCounter: Int, nonceHex: String) {
        self.size = size
        self.hmacHex = hmacHex
        self.flagsRaw = flagsRaw
        self.antiReplayProtection = antiReplayProtection
        self.encryptionProtection = encryptionProtection
        self.antiReplayIndex = antiReplayIndex
        self.securityVersion = securityVersion
        self.arRandom = arRandom
        self.arCounter = arCounter
        self.nonceHex = nonceHex
    }
}

/// The trailing Integrity table of a reserved MFS low-level file (1–5:
/// Anti-Replay, SVN Migration, Quota Storage — `mfs_dict`, MEA.py 10859),
/// decoded per the reserved-walk gating (MEA.py 7901–7929): files 1–3 always
/// carry one; file 4 (SVN Migration) carries one except at CSTXE (AFS); file 5
/// (Quota Storage) carries one only at CSME ≥ 12. A reserved file whose role
/// carries no Integrity (or whose content is empty) is not listed. `contentSize`
/// is that file's data length with the Integrity header removed.
public struct MFSReservedFileIntegrity: Codable, Sendable, Equatable {
    public var fileIndex: Int
    public var contentSize: Int
    public var integrity: MFSIntegrityTable

    public init(fileIndex: Int, contentSize: Int, integrity: MFSIntegrityTable) {
        self.fileIndex = fileIndex
        self.contentSize = contentSize
        self.integrity = integrity
    }
}

/// One slot of an IFWI 1.6/1.7 CSE Layout Table's partition inventory (upstream
/// `cse_lt_hdr_info`, MEA.py 11549). `name` is upstream's label — "Data",
/// "Boot 1"…"Boot 5", plus "Temp"/"ELog" on IFWI 1.7. `offset` is the slot's SPI
/// (the table base plus its raw offset field), made absolute like every region
/// offset in the model; `empty` is upstream's flag (offset/size NA in
/// [0, 0xFFFFFFFF], or the whole content erased to 0x00/0xFF) — empty slots are
/// still listed, exactly as upstream shows them.
public struct CSELayoutPartition: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var offset: Int
    public var size: Int
    public var empty: Bool

    public init(id: Int, name: String, offset: Int, size: Int, empty: Bool) {
        self.id = id
        self.name = name
        self.offset = offset
        self.size = size
        self.empty = empty
    }
}

/// Facts of an IFWI 1.6/1.7 CSE Layout Table (upstream `CSE_Layout_Table_16`/`_17`
/// + the region analysis MEA.py 11546–11605): the Data/Boot/Temp/ELog partition
/// inventory that maps the CSE region *before* the `$FPT` whose partitions the
/// FPT decode reports. `offset` is the table base (region `baseOffset` +
/// region-relative, like `CodePartition.offset`). `redundancy` is the 1.7 Flags
/// bit 0 ("backup of BP1 is stored in the otherwise-empty BP2"); false when the
/// version is 1.6, which carries no such flag. `checksumValid` is the 1.7 CRC-32
/// over the pointer block (Size word through the partition fields, CRC word
/// zeroed); nil for 1.6, which stores no comparable checksum. nil on
/// `FirmwareAnalysis` = no CSE LT (a pre-IFWI engine, e.g. CSME 11).
public struct CSELayoutTable: Codable, Sendable, Equatable {
    public var offset: Int                 // absolute table base
    public var version: Int                // 0x16 or 0x17
    public var redundancy: Bool            // 1.7 CSE Redundancy flag; always false for 1.6
    public var checksumValid: Bool?        // 1.7 pointer-block CRC-32; nil for 1.6
    public var partitions: [CSELayoutPartition]

    public init(offset: Int, version: Int, redundancy: Bool, checksumValid: Bool?,
                partitions: [CSELayoutPartition]) {
        self.offset = offset
        self.version = version
        self.redundancy = redundancy
        self.checksumValid = checksumValid
        self.partitions = partitions
    }
}

/// One entry of a Boot Partition Descriptor Table (upstream `BPDT_Entry`,
/// MEA.py 742). `name` is upstream's label — the `$CPD` partition name when the
/// entry content begins `$CPD`, else the `bpdt_dict` type name ("RBEP", "FTPR",
/// "PMCP", "PCHC", …), else "Unknown". `type` is the raw u16 Type; `offset` is
/// the entry's SPI (the BPDT base plus its raw offset), absolute like every
/// region offset; `empty` mirrors upstream (offset/size NA in [0, 0xFFFFFFFF],
/// or the whole content erased to 0xFF).
public struct BPDTPartition: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var type: Int
    public var offset: Int
    public var size: Int
    public var empty: Bool

    public init(id: Int, name: String, type: Int, offset: Int, size: Int, empty: Bool) {
        self.id = id
        self.name = name
        self.type = type
        self.offset = offset
        self.size = size
        self.empty = empty
    }
}

/// A Boot Partition Descriptor Table decoded from the head of a non-empty
/// IFWI CSE-LT Boot partition (upstream `BPDT_Header_1`/`_2` + entry loop,
/// MEA.py 11850–12107). `partitionName` names the hosting Boot slot ("Boot 1",
/// "Boot 3"). `version` is the BPDT version tag — 1 (IFWI 1.6 & 2.0) or 2
/// (IFWI 1.7). `redundancy` is the 1.7 `BPDTConfig` bit 0; false when the
/// version is 1, whose Checksum is an XOR redundancy value rather than a flag.
/// `checksumValid` is the 1.7 CRC-32 over the whole table (header + entries)
/// with the stored checksum field zeroed (signature excluded); nil for version
/// 1, which stores no comparable checksum. nil on `FirmwareAnalysis` = the
/// image has no IFWI (pre-CSE) or no boot partitions.
public struct BPDT: Codable, Sendable, Equatable {
    public var offset: Int                 // absolute BPDT base
    public var partitionName: String       // hosting CSE-LT Boot slot ("Boot 1"…)
    public var version: Int                // 1 (IFWI 1.6 & 2.0) or 2 (IFWI 1.7)
    public var redundancy: Bool            // 1.7 BPDTConfig bit 0; false for version 1
    public var checksumValid: Bool?        // 1.7 CRC-32 over header+entries; nil for version 1
    public var entries: [BPDTPartition]

    public init(offset: Int, partitionName: String, version: Int, redundancy: Bool,
                checksumValid: Bool?, entries: [BPDTPartition]) {
        self.offset = offset
        self.partitionName = partitionName
        self.version = version
        self.redundancy = redundancy
        self.checksumValid = checksumValid
        self.entries = entries
    }
}

/// A pre-CSE R0 manifest's `$MME` module directory plus the trailing `$MCP`
/// where one is present (upstream-map rows 51/52). The directory rows are
/// `MME_Header_Old` after a `$MAN` manifest (ME 2–5, stride 0x50) or
/// `MME_Header_New` after a `$MN2` manifest (ME 6–10, stride 0x60); the list
/// head is `manifest base + HeaderLength*4 + 0xC` (MEA.py 12256). Upstream
/// (MEA.py 12256–12369) walks these rows only for region-size / uncharted-
/// partition math and prints no module table, so this surfaces the directory
/// facts verbatim as a self-contained inventory. `offset` is the absolute
/// `$MME` list head. nil on `FirmwareAnalysis` for the CSME families and for
/// R1/R2 manifests (no pre-CSE directory).
public struct MMEModuleDirectory: Codable, Sendable, Equatable {
    public var offset: Int            // absolute $MME list head (baseOffset + region-relative)
    public var manifestTag: String    // "$MN2" (new header, ME 6–10) or "$MAN" (old, ME 2–5)
    public var declaredModules: Int   // manifest NumModules
    public var modules: [MMEModule]   // decoded rows, in file order (≤ declaredModules)
    public var mcp: MCPHeader?        // trailing $MCP after the 0x60 padding row, nil for $MAN

    public init(offset: Int, manifestTag: String, declaredModules: Int,
                modules: [MMEModule], mcp: MCPHeader?) {
        self.offset = offset
        self.manifestTag = manifestTag
        self.declaredModules = declaredModules
        self.modules = modules
        self.mcp = mcp
    }
}

/// One `$MME` module directory row. Fields are directory facts read verbatim —
/// `modBase`/`offsetMN2`/sizes are recorded exactly as stored and never resolved
/// to content offsets (upstream makes no uniqueness promise for them, e.g. many
/// rows share an `Offset_MN2`). New-header rows (ME 6–10) carry the
/// size/memory/entry fields plus a 32-byte hash; old-header rows (ME 2–5) carry
/// the four version u16s, a 16-byte GUID, a 20-byte hash and a single `size`.
/// The other shape's fields stay nil (the two never mix in one directory).
public struct MMEModule: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    /// Module hash as uppercase hex: SHA-256 (32 bytes) for the new header,
    /// 20 bytes for the old header.
    public var hashHex: String?
    /// Old-header GUID (16 bytes) as uppercase hex; nil for the new header.
    public var guidHex: String?
    // MME_Header_New (ME 6–10, after `$MN2`):
    public var modBase: Int?          // @ +0x34
    public var offsetMN2: Int?        // @ +0x38  module content offset from the $MN2
    public var sizeUncompressed: Int? // @ +0x3C
    public var sizeCompressed: Int?   // @ +0x40
    public var memorySize: Int?       // @ +0x44
    public var preUmaSize: Int?       // @ +0x48
    public var entryPoint: Int?       // @ +0x4C
    public var flags: UInt32?         // new @ +0x50, old @ +0x44
    // MME_Header_Old (ME 2–5, after `$MAN`):
    public var majorVersion: Int?     // @ +0x14 (u16)
    public var minorVersion: Int?     // @ +0x16 (u16)
    public var hotfixVersion: Int?    // @ +0x18 (u16)
    public var buildVersion: Int?     // @ +0x1A (u16)
    public var size: Int?             // @ +0x40

    public init(id: Int, name: String, hashHex: String? = nil, guidHex: String? = nil,
                modBase: Int? = nil, offsetMN2: Int? = nil,
                sizeUncompressed: Int? = nil, sizeCompressed: Int? = nil,
                memorySize: Int? = nil, preUmaSize: Int? = nil, entryPoint: Int? = nil,
                flags: UInt32? = nil,
                majorVersion: Int? = nil, minorVersion: Int? = nil,
                hotfixVersion: Int? = nil, buildVersion: Int? = nil, size: Int? = nil) {
        self.id = id
        self.name = name
        self.hashHex = hashHex
        self.guidHex = guidHex
        self.modBase = modBase
        self.offsetMN2 = offsetMN2
        self.sizeUncompressed = sizeUncompressed
        self.sizeCompressed = sizeCompressed
        self.memorySize = memorySize
        self.preUmaSize = preUmaSize
        self.entryPoint = entryPoint
        self.flags = flags
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
        self.hotfixVersion = hotfixVersion
        self.buildVersion = buildVersion
        self.size = size
    }
}

/// Multi-chip-package header that follows the `$MME` directory of an ME 8–10
/// `$MN2` after one 0x60 row of padding (`mcp_start = mod_start + NumModules *
/// mme_size + mme_size`, MEA.py 12326) — upstream `MCP_Header` (MEA.py 1145).
/// Its `CodeSize`/`Offset_Code_MN2` hold the whole-code partition size math.
/// nil on `MMEModuleDirectory` for `$MAN` (ME 2–5) or when the slot is empty.
public struct MCPHeader: Codable, Sendable, Equatable {
    public var offset: Int            // absolute $MCP base
    public var headerSize: Int        // HeaderSize @ +0x04 (dwords)
    public var codeSize: Int          // @ +0x08
    public var offsetCodeMN2: Int     // @ +0x0C  code start from the $MN2
    public var offsetPartFPT: Int     // @ +0x10  partition start from the $FPT
    public var hashHex: String        // SHA-256 @ +0x14, uppercase hex

    public init(offset: Int, headerSize: Int, codeSize: Int,
                offsetCodeMN2: Int, offsetPartFPT: Int, hashHex: String) {
        self.offset = offset
        self.headerSize = headerSize
        self.codeSize = codeSize
        self.offsetCodeMN2 = offsetCodeMN2
        self.offsetPartFPT = offsetPartFPT
        self.hashHex = hashHex
    }
}

/// A GSC "INFO" `$FPT` partition decode — upstream `info_anl` (MEA.py 9134)
/// reading `GSC_Info_FWI` (MEA.py 358) + a list of `GSC_Info_IUP` (MEA.py 410),
/// surfaced from any region whose FPT carries a partition literally named
/// "INFO" (only GSC-family images name one that, so the name gates the decode —
/// upstream-map row 79). The partition opens with a u32 revision that must be 1
/// (upstream errors otherwise but still decodes); `revisionValid` records it so
/// the analyzer can raise an Issue. `offset` is the absolute INFO partition base.
/// nil on `FirmwareAnalysis` when no FPT "INFO" partition is present. No real
/// GSC dump exists among the oracles — fixture-only.
public struct GSCInfo: Codable, Sendable, Equatable {
    public var offset: Int            // absolute INFO partition base (baseOffset + region-relative)
    public var revision: Int          // partition revision u32 @ +0x00
    public var revisionValid: Bool    // revision == 1 (upstream "Unknown revision" error otherwise)
    public var image: GSCFirmwareImage            // the single GSC_Info_FWI
    public var iupPartitions: [GSCIUPPartition]   // trailing GSC_Info_IUP rows, in file order

    public init(offset: Int, revision: Int, revisionValid: Bool,
                image: GSCFirmwareImage, iupPartitions: [GSCIUPPartition]) {
        self.offset = offset
        self.revision = revision
        self.revisionValid = revisionValid
        self.image = image
        self.iupPartitions = iupPartitions
    }
}

/// `GSC_Info_FWI` (igsc_system.h > gsc_fwu_fw_image_data, MEA.py 358) — the
/// 0x20-byte GSC Firmware Image Info header. `project` is the 4-char NUL-
/// trimmed ASCII Project. Field offsets are verbatim from the ctypes struct.
public struct GSCFirmwareImage: Codable, Sendable, Equatable {
    public var project: String       // Project[4] @ +0x00
    public var hotfix: Int           // u16 @ +0x04
    public var build: Int            // u16 @ +0x06
    public var gscMajor: Int         // u16 @ +0x08
    public var gscMinor: Int         // u16 @ +0x0A
    public var gscHotfix: Int        // u16 @ +0x0C
    public var gscBuild: Int         // u16 @ +0x0E
    public var flags: UInt16         // u16 @ +0x10 (unknown)
    public var fwType: UInt8         // u8  @ +0x12 (raw; ext15_fw_type label deferred)
    public var fwSku: UInt8          // u8  @ +0x13 (raw; ext15_fw_sku label deferred)
    public var arbSvn: UInt32        // u32 @ +0x14
    public var tcbSvn: UInt32        // u32 @ +0x18
    public var vcn: UInt32           // u32 @ +0x1C

    public init(project: String, hotfix: Int, build: Int,
                gscMajor: Int, gscMinor: Int, gscHotfix: Int, gscBuild: Int,
                flags: UInt16, fwType: UInt8, fwSku: UInt8,
                arbSvn: UInt32, tcbSvn: UInt32, vcn: UInt32) {
        self.project = project
        self.hotfix = hotfix
        self.build = build
        self.gscMajor = gscMajor
        self.gscMinor = gscMinor
        self.gscHotfix = gscHotfix
        self.gscBuild = gscBuild
        self.flags = flags
        self.fwType = fwType
        self.fwSku = fwSku
        self.arbSvn = arbSvn
        self.tcbSvn = tcbSvn
        self.vcn = vcn
    }

    /// Upstream `gsc_print`: the GSC version is "N/A" when major is 0 or 0xFFFF.
    public var versionText: String {
        if gscMajor == 0 || gscMajor == 0xFFFF { return "N/A" }
        return "\(gscMajor).\(gscMinor).\(gscHotfix).\(gscBuild)"
    }
}

/// `GSC_Info_IUP` (igsc_system.h > gsc_fwu_iup_data, MEA.py 410) — one 0x10-byte
/// GSC Independent Update Partition descriptor row.
public struct GSCIUPPartition: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String        // Name[4] @ +0x00, NUL-trimmed ASCII
    public var flags: UInt16       // u16 @ +0x04
    public var reserved: UInt16    // u16 @ +0x06
    public var svn: UInt32         // u32 @ +0x08
    public var vcn: UInt32         // u32 @ +0x0C

    public init(id: Int, name: String, flags: UInt16, reserved: UInt16,
                svn: UInt32, vcn: UInt32) {
        self.id = id
        self.name = name
        self.flags = flags
        self.reserved = reserved
        self.svn = svn
        self.vcn = vcn
    }
}

/// One GSC Option ROM image found by scanning a region for `orom_pat` — the
/// OROM/PCIR header signature (MEA.py 11021) — and decoding each match as a
/// `GSC_OROM_Header` (MEA.py 433) plus its `GSC_OROM_PCI_Data` (MEA.py 466) at
/// `PCIDataHdrOff` (upstream-map row 30/80; decode block MEA.py 12149–12179).
/// `offset` is the absolute image base; `payloadOffset` is the computed
/// `data_off = max(PCIDataHdrOff + PCIR.PCIDataHdrLen, EFIImageOffset,
/// OROMPayloadOff)` (the OROM payload after the headers), and `payloadIsCPD`
/// records whether that payload opens with `$CPD` (upstream uses both in the
/// OROM IUP size math). nil on `FirmwareAnalysis` unless the region is an OROM
/// image. Fixture-only: no real OROM dump exists among the oracles.
public struct GSCOROMImage: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var offset: Int            // absolute image base (match start)
    public var header: GSCOROMHeader
    public var pciData: GSCOROMPCIData
    public var payloadOffset: Int     // data_off (headers + payload split)
    public var payloadIsCPD: Bool     // payload opens with "$CPD"

    public init(id: Int, offset: Int, header: GSCOROMHeader,
                pciData: GSCOROMPCIData, payloadOffset: Int, payloadIsCPD: Bool) {
        self.id = id
        self.offset = offset
        self.header = header
        self.pciData = pciData
        self.payloadOffset = payloadOffset
        self.payloadIsCPD = payloadIsCPD
    }
}

/// `GSC_OROM_Header` (igsc_oprom.h > oprom_header_ext_v2, MEA.py 433) — the
/// 0x1C-byte Option ROM image header. Offsets verbatim from the ctypes struct.
public struct GSCOROMHeader: Codable, Sendable, Equatable {
    public var signature: UInt16       // u16 @ +0x00 = 0xAA55
    public var imageSize: UInt16       // u16 @ +0x02, in 512-byte blocks
    public var initFuncEntryPoint: UInt32  // u32 @ +0x04
    public var subSystem: UInt16       // u16 @ +0x08
    public var machineType: UInt16     // u16 @ +0x0A
    public var compressionType: UInt16 // u16 @ +0x0C
    public var reserved: UInt64        // u64 @ +0x0E
    public var efiImageOffset: UInt16  // u16 @ +0x16
    public var pciDataHeaderOffset: UInt16  // u16 @ +0x18
    public var oromPayloadOffset: UInt16    // u16 @ +0x1A

    public init(signature: UInt16, imageSize: UInt16, initFuncEntryPoint: UInt32,
                subSystem: UInt16, machineType: UInt16, compressionType: UInt16,
                reserved: UInt64, efiImageOffset: UInt16,
                pciDataHeaderOffset: UInt16, oromPayloadOffset: UInt16) {
        self.signature = signature
        self.imageSize = imageSize
        self.initFuncEntryPoint = initFuncEntryPoint
        self.subSystem = subSystem
        self.machineType = machineType
        self.compressionType = compressionType
        self.reserved = reserved
        self.efiImageOffset = efiImageOffset
        self.pciDataHeaderOffset = pciDataHeaderOffset
        self.oromPayloadOffset = oromPayloadOffset
    }

    /// Upstream `gsc_print`: "Image Size 0x%X" = ImageSize × 512.
    public var imageSizeBytes: Int { Int(imageSize) * 512 }
}

/// `GSC_OROM_PCI_Data` (igsc_oprom.h > oprom_pci_data, MEA.py 466) — the
/// 0x1C-byte OROM PCI Data (PCIR) header. Offsets verbatim from the ctypes
/// struct. `lastImage` = `LastImageMark` bit 7 (upstream `>> 7`); `classCode`
/// is the 3 LE bytes at +0x0D read as one UInt32.
public struct GSCOROMPCIData: Codable, Sendable, Equatable {
    public var signature: String       // char[4] @ +0x00 = "PCIR"
    public var vendorID: UInt16        // u16 @ +0x04
    public var deviceID: UInt16        // u16 @ +0x06
    public var deviceListPointer: UInt16   // u16 @ +0x08
    public var pciDataHeaderLength: UInt16 // u16 @ +0x0A
    public var pciDataHeaderRevision: UInt8 // u8 @ +0x0C
    public var classCode: UInt32       // u8[3] @ +0x0D (LE)
    public var imageSize: UInt16       // u16 @ +0x10, in 512-byte blocks
    public var revisionLevel: UInt16   // u16 @ +0x12
    public var codeType: UInt8         // u8  @ +0x14 (raw; pcir_code_types label deferred)
    public var lastImage: Bool         // u8  @ +0x15 bit 7
    public var maxRuntimeImageLength: UInt16   // u16 @ +0x16
    public var configUtilityCodeHeaderPointer: UInt16  // u16 @ +0x18
    public var dmtfCLPEntryPointPointer: UInt16        // u16 @ +0x1A

    public init(signature: String, vendorID: UInt16, deviceID: UInt16,
                deviceListPointer: UInt16, pciDataHeaderLength: UInt16,
                pciDataHeaderRevision: UInt8, classCode: UInt32,
                imageSize: UInt16, revisionLevel: UInt16, codeType: UInt8,
                lastImage: Bool, maxRuntimeImageLength: UInt16,
                configUtilityCodeHeaderPointer: UInt16,
                dmtfCLPEntryPointPointer: UInt16) {
        self.signature = signature
        self.vendorID = vendorID
        self.deviceID = deviceID
        self.deviceListPointer = deviceListPointer
        self.pciDataHeaderLength = pciDataHeaderLength
        self.pciDataHeaderRevision = pciDataHeaderRevision
        self.classCode = classCode
        self.imageSize = imageSize
        self.revisionLevel = revisionLevel
        self.codeType = codeType
        self.lastImage = lastImage
        self.maxRuntimeImageLength = maxRuntimeImageLength
        self.configUtilityCodeHeaderPointer = configUtilityCodeHeaderPointer
        self.dmtfCLPEntryPointPointer = dmtfCLPEntryPointPointer
    }
}

public enum Severity: String, Codable, Sendable {
    case note, warning, error
}

public struct Issue: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var severity: Severity
    public var message: String
}

/// Bumped whenever the model gains a field, so the UI can decide deliberately
/// whether to surface the new data (`reference/result-model.md` §Versioning).
public enum EngineModelRevision {
    /// Current revision of the `FirmwareAnalysis` shape.
    public static let current = 22
}
