import DumpCompareCore
import XCTest
@testable import DumpCompare

/// Stage 2 of `Design/FAVORITES_SYNC_PLAN.md`: the favourites live in a file,
/// and the key they used to live under goes away.
///
/// The file is the reason the rest of the feature is possible — a list in
/// `UserDefaults` cannot be carried anywhere — so these tests are about the two
/// things that would lose someone's patterns: a migration that runs twice, and
/// a file that cannot be read.
final class FavoritesFileTests: XCTestCase {
    private var suiteName = ""
    private var store: UserDefaults!
    private var file: URL!

    override func setUp() {
        super.setUp()
        (suiteName, store) = isolatedDefaults(for: self)
        FavoritePatternStore.defaults = store
        file = isolatedFavoritesFile(for: self)
    }

    override func tearDown() {
        FavoritePatternStore.defaults = .standard
        discardIsolatedFavoritesFile(file)
        discardIsolatedDefaults(suiteName, store)
        store = nil
        super.tearDown()
    }

    private func entry(_ name: String, _ pattern: String,
                       _ encoding: SearchEncoding = .hex) -> SearchPatternEntry {
        SearchPatternEntry(name: name, pattern: pattern, encoding: encoding)
    }

    private func legacyRow(_ name: String, _ pattern: String, _ encoding: String) -> [String: Any] {
        ["name": name, "pattern": pattern, "encoding": encoding, "caseSensitive": false]
    }

    // MARK: - Where it lives

    /// Inside the container, where a sandboxed app may write without asking
    /// anyone, under a folder of its own because the system puts its folders in
    /// Application Support too.
    func testTheDefaultPlaceIsTheContainersApplicationSupport() {
        let url = FavoritesFile.defaultURL()
        XCTAssertEqual(url.lastPathComponent, "Favorites.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "DumpCompare")
        XCTAssertTrue(url.path.contains("Application Support"), url.path)
    }

    /// Writing creates the folder: on a fresh install nothing has made it.
    func testWritingCreatesTheFolder() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the premise")

        FavoritePatternStore.add(entry("ME FPT", "$FPT", .ascii))

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let text = try XCTUnwrap(String(data: Data(contentsOf: file), encoding: .utf8))
        XCTAssertTrue(text.contains("ME FPT"), text)
    }

    /// No file yet is a normal state, not an error: a fresh install has an
    /// empty library and nothing to complain about.
    func testNoFileYetIsAnEmptyLibrary() {
        XCTAssertTrue(FavoritePatternStore.favorites.isEmpty)
        XCTAssertNil(FavoritePatternStore.loadError)
    }

    // MARK: - What is written

    /// The bookkeeping is stamped by the store, not left to the caller: an
    /// entry kept from the Find bar has no idea which machine it is on or where
    /// it belongs in the list.
    func testAKeptPatternIsStampedAndPlaced() throws {
        FavoritePatternStore.add(entry("first", "11"))
        FavoritePatternStore.add(entry("second", "22"))

        let kept = FavoritePatternStore.favorites
        XCTAssertEqual(kept.map(\.name), ["first", "second"])
        XCTAssertLessThan(kept[0].sortKey, kept[1].sortKey, "added at the end")
        XCTAssertFalse(kept[0].device.isEmpty, "and stamped with this machine")
        XCTAssertEqual(kept[0].device, DeviceIdentity.current)
    }

    /// The id an entry is written with is the id it is read back with — an
    /// identity re-minted on every read would be no identity at all, and the
    /// whole merge rests on it.
    func testIdsSurviveALaunch() throws {
        FavoritePatternStore.add(entry("ME FPT", "$FPT", .ascii))
        let before = try XCTUnwrap(FavoritePatternStore.favorites.first?.id)

        FavoritePatternStore.forgetLastGood()  // as a launch would

        XCTAssertEqual(FavoritePatternStore.favorites.first?.id, before)
    }

    // MARK: - What a change leaves behind

    /// A removed entry leaves a tombstone: an entry that is simply absent is
    /// indistinguishable from one another machine has never seen, and a merge
    /// would put it back (`Design/FAVORITES_SYNC_PLAN.md`).
    func testRemovingAnEntryLeavesATombstone() throws {
        FavoritePatternStore.add(entry("keep", "11"))
        FavoritePatternStore.add(entry("remove", "22"))
        let doomed = try XCTUnwrap(FavoritePatternStore.favorites.last)

        FavoritePatternStore.replace(with: FavoritePatternStore.favorites.filter { $0.id != doomed.id })

        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name), ["keep"])
        XCTAssertEqual(FavoritePatternStore.library.tombstones.map(\.id), [doomed.id])
        XCTAssertEqual(FavoritePatternStore.library.tombstones.first?.device,
                       DeviceIdentity.current, "and says who deleted it")
    }

    /// An edited entry is stamped with the time and the machine; one merely
    /// carried along is not — otherwise every save would look like an edit of
    /// everything, and a merge would have nothing to go on.
    func testOnlyAChangedEntryIsRestamped() throws {
        FavoritePatternStore.add(entry("first", "11"))
        FavoritePatternStore.add(entry("second", "22"))
        let before = FavoritePatternStore.favorites
        let untouchedStamp = before[0].modifiedAt

        var edited = before[1]
        edited.name = "renamed"
        FavoritePatternStore.replace(with: [before[0], edited])

        let after = FavoritePatternStore.favorites
        XCTAssertEqual(after[0].modifiedAt.timeIntervalSince1970,
                       untouchedStamp.timeIntervalSince1970, accuracy: 0.002,
                       "the one nobody touched is not restamped")
        XCTAssertGreaterThan(after[1].modifiedAt, before[1].modifiedAt)
        XCTAssertEqual(after[1].device, DeviceIdentity.current)
    }

    /// Every write counts, by this machine's name: that count is what tells a
    /// later version from a concurrent one when two machines share the file.
    func testEveryWriteCountsAgainstThisMachine() {
        FavoritePatternStore.add(entry("first", "11"))
        let after1 = FavoritePatternStore.library.vector[DeviceIdentity.current]
        FavoritePatternStore.add(entry("second", "22"))
        let after2 = FavoritePatternStore.library.vector[DeviceIdentity.current]

        XCTAssertEqual(after1, 1)
        XCTAssertEqual(after2, 2)
    }

    // MARK: - Migration

    /// The list moves out of `UserDefaults` on the first launch that finds it,
    /// keeping its order, and the key is gone afterwards: two stores on one
    /// machine is the syncing problem indoors.
    func testTheOldKeyMovesIntoTheFileAndGoes() throws {
        store.set([legacyRow("ME FPT", "$FPT", "ascii"),
                   legacyRow("Capsule", "5A A5", "hex")],
                  forKey: FavoritePatternStore.userDefaultsKey)

        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name), ["ME FPT", "Capsule"])
        XCTAssertNil(store.array(forKey: FavoritePatternStore.userDefaultsKey),
                     "the key does not stay behind")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // And the entries gained the identity they never had.
        let ids = Set(FavoritePatternStore.favorites.map(\.id))
        XCTAssertEqual(ids.count, 2)
    }

    /// A row that is not an entry is skipped rather than losing the whole list:
    /// a hand-edited plist, or an encoding this build no longer has.
    func testAnUnreadableRowIsSkippedOnTheWayOut() {
        store.set([legacyRow("ok", "DE AD", "hex"),
                   ["pattern": "no encoding here"],
                   ["encoding": "ascii"],
                   legacyRow("klingon", "boot", "klingon")],
                  forKey: FavoritePatternStore.userDefaultsKey)

        XCTAssertEqual(FavoritePatternStore.favorites.map(\.pattern), ["DE AD"])
    }

    /// A key left behind by an older build must not overwrite a file that
    /// already holds patterns — the file is the newer truth.
    func testAStaleKeyDoesNotOverwriteTheFile() throws {
        FavoritePatternStore.add(entry("kept in the file", "11"))
        store.set([legacyRow("stale", "22", "hex")],
                  forKey: FavoritePatternStore.userDefaultsKey)

        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name), ["kept in the file"])
        XCTAssertNil(store.array(forKey: FavoritePatternStore.userDefaultsKey),
                     "and the stale key still goes")
    }

    // MARK: - A file that cannot be read

    /// The list the app is showing does not vanish because the file went bad
    /// behind its back: the truth is what this machine believes, held in
    /// memory, and the file is where it is kept — not the other way round.
    /// The next change writes it out again, whole.
    func testAFileCorruptedBehindTheAppsBackDisturbsNothing() throws {
        FavoritePatternStore.add(entry("ME FPT", "$FPT", .ascii))
        XCTAssertEqual(FavoritePatternStore.favorites.count, 1, "the premise")

        try Data("this is not a library".utf8).write(to: file)

        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name), ["ME FPT"],
                       "what the app believes is unchanged")

        FavoritePatternStore.add(entry("Capsule", "5A A5"))

        let rewritten = try FavoritesDocument(fileContents: Data(contentsOf: file))
        XCTAssertEqual(rewritten.local.ordered.map(\.name), ["ME FPT", "Capsule"],
                       "and the file is whole again")
    }

    /// With nothing good to fall back on — a corrupt file at launch — the app
    /// still opens, with an empty list and the reason recorded.
    func testACorruptFileAtLaunchIsEmptyAndSaysWhy() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: file)
        FavoritePatternStore.forgetLastGood()

        XCTAssertTrue(FavoritePatternStore.favorites.isEmpty)
        XCTAssertNotNil(FavoritePatternStore.loadError)
    }
}
