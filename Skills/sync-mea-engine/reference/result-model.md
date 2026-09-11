# UI-facing result model — `FirmwareAnalysis`

The whole point of the Swift engine is one typed, `Codable` result tree that
ByteRipper's UI renders after it analyses an ME/engine region of a dump. It is
the "structured output for UI": no parser writes text tables (as MEA.py does
for a console); every decoder and the pipeline feed this model. The pipeline
is reached through the module's async API and awaits its (live-fetched, never
stored) databases where identification needs them — see reference/async-api.md.

File: `Packages/MEFirmware/Sources/MEFirmware/Models/FirmwareAnalysis.swift`

## Invariants (do not break these)

- **Codable and additive-only.** UI binds by field name. A sync may add fields,
  enum cases, or nested structs; it must never rename, retype, or remove an
  existing field. That is how the engine stays safe to refresh underneath a
  shipping UI.
- **`EngineModelRevision`** increments whenever the model gains fields, so the
  UI can decide deliberately whether to surface the new data.
- **Enums are `String`-raw** so serialized/archived values stay stable across
  Swift versions.
- **Never put DB-derived text in the model.** The model carries parsed facts
  (version numbers, dates, sizes, booleans). Display labels such as
  "Management Engine", "Production", or the human firmware name belong to the
  DB layer and to the UI, not here.

## Shape (starting point; bootstrap materializes it)

```swift
public struct FirmwareAnalysis: Codable, Identifiable {
    public var id: String { "\(family.rawValue)-\(variant)-\(version.text)" }

    public var family: FirmwareFamily        // .csme, .cstxe, .cssps, .gsc, ...
    public var variant: String               // e.g. "CSME", "PHYPTGP", "PCHCICP"
    public var version: Version              // parsed major.minor.hotfix.build
    public var securityVersion: String?      // SVN / VCN from the manifest
    public var release: ReleaseType          // .production / .preProduction / .romBypass
    public var type: FirmwareType            // .region / .extracted / .update
    public var sku: String
    public var platform: String
    public var manufactureDate: Date?
    public var sizeBytes: Int
    public var databaseName: String?         // unique name when found in MEA.dat

    public var rsaSignatureValid: Bool?      // nil when not checkable
    public var checksums: Checksums?         // sha256/sha384/crc of the region
    public var regions: [FPTRegion]          // FPT/partition table if present
    public var manifest: ManifestSummary?    // $MN2/$MAN facts + security fields
    public var codePartition: CodePartition? // $CPD: entries, extensions, modules
    public var issues: [Issue]               // notes / warnings / errors
}

public enum FirmwareFamily: String, Codable, CaseIterable {
    case me, csme, txe, cstxe, sps, cssps, gsc, pmc, pchc, phy, orom, unknown
}

public struct Version: Codable, Equatable {
    public var major: Int; public var minor: Int
    public var hotfix: Int; public var build: Int
    public var meMajor: Int?; public var meMinor: Int?   // MEU fields, when present
    public var text: String { ... }                       // "15.40.37.3121"
}

public enum ReleaseType: String, Codable { case production, preProduction, romBypass, unknown }
public enum FirmwareType: String, Codable { case region, extracted, update, unknown }

public struct FPTRegion: Codable, Identifiable {
    public var id: Int            // partition index
    public var name: String       // e.g. "FTUE", "rbe", "FTPR"
    public var offset: Int; public var size: Int
    public var flags: UInt32
}

public struct ManifestSummary: Codable { /* family/type/date/sku fields from $MN2 */ }
public struct CodePartition: Codable { /* $CPD entries, CSE extensions, module list */ }

public struct Checksums: Codable { public var sha256: String?; public var sha384: String?; public var crc32: UInt32? }
public struct Issue: Codable, Identifiable {
    public var id: Int
    public var severity: Severity        // .note / .warning / .error   (maps to MEA colours)
    public var message: String
}
```

## How upstream's console tables map to it

MEA.py prints one table per parsed structure (`FPT`, `BPDT`, `$MN2`, `$CPD`,
each `CSE_Ext_*`, module list…). Each table's rows become a nested struct in
this model; each column becomes a field. The correspondence is kept in
`upstream-map.md` so a new upstream structure has a defined target before you
port it — you never invent a model field ad hoc mid-sync.

## Versioning

- Add fields in the same order MEA.py prints / Intel's format defines.
- New nested struct → append an optional property (or new array) rather than
  nesting breaking change.
- Bump `EngineModelRevision` in the same change that adds a field.
