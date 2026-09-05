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
/// It lives in a **file** rather than in `UserDefaults`
/// (`Design/FAVORITES_SYNC_PLAN.md`): a list that is knowledge belongs
/// somewhere it can be carried to another machine, kept in version control, or
/// read. The key it used to live under migrates on the first launch that finds
/// it, and is then gone — two stores on one machine is the syncing problem
/// indoors and for no reason.
enum FavoritePatternStore {
    /// The key the favourites used to live under, kept only to migrate away.
    static let userDefaultsKey = "FindFavorites"

    /// The domain the *bookkeeping* lives in — the device id, and nothing about
    /// the patterns themselves. Swappable for tests, like the history's.
    static var defaults: UserDefaults = .standard

    /// Fired whenever the list changes, so the Find bar's menu and the form
    /// that edits it can re-read. A notification rather than a closure: the
    /// list has more than one reader — every window's find bar, and the
    /// settings form — and none of them owns the store.
    static let didChangeNotification = Notification.Name("FavoritePatternStoreDidChange")

    // MARK: - Reading

    /// The kept patterns, in the order the user put them in.
    static var favorites: [SearchPatternEntry] { library.ordered }

    /// The library as it stands — what this machine believes, which is what the
    /// app reads and draws. A shared file, when there is one, is merged into it
    /// rather than read from (`LibrarySync`).
    static var library: PatternLibrary {
        get {
            migrateIfNeeded()
            return sync.library
        }
        set { sync.save(newValue) }
    }

    /// The loop that keeps this machine's file level with a shared one. One
    /// instance, rebuilt when the file it reads changes.
    private static var syncInstance: LibrarySync?

    static var sync: LibrarySync {
        if let syncInstance, syncInstance.localURL == FavoritesFile.url { return syncInstance }
        let made = LibrarySync(localURL: FavoritesFile.url,
                               sharedURL: sharedURL,
                               device: DeviceIdentity.current)
        made.onChange = {
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
        made.didPublish = { url in
            // Fresh bookmark for the folder it went into: a bookmark can go
            // stale, and a stale one sends the next launch down the path.
            LibraryLocation.remember(url.deletingLastPathComponent())
        }
        // Held *before* it does anything. Its first merge announces what it
        // brings back, and anything reading the library on that announcement
        // asks for this property again — which, with the instance not yet
        // stored, built a second one (`LibrarySync.init`).
        syncInstance = made
        made.start()
        return made
    }

    /// Where the library is published, or nil while it is kept to this Mac.
    /// Set by the Favorites tab (stage 5 of the plan); remembered as a
    /// security-scoped bookmark, not as a path.
    ///
    /// Held here rather than read back off the sync: building a sync needs to
    /// know where it publishes, so asking the sync for it would be asking it to
    /// exist before it does.
    /// The folder the library is published to, or nil while it is kept to this
    /// Mac. Set by the Favorites tab (§11).
    ///
    /// A folder rather than a file, because that is what the sandbox grants
    /// durably (`LibraryLocation`); the file inside it is the app's to name.
    static var sharedFolder: URL? {
        get {
            if !restoredLocation {
                restoredLocation = true
                publishedFolder = LibraryLocation.restore()
            }
            return publishedFolder
        }
        set {
            restoredLocation = true
            publishedFolder = newValue
            guard let newValue else {
                LibraryLocation.forget()
                sync.sharedURL = nil
                return
            }
            LibraryLocation.remember(newValue)
            sync.sharedURL = LibraryLocation.file(in: newValue)
        }
    }

    /// The file *this machine* writes — inside the folder, named by the app
    /// after this Mac. Everyone else's sit beside it (`LibrarySync`).
    static var sharedURL: URL? { sharedFolder.map { LibraryLocation.file(in: $0) } }

    /// Publishes into `folder`, deciding what to do with a library already
    /// there — the question a second machine's first publish asks (§11).
    static func publish(to folder: URL, adopting: LibrarySync.Adoption) {
        restoredLocation = true
        publishedFolder = folder
        LibraryLocation.remember(folder)
        sync.publish(to: folder, adopting: adopting)
    }

    /// What is in the folder being joined — empty, holding patterns, or there
    /// and unreadable.
    static func inspectShared(in folder: URL) -> LibrarySync.SharedFileState {
        sync.inspectShared(in: folder)
    }

    /// When the library and the shared file were last agreed.
    static var lastPublished: Date? { sync.lastPublished }

    /// Why the library could not be published, if it could not — the file
    /// moved in the Finder, a drive not mounted, a folder this app was never
    /// given. The list is unaffected; the tab is where it is said.
    static var publishError: Error? { sync.publishError }

    /// Starts the library: reads it, and — when it is published somewhere —
    /// merges whatever the shared file holds and begins watching it.
    ///
    /// Called at launch and whenever the app comes forward. Until this existed
    /// the library was built on first use, so a machine that had not opened the
    /// Find bar was not watching the file at all: a pattern added on the other
    /// Mac (or by hand) arrived only after something happened to ask for the
    /// favourites. Coming forward syncs too — a Mac that was asleep hears about
    /// nothing while it sleeps, and the watcher cannot report what it did not
    /// see.
    static func start() {
        sync.sync()
    }

    /// What is wrong with the library, in a few words, or nil when nothing is.
    ///
    /// One wording for every place that has to say it — the Favorites tab and
    /// the Find bar's menu — because a problem the user meets in two places
    /// under two names is two problems as far as they can tell (§11).
    static var syncProblem: String? {
        let count = conflicts.count
        if count > 0 {
            return count == 1 ? "1 conflicting change" : "\(count) conflicting changes"
        }
        guard sharedFolder != nil else { return nil }
        if !LibraryLocation.hasAccess { return "no access to the library folder" }
        if publishError != nil { return "not syncing" }
        return nil
    }

    /// Whether this app may still write where the library lives.
    static var hasFolderAccess: Bool {
        sharedFolder == nil || LibraryLocation.hasAccess
    }

    /// Applies the user's answers to a merge that had questions, and publishes
    /// the result (§11).
    static func resolve(_ answers: [UUID: LibraryResolution]) {
        sync.resolve(answers)
    }

    private static var publishedFolder: URL?
    private static var restoredLocation = false

    /// What a merge could not decide. While this is non-empty the library is
    /// read-only until the user has answered (§11).
    static var conflicts: [LibraryConflict] { sync.conflicts }

    /// Whether the last answer failed to take, because the shared library
    /// changed again before it could be published.
    static var answerDidNotTake: Bool { sync.answerDidNotTake }

    /// Why the library could not be read or written, if it could not. Nil when
    /// all is well; the Favorites tab is where it will be said.
    static var loadError: Error? { sync.loadError }

    /// Forgets everything read from the current file — called when the file the
    /// store reads changes, and by tests standing in for a launch.
    static func forgetLastGood() {
        syncInstance = nil
        restoredLocation = false
        publishedFolder = nil
    }

    // MARK: - Writing

    /// Replaces the list — what the form saves, including a reorder, an edit and
    /// a removal. The order given is the order kept.
    ///
    /// Two things happen here that a plain assignment would miss, and both are
    /// what lets another machine make sense of the result
    /// (`Design/FAVORITES_SYNC_PLAN.md`):
    ///
    /// - an entry whose *content* changed is stamped with the time and this
    ///   machine, since that is what says it was edited rather than merely
    ///   carried along;
    /// - an entry that is gone leaves a **tombstone**. An entry that is simply
    ///   absent is indistinguishable from one the other machine has never seen,
    ///   and a merge would put it back.
    static func replace(with entries: [SearchPatternEntry]) {
        var updated = library
        let before = Dictionary(updated.entries.map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first })
        let now = Date()
        let stamped = entries.map { entry -> SearchPatternEntry in
            guard let old = before[entry.id], old != entry else { return entry }
            var edited = entry
            edited.modifiedAt = now
            edited.device = DeviceIdentity.current
            return edited
        }
        let survivors = Set(stamped.map(\.id))
        for gone in updated.entries where !survivors.contains(gone.id) {
            updated.tombstones.append(PatternLibrary.Tombstone(id: gone.id, deletedAt: now,
                                                               device: DeviceIdentity.current))
        }
        updated.setOrder(stamped)
        library = updated
    }

    /// Keeps `entry`, at the end of the list.
    ///
    /// Returns false when the same search is already kept — same pattern, same
    /// encoding, same case rule — because a second copy of it under another
    /// name is two answers to one question. The caller offers to rename the
    /// one that is there instead (§11).
    @discardableResult
    static func add(_ entry: SearchPatternEntry) -> Bool {
        var updated = library
        guard !updated.entries.contains(where: { $0.isSameSearch(as: entry) }) else { return false }
        var kept = entry
        kept.sortKey = PatternLibrary.sortKey(between: updated.ordered.last?.sortKey, and: nil)
        kept.modifiedAt = Date()
        kept.device = DeviceIdentity.current
        updated.entries.append(kept)
        library = updated
        return true
    }

    /// The kept entry for the same search as `entry`, if there is one — what
    /// "already in your favourites, as *Foo*" is read from.
    static func existing(for entry: SearchPatternEntry) -> SearchPatternEntry? {
        favorites.first { $0.isSameSearch(as: entry) }
    }

    // MARK: - Migration

    /// Moves a library kept under the old `UserDefaults` key into the file,
    /// once. Entries arrive with ids minted on the way — they never had any —
    /// and in the order they were stored.
    private static func migrateIfNeeded() {
        guard let rows = defaults.array(forKey: userDefaultsKey) as? [[String: Any]] else { return }
        defer { defaults.removeObject(forKey: userDefaultsKey) }
        let entries = rows.compactMap(SearchPatternEntry.init(stored:))
        // A file that already holds patterns is the newer truth: a key left
        // behind by an older build must not overwrite it.
        guard !entries.isEmpty, (try? FavoritesFile.read())?.local.entries.isEmpty ?? true else { return }
        var migrated = PatternLibrary()
        migrated.setOrder(entries)
        try? FavoritesFile.write(FavoritesDocument(local: migrated))
        syncInstance = nil
    }
}
