import Foundation

/// The kept patterns, as a collection two machines keep in step
/// (`SyncedCollection`, `Design/FAVORITES_SYNC_PLAN.md`).
///
/// Nothing about carrying favourites between Macs is about *patterns*: an item
/// needs an identity, a place in the order, a time and a machine, and the merge
/// does the rest. So the library is one use of that machinery rather than a
/// thing of its own — which is what makes bookmarks or segments, when they want
/// the same treatment, a conformance instead of a second copy of all this.
public typealias PatternLibrary = SyncedCollection<SearchPatternEntry>

extension SearchPatternEntry: SyncedItem {
    /// §11 keeps one search once, whatever it is called — so two entries that
    /// ask the same thing of a file are the same thing said twice, and one of
    /// them has to go.
    public func isDuplicate(of other: SearchPatternEntry) -> Bool {
        isSameSearch(as: other)
    }
}

extension SearchEncoding: Codable {}

/// The questions a merge of two pattern libraries could not answer, and the
/// merge that raises them (`SyncMerge`).
public typealias LibraryConflict = SyncConflict<SearchPatternEntry>
public typealias LibraryResolution = SyncResolution
public typealias LibraryMerge = SyncMerge<SearchPatternEntry>

/// What this machine keeps on disk: its library, and the state it last agreed
/// with each of the other machines' files (`SyncDocument`).
public typealias FavoritesDocument = SyncDocument<SearchPatternEntry>
