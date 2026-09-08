import Foundation

/// Parsed MEA.dat: the firmware database the module consults to turn a
/// manifest RSA public key into a family / version / SKU / release.
///
/// Bootstrap materializes only the revision marker; the generic grammar parser
/// (`_`-separated entries, `RSAPKEY_*` and `*** section ***` lines, so database
/// additions never need a code change) is the DB-layer incremental step — see
/// `reference/upstream-map.md`, "Identification & database layer".
public struct MEADatabase: Sendable, Equatable {
    /// Revision from the file's `*** Revision rNNN … ***` header, when present.
    public var revision: Int?

    public init(revision: Int? = nil) {
        self.revision = revision
    }

    /// Minimal deterministic parser: extracts the revision marker. The full
    /// grammar lands with the DB-layer port; keeping this here makes the fetch
    /// seam testable now without touching the network.
    public static func parse(_ text: String) -> MEADatabase {
        MEADatabase(revision: Self.revision(in: text))
    }

    static func revision(in text: String) -> Int? {
        guard let range = text.range(of: #"Revision\s+r(\d+)"#, options: .regularExpression) else {
            return nil
        }
        return Int(text[range].drop(while: { !$0.isNumber }))
    }
}
