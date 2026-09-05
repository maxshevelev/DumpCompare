import DumpCompareCore
import XCTest
@testable import DumpCompare

/// Stage 6 of `Design/FAVORITES_SYNC_PLAN.md`: what the user meets when the
/// merge could not decide, and what the app does with files in the folder that
/// are not a machine's library.
///
/// Two machines are two `LibrarySync`s over one folder, each writing its own
/// file (as in `LibrarySyncTests`); the tab and the sheet are driven directly,
/// with the sheet's presentation behind a seam.
@MainActor
final class LibraryConflictTests: XCTestCase {
    private var suiteName = ""
    private var store: UserDefaults!
    private var localFile: URL!
    private var folder: URL!

    override func setUp() {
        super.setUp()
        (suiteName, store) = isolatedDefaults(for: self)
        FavoritePatternStore.defaults = store
        localFile = isolatedFavoritesFile(for: self)
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LibraryConflictTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        FavoritePatternStore.sharedFolder = nil
        FavoritePatternStore.defaults = .standard
        discardIsolatedFavoritesFile(localFile)
        try? FileManager.default.removeItem(at: folder)
        discardIsolatedDefaults(suiteName, store)
        store = nil
        super.tearDown()
    }

    /// The other machine's file — what "theirs" means in here.
    private var sharedURL: URL {
        folder.appendingPathComponent(LibraryLocation.fileName(for: "other-mac"))
    }

    /// This machine's own file in the folder.
    private var ourURL: URL { LibraryLocation.file(in: folder) }

    private func entry(_ name: String, _ pattern: String,
                       id: UUID = UUID()) -> SearchPatternEntry {
        SearchPatternEntry(id: id, name: name, pattern: pattern, encoding: .hex)
    }

    /// The other machine, publishing to the same file.
    private func otherMac() -> LibrarySync {
        let sync = LibrarySync(localURL: folder.appendingPathComponent("other/Favorites.json"),
                               sharedURL: sharedURL, device: "other-mac")
        sync.start()
        return sync
    }

    private func rename(_ id: UUID, to name: String, in sync: LibrarySync) {
        var library = sync.library
        library.entries = library.entries.map {
            var entry = $0
            if entry.id == id { entry.name = name }
            return entry
        }
        sync.save(library)
    }

    /// Sets up the one case that matters: both machines rename the same entry
    /// before either sees the other. Returns the entry's id.
    ///
    /// The question lands on whichever machine syncs *second* — the first one
    /// published and knows nothing about the second's version, which is exactly
    /// how a sync client's window behaves. Here that machine is this one.
    @discardableResult
    private func makeAConflict() -> UUID {
        let shared = entry("ME FPT", "$FPT")
        FavoritePatternStore.add(shared)
        FavoritePatternStore.sharedFolder = folder

        let other = otherMac()                       // takes the file as it stands
        let id = FavoritePatternStore.favorites[0].id
        FavoritePatternStore.sharedFolder = nil      // this machine loses sight of the file
        rename(id, to: "Intel ME FPT", in: FavoritePatternStore.sync)
        rename(id, to: "ME region table", in: other) // the other publishes its version
        FavoritePatternStore.sharedFolder = folder   // and this one comes back to find it
        return id
    }

    /// One library, one object. Merging announces what it brings back, and
    /// anything that reads the library on that announcement asks the store for
    /// it again — which, while the instance was still being built, built a
    /// second one. Two objects then held two ideas of what was agreed and what
    /// was still a question, and the tab showed one machine's list above the
    /// other's unanswered question.
    func testTheStoreNeverBuildsASecondLibrary() throws {
        FavoritePatternStore.add(entry("ME FPT", "$FPT"))
        FavoritePatternStore.sharedFolder = folder

        // Something for the first merge to bring back, so building the library
        // announces — which is the moment the second one used to appear.
        var theirs = PatternLibrary()
        theirs.setOrder([entry("from another Mac", "22")])
        theirs.vector = VersionVector(["other-mac": 9])
        try theirs.fileContents().write(to: sharedURL)
        FavoritePatternStore.forgetLastGood()          // as a launch would

        var seenFromInsideTheAnnouncement: [ObjectIdentifier] = []
        let token = NotificationCenter.default.addObserver(
            forName: FavoritePatternStore.didChangeNotification, object: nil, queue: nil) { _ in
            seenFromInsideTheAnnouncement.append(ObjectIdentifier(FavoritePatternStore.sync))
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let built = ObjectIdentifier(FavoritePatternStore.sync)   // builds and starts it

        XCTAssertFalse(seenFromInsideTheAnnouncement.isEmpty,
                       "the premise: building it announced something")
        XCTAssertTrue(seenFromInsideTheAnnouncement.allSatisfy { $0 == built },
                      "every reader saw the same library")
    }

    // MARK: - The tab

    /// The tab says how many questions there are and offers the sheet, rather
    /// than throwing a modal in front of someone mid-search.
    func testTheTabOffersToResolveRatherThanInterrupting() {
        makeAConflict()
        let tab = FavoritePatternsSettingsViewController()
        _ = tab.view
        tab.reload()

        XCTAssertFalse(tab.resolveButton.isHidden)
        XCTAssertTrue(tab.locationLabel.stringValue.contains("conflicting change"),
                      tab.locationLabel.stringValue)
        XCTAssertEqual(tab.locationLabel.textColor, .systemRed,
                       "it asks for something only the user can settle")
    }

    /// An answer that cannot be published must say so. Otherwise Apply is a
    /// button that changes nothing, gives no reason, and leaves the same
    /// question on screen — which is what it looked like from outside.
    ///
    /// (While the question still stands nothing is written at all, so there is
    /// no failure to report yet: the write is attempted by the *answer*.)
    func testAnAnswerThatCannotBePublishedSaysSo() throws {
        let id = makeAConflict()
        // Nothing may be written to the folder any more, which is what a lost
        // permission looks like from in here. (A folder that *vanishes* is not
        // the same thing: the library is simply republished into it.)
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: folder.path)
        }

        FavoritePatternStore.resolve([id: .keepOurs])

        XCTAssertTrue(FavoritePatternStore.conflicts.isEmpty, "the answer was applied")
        XCTAssertNotNil(FavoritePatternStore.publishError, "and it could not be published")

        let tab = FavoritePatternsSettingsViewController()
        _ = tab.view
        tab.reload()
        XCTAssertTrue(tab.locationLabel.stringValue.contains("cannot be published"),
                      tab.locationLabel.stringValue)
        XCTAssertEqual(tab.locationLabel.textColor, .systemRed)
    }

    /// And the library is read-only while the question stands: nothing may be
    /// written until it is answered, so the table stops offering to change it.
    ///
    /// Read-only, not dead: a row can still be selected and read, which is how
    /// the user decides what to answer. Disabling the table took that away
    /// along with the editing.
    func testTheLibraryIsReadOnlyButStillReadable() throws {
        makeAConflict()
        let tab = FavoritePatternsSettingsViewController()
        _ = tab.view
        tab.reload()

        XCTAssertFalse(tab.addButton.isEnabled)
        tab.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(tab.table.selectedRow, 0, "a row can still be picked and read")
        XCTAssertFalse(tab.removeButton.isEnabled)
        XCTAssertEqual(tab.fieldForTests(row: 0, name: true)?.isEditable, false)
        XCTAssertEqual(tab.encodingPopupForTests(row: 0)?.isEnabled, false)

        // The list itself is still there to read, and still searchable.
        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name), ["Intel ME FPT"])
    }

    /// And the Find bar says it too, in red, on the row that leads to the
    /// place it can be answered. A conflict only the Settings window mentions
    /// is a silent state: the library has stopped syncing and stopped being
    /// editable, and the bar is where the user actually is.
    func testTheFindBarsMenuCarriesTheProblem() throws {
        makeAConflict()
        let bar = FindBarView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = bar
        bar.prepareForShow()

        let menu = try XCTUnwrap(bar.patternMenuForTests)
        let manage = try XCTUnwrap(menu.items.first {
            ($0.attributedTitle?.string ?? $0.title).hasPrefix("Manage Favorites…")
        })
        let title = try XCTUnwrap(manage.attributedTitle)
        XCTAssertTrue(title.string.contains("1 conflicting change"), title.string)
        XCTAssertNotNil(manage.image, "and it is marked")

        var colours: [NSColor] = []
        title.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: title.length)) {
            value, _, _ in
            if let colour = value as? NSColor { colours.append(colour) }
        }
        XCTAssertTrue(colours.contains(.systemRed), "the problem is red")

        // Answered, and the row goes back to being a plain command.
        FavoritePatternStore.resolve([FavoritePatternStore.conflicts[0].id: .keepOurs])
        bar.prepareForShow()
        let after = try XCTUnwrap(bar.patternMenuForTests?.items.first {
            ($0.attributedTitle?.string ?? $0.title).hasPrefix("Manage Favorites…")
        })
        XCTAssertNil(after.image)
        XCTAssertFalse((after.attributedTitle?.string ?? "").contains("conflicting"))
    }

    // MARK: - The sheet

    /// One row per conflict, saying what each side holds — "renamed here,
    /// renamed there" — and every row starts on this machine's version, so
    /// leaving the sheet alone changes nothing.
    func testTheSheetShowsBothSidesOfEachConflict() throws {
        makeAConflict()
        let sheet = LibraryConflictSheetController(conflicts: FavoritePatternStore.conflicts) { _ in }
        _ = sheet.view

        XCTAssertEqual(sheet.conflictCountForTests, 1)
        let row = try XCTUnwrap(sheet.rowForTests(0))
        XCTAssertEqual(row.pattern, "Intel ME FPT", "the row says which entry it is about")
        // Each side in full — the name *and* the pattern. Two sides that
        // disagree about the pattern under one name would otherwise read as a
        // choice between two identical things.
        XCTAssertTrue(row.ours.contains("Intel ME FPT"), row.ours)
        XCTAssertTrue(row.ours.contains("\"$FPT\""), row.ours)
        XCTAssertTrue(row.theirs.contains("ME region table"), row.theirs)
        XCTAssertTrue(row.theirs.contains("\"$FPT\""), row.theirs)
        XCTAssertEqual(sheet.answers.values.first, .keepOurs)
    }

    /// Answering applies to the library and clears the questions, and the
    /// result is published — the other machine takes it from the file.
    func testAnsweringResolvesAndPublishes() throws {
        let id = makeAConflict()
        let tab = FavoritePatternsSettingsViewController()
        _ = tab.view
        var presented: LibraryConflictSheetController?
        tab.presentResolver = { presented = $0 }
        tab.reload()

        tab.resolveButton.performClick(nil)
        let sheet = try XCTUnwrap(presented)
        _ = sheet.view
        sheet.chooseForTests(.keepTheirs, row: 0)
        sheet.handleSubmit()

        XCTAssertTrue(FavoritePatternStore.conflicts.isEmpty)
        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name), ["ME region table"])
        let published = try PatternLibrary(fileContents: Data(contentsOf: ourURL))
        XCTAssertEqual(published.ordered.map(\.name), ["ME region table"])
        XCTAssertEqual(FavoritePatternStore.favorites.first?.id, id, "the same entry, renamed")
    }

    /// Keeping this machine's version is an answer too, and it publishes.
    func testKeepingMineIsAnAnswer() throws {
        makeAConflict()
        let sheet = LibraryConflictSheetController(conflicts: FavoritePatternStore.conflicts) { answers in
            FavoritePatternStore.resolve(answers)
        }
        _ = sheet.view

        sheet.keepAllMineForTests()
        sheet.handleSubmit()

        XCTAssertTrue(FavoritePatternStore.conflicts.isEmpty)
        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name), ["Intel ME FPT"])
        let published = try PatternLibrary(fileContents: Data(contentsOf: ourURL))
        XCTAssertEqual(published.ordered.map(\.name), ["Intel ME FPT"])
    }

    /// Until the sheet is answered the questions stand and the library stays
    /// read-only — opening the sheet and leaving it is not an answer, which is
    /// why its other button says "Later" rather than "Cancel".
    func testTheQuestionsStandUntilTheSheetIsAnswered() {
        makeAConflict()
        let sheet = LibraryConflictSheetController(conflicts: FavoritePatternStore.conflicts) { answers in
            FavoritePatternStore.resolve(answers)
        }
        _ = sheet.view
        sheet.chooseForTests(.keepTheirs, row: 0)

        XCTAssertFalse(FavoritePatternStore.conflicts.isEmpty, "choosing is not applying")

        sheet.handleSubmit()

        XCTAssertTrue(FavoritePatternStore.conflicts.isEmpty)
    }

    /// A question that has answered itself must not wedge the library for ever.
    ///
    /// The other machine can adopt this one's version while the sheet is still
    /// unopened — and until this was fixed, the merge was never run again:
    /// nothing published, nothing could be edited, and the only way out was to
    /// answer a question that no longer existed.
    func testAQuestionThatAnsweredItselfClearsOnTheNextSync() throws {
        let id = makeAConflict()
        XCTAssertFalse(FavoritePatternStore.conflicts.isEmpty, "the premise")

        // The other machine takes this one's version.
        var theirs = try PatternLibrary(fileContents: Data(contentsOf: sharedURL))
        theirs.entries = FavoritePatternStore.library.entries
        theirs.vector = theirs.vector.merged(with: FavoritePatternStore.library.vector)
        try theirs.fileContents().write(to: sharedURL)

        FavoritePatternStore.sync.sync()

        XCTAssertTrue(FavoritePatternStore.conflicts.isEmpty,
                      "there is nothing left to disagree about")
        XCTAssertEqual(FavoritePatternStore.favorites.first?.id, id)
    }

    /// An answer given on the other Mac settles the question here too, so a
    /// resolver standing open is asking about something already decided — and
    /// its Apply would find nothing to apply. It closes itself, and the tab
    /// says why: a sheet that vanishes on its own is otherwise a mystery.
    func testTheResolverClosesWhenTheQuestionIsAnsweredElsewhere() throws {
        let id = makeAConflict()
        let tab = FavoritePatternsSettingsViewController()
        _ = tab.view
        var presented: LibraryConflictSheetController?
        tab.presentResolver = { presented = $0 }
        tab.reload()
        tab.resolveButton.performClick(nil)
        let sheet = try XCTUnwrap(presented)
        _ = sheet.view

        // The other machine answers, keeping this machine's version — which
        // reaches here as a file whose counters cover everything we wrote.
        let other = otherMac()
        XCTAssertEqual(other.conflicts.count, 1, "the premise: it is asked too")
        other.resolve([id: .keepTheirs])
        FavoritePatternStore.sync.sync()

        XCTAssertTrue(FavoritePatternStore.conflicts.isEmpty, "settled here as well")
        XCTAssertTrue(sheet.closedBecauseTheQuestionsChanged, "and the sheet went with it")
        XCTAssertTrue(tab.messageForTests.contains("answered on your other Mac"),
                      tab.messageForTests)
    }

    /// Answering *in* the sheet is not the same event: it closes by its own
    /// Apply, and nothing tells the user their other Mac did anything.
    func testAnsweringHereDoesNotReadAsTheOtherMacAnswering() throws {
        makeAConflict()
        let tab = FavoritePatternsSettingsViewController()
        _ = tab.view
        var presented: LibraryConflictSheetController?
        tab.presentResolver = { presented = $0 }
        tab.reload()
        tab.resolveButton.performClick(nil)
        let sheet = try XCTUnwrap(presented)
        _ = sheet.view

        sheet.handleSubmit()

        XCTAssertTrue(FavoritePatternStore.conflicts.isEmpty)
        XCTAssertFalse(sheet.closedBecauseTheQuestionsChanged)
        XCTAssertFalse(tab.messageForTests.contains("other Mac"), tab.messageForTests)
    }

    // MARK: - What else is in the folder

    /// A copy a sync client left behind is **not** the app's to read, fold in
    /// or remove.
    ///
    /// It used to do all three, on the theory that nobody ever opens
    /// "DumpCompare Patterns 2.json". Taking part in a provider's conflicts is
    /// what one file with two writers forced; with one file per machine there
    /// are none to take part in, and a file a provider could not decide about
    /// is the user's to look at.
    func testACopyLeftBySyncClientIsLeftAlone() throws {
        FavoritePatternStore.add(entry("mine", "11"))
        FavoritePatternStore.sharedFolder = folder

        var stray = PatternLibrary()
        stray.setOrder([entry("left behind by the sync", "22")])
        let copies = ["DumpCompare Patterns 2.json",
                      "DumpCompare Patterns (A93F1C0D22B7) 2.json",
                      "DumpCompare Patterns (A93F1C0D22B7) (Max's conflicted copy 2026-09-05).json"]
        for name in copies {
            try stray.fileContents().write(to: folder.appendingPathComponent(name))
        }

        FavoritePatternStore.sync.sync()

        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name), ["mine"],
                       "nothing was folded in")
        for name in copies {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path),
                "and \(name) is still there for the user to look at")
        }
    }

    /// A file the user named is theirs as well — only the app's own naming is
    /// a library.
    func testAFileTheUserNamedIsLeftAlone() throws {
        FavoritePatternStore.add(entry("mine", "11"))
        FavoritePatternStore.sharedFolder = folder

        var backup = PatternLibrary()
        backup.setOrder([entry("from the backup", "33")])
        let backupURL = folder.appendingPathComponent("DumpCompare Patterns backup.json")
        try backup.fileContents().write(to: backupURL)

        FavoritePatternStore.sync.sync()

        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name), ["mine"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }

    /// The naming itself, stated once: a machine's stamp in brackets, and
    /// nothing else. Anything a person or a sync client put in that folder is
    /// not one of these files.
    func testWhichNamesAreALibraryFile() {
        for name in ["DumpCompare Patterns (A93F1C0D22B7).json",
                     LibraryLocation.fileName(for: "any machine")] {
            XCTAssertTrue(LibraryLocation.isLibraryFile(name), name)
        }
        for name in ["DumpCompare Patterns.json",
                     "DumpCompare Patterns 2.json",
                     "DumpCompare Patterns (A93F1C0D22B7) 2.json",
                     "DumpCompare Patterns (A93F1C0D22B7) (conflicted copy).json",
                     "DumpCompare Patterns (a93f1c0d22b7).json",
                     "DumpCompare Patterns (A93F1C0D22B).json",
                     "DumpCompare Patterns ().json",
                     "DumpCompare Patterns backup.json",
                     "Other Patterns (A93F1C0D22B7).json",
                     "DumpCompare Patterns (A93F1C0D22B7).txt"] {
            XCTAssertFalse(LibraryLocation.isLibraryFile(name), name)
        }
    }
}
