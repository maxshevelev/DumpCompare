import Foundation
import DumpCompareCore

/// The patterns the user keeps: named searches that survive use of the app
/// (§11, `Design/PATTERN_LIBRARY_IDEA.md`).
///
/// The counterpart of `FindHistoryStore`, and deliberately its opposite in the
/// two ways that matter. The history is a cache — capped at ten, written by
/// every search, evicted by the next one — while this is a list the user
/// curates: no cap, no eviction, and the order is theirs, because the order a
/// bench keeps its patterns in is knowledge too.
///
/// Same storage shape as the history (an array of dictionaries in
/// `UserDefaults`, one swappable domain so tests do not write the user's own),
/// and the same entry type with the name filled in.
enum FavoritePatternStore {
    static let userDefaultsKey = "FindFavorites"

    /// The domain the favourites live in. Swappable for tests, like the
    /// history's.
    static var defaults: UserDefaults = .standard

    /// Fired whenever the list changes, so the Find bar's menu and the form
    /// that edits it can re-read. A notification rather than a closure: the
    /// list has more than one reader — every window's find bar, and the
    /// settings form — and none of them owns the store.
    static let didChangeNotification = Notification.Name("FavoritePatternStoreDidChange")

    /// The kept patterns, in the order the user put them in.
    static var favorites: [SearchPatternEntry] {
        guard let raw = defaults.array(forKey: userDefaultsKey) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap(SearchPatternEntry.init(stored:))
    }

    /// Replaces the list — what the form saves, including a reorder.
    static func replace(with entries: [SearchPatternEntry]) {
        defaults.set(entries.map(\.storedValue), forKey: userDefaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Keeps `entry`, at the end of the list.
    ///
    /// Returns false when the same search is already kept — same pattern, same
    /// encoding, same case rule — because a second copy of it under another
    /// name is two answers to one question. The caller offers to rename the
    /// one that is there instead (§11).
    @discardableResult
    static func add(_ entry: SearchPatternEntry) -> Bool {
        var entries = favorites
        guard !entries.contains(where: { $0.isSameSearch(as: entry) }) else { return false }
        entries.append(entry)
        replace(with: entries)
        return true
    }

    /// The kept entry for the same search as `entry`, if there is one — what
    /// "already in your favourites, as *Foo*" is read from.
    static func existing(for entry: SearchPatternEntry) -> SearchPatternEntry? {
        favorites.first { $0.isSameSearch(as: entry) }
    }
}

extension SearchPatternEntry {
    /// Whether two entries ask the same thing of a file. The name is not part
    /// of it: renaming a favourite does not make it a different search, and
    /// keeping the same search twice under two names is what `add` refuses.
    func isSameSearch(as other: SearchPatternEntry) -> Bool {
        pattern == other.pattern && encoding == other.encoding
            && caseSensitive == other.caseSensitive
    }
}
