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

// Parser placeholders: the DB layer that turns each .dat file into one of
// these is a later incremental step (upstream-map "Data files consumed"), and
// nothing in the bootstrap spine consumes them yet. They exist so the protocol
// seam above is concrete and injectable from day one. Until their parsers land,
// the protocol defaults below fail loudly rather than hand out empty values.
public struct HuffmanDictionaries: Sendable, Equatable {
    public init() {}
}
public struct FileTable: Sendable, Equatable {
    public init() {}
}

extension MEADataSource {
    /// Not ported yet: upstream `cse_huffman_dictionary_load` parses Huffman.dat
    /// into the dictionaries the decompressor needs. Throws until then.
    public func huffmanDictionaries() async throws -> HuffmanDictionaries {
        throw MEADataError.malformed(file: "Huffman.dat (parser not ported yet)")
    }

    /// Not ported yet: upstream FileTable.dat loaders / `check_ftbl_id`. Throws
    /// until then.
    public func fileTable() async throws -> FileTable {
        throw MEADataError.malformed(file: "FileTable.dat (parser not ported yet)")
    }
}
