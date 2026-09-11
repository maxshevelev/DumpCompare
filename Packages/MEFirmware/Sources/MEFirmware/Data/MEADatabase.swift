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
    /// Read-only from outside: `haystack` below is derived from it at init, so
    /// a caller replacing the corpus behind its back would leave the two out
    /// of step. Build a new database instead.
    public private(set) var lines: [String]

    /// The `rsa_pre_keys` JSON list from the `Structures` section: SHA-256
    /// public-key hashes known to be Pre-Production keys.
    public var preProductionKeyHashes: Set<String>

    /// `lines` flattened into one newline-separated ASCII buffer, with each
    /// line's start offset alongside.
    ///
    /// Every DB lookup here is "the first line containing this hash", and
    /// `String.contains` is grapheme-aware: Foundation walks character
    /// boundaries through `_opaqueCharacterStride` for every candidate
    /// position, which measured at ~30% of a whole firmware parse — the corpus
    /// is ~3900 lines and identification searches it several times per image.
    /// Searching the bytes instead is the same answer for the ASCII hex hashes
    /// these are called with, at a fraction of the cost.
    private var haystack: Data
    private var lineStarts: [Int]

    public init(revision: Int? = nil,
                lines: [String] = [],
                preProductionKeyHashes: Set<String> = []) {
        self.revision = revision
        self.lines = lines
        self.preProductionKeyHashes = preProductionKeyHashes
        var buffer = Data()
        var starts = [Int]()
        starts.reserveCapacity(lines.count)
        for line in lines {
            starts.append(buffer.count)
            buffer.append(contentsOf: line.utf8)
            buffer.append(0x0A)
        }
        self.haystack = buffer
        self.lineStarts = starts
    }

    /// The first line containing `needle`, as an index into `lines`.
    private func firstLineIndex(containing needle: String) -> Int? {
        let pattern = Data(needle.utf8)
        guard !pattern.isEmpty,
              let found = haystack.range(of: pattern) else { return nil }
        let hit = found.lowerBound - haystack.startIndex
        // The line whose span holds `hit`: the last start at or before it. A
        // match never straddles a line, since the separator is a newline and
        // no needle carries one.
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= hit { low = mid } else { high = mid - 1 }
        }
        return lineStarts.isEmpty ? nil : low
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
        guard let index = firstLineIndex(containing: publicKeyHash) else { return nil }
        let parts = lines[index].split(separator: "_", omittingEmptySubsequences: false)
        return parts.count > 1 ? String(parts[1]) : nil
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
        return cseCells(in: row, family: family)
    }

    /// The same cells, read off a row the caller already has. Identification
    /// needs both the row itself (as the firmware's database name) and these
    /// cells, and finding the row is a search of the whole corpus — so it is
    /// worth doing once.
    public func cseCells(in row: String, family: FirmwareFamily) -> CSECells? {
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
        firstLineIndex(containing: signatureHash).map { lines[$0] }
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
