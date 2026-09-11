import Foundation

/// The seam that hands the module its firmware databases. Three upstream files
/// are fetched live from the MEAnalyzer git repository on first use and cached
/// in memory only — no disk, no snapshot (the exact rule of
/// `Skills/sync-mea-engine/reference/async-api.md`). A test injects a stub so a
/// parse run never touches the network.
public protocol MEADataSource: Sendable {
    /// Parsed MEA.dat: revision header, firmware lines, `RSAPKEY_*` map,
    /// `rsa_pre_keys` and `cse_known_bad_hashes` sections. Consumed by the
    /// identification step of the analysis pipeline.
    func database() async throws -> MEADatabase

    /// Huffman dictionaries keyed by (variant, major, minor) — fetched only
    /// when a run actually needs to decompress an older CSE module.
    func huffmanDictionaries() async throws -> HuffmanDictionaries

    /// FileTable.dat module-name/version map for the VFS walk.
    func fileTable() async throws -> FileTable

    /// Emits when a background check has replaced `MEA.dat` with a newer one.
    ///
    /// A source holds its database for the life of the process and re-checks it
    /// once a day, behind whatever is being read at the time — so an analysis
    /// can be finished against a database that has since been superseded. This
    /// is how the module hears about it and analyses again, against what has
    /// just arrived. A source that never changes its mind never emits.
    func databaseChanges() async -> AsyncStream<Void>
}

/// Typed fetch/parse failures, mirroring `GuidsSourceError` in
/// `Modules/UEFITool/Sources/UEFIToolUI/GuidsSource.swift` so the app can
/// present a retry affordance. Identification cannot degrade when `MEA.dat` is
/// missing — there is no offline baseline — so the module surfaces the error.
public enum MEADataError: LocalizedError, Sendable, Equatable {
    case offline(underlying: String)
    case badResponse(status: Int)
    case rateLimited
    case malformed(file: String)

    public var errorDescription: String? {
        switch self {
        case .offline(let underlying):
            return "Could not reach the MEAnalyzer repository (\(underlying))."
        case .badResponse(let status):
            return "The MEAnalyzer repository answered HTTP \(status)."
        case .rateLimited:
            return "The MEAnalyzer repository rate-limited the request; try again shortly."
        case .malformed(let file):
            return "\(file) downloaded but could not be parsed."
        }
    }
}

// Parser placeholder: the DB layer that turns FileTable.dat into this is a
// later incremental step (upstream-map "CSE file systems"); nothing consumes
// it yet. It exists so the protocol seam above is concrete and injectable from
// day one. `HuffmanDictionaries` (the real type) lives in Decompress/Huffman.swift.
public struct FileTable: Sendable, Equatable {
    public init() {}
}

extension MEADataSource {
    /// A source with nothing to announce — a stub in a test, a local file.
    public func databaseChanges() async -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }

    /// Default: no dictionaries available — the caller decides whether that is
    /// fatal. `MEAGitHubDataRepository` overrides this with a live single-flight
    /// fetch of `Huffman.dat`; test stubs that only need `database()` inherit it.
    public func huffmanDictionaries() async throws -> HuffmanDictionaries {
        throw MEADataError.malformed(file: "Huffman.dat (no data source configured)")
    }

    /// Not ported yet: upstream FileTable.dat loaders / `check_ftbl_id`. Throws
    /// until then.
    public func fileTable() async throws -> FileTable {
        throw MEADataError.malformed(file: "FileTable.dat (parser not ported yet)")
    }
}
