import Foundation
import DumpCompareCore

/// One machine's copy of the pattern library, and the loop that keeps it level
/// with the other machines' (`Design/FAVORITES_SYNC_PLAN.md`).
///
/// The local file is the **truth**: read at launch, written on every change,
/// always there. A folder the user syncs — iCloud Drive, a stick, a git
/// checkout — is the **medium** the machines exchange state through, and it can
/// be unmounted, half-downloaded or busy while the Find bar still has to list
/// patterns. So nothing here reads the folder to answer a question about the
/// library; it reads it to merge.
///
/// **One file per machine.** This Mac writes exactly one file in that folder
/// and never touches another's; it reads every file it finds there and merges
/// each into its own library against the state the two last agreed on. Nothing
/// in the folder has two writers, so the sync provider has nothing to
/// arbitrate: no "last write wins", no conflicted copies, and — the failure
/// that made this necessary — no version silently discarded when two machines
/// wrote while one was offline. A disagreement is then a question for the user,
/// which is the only correct answer, and it is asked on both machines because
/// both can see both files.
///
/// One instance per collection, so a test can make two of them over one folder
/// and be two machines.
///
/// Generic in the *kind* of collection (`SyncedCollectionKind`): none of this
/// is about patterns. A folder, a file per machine, a three-way merge and a
/// question the user answers are what anything the app wants on every Mac will
/// need, and writing it twice is how two of them come to disagree.
final class FolderSync<Kind: SyncedCollectionKind> {
    typealias Item = Kind.Item
    typealias Folder = SyncFolder<Kind>
    /// This machine's file — the truth, and the bases beside it.
    let localURL: URL
    /// The file *this machine* writes in the shared folder, or nil while the
    /// library is kept to this Mac. Everyone else's files sit beside it.
    var sharedURL: URL? {
        didSet {
            guard sharedURL != oldValue else { return }
            watcher?.stop()
            watcher = nil
            stopPresenting()
            poll?.invalidate()
            poll = nil
            if sharedURL == nil {
                // Unpublished: nothing to have agreed with any more.
                document.bases = [:]
                saveLocal()
            } else {
                watchShared()
                sync()
            }
        }
    }

    /// The folder the machines share, derived from this machine's file in it.
    var sharedFolder: URL? { sharedURL?.deletingLastPathComponent() }

    /// This machine's name in a version vector.
    let device: String

    /// Fired after the library changes for any reason — a local edit, or a
    /// merge bringing in someone else's. The store turns it into its own
    /// notification, which every Find bar menu and the Favorites tab follow.
    var onChange: (() -> Void)?

    /// Fired after each successful publish, with the file written.
    ///
    /// What it is for: an atomic write replaces the file, and a security-scoped
    /// bookmark taken against the one before it goes stale. A stale bookmark
    /// means the next launch reaches the file by path instead — which, for a
    /// folder macOS protects, is the system asking the user for permission all
    /// over again. Taking a fresh bookmark on the way past is what keeps the
    /// second launch quiet.
    var didPublish: ((URL) -> Void)?

    /// What the merge could not decide. While this is non-empty the library is
    /// read-only — nothing new may be added or edited until the user has
    /// answered (§11). This machine's file goes on saying what this machine
    /// believes, so the other Mac is asked about the same disagreement.
    private(set) var conflicts: [SyncConflict<Item>] = []

    /// True when the user answered and the answer did not take — the merge
    /// straight after it asked again, because another machine's file had moved
    /// on. Says what an unchanged window otherwise leaves them to guess.
    private(set) var answerDidNotTake = false

    /// Why the local file could not be read or written, if it could not.
    private(set) var loadError: Error?
    /// Why the folder could not be reached, if it could not. Not an error the
    /// user has to act on — the truth is safe locally — but the Favorites tab
    /// says when the library was last published.
    private(set) var publishError: Error?
    /// When the library and the folder were last agreed.
    private(set) var lastPublished: Date?

    private var document: SyncDocument<Item>
    /// What is on disk, so a save that would write the same bytes is skipped.
    private var savedDocument: SyncDocument<Item>?
    private var watcher: FileChangeWatcher?
    private var localWatcher: FileChangeWatcher?
    /// One per file being watched: the folder, so a machine writing for the
    /// first time is noticed, and each library file in it, so a provider that
    /// fetches on demand fetches.
    private var presenters: [URL: LibraryFilePresenter] = [:]
    private var poll: Timer?

    /// How often the folder is asked about when nothing has said it changed. A
    /// backstop, not the mechanism: the presenters are what carry a change
    /// promptly, and this is for the providers that do not announce one. Cheap
    /// — a few kilobytes read and, almost always, a merge that finds nothing to
    /// do. A `var` so tests need not wait a minute.
    static var pollInterval: TimeInterval {
        get { FolderSyncSettings.pollInterval }
        set { FolderSyncSettings.pollInterval = newValue }
    }

    /// Reads this machine's file and nothing else.
    ///
    /// **No syncing here.** Merging announces what it brings back, an
    /// announcement is what makes the app read the library, and reading the
    /// library is what builds this object: an initialiser that syncs is an
    /// initialiser that re-enters itself, and the second instance it produces
    /// has its own idea of what is agreed and what is still a question. That is
    /// how a table could show the other machine's version while the line above
    /// it still asked which version to keep — two libraries, one window.
    ///
    /// `start()` is where the work goes, once the owner holds the instance.
    init(localURL: URL, sharedURL: URL? = nil, device: String) {
        self.localURL = localURL
        self.sharedURL = sharedURL
        self.device = device
        document = SyncDocument<Item>()
        loadLocal()
        watchLocal()
    }

    /// Begins watching the folder and merges what is in it. Called by the owner
    /// after it has taken hold of the instance.
    func start() {
        // One line at startup, so which build is running is a fact rather than
        // a memory. Two Macs sharing a library must be on the same one: an
        // older build discards what a newer one asks about, and the newer one
        // then defers to it in good faith.
        NSLog("DumpCompare library: starting, rules of %@, device %@, writing %@",
              Self.rulesVersion, String(device.prefix(8)),
              sharedURL?.lastPathComponent ?? "this Mac only")
        guard sharedURL != nil else { return }
        watchShared()
        sync()
    }

    /// Bumped whenever the merging rules change in a way that matters between
    /// machines — what to quote when two Macs disagree about a library.
    static var rulesVersion: String { FolderSyncSettings.rulesVersion }

    deinit {
        watcher?.stop()
        localWatcher?.stop()
        for presenter in presenters.values { presenter.stop() }
        poll?.invalidate()
    }

    // MARK: - The library

    /// What this machine believes — what the app reads and draws.
    var library: SyncedCollection<Item> { document.local }

    /// The state last agreed with each machine's file, by that file's name.
    var bases: [String: SyncedCollection<Item>] { document.bases }

    /// Records a change made here, and publishes it.
    ///
    /// Refused while a conflict is unanswered: editing a list the user has been
    /// asked about is the one way this design can lose a pattern.
    func save(_ library: SyncedCollection<Item>) {
        guard conflicts.isEmpty else { return }
        var written = library
        written.vector.increment(for: device)
        document.local = written
        saveLocal()
        onChange?()
        sync()
    }

    /// Applies the user's answers and publishes the result.
    ///
    /// Answering is not only a choice about entries, it is this machine saying
    /// it has **seen** the versions it was asked about. Both halves matter:
    /// without the second, the next merge finds the same versions differing
    /// from the same bases and asks again — the answer is applied, nothing is
    /// published, and the library stays wedged, which is exactly what an Apply
    /// that appeared to do nothing was.
    ///
    /// So each version a question was about becomes the base for that file, and
    /// its counters are merged into ours: from here on this machine has seen
    /// everything those versions knew, and the result is simply newer.
    func resolve(_ answers: [UUID: SyncResolution]) {
        NSLog("DumpCompare library: answering %d question(s) with %@",
              conflicts.count, String(describing: answers.values.map { "\($0)" }))
        guard !conflicts.isEmpty else {
            NSLog("DumpCompare library: nothing to answer — the questions had already gone")
            return
        }
        let outcome = SyncMerge<Item>.Outcome(library: document.local, conflicts: conflicts)
        var resolved = SyncMerge<Item>.resolve(outcome, with: answers)
        // What the answers are *about*: the versions in the folder, read afresh
        // rather than remembered, so an answer given after a relaunch — or
        // after a file moved on — still counts as having seen it.
        for (name, asked) in conflictedWith {
            let seen = sharedFolder
                .flatMap { try? readShared(at: $0.appendingPathComponent(name)) } ?? asked
            resolved.vector = resolved.vector.merged(with: seen.vector)
            document.bases[name] = seen
        }
        resolved.vector.increment(for: device)
        conflicts = []
        conflictedWith = [:]
        answerDidNotTake = false
        document.local = resolved
        saveLocal()
        onChange?()
        sync()
        // Answered, and asked again: a file moved while the sheet was open, so
        // the answer was about a version that is no longer there.
        answerDidNotTake = !conflicts.isEmpty
        NSLog("DumpCompare library: after answering — %d question(s), local=%@ %@, error=%@",
              conflicts.count, Self.describe(document.local.ordered),
              Self.describe(document.local.vector), String(describing: publishError))
    }

    /// The versions the outstanding questions are about, by file — what
    /// answering them means this machine has seen.
    private var conflictedWith: [String: SyncedCollection<Item>] = [:]

    // MARK: - Joining a folder that already holds patterns

    /// What to do when the folder pointed at is not empty — the one moment two
    /// libraries meet (`Design/FAVORITES_SYNC_PLAN.md`).
    enum Adoption {
        /// Keep both lists. The default, and the case that actually happens:
        /// twelve patterns on one machine and three on the other should make
        /// fifteen.
        case merge
        /// Start from what the folder holds, dropping what this machine had.
        case takeTheFile
        /// Keep this machine's list and remove the rest from the folder. The
        /// only destructive answer, so it is never the default.
        case replaceTheFile
    }

    /// Publishes into `folder`, deciding what to do with what is already there.
    ///
    /// The two decided answers are carried out with *tombstones*, not by
    /// writing over anyone's file: this machine only ever writes its own, and a
    /// deletion the other machines will honour is the honest way to say "that
    /// list is not the one we are keeping".
    func publish(to folder: URL, adopting: Adoption) {
        let ourFile = Folder.file(in: folder, device: device)
        switch adopting {
        case .merge:
            // No bases: this machine has never agreed anything with these
            // files, so everything either side holds is kept.
            document.bases = [:]
            sharedURL = ourFile
        case .takeTheFile:
            document.bases = [:]
            let theirs = folderLibrary(in: folder, excluding: ourFile)
            var mine = document.local
            let keep = Set(theirs.entries.map(\.id))
            for entry in mine.entries where !keep.contains(entry.id) {
                mine.tombstones.append(.init(id: entry.id, device: device))
            }
            mine.entries = mine.entries.filter { keep.contains($0.id) }
            var taken = SyncMerge<Item>.merge(base: nil, ours: mine, theirs: theirs,
                                           assumeConcurrent: true).library
            taken.vector.increment(for: device)
            document.local = taken
            saveLocal()
            onChange?()
            sharedURL = ourFile
        case .replaceTheFile:
            let theirs = folderLibrary(in: folder, excluding: ourFile)
            var mine = document.local
            let ours = Set(mine.entries.map(\.id))
            for entry in theirs.entries where !ours.contains(entry.id) {
                mine.tombstones.append(.init(id: entry.id, device: device))
            }
            mine.vector = mine.vector.merged(with: theirs.vector)
            mine.vector.increment(for: device)
            document.local = mine
            document.bases = [:]
            saveLocal()
            sharedURL = ourFile
        }
    }

    /// Everything the folder's files say, merged into one library — what a
    /// machine joining the folder is joining.
    private func folderLibrary(in folder: URL, excluding ourFile: URL?) -> SyncedCollection<Item> {
        var library = SyncedCollection<Item>()
        for url in Folder.libraryFiles(in: folder)
        where url.lastPathComponent != ourFile?.lastPathComponent {
            guard let theirs = try? readShared(at: url) else { continue }
            library = SyncMerge<Item>.merge(base: nil, ours: library, theirs: theirs,
                                         assumeConcurrent: true).library
        }
        return library
    }

    /// What is in the folder being joined — the question the tab has to ask
    /// before it publishes anything.
    enum SharedFileState: Equatable {
        /// Nothing there, or libraries with no patterns in them: nothing to
        /// reconcile, so nothing to ask about.
        case empty
        /// Libraries with patterns, which is the one moment two libraries meet.
        case patterns(Int)
        /// There are files and they cannot be read as libraries — not
        /// downloaded yet, damaged, or something else entirely. **Never**
        /// treated as empty: that road ends with the app publishing into a
        /// folder whose library it could not read.
        case unreadable
    }

    /// Reads the folder the way joining it would.
    func inspectShared(in folder: URL) -> SharedFileState {
        let files = Folder.libraryFiles(in: folder)
            .filter { $0.lastPathComponent != sharedURL?.lastPathComponent }
        guard !files.isEmpty else { return .empty }
        var library = SyncedCollection<Item>()
        var read = false
        for url in files {
            // A file in iCloud Drive may be a placeholder the machine has not
            // downloaded yet; asking for it is the difference between "empty
            // library" and "wait a moment".
            guard let theirs = try? readShared(at: url) else { continue }
            library = SyncMerge<Item>.merge(base: nil, ours: library, theirs: theirs,
                                         assumeConcurrent: true).library
            read = true
        }
        guard read else { return .unreadable }
        return library.entries.isEmpty ? .empty : .patterns(library.entries.count)
    }

    // MARK: - The loop

    /// Merges every machine's file into this one's library and writes this
    /// machine's own back — the same work in both directions, since a merge is
    /// symmetrical and any side may have moved.
    func sync() {
        guard let ourURL = sharedURL else { return }
        let before = document.local.ordered
        let hadConflicts = !conflicts.isEmpty
        var problems: [Error] = []
        var raised: [SyncConflict<Item>] = []
        var asked: [String: SyncedCollection<Item>] = [:]

        // This machine's own file is read like any other. Nothing else writes
        // it, so a difference can only be a hand edit or a copy restored from a
        // backup — both of which are things somebody meant.
        for url in Folder.libraryFiles(in: ourURL.deletingLastPathComponent()) {
            do {
                try absorb(url, raising: &raised, asking: &asked)
            } catch {
                problems.append(error)
            }
        }
        conflicts = raised
        conflictedWith = asked

        do {
            // Written even while a question stands. The file is **this
            // machine's own**, and what it holds is what this machine believes
            // — the conflicted entry as it is here, not a half-merged list. Two
            // Macs that changed the same entry must both be asked, and the
            // other Mac cannot ask about a version it was never shown: holding
            // the file back is what used to leave the second machine unaware,
            // carrying on with a version the first had already disagreed with.
            //
            // Only when this machine's file would actually say something
            // different.
            //
            // Writing an identical library still touches the file, and a
            // touched file in a synced folder is an upload, which is a download
            // on the other machine, which wakes its merge, which writes an
            // identical library back. Two machines then sync each other in a
            // circle for ever and nothing ever arrives — which is exactly what
            // a cloud client showing endless activity is telling you.
            //
            // Compared — and written — in the one canonical form, or two
            // machines holding the same facts in different array orders each
            // rewrite in their own and never stop.
            //
            // And when the file knows *less* than this machine does, even
            // though it lists the same patterns. What it would be missing is
            // the record of whose versions this machine has seen — which is
            // how an answer travels: keeping this machine's version changes no
            // pattern in the file and everything about whether the other Mac
            // may take it. Left out, an answer on one Mac settled nothing on
            // the other. The counters only ever join, so this settles: once
            // both files carry the join, neither has anything left to add.
            let ours = document.local
            let onDisk = try readShared(at: ourURL)
            if onDisk.canonical.entries != ours.canonical.entries
                || onDisk.canonical.tombstones != ours.canonical.tombstones
                || !onDisk.vector.dominates(ours.vector) {
                try writeShared(ours, to: ourURL)
                didPublish?(ourURL)
                document.bases[ourURL.lastPathComponent] = ours
            } else {
                // Left alone, so what is agreed with it is what it holds — not
                // what this machine holds. They differ by the counters this
                // machine has picked up from elsewhere since, and recording
                // ours would make the next round call the file stale and
                // rewrite it, once per counter, for ever.
                document.bases[ourURL.lastPathComponent] = onDisk
            }
            lastPublished = Date()
        } catch {
            problems.append(error)
        }
        saveLocal()
        announceIfChanged(from: before, hadConflicts: hadConflicts)
        presentEveryFile()

        // A folder that cannot be reached — not mounted, still downloading,
        // locked by the sync client — is not a failure to report to anyone. The
        // truth is already safe locally, and the next change or the next
        // external event tries again.
        publishError = problems.first
        if let publishError {
            // Also to the log: a failure that only a settings tab can show is a
            // failure nobody quotes, and this one took several rounds to name.
            NSLog("DumpCompare: could not publish the pattern library to %@ — %@",
                  ourURL.path, String(describing: publishError))
        }
    }

    /// Merges one machine's file into this machine's library.
    private func absorb(_ url: URL, raising raised: inout [SyncConflict<Item>],
                        asking asked: inout [String: SyncedCollection<Item>]) throws {
        let name = url.lastPathComponent
        var theirs = SyncedCollection<Item>()
        var thrown: Error?
        var coordinationError: NSError?
        // Coordinated as this app's presenter, so our own writes do not come
        // back to us as somebody else's change — which, with a publish at the
        // end of every merge, would be a loop. Read-only: another machine's
        // file is never ours to write.
        NSFileCoordinator(filePresenter: presenters[url]).coordinate(
            readingItemAt: url, options: .withoutChanges, error: &coordinationError
        ) { url in
            do { theirs = try readShared(at: url) } catch { thrown = error }
        }
        if let error = thrown ?? coordinationError { throw error }

        let agreed = document.bases[name]
        // A file edited by hand says something new and carries no evidence of
        // having been written: nothing bumped its version counters, so "we have
        // seen everything it knows about" is true of the counters and false of
        // the bytes. Without this a pattern typed into the file is dropped, and
        // the next publish leaves it behind.
        //
        // The test is against what the two last *agreed*, not against what this
        // machine holds: the base is a copy of the file as it was when they
        // agreed, so a file whose counters have not moved since then and whose
        // content has can only have been written by something that does not
        // keep counters.
        let editedOutsideTheApp = agreed.map {
            theirs.vector == $0.vector && theirs.canonical != $0.canonical
        } ?? false
        // A base is only a base while the file *descends* from it. If the
        // file's version has not seen everything the base had, the two have no
        // common past worth the name, and every difference is a question rather
        // than a rule.
        let base = agreed.flatMap { theirs.vector.dominates($0.vector) ? $0 : nil }
        // A file whose counters cover everything this machine has written is a
        // file written by a machine that has *seen* this one's version — which,
        // while a question stands, only happens when somebody answered it over
        // there. So it is taken, and the question here goes away with it: an
        // answer given on one Mac settles the same disagreement on the other,
        // which is the whole point of asking both.
        //
        // What makes that safe is the rule below: a machine that is only
        // *asking* never folds the other's counters into its own, so it can
        // never claim to have seen a version it has not accepted.
        let ourVersionBefore = document.local.vector
        let outcome = SyncMerge<Item>.merge(base: base, ours: document.local, theirs: theirs,
                                         assumeConcurrent: editedOutsideTheApp)
        document.local = outcome.library
        guard outcome.isResolved else {
            // A question keeps this machine's version *where it was*. The merge
            // counts the other side's writes as seen, which is right when it
            // produced an answer and wrong when it produced a question: with
            // their counters folded in, the next sync finds this machine simply
            // newer, takes its version, and the disagreement the user was about
            // to settle has settled itself in their favour.
            document.local.vector = ourVersionBefore
            raised.append(contentsOf: outcome.conflicts)
            asked[name] = theirs
            // A question is rare and expensive to diagnose from the outside —
            // the three libraries that produced it are gone by the time anyone
            // asks. So it says what it merged.
            NSLog("DumpCompare library: %d question(s) from %@ — base=%@ %@ ours=%@ %@ theirs=%@ %@",
                  outcome.conflicts.count, name,
                  Self.describe(base?.ordered), Self.describe(base?.vector),
                  Self.describe(document.local.ordered), Self.describe(document.local.vector),
                  Self.describe(theirs.ordered), Self.describe(theirs.vector))
            return
        }
        // Agreed with that machine, up to the version just read: what its next
        // version will be compared against.
        document.bases[name] = theirs
    }

    /// What this Mac is called, for the person who opens the folder.
    static var thisMachine: String {
        get { FolderSyncSettings.thisMachine }
        set { FolderSyncSettings.thisMachine = newValue }
    }

    /// One line's worth of a library, for the log.
    static func describe(_ entries: [Item]?) -> String {
        guard let entries else { return "—" }
        return "[" + entries.map { "\($0.label)/\($0.id.uuidString.prefix(8))" }
            .joined(separator: ", ") + "]"
    }

    static func describe(_ vector: VersionVector?) -> String {
        guard let vector else { return "—" }
        return "{" + vector.counters.sorted { $0.key < $1.key }
            .map { "\($0.key.prefix(8)):\($0.value)" }.joined(separator: " ") + "}"
    }

    /// Announces only what a reader would notice: the patterns as they are
    /// listed, or a question appearing or going away.
    private func announceIfChanged(from before: [Item], hadConflicts: Bool) {
        guard document.local.ordered != before || hadConflicts != !conflicts.isEmpty else { return }
        onChange?()
    }

    /// Asks the provider for a file only when this machine does not have the
    /// current version.
    ///
    /// Asking unconditionally, once a minute, is asking a cloud client to do
    /// something once a minute — which is what "it never stops syncing" looks
    /// like from the outside, even when nothing is written.
    private func materialiseIfNeeded(_ url: URL) {
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        guard status != nil, status != .current else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    private func readShared(at url: URL) throws -> SyncedCollection<Item> {
        guard FileManager.default.fileExists(atPath: url.path) else { return SyncedCollection<Item>() }
        do {
            return try SyncedCollection<Item>(fileContents: Data(contentsOf: url))
        } catch {
            // Not downloaded yet is the common one, and it is temporary: ask
            // for the file and let the error stand this time round. Throwing is
            // what stops this machine from acting on a file it has not read.
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw error
        }
    }

    private func writeShared(_ library: SyncedCollection<Item>, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Stamped on the way out, every time: a merge can bring another
        // machine's copy in whole, and this machine must not sign its file with
        // somebody else's name. It is also the one place a Mac's *current* name
        // enters the folder — the filename cannot carry it, since a name a
        // network hands out would move the file.
        var written = library
        written.machine = Self.thisMachine
        var thrown: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: presenters[url]).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError
        ) { url in
            do {
                try written.canonical.fileContents().write(to: url, options: .atomic)
            } catch {
                thrown = error
            }
        }
        if let error = thrown ?? coordinationError { throw error }
    }

    /// Watches the folder the way an open dump is watched (§5.5), so another
    /// machine's change arrives without anyone pressing anything.
    private func watchShared() {
        guard let ourURL = sharedURL, let folder = sharedFolder else { return }
        // A folder that does not exist yet cannot be watched, and neither can
        // an empty one usefully: writing this machine's file is also what makes
        // the folder a library folder.
        if !FileManager.default.fileExists(atPath: ourURL.path) {
            try? writeShared(document.local, to: ourURL)
        }
        // The *folder*, not one file: a machine publishing for the first time
        // adds a file, which no file watcher would ever hear about.
        let watcher = FileChangeWatcher(url: folder)
        watcher.onChange = { [weak self] in
            guard let self else { return }
            watcher.rebind(to: self.sharedFolder)
            self.sync()
        }
        self.watcher = watcher
        presentEveryFile()

        // And a slow backstop for the providers that announce nothing.
        poll?.invalidate()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            guard let self, let folder = self.sharedFolder else { return }
            for url in Folder.libraryFiles(in: folder) { self.materialiseIfNeeded(url) }
            self.sync()
        }
        // Common modes, so it keeps ticking while a menu is open or a sheet is
        // up: those are exactly the moments the user is looking at the library.
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    /// Registers this app's interest in the folder and in every library file in
    /// it.
    ///
    /// A watcher hears about the *disk*. A cloud provider does not write the
    /// disk when another machine changes a file — it fetches the new version
    /// when something asks for it, which is why a change used to arrive only
    /// after the file had been opened in the Finder. A presenter is this app
    /// asking, from now on. The set is refreshed after every sync, because a
    /// machine that has just joined has a file nobody was presenting.
    private func presentEveryFile() {
        guard let folder = sharedFolder else { return }
        var wanted = Set([folder])
        wanted.formUnion(Folder.libraryFiles(in: folder))
        for (url, presenter) in presenters where !wanted.contains(url) {
            presenter.stop()
            presenters[url] = nil
        }
        for url in wanted where presenters[url] == nil {
            presenters[url] = LibraryFilePresenter(url: url) { [weak self] in self?.sync() }
        }
    }

    private func stopPresenting() {
        for presenter in presenters.values { presenter.stop() }
        presenters = [:]
    }

    // MARK: - This machine's file

    private func loadLocal() {
        do {
            guard FileManager.default.fileExists(atPath: localURL.path) else { return }
            document = try SyncDocument<Item>(fileContents: Data(contentsOf: localURL))
            savedDocument = document
            loadError = nil
        } catch {
            // A file that cannot be read is not an empty library: showing no
            // patterns would read as "they are gone", and the next write would
            // make that true. The document stays as it was and the reason is
            // kept for the Favorites tab to say.
            loadError = error
        }
    }

    private func saveLocal() {
        // The same rule as the shared files, for the same reason on a smaller
        // scale: a poll that found nothing must not rewrite this machine's file
        // every minute, waking its own watcher each time.
        guard document != savedDocument else { return }
        do {
            try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try document.fileContents().write(to: localURL, options: .atomic)
            savedDocument = document
            loadError = nil
            // An atomic write replaces the file, so a watcher bound to the old
            // one is watching something unlinked — and on a fresh install there
            // was nothing to bind to until now.
            localWatcher?.rebind(to: localURL)
            if localWatcher == nil { watchLocal() }
        } catch {
            loadError = error
        }
    }

    /// Re-reads this machine's file — after something outside wrote it, and in
    /// tests standing in for a launch.
    func reloadLocal() {
        loadLocal()
    }

    /// Watches this machine's own file as well as the shared folder.
    ///
    /// It is the app's storage, but it is also JSON on purpose: the argument
    /// for a file at all was that a library can be read, diffed and edited. So
    /// a pattern added with a text editor arrives the way one added on another
    /// Mac does, instead of sitting there until the next launch and being
    /// overwritten by the next save.
    private func watchLocal() {
        guard FileManager.default.fileExists(atPath: localURL.path) else { return }
        let watcher = FileChangeWatcher(url: localURL)
        watcher.onChange = { [weak self] in
            guard let self else { return }
            watcher.rebind(to: self.localURL)
            self.takeLocalEditsFromDisk()
        }
        localWatcher = watcher
    }

    /// Adopts a change made to the local file by something other than this app.
    ///
    /// Only when it says something new: every save writes that file, and each
    /// of those writes comes back through the watcher. Announcing them would
    /// rebuild every Find bar menu twice per keystroke.
    private func takeLocalEditsFromDisk() {
        let before = document
        loadLocal()
        guard document != before else { return }
        onChange?()
        // What was typed into the file is a change like any other, so it is
        // published — otherwise it would be undone by the next merge.
        sync()
    }
}


/// What every `FolderSync` works to, whatever it carries.
///
/// Beside the class rather than in it: a generic type cannot hold a stored
/// static, and none of these depend on what is being synced.
enum FolderSyncSettings {
    /// How often a folder is asked about when nothing has said it changed. A
    /// backstop, not the mechanism — the presenters carry a change promptly,
    /// and this is for the providers that announce nothing. A `var` so tests
    /// need not wait a minute.
    static var pollInterval: TimeInterval = 60

    /// Bumped whenever the merging rules change in a way that matters between
    /// machines — what to quote when two Macs disagree.
    static let rulesVersion = "2026-09-06a"

    /// What this Mac is called, for the person who opens the folder. A `var` so
    /// a test can be a differently-named machine.
    static var thisMachine = Host.current().localizedName ?? ""
}

/// The pattern library's own loop, under the name the app has always used.
typealias LibrarySync = FolderSync<PatternLibraryKind>
