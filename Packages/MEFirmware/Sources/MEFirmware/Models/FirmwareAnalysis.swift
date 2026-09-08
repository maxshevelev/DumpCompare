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
/// manifest). `size` is the uncompressed module size.
public struct CPDModule: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String      // NUL-stripped 12-byte Name, e.g. "$MN2", "rbe"
    public var offset: Int
    public var isHuffman: Bool   // OffsetAttrib bit 25
    public var size: Int

    public init(id: Int, name: String, offset: Int, isHuffman: Bool, size: Int) {
        self.id = id
        self.name = name
        self.offset = offset
        self.isHuffman = isHuffman
        self.size = size
    }
}

/// Code Partition Directory facts for the *operational* partition — the one
/// whose `$MN2`/`$MAN` the engine identified (upstream `CPD_Header_R1`/`_R2` +
/// its `CPD_Entry` module list). Header fields are set from the `$CPD` header;
/// `modules` is the decoded module directory. CSE extension blocks
/// (`CSE_Ext_*`) and any deeper unpack are future stages.
public struct CodePartition: Codable, Sendable, Equatable {
    public var name: String            // PartitionName, e.g. "FTPR", "RBEP"
    public var offset: Int             // absolute $CPD header offset (region baseOffset + CPD base)
    public var headerVersion: Int      // 1 = R1, 2 = R2
    public var headerLength: Int       // 0x10 (R1) / 0x14 (R2)
    public var entryCount: Int         // declared NumModules (may exceed modules.count when the buffer truncates)
    public var checksumValid: Bool?    // R1 Checksum-8 result; nil for R2 (CRC-32 not yet ported)
    public var modules: [CPDModule]

    public init(name: String, offset: Int, headerVersion: Int, headerLength: Int,
                entryCount: Int, checksumValid: Bool?, modules: [CPDModule]) {
        self.name = name
        self.offset = offset
        self.headerVersion = headerVersion
        self.headerLength = headerLength
        self.entryCount = entryCount
        self.checksumValid = checksumValid
        self.modules = modules
    }
}

public struct Checksums: Codable, Sendable, Equatable {
    public var sha256: String?
    public var sha384: String?
    public var crc32: UInt32?
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
    public static let current = 3
}
