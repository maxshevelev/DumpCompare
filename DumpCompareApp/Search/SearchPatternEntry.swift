import Foundation
import DumpCompareCore

/// A search someone kept: the pattern as they wrote it, the encoding it is read
/// in, how letters compare — and, for a favourite, what it is called (§11).
///
/// One type for both lists in the Find bar's menu, because a favourite **is** a
/// recent with a name and nothing else (`Design/PATTERN_LIBRARY_IDEA.md`). That
/// is worth more than the tidiness of it: one row renderer, one pick handler,
/// one validation, and "keep this one" is naming a recent. A recent's `name` is
/// empty — nothing typed into a field has one.
struct SearchPatternEntry: Equatable {
    /// What a favourite is called; empty for a recent.
    var name: String
    /// The text the user wrote, not the bytes it parses to. Keeping the text is
    /// what makes an entry editable in a form and re-parseable by the same call
    /// the bar makes — and `DE AD` and `DEAD` stay two entries, which is right
    /// for a list and wrong only for the search itself.
    var pattern: String
    var encoding: SearchEncoding
    /// Whether the search was run case-sensitively. Meaningful only for text
    /// encodings — hex is always byte-exact, so its flag never shows and is
    /// never restored (§11).
    var caseSensitive: Bool

    init(name: String = "", pattern: String, encoding: SearchEncoding,
         caseSensitive: Bool = false) {
        self.name = name
        self.pattern = pattern
        self.encoding = encoding
        self.caseSensitive = caseSensitive
    }

    /// Whether the pattern can still be looked for. It always can: what an
    /// entry may hold is what `SearchEngine.parsePattern` accepts, and that is
    /// code rather than data. A hand-edited plist is the only way to a `false`
    /// here, and then the bar reports it like any other bad pattern (§11).
    var isUsable: Bool {
        (try? SearchEngine.parsePattern(pattern, encoding: encoding)) != nil
    }

    /// How letters compare for this entry, which is the pair the search itself
    /// takes. Hex folds nothing whatever the flag says.
    var folding: CaseFolding {
        CaseFolding(encoding: encoding, caseSensitive: caseSensitive)
    }

    // MARK: - Persistence

    /// The dictionary form both stores keep in `UserDefaults`. A recent writes
    /// no name, so a store written before favourites existed reads back
    /// unchanged.
    var storedValue: [String: Any] {
        var value: [String: Any] = ["pattern": pattern,
                                    "encoding": encoding.rawValue,
                                    "caseSensitive": caseSensitive]
        if !name.isEmpty { value["name"] = name }
        return value
    }

    /// Reads one back, or nil for a row that is not one — a plist edited by
    /// hand, or an encoding this build no longer has.
    init?(stored value: [String: Any]) {
        guard let pattern = value["pattern"] as? String,
              let encodingName = value["encoding"] as? String,
              let encoding = SearchEncoding(rawValue: encodingName) else { return nil }
        self.init(name: value["name"] as? String ?? "",
                  pattern: pattern,
                  encoding: encoding,
                  caseSensitive: value["caseSensitive"] as? Bool ?? false)
    }
}
