# Module contract — async external API + live data

This file pins the boundary between `Packages/MEFirmware` and ByteRipper's
UI, and how the module gets its firmware databases. It mirrors the app's
existing runtime-fetch pattern (`GuidsSource` / `LongSoftGuidsRepository` in
`Modules/UEFITool/Sources/UEFIToolUI/GuidsSource.swift`) on purpose, so a
reader who knows the GUID catalogue knows this module.

## External API — async, never blocking the UI

The module exposes async entry points; the UI/VM awaits them off the main
thread. Heavy parse work runs inside the module (an `actor` serialises it and
keeps the main thread free).

```swift
public actor MEFirmwareAnalyzer {
    private let data: any MEADataSource

    public init(data: any MEADataSource = MEAGitHubDataRepository()) { ... }

    /// Analyse one engine region (or the ME partition extracted from a dump).
    /// Structural parsing starts immediately; if identification needs the
    /// firmware databases, the pipeline awaits the live fetch and then
    /// continues to a complete `FirmwareAnalysis`. Never re-parses the file.
    public func analyze(region: Data, baseOffset: Int) async throws -> FirmwareAnalysis
}
```

The pipeline inside `analyze` is single-pass with a suspended dependency:

1. decode containers/structures that need no DB (FPT, BPDT, $CPD, manifest);
2. at the identification step, `try await data.database()` (first call loads);
3. finish — look up the RSA-key hash, fill version/SKU/release/date,
   checksums, module walk — and return the complete model.

The file is read once; the data is awaited where it is needed. That is the
"module continues after it has all the data" guarantee.

## Data source — lazy, single-flight, in-memory, no disk

Three upstream files are fetched from the MEAnalyzer git repository
(`master`): `MEA.dat`, `Huffman.dat`, `FileTable.dat`.

```swift
public protocol MEADataSource: Sendable {
    /// Parsed MEA.dat: revision header, firmware lines, RSAPKEY_* map,
    /// `rsa_pre_keys` and `cse_known_bad_hashes` sections.
    func database() async throws -> MEADatabase
    /// Huffman dictionaries keyed by (variant, major, minor) — fetched only
    /// when a run actually needs to decompress an older CSE module.
    func huffmanDictionaries() async throws -> HuffmanDictionaries
    /// FileTable.dat module-name/version map for the VFS walk.
    func fileTable() async throws -> FileTable
}

public struct MEAGitHubDataRepository: MEADataSource {
    // raw.githubusercontent.com/platomav/MEAnalyzer/master/<MEA.dat|Huffman.dat|FileTable.dat>
    // One shared URLSession like LongSoftGuidsRepository; User-Agent "ByteRipper".
    // No disk cache by design: next app launch fetches fresh.
}
```

Guarantees the provider must uphold:

- **Lazy.** Nothing is fetched at module init or app launch. The first call
  that needs a database triggers the fetch.
- **Single-flight.** Concurrent first calls share one in-flight `Task`
  (`private var cached: Task<MEADatabase, Error>?`). One network round for the
  whole run, not one per call or per pane.
- **In-memory only.** Cache lives as long as the process; no file is written.
  A relaunch re-fetches — which is exactly what "these databases change every
  week" wants.
- **Per-file need.** `database()` is the common one. `huffmanDictionaries()`
  and `fileTable()` are pulled only by unpack/verbose paths, so a plain
  identification fetch stays one file.

## Errors — typed, mirroring `GuidsSourceError`

Identification cannot meaningfully degrade when `MEA.dat` is missing (there is
no offline baseline to fall back to), so the module surfaces the fetch
failure to the UI:

```swift
public enum MEADataError: LocalizedError, Equatable {
    case offline(underlying: String)
    case badResponse(status: Int)
    case rateLimited
    case malformed(file: String)   // data arrived but failed to parse
}
```

The app decides presentation (retry affordance, "last known revision rNNN"
from the previous successful run is available to the *UI* only if the UI keeps
it; the module itself never persists).

## Testing seam

Tests must never touch the network. `analyze` takes the source through the
initializer, so a test injects a stub `MEADataSource` built from fixture
strings and asserts on `FirmwareAnalysis`. Provide the equivalent of
`GuidsCatalogue.empty` only for `HuffmanDictionaries`/`FileTable` where a run
can legitimately proceed without them; `MEADatabase` has no empty stand-in for
identification.

## Where upstream's files come from

- `MEA.dat`: `raw.githubusercontent.com/platomav/MEAnalyzer/master/MEA.dat` —
  same file the upstream script itself polls for updates (`mea_upd_check`).
- Revision marker: the file's `*** Revision rNNN (date) ***` header line.
- `Huffman.dat`, `FileTable.dat`: same repo, same branch.
