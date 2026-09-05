import DumpCompareCore
import XCTest
@testable import DumpCompare

/// Stage 4 of `Design/FAVORITES_SYNC_PLAN.md`: the loop that keeps one
/// machine's library level with the other machines' files.
///
/// Two `LibrarySync` instances over one folder *are* two machines — each with
/// its own local file, its own file in the folder, its own name in a version
/// vector, and no knowledge of the other except through the folder. That is the
/// whole point of the type being an object rather than a global: the
/// interesting cases need two of them, and none of them needs a window or a
/// network.
final class LibrarySyncTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LibrarySyncTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        folder = nil
        super.tearDown()
    }

    /// The file a given machine writes — one each, which is the whole design.
    private func file(of device: String) -> URL {
        folder.appendingPathComponent(LibraryLocation.fileName(for: device))
    }

    /// A machine: its own local file, its own name, its own file in the folder.
    private func machine(_ name: String, publishing: Bool = true) -> LibrarySync {
        let sync = LibrarySync(localURL: folder.appendingPathComponent("\(name)/Favorites.json"),
                               sharedURL: publishing ? file(of: name) : nil,
                               device: name)
        sync.start()
        return sync
    }

    private func entry(_ name: String, _ pattern: String,
                       id: UUID = UUID()) -> SearchPatternEntry {
        SearchPatternEntry(id: id, name: name, pattern: pattern, encoding: .hex)
    }

    /// Adds an entry the way the store does — through `save`, which is what
    /// publishes.
    @discardableResult
    private func add(_ entry: SearchPatternEntry, to machine: LibrarySync) -> SearchPatternEntry {
        var library = machine.library
        var placed = entry
        placed.sortKey = PatternLibrary.sortKey(between: library.ordered.last?.sortKey, and: nil)
        placed.device = machine.device
        library.entries.append(placed)
        machine.save(library)
        return placed
    }

    private func names(_ machine: LibrarySync) -> [String] { machine.library.ordered.map(\.name) }

    /// What a file in the folder says.
    private func names(in url: URL) throws -> [String] {
        try PatternLibrary(fileContents: Data(contentsOf: url)).ordered.map(\.name)
    }

    private func modified(_ url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    /// Rewrites a machine's file the way a text editor or a restored backup
    /// would: new content, and nothing to say it was written.
    private func edit(_ url: URL, _ change: (inout PatternLibrary) -> Void) throws {
        var library = try PatternLibrary(fileContents: Data(contentsOf: url))
        change(&library)
        try library.fileContents().write(to: url, options: .atomic)
    }

    // MARK: - The medium

    /// What one machine keeps reaches the other through the folder, and nothing
    /// else: no shared object, no notification between them.
    func testWhatOneMachineKeepsReachesTheOther() {
        let desk = machine("desk")
        let laptop = machine("laptop")

        add(entry("ME FPT", "$FPT"), to: desk)
        laptop.sync()

        XCTAssertEqual(names(laptop), ["ME FPT"])
    }

    /// **One file per machine**, which is what makes a sync provider's
    /// arbitration impossible: this Mac writes its own and never anybody
    /// else's, so there is no file two machines can both have written between
    /// one sync and the next.
    func testEachMachineWritesOnlyItsOwnFile() throws {
        let desk = machine("desk")
        let laptop = machine("laptop")
        add(entry("from the desk", "11"), to: desk)
        laptop.sync()
        add(entry("from the laptop", "22"), to: laptop)

        let deskFileTouched = try modified(file(of: "desk"))
        for _ in 0..<3 { laptop.sync() }

        XCTAssertEqual(try modified(file(of: "desk")), deskFileTouched,
                       "the laptop never writes the desk's file")
        XCTAssertEqual(Set(try names(in: file(of: "laptop"))),
                       ["from the desk", "from the laptop"],
                       "it says everything it knows in its own")
        XCTAssertEqual(try names(in: file(of: "desk")), ["from the desk"],
                       "and the desk's file is still the desk's own word")
    }

    /// A third machine reads the whole folder, not one file: everything either
    /// of the other two has ever said is in it.
    func testAThirdMachineTakesEverythingInTheFolder() {
        let desk = machine("desk")
        let laptop = machine("laptop")
        add(entry("from the desk", "11"), to: desk)
        add(entry("from the laptop", "22"), to: laptop)

        let mini = machine("mini")

        XCTAssertEqual(Set(names(mini)), ["from the desk", "from the laptop"])
        XCTAssertTrue(mini.conflicts.isEmpty, "two machines saying different things is not a conflict")
    }

    /// Twelve here and three there make fifteen — the case the feature exists
    /// for, and it asks nothing.
    func testTwoMachinesAddingSeparatelyEndUpWithBoth() {
        let desk = machine("desk")
        let laptop = machine("laptop")
        add(entry("ME FPT", "$FPT"), to: desk)
        laptop.sync()

        add(entry("desk pattern", "11"), to: desk)
        add(entry("laptop pattern", "22"), to: laptop)
        desk.sync()
        laptop.sync()

        XCTAssertTrue(desk.conflicts.isEmpty)
        XCTAssertEqual(Set(names(desk)), ["ME FPT", "desk pattern", "laptop pattern"])
        XCTAssertEqual(Set(names(laptop)), Set(names(desk)), "and both machines agree")
    }

    /// A deletion travels as a deletion: the tombstone is what makes it
    /// distinguishable from an entry the other machine has never seen.
    func testADeletionTravels() {
        let desk = machine("desk")
        let laptop = machine("laptop")
        let doomed = add(entry("mistake", "11"), to: desk)
        laptop.sync()
        XCTAssertEqual(names(laptop), ["mistake"], "the premise")

        var library = desk.library
        library.entries.removeAll { $0.id == doomed.id }
        library.tombstones.append(PatternLibrary.Tombstone(id: doomed.id, device: "desk"))
        desk.save(library)
        laptop.sync()

        XCTAssertTrue(names(laptop).isEmpty)
    }

    /// Which Mac wrote a file is *inside* it, since the name cannot carry it:
    /// a hostname moves, and a file that moves with it is a machine writing a
    /// second file and abandoning the first.
    func testTheFileSaysWhichMacWroteIt() throws {
        let previous = LibrarySync.thisMachine
        LibrarySync.thisMachine = "Maxim's Mac mini"
        defer { LibrarySync.thisMachine = previous }

        let desk = machine("desk")
        add(entry("ME FPT", "$FPT"), to: desk)

        let written = try PatternLibrary(fileContents: Data(contentsOf: file(of: "desk")))
        XCTAssertEqual(written.machine, "Maxim's Mac mini")
    }

    /// And renaming the Mac renames nothing: the file stays where it is, and
    /// what it says about the patterns has not changed, so nothing is written.
    func testRenamingTheMacIsNotAChangeToTheLibrary() throws {
        let previous = LibrarySync.thisMachine
        LibrarySync.thisMachine = "Mac mini"
        defer { LibrarySync.thisMachine = previous }

        let desk = machine("desk")
        add(entry("ME FPT", "$FPT"), to: desk)
        let settled = try modified(file(of: "desk"))

        LibrarySync.thisMachine = "Something Else Entirely"
        for _ in 0..<3 { desk.sync() }

        XCTAssertEqual(try modified(file(of: "desk")), settled,
                       "a Mac's name is not what the library says")
        XCTAssertEqual(try names(in: file(of: "desk")), ["ME FPT"])
    }

    // MARK: - The truth is local    // MARK: - The truth is local

    /// The library is readable with the folder gone: the app draws from this
    /// machine's file, and a drive that is not mounted is not an empty list.
    func testTheLibraryStandsWithoutTheSharedFolder() throws {
        let desk = machine("desk")
        add(entry("ME FPT", "$FPT"), to: desk)

        try FileManager.default.removeItem(at: file(of: "desk"))
        desk.sync()

        XCTAssertEqual(names(desk), ["ME FPT"])
    }

    /// And editing while it is unreachable is ordinary: the changes are kept
    /// locally and published when the folder comes back — offline edits are one
    /// more concurrent writer, which is the case the merge is for.
    func testEditingWhileTheFolderIsAwayPublishesLater() {
        let desk = machine("desk")
        let laptop = machine("laptop")
        add(entry("shared", "11"), to: desk)
        laptop.sync()

        // The drive goes away for the desk, which goes on being used.
        desk.sharedURL = nil
        add(entry("typed offline", "22"), to: desk)
        XCTAssertEqual(Set(names(desk)), ["shared", "typed offline"])

        // And comes back.
        desk.sharedURL = file(of: "desk")
        laptop.sync()

        XCTAssertEqual(Set(names(laptop)), ["shared", "typed offline"])
    }

    /// This machine's file carries both roles — what it believes, and what it
    /// last agreed with each machine's file — written together, so a launch
    /// picks up bases that belong to the truth beside them.
    func testTheLocalFileKeepsTheTruthAndTheBasesTogether() throws {
        let desk = machine("desk")
        add(entry("ME FPT", "$FPT"), to: desk)

        let document = try FavoritesDocument(
            fileContents: Data(contentsOf: folder.appendingPathComponent("desk/Favorites.json")))

        XCTAssertEqual(document.local.ordered.map(\.name), ["ME FPT"])
        XCTAssertEqual(document.bases[file(of: "desk").lastPathComponent]?.ordered.map(\.name),
                       ["ME FPT"], "published, so the two agree")
    }

    /// One base per machine, because there is one file per machine: what this
    /// Mac last agreed with the laptop says nothing about the desk.
    func testEachMachinesFileHasItsOwnBase() {
        let desk = machine("desk")
        let laptop = machine("laptop")
        add(entry("from the desk", "11"), to: desk)
        add(entry("from the laptop", "22"), to: laptop)
        let mini = machine("mini")

        XCTAssertEqual(Set(mini.bases.keys),
                       [file(of: "desk").lastPathComponent,
                        file(of: "laptop").lastPathComponent,
                        file(of: "mini").lastPathComponent])
    }

    /// Nothing published, nothing agreed: with no folder there is no base,
    /// because there is nobody to have agreed with.
    func testAnUnpublishedLibraryHasNoBase() {
        let alone = machine("alone", publishing: false)
        add(entry("ME FPT", "$FPT"), to: alone)

        XCTAssertTrue(alone.bases.isEmpty)
        XCTAssertEqual(names(alone), ["ME FPT"])
    }

    // MARK: - Edited by hand

    /// The file is JSON on purpose — a library can be read, diffed and edited —
    /// so a pattern typed into it with a text editor has to arrive.
    ///
    /// It carries no evidence of having been written: nothing bumps the version
    /// counters, so "we have seen everything that file knows about" is true and
    /// wrong. This is the case that used to drop the entry and then write over
    /// it on the next publish.
    func testAPatternTypedIntoThisMachinesFileByHandArrives() throws {
        let desk = machine("desk")
        add(entry("kept in the app", "11"), to: desk)

        try edit(file(of: "desk")) { $0.entries.append(entry("typed into the file", "22")) }
        desk.sync()

        XCTAssertEqual(Set(names(desk)), ["kept in the app", "typed into the file"])
        XCTAssertEqual(Set(try names(in: file(of: "desk"))),
                       ["kept in the app", "typed into the file"],
                       "and it is not written over")
    }

    /// A line deleted by hand is not a deletion — there is no tombstone, and
    /// absence is not evidence. It comes back, which is the safe way round for
    /// a file anyone may edit.
    func testALineDeletedByHandComesBack() throws {
        let desk = machine("desk")
        add(entry("first", "11"), to: desk)
        add(entry("second", "22"), to: desk)

        try edit(file(of: "desk")) { $0.entries.removeAll { $0.name == "second" } }
        desk.sync()

        XCTAssertEqual(Set(names(desk)), ["first", "second"])
    }

    /// A change in the folder reaches the app without anyone pressing anything:
    /// the folder is watched, and the watcher survives files being replaced
    /// rather than written in place, which is how every editor and every sync
    /// client saves.
    func testAnotherMachinesWriteArrivesOnItsOwn() throws {
        let previousDebounce = FileChangeWatcher.debounceInterval
        FileChangeWatcher.debounceInterval = 0.05
        defer { FileChangeWatcher.debounceInterval = previousDebounce }

        let desk = machine("desk")
        add(entry("kept in the app", "11"), to: desk)

        // The other machine's file appears, and then changes: a folder watcher
        // is what hears the first, and there is nothing to press for either.
        var theirs = PatternLibrary()
        for name in ["first from the laptop", "second from the laptop"] {
            theirs.entries.append(entry(name, name.hasPrefix("first") ? "22" : "33"))
            theirs.vector.increment(for: "laptop")
            try theirs.fileContents().write(to: file(of: "laptop"), options: .atomic)

            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, !names(desk).contains(name) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertTrue(names(desk).contains(name),
                          "\(name) must arrive without anyone pressing anything")
        }
    }

    /// Nothing has to ask for the favourites for the library to be current: a
    /// Mac that has not opened the Find bar since launch is still a Mac whose
    /// library should be up to date, and a machine that was asleep heard
    /// nothing while it slept.
    func testStartingTheLibraryTakesWhatTheFolderHolds() throws {
        let desk = machine("desk")
        add(entry("from the desk", "11"), to: desk)

        // A second machine that has never looked at the folder, built the way
        // the app builds it at launch.
        let laptop = LibrarySync(localURL: folder.appendingPathComponent("laptop/Favorites.json"),
                                 sharedURL: file(of: "laptop"), device: "laptop")
        laptop.start()

        XCTAssertEqual(names(laptop), ["from the desk"],
                       "building it is enough; nothing had to ask for a pattern")

        // And a later catch-up takes what arrived while it was not looking.
        add(entry("arrived while asleep", "22"), to: desk)
        laptop.sync()

        XCTAssertEqual(Set(names(laptop)), ["from the desk", "arrived while asleep"])
    }

    /// A cloud provider does not write the disk when another machine changes a
    /// file: it fetches the new version when something asks for it. So the app
    /// asks — a file presenter says it is interested, and a slow poll covers
    /// the providers that announce nothing. Without either, a change arrived
    /// only after the file had been opened in the Finder.
    func testTheLibraryAsksForChangesRatherThanWaitingToBeTold() throws {
        let previousInterval = LibrarySync.pollInterval
        LibrarySync.pollInterval = 0.1
        defer { LibrarySync.pollInterval = previousInterval }

        // Built after the interval is short, since the timer is scheduled when
        // the machine starts publishing.
        let desk = machine("desk")
        add(entry("kept here", "11"), to: desk)

        // Another machine's change, arriving as bytes with nothing to announce
        // it — the watcher's events are deliberately not what this test relies
        // on, since a provider produces none.
        var theirs = PatternLibrary()
        theirs.entries.append(entry("from the other Mac", "22"))
        theirs.vector = VersionVector(["laptop": 9])
        try theirs.fileContents().write(to: file(of: "laptop"))

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !names(desk).contains("from the other Mac") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertTrue(names(desk).contains("from the other Mac"),
                      "nobody pressed anything and nobody opened the Finder")
    }

    /// A sync that has nothing to say leaves the file alone.
    ///
    /// Writing an identical library still touches the file, and a touched file
    /// in a synced folder is an upload — which is a download on the other
    /// machine, which wakes its merge, which writes back. The two then sync each
    /// other in a circle for ever, which is what a cloud client showing endless
    /// activity is telling you.
    func testSyncingWithNothingToSayDoesNotTouchTheFile() throws {
        let desk = machine("desk")
        add(entry("ME FPT", "$FPT"), to: desk)
        let written = try modified(file(of: "desk"))

        for _ in 0..<5 { desk.sync() }

        XCTAssertEqual(try modified(file(of: "desk")), written, "five syncs, no writes")
    }

    /// Two machines hold the same facts in different array orders — each merge
    /// puts its own entries first — and that must not be a difference. It was:
    /// each side rewrote its file in its own order, the other saw a change, and
    /// the cloud client never stopped moving.
    func testAnotherArrayOrderIsNotAChange() throws {
        let desk = machine("desk")
        add(entry("first", "11"), to: desk)
        add(entry("second", "22"), to: desk)

        // The same library, the same sort keys, the array the other way round.
        try edit(file(of: "desk")) { $0.entries.reverse() }
        let written = try modified(file(of: "desk"))

        for _ in 0..<3 { desk.sync() }

        XCTAssertEqual(try modified(file(of: "desk")), written,
                       "nothing was said, so nothing was written")
        XCTAssertEqual(names(desk), ["first", "second"], "and the order shown is the sort keys'")
    }

    /// And two machines reach a state where neither writes any more — the
    /// difference between "synced" and "syncing for ever".
    func testTwoMachinesSettle() throws {
        let desk = machine("desk")
        let laptop = machine("laptop")
        add(entry("from the desk", "11"), to: desk)
        laptop.sync()
        add(entry("from the laptop", "22"), to: laptop)
        desk.sync()
        laptop.sync()
        desk.sync()

        let settledDesk = try modified(file(of: "desk"))
        let settledLaptop = try modified(file(of: "laptop"))

        for _ in 0..<3 {
            desk.sync()
            laptop.sync()
        }

        XCTAssertEqual(try modified(file(of: "desk")), settledDesk, "nobody writes once they agree")
        XCTAssertEqual(try modified(file(of: "laptop")), settledLaptop)
        XCTAssertEqual(Set(names(desk)), Set(names(laptop)))
        XCTAssertEqual(Set(names(desk)), ["from the desk", "from the laptop"])
    }

    // MARK: - Concurrent writes

    /// The window the sync client leaves open: both machines change the same
    /// entry before either sees the other. Nothing is decided, nothing is
    /// written, and each machine goes on showing its own.
    func testTwoMachinesRenamingOneEntryIsAQuestion() throws {
        let desk = machine("desk")
        let laptop = machine("laptop")
        let shared = add(entry("ME FPT", "$FPT"), to: desk)
        laptop.sync()

        // Neither sees the other while it writes: two edits, one window.
        laptop.sharedURL = nil
        rename(shared, to: "Intel ME FPT", on: desk)
        rename(shared, to: "ME region table", on: laptop)
        laptop.sharedURL = file(of: "laptop")   // rejoins, and finds the desk's version

        XCTAssertEqual(laptop.conflicts.count, 1, "the laptop is asked")
        XCTAssertEqual(names(laptop), ["ME region table"],
                       "and goes on showing what it believes meanwhile")
        XCTAssertEqual(try names(in: file(of: "laptop")), ["ME region table"],
                       "each file says what its own machine believes")
        XCTAssertEqual(try names(in: file(of: "desk")), ["Intel ME FPT"],
                       "and neither holds a half-merged list")
    }

    /// A race ends as a question **on both machines**, and neither of them
    /// decides it alone.
    ///
    /// A machine that is asking still publishes its own file: the file is its
    /// own belief, not a half-merged list, and the other Mac cannot be asked
    /// about a version it was never shown. Holding it back left the second
    /// machine carrying on, unaware, with a version the first had already
    /// disagreed with.
    func testARaceIsAQuestionOnBothMachines() throws {
        let desk = machine("desk")
        let laptop = machine("laptop")
        let shared = add(entry("ME FPT", "$FPT"), to: desk)
        laptop.sync()

        laptop.sharedURL = nil
        rename(shared, to: "Intel ME FPT", on: desk)
        rename(shared, to: "ME region table", on: laptop)
        laptop.sharedURL = file(of: "laptop")
        desk.sync()

        XCTAssertEqual(laptop.conflicts.count, 1)
        XCTAssertEqual(desk.conflicts.count, 1)
        XCTAssertEqual(names(laptop), ["ME region table"], "each keeps its own meanwhile")
        XCTAssertEqual(names(desk), ["Intel ME FPT"])
    }

    /// And answering on one machine settles it on the other, without anybody
    /// answering the same question twice.
    ///
    /// What carries the answer is the counters: a machine only counts another's
    /// writes as seen when it has *accepted* that version, which is what
    /// answering does. So a file whose counters cover everything this machine
    /// wrote was written by a machine that saw this one's version and decided
    /// — and this machine takes it. A machine that is merely asking never folds
    /// the other's counters in, so it can never claim that by accident.
    func testAnAnswerOnOneMachineSettlesTheOther() throws {
        let desk = machine("desk")
        let laptop = machine("laptop")
        let shared = add(entry("ME FPT", "$FPT"), to: desk)
        laptop.sync()

        laptop.sharedURL = nil
        rename(shared, to: "Intel ME FPT", on: desk)
        rename(shared, to: "ME region table", on: laptop)
        laptop.sharedURL = file(of: "laptop")
        desk.sync()
        XCTAssertEqual(desk.conflicts.count, 1, "the premise: both are asked")

        laptop.resolve([shared.id: .keepOurs])
        desk.sync()

        XCTAssertTrue(desk.conflicts.isEmpty, "the answer settles it here too")
        XCTAssertEqual(names(desk), ["ME region table"])
        XCTAssertEqual(names(laptop), ["ME region table"])
    }

    /// But when both versions do reach the folder — each machine published
    /// before the other's file had arrived, which is the window a cloud leaves
    /// open — both are asked. Which is the honest answer: neither version is
    /// the app's to discard.
    func testBothMachinesAreAskedWhenBothVersionsReachTheFolder() throws {
        let desk = machine("desk")
        let laptop = machine("laptop")
        let shared = add(entry("ME FPT", "$FPT"), to: desk)
        laptop.sync()

        // The desk publishes its version, and it is still on its way down: the
        // laptop cannot see the file yet, so it publishes its own knowing
        // nothing about it.
        rename(shared, to: "Intel ME FPT", on: desk)
        let inTransit = folder.appendingPathComponent("in-transit")
        try FileManager.default.moveItem(at: file(of: "desk"), to: inTransit)
        rename(shared, to: "ME region table", on: laptop)
        try FileManager.default.moveItem(at: inTransit, to: file(of: "desk"))

        laptop.sync()
        desk.sync()

        XCTAssertEqual(laptop.conflicts.count, 1)
        XCTAssertEqual(desk.conflicts.count, 1)
        XCTAssertEqual(names(laptop), ["ME region table"], "each keeps its own meanwhile")
        XCTAssertEqual(names(desk), ["Intel ME FPT"])
    }

    /// While a question stands the library is read-only: a save is refused
    /// rather than quietly overwriting the answer the user has not given.
    func testNothingIsSavedWhileAQuestionStands() {
        let desk = machine("desk")
        let laptop = machine("laptop")
        let shared = add(entry("ME FPT", "$FPT"), to: desk)
        laptop.sync()
        laptop.sharedURL = nil

        rename(shared, to: "desk name", on: desk)
        rename(shared, to: "laptop name", on: laptop)
        laptop.sharedURL = file(of: "laptop")
        XCTAssertFalse(laptop.conflicts.isEmpty, "the premise")

        add(entry("while unresolved", "99"), to: laptop)

        XCTAssertEqual(names(laptop), ["laptop name"], "the save was refused")
    }

    /// Answering it publishes the answer, and the other machine takes it.
    func testAnsweringPublishesTheResult() {
        let desk = machine("desk")
        let laptop = machine("laptop")
        let shared = add(entry("ME FPT", "$FPT"), to: desk)
        laptop.sync()
        laptop.sharedURL = nil

        rename(shared, to: "desk name", on: desk)
        rename(shared, to: "laptop name", on: laptop)
        laptop.sharedURL = file(of: "laptop")

        laptop.resolve([shared.id: .keepTheirs])
        desk.sync()

        XCTAssertTrue(laptop.conflicts.isEmpty)
        XCTAssertEqual(names(laptop), ["desk name"])
        XCTAssertEqual(names(desk), ["desk name"], "and both machines agree again")
    }

    /// Keeping *this* machine's version is an answer like any other, and it has
    /// to publish. It did not: the answer was applied and then the next merge
    /// found the same two versions differing from the same base and asked
    /// again, so nothing was written and both machines stayed in conflict with
    /// the file untouched.
    ///
    /// Answering is also this machine saying it has seen the other's version —
    /// that is what makes the result simply newer rather than another
    /// disagreement.
    func testKeepingMyVersionPublishesIt() throws {
        let desk = machine("desk")
        let laptop = machine("laptop")
        let shared = add(entry("ME FPT", "$FPT"), to: desk)
        laptop.sync()

        // Both write while neither can see the other, and both count their own
        // writes — the vectors are genuinely concurrent, as two machines' are.
        laptop.sharedURL = nil
        rename(shared, to: "laptop name", on: laptop)
        rename(shared, to: "desk name", on: desk)
        laptop.sharedURL = file(of: "laptop")
        XCTAssertFalse(laptop.conflicts.isEmpty, "the premise: a question")

        laptop.resolve([shared.id: .keepOurs])

        XCTAssertTrue(laptop.conflicts.isEmpty, "answered")
        XCTAssertEqual(names(laptop), ["laptop name"])
        XCTAssertEqual(try names(in: file(of: "laptop")), ["laptop name"],
                       "and the answer reached the folder")

        desk.sync()
        XCTAssertTrue(desk.conflicts.isEmpty, "the other machine takes it without a question")
        XCTAssertEqual(names(desk), ["laptop name"])
    }

    /// A question stands until it is answered — it does not settle itself in
    /// this machine's favour on the next sync.
    ///
    /// The merge counts the other side's writes as seen, which is right for an
    /// answer and wrong for a question: with their counters folded in, the next
    /// merge finds this machine simply newer and takes its version, so a
    /// disagreement the user was about to settle disappears with their side
    /// silently discarded.
    func testAQuestionDoesNotSettleItself() throws {
        let desk = machine("desk")
        let laptop = machine("laptop")
        let shared = add(entry("ME FPT", "$FPT"), to: desk)
        laptop.sync()
        laptop.sharedURL = nil
        rename(shared, to: "laptop name", on: laptop)
        rename(shared, to: "desk name", on: desk)
        laptop.sharedURL = file(of: "laptop")
        XCTAssertEqual(laptop.conflicts.count, 1, "the premise")

        for _ in 0..<3 { laptop.sync() }

        XCTAssertEqual(laptop.conflicts.count, 1, "still the user's to answer")
        XCTAssertEqual(try names(in: file(of: "desk")), ["desk name"],
                       "and the other machine's version is still there to choose")
    }

    /// Keeping this machine's version has to work even when this machine can
    /// never be "newer" on counters alone.
    ///
    /// A library that has been on three machines carries three counters, and a
    /// file written by the third leaves this one behind on that count for ever
    /// — no number of local edits catches up. Answering therefore has to mean
    /// "I have seen the version in that file", or the same question is raised
    /// again on the next merge and the answer is never published. This is the
    /// case that made This Mac → Apply do nothing while Shared → Apply worked:
    /// the second produces the file's own version, which needs no counters to
    /// be accepted.
    func testKeepingMyVersionWorksWithAThirdMachineInTheHistory() throws {
        let desk = machine("desk")
        let laptop = machine("laptop")
        let shared = add(entry("ME FPT", "$FPT"), to: desk)
        laptop.sync()

        laptop.sharedURL = nil
        rename(shared, to: "laptop name", on: laptop)

        // The desk publishes its own version, and its file also carries a third
        // machine's counter — one that has been retired, or whose container was
        // reset and came back under a new name.
        rename(shared, to: "desk name", on: desk)
        try edit(file(of: "desk")) {
            $0.vector = $0.vector.merged(with: VersionVector(["retired-mac": 5]))
        }

        laptop.sharedURL = file(of: "laptop")
        XCTAssertEqual(laptop.conflicts.count, 1, "the premise: a question")

        laptop.resolve([shared.id: .keepOurs])

        XCTAssertTrue(laptop.conflicts.isEmpty, "answered")
        let after = try PatternLibrary(fileContents: Data(contentsOf: file(of: "laptop")))
        XCTAssertEqual(after.ordered.map(\.name), ["laptop name"],
                       "and the answer reached the folder")
        XCTAssertEqual(after.vector["retired-mac"], 5,
                       "without forgetting what the third machine had written")

        desk.sync()
        XCTAssertEqual(names(desk), ["laptop name"], "the other machine takes it")
    }

    /// And it stays answered: the next sync must not raise the same question a
    /// second time.
    func testAnAnsweredQuestionStaysAnswered() {
        let desk = machine("desk")
        let laptop = machine("laptop")
        let shared = add(entry("ME FPT", "$FPT"), to: desk)
        laptop.sync()
        laptop.sharedURL = nil
        rename(shared, to: "laptop name", on: laptop)
        rename(shared, to: "desk name", on: desk)
        laptop.sharedURL = file(of: "laptop")
        laptop.resolve([shared.id: .keepOurs])

        for _ in 0..<3 { laptop.sync() }

        XCTAssertTrue(laptop.conflicts.isEmpty)
        XCTAssertEqual(names(laptop), ["laptop name"])
    }

    /// Two machines editing while one is offline must not lose an edit.
    ///
    /// This machine records what it last read from another's file as agreed —
    /// normally true, and false when that file is replaced by something from a
    /// different lineage: a copy restored from a backup, or a version a sync
    /// provider kept over another. "I have not changed since the base" then
    /// reads as "only they changed it", and this machine's work is replaced
    /// without a word. A base is only a base while the file descends from it.
    func testAnEditIsNotLostWhenAFileComesBackFromAnotherLineage() throws {
        let desk = machine("desk")
        let laptop = machine("laptop")
        let shared = add(entry("ME FPT", "$FPT"), to: desk)
        laptop.sync()

        // The laptop edits and publishes; as far as it knows, all is agreed.
        rename(shared, to: "laptop name", on: laptop)
        XCTAssertEqual(names(laptop), ["laptop name"])

        // The desk's file comes back holding a version of its own, out of a
        // lineage the laptop's base is not part of.
        try edit(file(of: "desk")) { library in
            library.entries = library.entries.map {
                var entry = $0
                if entry.id == shared.id { entry.name = "desk name" }
                return entry
            }
            library.vector = VersionVector(["desk-restored": 9])
        }

        laptop.sync()

        XCTAssertEqual(laptop.conflicts.count, 1,
                       "the laptop is asked rather than quietly overwritten")
        XCTAssertEqual(names(laptop), ["laptop name"],
                       "and goes on showing its own until it is answered")
    }

    /// A standing question is not swept away by counters that do not cover
    /// this machine's own version.
    ///
    /// Counters are what carry an answer, so they have to be read strictly: a
    /// file written by a machine that has *not* seen this one's version has
    /// decided nothing, and taking it would answer the user's question for them
    /// by discarding their side. Which is what a conflict resolving itself a
    /// few seconds later, in the other machine's favour, looks like.
    func testAQuestionIsNotSweptAwayByCountersThatMissedThisMachine() throws {
        let desk = machine("desk")
        let laptop = machine("laptop")
        let shared = add(entry("ME FPT", "$FPT"), to: desk)
        laptop.sync()

        laptop.sharedURL = nil
        rename(shared, to: "laptop name", on: laptop)
        rename(shared, to: "desk name", on: desk)
        laptop.sharedURL = file(of: "laptop")
        XCTAssertEqual(laptop.conflicts.count, 1, "the premise: a question")

        // The other machine writes again — its own work, and nothing of this
        // machine's: a third Mac's counter, not this one's.
        try edit(file(of: "desk")) { library in
            library.vector = library.vector.merged(with: VersionVector(["a-third-mac": 7]))
            library.vector.increment(for: "desk")
        }

        laptop.sync()

        XCTAssertEqual(laptop.conflicts.count, 1, "still the user's to answer")
        XCTAssertEqual(names(laptop), ["laptop name"], "and their side is still here")
    }

    /// Edited here, deleted there: **both** machines ask, and neither decides
    /// it by carrying on.
    ///
    /// The machine that deleted used to keep its deletion without a word, and
    /// silence is not neutral: deciding without asking folds the other's
    /// counters into its own, and counters covering the other machine's version
    /// are how an answer travels. So the deletion arrived at the machine that
    /// had edited the entry as somebody's *answer*, and its question resolved
    /// itself, in favour of the deletion, a couple of seconds after appearing.
    func testAnEditAgainstADeletionIsAQuestionOnBothMachines() throws {
        let desk = machine("desk")
        let laptop = machine("laptop")
        let shared = add(entry("ME FPT", "$FPT"), to: desk)
        laptop.sync()

        // The desk's rename is still on its way down, so the laptop deletes the
        // entry knowing nothing about it.
        rename(shared, to: "Intel ME FPT", on: desk)
        let inTransit = folder.appendingPathComponent("in-transit")
        try FileManager.default.moveItem(at: file(of: "desk"), to: inTransit)
        var without = laptop.library
        without.entries.removeAll { $0.id == shared.id }
        without.tombstones.append(PatternLibrary.Tombstone(id: shared.id, device: "laptop"))
        laptop.save(without)
        try FileManager.default.moveItem(at: inTransit, to: file(of: "desk"))

        laptop.sync()
        desk.sync()

        XCTAssertEqual(laptop.conflicts.count, 1, "the machine that deleted is asked")
        XCTAssertEqual(desk.conflicts.count, 1, "and so is the one that edited")

        for _ in 0..<3 {
            desk.sync()
            laptop.sync()
        }

        XCTAssertEqual(desk.conflicts.count, 1, "and it does not answer itself")
        XCTAssertEqual(names(desk), ["Intel ME FPT"], "the edit is still here to keep")

        // Answered on the machine that edited, and the other takes it.
        desk.resolve([shared.id: .keepOurs])
        laptop.sync()

        XCTAssertTrue(desk.conflicts.isEmpty)
        XCTAssertTrue(laptop.conflicts.isEmpty, "one answer settles both")
        XCTAssertEqual(names(laptop), ["Intel ME FPT"])
    }

    /// Renames an entry on one machine, the way the Favorites tab does.
    private func rename(_ entry: SearchPatternEntry, to name: String, on machine: LibrarySync) {
        var library = machine.library
        library.entries = library.entries.map {
            var edited = $0
            if edited.id == entry.id { edited.name = name }
            return edited
        }
        machine.save(library)
    }

    // MARK: - Announcing

    /// A change that arrives from the folder is announced like a local one —
    /// that is how every Find bar menu and the Favorites tab hear about it.
    func testAMergedChangeIsAnnounced() {
        let desk = machine("desk")
        let laptop = machine("laptop")
        add(entry("ME FPT", "$FPT"), to: desk)

        var announcements = 0
        laptop.onChange = { announcements += 1 }
        laptop.sync()

        XCTAssertGreaterThan(announcements, 0)
        XCTAssertEqual(names(laptop), ["ME FPT"])
    }
}
