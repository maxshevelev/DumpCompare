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

    /// The manual CSE cells of the firmware row matching `signatureHash`
    /// (upstream `get_cse_db`, MEA.py 10262): the SKU, the PCH/SoC stepping and
    /// the Power Down Mitigation token, read from the `_`-separated cells of
    /// the row — which cell holds what depends on the family, exactly as
    /// upstream's per-variant branches say.
    ///
    /// A stepping cell reading `X`/`XX` is upstream's "not recorded" and comes
    /// back nil, as does a PDM cell that carries no PDM token. Nil for a
    /// firmware with no row at all (an unreleased build), which is upstream's
    /// `sku_stp = 'Unknown'` / `sku_pdm = 'UPDM'` default.
    public func cseCells(matchingSignatureHash signatureHash: String,
                         family: FirmwareFamily) -> CSECells? {
        guard let row = firmwareRow(matchingSignatureHash: signatureHash) else {
            return nil
        }
        let cells = row.split(separator: "_", omittingEmptySubsequences: false)
            .map(String.init)
        func cell(_ index: Int) -> String? {
            guard index < cells.count else { return nil }
            let value = cells[index]
            return value.isEmpty ? nil : value
        }
        func stepping(_ index: Int) -> String? {
            guard let value = cell(index), value != "X", value != "XX" else { return nil }
            return value
        }
        switch family {
        case .csme:
            let pdm = cell(4).flatMap { value in
                ["YPDM", "NPDM", "UPDM1", "UPDM2", "UPDM"].first { value.contains($0) }
            }
            return CSECells(sku: cell(2), stepping: stepping(3), pdm: pdm)
        case .cstxe:
            return CSECells(sku: nil, stepping: stepping(1), pdm: nil)
        case .cssps:
            // Upstream reads a (CS)SPS stepping only from a row whose *last*
            // cell is `EXTR` — and every row's last cell is its signature
            // hash, so that branch never fires and a (CS)SPS stepping is
            // never taken from the database (MEA.py 10280). Reproduced as it
            // is: MEA's own output is what this engine is checked against.
            guard cells.last == "EXTR" else { return CSECells(sku: nil, stepping: nil, pdm: nil) }
            return CSECells(sku: nil, stepping: stepping(3), pdm: nil)
        default:
            return nil
        }
    }

    /// True when `publicKeyHash` is a known Pre-Production key (`release_fix`).
    public func isPreProductionKey(_ publicKeyHash: String) -> Bool {
        preProductionKeyHashes.contains(publicKeyHash)
    }

    /// What `cseCells` read off a firmware row. Each is nil where upstream's
    /// own filters leave its variable at the default.
    public struct CSECells: Equatable, Sendable {
        public var sku: String?
        public var stepping: String?
        /// The PDM token as the database spells it — `YPDM`, `NPDM`, `UPDM1`,
        /// `UPDM2` or `UPDM`. The wording of the row is the UI's.
        public var pdm: String?
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
