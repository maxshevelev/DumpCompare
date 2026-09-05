import DumpCompareCore
import XCTest
@testable import DumpCompare

/// Proof that none of the syncing is about patterns
/// (`Design/FAVORITES_SYNC_PLAN.md`).
///
/// A second collection, defined here and nowhere else: a note is a line of text
/// with an id, a place in the order, a time and a machine — the whole of what
/// `SyncedItem` asks for. Everything else is the machinery the favourites use,
/// unchanged: the same file per machine, the same three-way merge, the same
/// questions, the same answers.
///
/// It is a *test* collection on purpose. The claim being made is that the next
/// thing the app wants on every Mac — bookmarks, segments — is a conformance
/// rather than a second copy of six hundred lines, and the honest way to make
/// that claim is to write the conformance and run the machinery over it.
final class GenericSyncTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GenericSyncTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        folder = nil
        super.tearDown()
    }

    // MARK: - A second collection

    /// A line of text kept on every Mac. Two notes are the same note when they
    /// say the same thing — the id, the order and the time are bookkeeping,
    /// exactly as they are for a kept search.
    private struct Note: SyncedItem, SyncPresentable {
        let id: UUID
        var text: String
        var sortKey: Double
        var modifiedAt: Date
        var device: String

        init(id: UUID = UUID(), text: String, sortKey: Double = 0,
             modifiedAt: Date = Date(), device: String = "") {
            self.id = id
            self.text = text
            self.sortKey = sortKey
            self.modifiedAt = modifiedAt
            self.device = device
        }

        static func == (lhs: Note, rhs: Note) -> Bool { lhs.text == rhs.text }

        var label: String { text }
        var summary: String { "“\(text)”" }
    }

    private enum NoteKind: SyncedCollectionKind {
        typealias Item = Note

        static let fileStem = "DumpCompare Notes"
        static let folderBookmarkKey = "NotesFolderBookmark"
        static let folderPathKey = "NotesFolderPath"
        static let legacyBookmarkKey = "NotesPublishedBookmark"
        static let legacyPathKey = "NotesPublishedPath"
        static var defaults: UserDefaults { FavoritePatternStore.defaults }
    }

    private typealias NoteSync = FolderSync<NoteKind>

    private func file(of device: String) -> URL {
        folder.appendingPathComponent(SyncFolder<NoteKind>.fileName(for: device))
    }

    private func machine(_ name: String) -> NoteSync {
        let sync = NoteSync(localURL: folder.appendingPathComponent("\(name)/Notes.json"),
                            sharedURL: file(of: name), device: name)
        sync.start()
        return sync
    }

    @discardableResult
    private func add(_ text: String, to machine: NoteSync) -> Note {
        var collection = machine.library
        let note = Note(text: text,
                        sortKey: SyncedCollection<Note>.sortKey(
                            between: collection.ordered.last?.sortKey, and: nil),
                        device: machine.device)
        collection.entries.append(note)
        machine.save(collection)
        return note
    }

    private func texts(_ machine: NoteSync) -> [String] { machine.library.ordered.map(\.text) }

    // MARK: - The same machinery, a different thing carried

    /// What one machine keeps reaches the other, and two machines adding
    /// separately end up with both.
    func testNotesTravelBetweenTwoMachines() {
        let desk = machine("desk")
        let laptop = machine("laptop")

        add("check the ME region", to: desk)
        laptop.sync()
        add("and the descriptor", to: laptop)
        desk.sync()

        XCTAssertEqual(Set(texts(desk)), ["check the ME region", "and the descriptor"])
        XCTAssertEqual(Set(texts(laptop)), Set(texts(desk)))
        XCTAssertTrue(desk.conflicts.isEmpty)
    }

    /// A deletion travels as a deletion, which is the tombstone doing its work
    /// for a collection that has never heard of patterns.
    func testADeletedNoteStaysDeleted() {
        let desk = machine("desk")
        let laptop = machine("laptop")
        let doomed = add("a note made in error", to: desk)
        laptop.sync()
        XCTAssertEqual(texts(laptop), ["a note made in error"], "the premise")

        var without = desk.library
        without.entries.removeAll { $0.id == doomed.id }
        without.tombstones.append(SyncTombstone(id: doomed.id, device: "desk"))
        desk.save(without)
        laptop.sync()

        XCTAssertTrue(texts(laptop).isEmpty)
    }

    /// A race is a question on both machines, and an answer on one settles the
    /// other — the rule the favourites were taught, applying to something else
    /// entirely because it was never about them.
    func testARaceIsAQuestionOnBothMachinesAndOneAnswerSettlesIt() {
        let desk = machine("desk")
        let laptop = machine("laptop")
        let shared = add("ME region", to: desk)
        laptop.sync()

        laptop.sharedURL = nil
        edit(shared, to: "Intel ME region", on: desk)
        edit(shared, to: "ME region (16 MB)", on: laptop)
        laptop.sharedURL = file(of: "laptop")
        desk.sync()

        XCTAssertEqual(laptop.conflicts.count, 1)
        XCTAssertEqual(desk.conflicts.count, 1)

        laptop.resolve([shared.id: .keepOurs])
        desk.sync()

        XCTAssertTrue(desk.conflicts.isEmpty, "one answer settles both")
        XCTAssertEqual(texts(desk), ["ME region (16 MB)"])
    }

    /// And the questions read as questions about *notes*: the sheet takes what
    /// each side holds from the item itself.
    func testTheQuestionSaysWhatEachSideHolds() throws {
        let desk = machine("desk")
        let laptop = machine("laptop")
        let shared = add("ME region", to: desk)
        laptop.sync()
        laptop.sharedURL = nil
        edit(shared, to: "Intel ME region", on: desk)
        edit(shared, to: "ME region (16 MB)", on: laptop)
        laptop.sharedURL = file(of: "laptop")

        guard case let .bothEdited(ours, theirs) = try XCTUnwrap(laptop.conflicts.first) else {
            return XCTFail("expected bothEdited, got \(laptop.conflicts)")
        }
        XCTAssertEqual(ours.summary, "“ME region (16 MB)”")
        XCTAssertEqual(theirs.summary, "“Intel ME region”")
    }

    /// Two collections in one folder do not read each other: what counts as a
    /// file is the *collection's* own naming, so a folder can hold the
    /// favourites and the notes without either noticing the other.
    func testTwoCollectionsShareAFolderWithoutSeeingEachOther() throws {
        let notes = machine("desk")
        add("a note", to: notes)

        let patterns = LibrarySync(
            localURL: folder.appendingPathComponent("patterns/Favorites.json"),
            sharedURL: LibraryLocation.file(in: folder, device: "desk"),
            device: "desk")
        patterns.start()
        var library = patterns.library
        library.entries.append(SearchPatternEntry(name: "ME FPT", pattern: "$FPT", encoding: .hex))
        patterns.save(library)

        notes.sync()

        XCTAssertEqual(texts(notes), ["a note"], "the notes did not take in a pattern")
        XCTAssertEqual(patterns.library.ordered.map(\.name), ["ME FPT"])
        XCTAssertTrue(notes.conflicts.isEmpty)
        XCTAssertTrue(patterns.conflicts.isEmpty)
        XCTAssertNotEqual(SyncFolder<NoteKind>.fileName(for: "desk"),
                          LibraryLocation.fileName(for: "desk"))
    }

    private func edit(_ note: Note, to text: String, on machine: NoteSync) {
        var collection = machine.library
        collection.entries = collection.entries.map {
            var edited = $0
            if edited.id == note.id { edited.text = text }
            return edited
        }
        machine.save(collection)
    }
}
