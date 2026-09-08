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
    public var manufactureDate: Date?
    public var sizeBytes: Int
    public var databaseName: String?          // unique name when found in MEA.dat
    public var rsaSignatureValid: Bool?       // nil when not checkable
    public var checksums: Checksums?
    public var regions: [FPTRegion]           // FPT / partition table if present
    public var manifest: ManifestSummary?     // $MN2/$MAN facts + security fields
    public var codePartition: CodePartition?  // $CPD: entries, extensions, modules
    public var mfsVolume: MFSVolume?          // MFS volume facts, when an FPT "MFS" region decodes
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

    public var text: String { "\(major).\(minor).\(hotfix).\(build)" }
}

public enum ReleaseType: String, Codable, Sendable {
    case production, preProduction, romBypass, unknown
}

public enum FirmwareType: String, Codable, Sendable {
    case region, extracted, update, unknown
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

    public init(offset: Int, tag: String, format: ManifestFormat,
                major: Int, minor: Int, hotfix: Int, build: Int, svn: Int,
                day: Int, month: Int, year: Int,
                keyHash: String?, signatureHash: String?) {
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

    public init(id: Int, tag: Int, size: Int, offset: Int,
                systemInfo: SystemInfoExtension? = nil,
                partitionInfo: PartitionInfoExtension? = nil,
                signedPackage: SignedPackageExtension? = nil,
                clientSystemInfo: ClientSystemInfoExtension? = nil,
                featurePermissions: FeaturePermissionsExtension? = nil,
                moduleAttributes: ModuleAttributesExtension? = nil) {
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
/// chain, describing the module that `.met` accompanies. Raw scalars: exactly
/// one payload group is set per block (the `_Mod`/row-based tags `0x04`–`0x0D`
/// surface as an opaque envelope). `moduleHash` is the owner body's stored hash
/// as uppercase hex — SHA-256 (64 chars) in R1, SHA-384 (96 chars) in R2.
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

public struct Checksums: Codable, Sendable, Equatable {
    public var sha256: String?
    public var sha384: String?
    public var crc32: UInt32?
}

/// MFS volume facts — the oldest CSE file system layout: a paged flash area
/// whose logical volume header (FTBL dictionary / platform ids, declared size,
/// file-record count) lives in the assembled System chunk 0. Decoded from an FPT
/// region named "MFS", present on both real dumps (CSME 12.0.3: FTBL dict
/// 1/plat 0 → `usesFTBL` false, old-style; CSME 15.0.30: dict 0x0A/plat 4 →
/// `usesFTBL` true). `signatureValid` is false when the region carries MFS pages
/// but chunk 0 is not a valid volume header (a corrupt or hot volume); nil
/// `mfsVolume` on `FirmwareAnalysis` means no decodable MFS region was found.
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

    public init(offset: Int, pageSize: Int, pageCount: Int,
                systemPageCount: Int, dataPageCount: Int,
                signatureValid: Bool, volumeSize: Int, computedVolumeSize: Int,
                fileRecordCount: Int, usedFileCount: Int,
                ftblDictionary: Int, ftblPlatform: Int, ftblReserved: Int,
                usesFTBL: Bool) {
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
    public static let current = 6
}
