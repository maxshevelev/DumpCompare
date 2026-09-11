import Foundation

/// A search someone kept: the pattern as they wrote it, the encoding it is read
/// in, how letters compare — and, for a favourite, what it is called (§11).
///
/// One type for both lists in the Find bar's menu, because a favourite **is** a
/// recent with a name and nothing else (`Design/PATTERN_LIBRARY_IDEA.md`). That
/// is worth more than the tidiness of it: one row renderer, one pick handler,
/// one validation, and "keep this one" is naming a recent. A recent's `name` is
/// empty — nothing typed into a field has one.
///
/// Beside what the user wrote, an entry carries the bookkeeping a *shared*
/// library needs (`Design/FAVORITES_SYNC_PLAN.md`): an `id` of its own, where
/// it sits in the list, when it was last changed and by which machine. None of
/// it is visible anywhere in the app, and the recents do not store it — a
/// pattern typed on this Mac has no identity to keep in step with anything.
public struct SearchPatternEntry: Equatable, Sendable {
    /// The entry's own identity, minted once and kept for its lifetime.
    ///
    /// What it exists for is syncing: identity by content — pattern, encoding,
    /// case rule — is right for "do not keep the same search twice" and wrong
    /// the moment two machines are involved, where a rename would read as a
    /// deletion plus an addition, and a deletion would be indistinguishable
    /// from never having had it.
    public let id: UUID
    /// What a favourite is called; empty for a recent.
    public var name: String
    /// The text the user wrote, not the bytes it parses to. Keeping the text is
    /// what makes an entry editable in a form and re-parseable by the same call
    /// the bar makes — and `DE AD` and `DEAD` stay two entries, which is right
    /// for a list and wrong only for the search itself.
    public var pattern: String
    public var encoding: SearchEncoding
    /// Whether the search was run case-sensitively. Meaningful only for text
    /// encodings — hex is always byte-exact, so its flag never shows and is
    /// never restored (§11).
    public var caseSensitive: Bool

    // MARK: - Bookkeeping

    /// Where the entry sits in the list: a number between its neighbours', not
    /// an index. An index would renumber every entry below a reorder, and two
    /// machines renumbering the same list have nothing left to merge.
    public var sortKey: Double
    /// When the entry last changed, by the clock of the machine that changed
    /// it. Used for display and as a tiebreak — never as the arbiter of a
    /// merge, because two Macs' clocks disagree by more than a sync takes.
    ///
    /// Kept to the millisecond by the file, which is finer than anything that
    /// reads it and still legible in a diff.
    public var modifiedAt: Date
    /// The machine that last changed it, or empty where that is unknown — an
    /// entry written before this bookkeeping existed, which is honest rather
    /// than claiming this Mac wrote it.
    public var device: String

    public init(id: UUID = UUID(), name: String = "", pattern: String,
                encoding: SearchEncoding, caseSensitive: Bool = false,
                sortKey: Double = 0, modifiedAt: Date = Date(), device: String = "") {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.encoding = encoding
        self.caseSensitive = caseSensitive
        self.sortKey = sortKey
        self.modifiedAt = modifiedAt
        self.device = device
    }

    /// Two entries are equal when they say the same thing: the same search
    /// under the same name. The id, the order and the time of writing are
    /// bookkeeping — a list that re-recorded the search already at its front
    /// would otherwise count as changed on every press of ‹ ›, and a merge
    /// asking "did both sides change this the same way" wants the answer about
    /// the *content*.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.pattern == rhs.pattern
            && lhs.encoding == rhs.encoding && lhs.caseSensitive == rhs.caseSensitive
    }

    /// Whether two entries ask the same thing of a file. The name is not part
    /// of it: renaming a favourite does not make it a different search, and
    /// keeping the same search twice under two names is what the library
    /// refuses (§11).
    public func isSameSearch(as other: SearchPatternEntry) -> Bool {
        pattern == other.pattern && encoding == other.encoding
            && caseSensitive == other.caseSensitive
    }

    /// Whether the pattern can still be looked for. It always can: what an
    /// entry may hold is what `SearchEngine.parsePattern` accepts, and that is
    /// code rather than data. A hand-edited store is the only way to a `false`
    /// here, and then the bar reports it like any other bad pattern (§11).
    public var isUsable: Bool {
        (try? SearchEngine.parsePattern(pattern, encoding: encoding)) != nil
    }

    /// How letters compare for this entry, which is the pair the search itself
    /// takes. Hex folds nothing whatever the flag says.
    public var folding: CaseFolding {
        CaseFolding(encoding: encoding, caseSensitive: caseSensitive)
    }

    // MARK: - Persistence

    /// The dictionary form the favourites keep in `UserDefaults`, carrying the
    /// bookkeeping so an entry's identity survives a launch. A recent writes
    /// `recentValue` instead: it has no name, no place in a curated order and
    /// nothing to keep in step with another machine.
    public var storedValue: [String: Any] {
        var value = recentValue
        value["id"] = id.uuidString
        value["sortKey"] = sortKey
        value["modifiedAt"] = modifiedAt.timeIntervalSince1970
        if !device.isEmpty { value["device"] = device }
        return value
    }

    /// The dictionary form the *history* keeps: what was searched for, and
    /// nothing about identity or order. A store written before favourites
    /// existed reads back unchanged, and one written now stays as small.
    public var recentValue: [String: Any] {
        var value: [String: Any] = ["pattern": pattern,
                                    "encoding": encoding.rawValue,
                                    "caseSensitive": caseSensitive]
        if !name.isEmpty { value["name"] = name }
        return value
    }

    /// Reads one back, or nil for a row that is not one — a plist edited by
    /// hand, or an encoding this build no longer has.
    ///
    /// Bookkeeping that is not there is minted: a row from before it existed
    /// gets an id of its own the first time it is read, which is also the
    /// migration.
    public init?(stored value: [String: Any]) {
        guard let pattern = value["pattern"] as? String,
              let encodingName = value["encoding"] as? String,
              let encoding = SearchEncoding(rawValue: encodingName) else { return nil }
        let stamp = value["modifiedAt"] as? TimeInterval
        self.init(id: (value["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                  name: value["name"] as? String ?? "",
                  pattern: pattern,
                  encoding: encoding,
                  caseSensitive: value["caseSensitive"] as? Bool ?? false,
                  sortKey: value["sortKey"] as? Double ?? 0,
                  modifiedAt: stamp.map(Date.init(timeIntervalSince1970:)) ?? Date(),
                  device: value["device"] as? String ?? "")
    }
}

// MARK: - The library file

extension SearchPatternEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, pattern, encoding, caseSensitive, sortKey, modifiedAt, device
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The pattern and its encoding are the entry; everything else has an
        // answer when it is missing. A row that lost its name is still a
        // search, and one that lost its id gets a new one — which is exactly
        // what reading a library written before ids existed has to do.
        self.init(id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                  name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
                  pattern: try container.decode(String.self, forKey: .pattern),
                  encoding: try container.decode(SearchEncoding.self, forKey: .encoding),
                  caseSensitive: try container.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false,
                  sortKey: try container.decodeIfPresent(Double.self, forKey: .sortKey) ?? 0,
                  modifiedAt: try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date(),
                  device: try container.decodeIfPresent(String.self, forKey: .device) ?? "")
    }
}

