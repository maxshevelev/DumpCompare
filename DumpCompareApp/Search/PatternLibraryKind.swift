import Foundation
import DumpCompareCore

/// What a synced collection needs to know about itself to live in a folder the
/// user shares (`Design/FAVORITES_SYNC_PLAN.md`).
///
/// One of these per thing the app syncs. Everything else — the merge, the
/// questions, the publishing loop, the bookmark — is written once and takes
/// this as its parameter, so bookmarks or segments become a conformance rather
/// than a second copy of all of it.
protocol SyncedCollectionKind {
    /// What the collection holds. Shown to the user where a merge cannot
    /// decide, so it has to be presentable (`SyncPresentable`).
    associatedtype Item: SyncedItem & SyncPresentable

    /// What every machine's file in the shared folder is called, before the
    /// bracketed stamp that says which machine wrote it. The name a stranger
    /// sees, in a folder among other people's files.
    static var fileStem: String { get }

    /// Where the folder is remembered, and where it *was* remembered when the
    /// app was pointed at a file rather than a folder.
    static var folderBookmarkKey: String { get }
    static var folderPathKey: String { get }
    static var legacyBookmarkKey: String { get }
    static var legacyPathKey: String { get }

    /// The defaults domain those keys live in — the owning store's, so a test
    /// that isolates one isolates all of it.
    static var defaults: UserDefaults { get }
}

/// The kept patterns: the first collection to be carried between machines, and
/// the one the rest was written from (§11).
enum PatternLibraryKind: SyncedCollectionKind {
    typealias Item = SearchPatternEntry

    static let fileStem = "DumpCompare Patterns"
    static let folderBookmarkKey = "LibraryFolderBookmark"
    static let folderPathKey = "LibraryFolderPath"
    static let legacyBookmarkKey = "LibraryPublishedBookmark"
    static let legacyPathKey = "LibraryPublishedPath"
    static var defaults: UserDefaults { FavoritePatternStore.defaults }
}

/// The pattern library's folder, under the name the app has always used for it.
typealias LibraryLocation = SyncFolder<PatternLibraryKind>
