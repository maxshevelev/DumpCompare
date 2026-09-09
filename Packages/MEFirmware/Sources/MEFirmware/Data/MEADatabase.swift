import Foundation

/// Parsed MEA.dat: the firmware database the module consults to turn a
/// manifest RSA public key into a family / version / SKU / release.
///
/// Mirrors how upstream `MEA.py` keeps the file: `mea_db_read` (whole text) and
/// `mea_db_lines` (`splitlines()`), searched per query rather than eagerly
/// indexed — a few thousand lines, so linear scans cost nothing and the lookup
/// semantics stay byte-for-byte upstream's (substring match, `_`-split, first
/// hit wins). The two query shapes:
/// - **variant**: a 64-hex RSA **public-key** hash is searched as a substring
///   of every line; only `RSAPKEY_<VARIANT>_<hash> …` lines can match, and the
///   variant is line part index 1 (`get_variant`, ~10330).
/// - **firmware row**: a 64-hex RSA **signature** hash is the row key of the
///   canonical firmware lines (`version_…_PRD_EXTR_<hash>`, ~13645).
/// - **release fix**: membership of the public-key hash in the `rsa_pre_keys`
///   JSON list (loaded from the `Structures` section via `get_db_json_obj`,
///   ~9968) reclassifies wrong-PRD as PRE (`release_fix`, ~10254).
public struct MEADatabase: Sendable, Equatable {
    /// Revision from the file's `*** Revision rNNN … ***` header, when present.
    public var revision: Int?

    /// Every non-empty line of MEA.dat, verbatim (the search corpus).
    public var lines: [String]

    /// The `rsa_pre_keys` JSON list from the `Structures` section: SHA-256
    /// public-key hashes known to be Pre-Production keys.
    public var preProductionKeyHashes: Set<String>

    public init(revision: Int? = nil,
                lines: [String] = [],
                preProductionKeyHashes: Set<String> = []) {
        self.revision = revision
        self.lines = lines
        self.preProductionKeyHashes = preProductionKeyHashes
    }

    /// Deterministic parser: revision header, the line corpus, and the
    /// `rsa_pre_keys` JSON block. Database additions (new firmware lines, new
    /// `RSAPKEY_*` keys) need no code change — only a change to this *grammar*
    /// does.
    public static func parse(_ text: String) -> MEADatabase {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var db = MEADatabase(revision: revision(in: text), lines: lines)
        db.preProductionKeyHashes = preProductionKeys(in: text)
        return db
    }

    /// Variant token whose `RSAPKEY_*` line contains `publicKeyHash`
    /// (`get_variant` DB step): split the matched line on `_`, index 1. First
    /// hit wins; nil when no line carries the hash (unknown key).
    public func variant(matchingKeyHash publicKeyHash: String) -> String? {
        for line in lines where line.contains(publicKeyHash) {
            let parts = line.split(separator: "_", omittingEmptySubsequences: false)
            if parts.count > 1 { return String(parts[1]) }
        }
        return nil
    }

    /// True when `publicKeyHash` is a known Pre-Production key (`release_fix`).
    public func isPreProductionKey(_ publicKeyHash: String) -> Bool {
        preProductionKeyHashes.contains(publicKeyHash)
    }

    /// The canonical firmware row (a `version_…_<sigHash>` line) whose signature
    /// hash is `signatureHash`, verbatim. Mirrors the DB membership search; nil
    /// when the firmware is not in the database.
    public func firmwareRow(matchingSignatureHash signatureHash: String) -> String? {
        lines.first { $0.contains(signatureHash) }
    }

    // MARK: - Grammar

    static func revision(in text: String) -> Int? {
        guard let range = text.range(of: #"Revision\s+r(\d+)"#, options: .regularExpression) else {
            return nil
        }
        return Int(text[range].drop(while: { !$0.isNumber }))
    }

    /// `get_db_json_obj('rsa_pre_keys')`: text between `rsa_pre_keys*BGN` and
    /// `rsa_pre_keys*END`, inline ` # comment` stripped per line, parsed as a
    /// JSON array of hex strings.
    static func preProductionKeys(in text: String) -> Set<String> {
        guard let bgn = text.range(of: "rsa_pre_keys*BGN"),
              let end = text.range(of: "rsa_pre_keys*END",
                                   range: bgn.upperBound..<text.endIndex) else {
            return []
        }
        let body = text[bgn.upperBound..<end.lowerBound]
        let stripped = body.split(separator: "\n").map { line -> String in
            if let comment = line.range(of: " # ") { return String(line[..<comment.lowerBound]) }
            return String(line)
        }
        guard let data = stripped.joined().data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        return Set(array.compactMap { ($0 as? String)?.uppercased() })
    }
}
