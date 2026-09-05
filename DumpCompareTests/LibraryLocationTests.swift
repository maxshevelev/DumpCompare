import DumpCompareCore
import XCTest
@testable import DumpCompare

/// Stage 5 of `Design/FAVORITES_SYNC_PLAN.md`: moving the library out of the
/// app's own storage and into a folder the user's sync client watches.
///
/// The tab is where it happens, so these tests drive the tab — with the panel
/// and the alert behind seams, because a test run has nobody to answer them.
@MainActor
final class LibraryLocationTests: XCTestCase {
    private var suiteName = ""
    private var store: UserDefaults!
    private var localFile: URL!
    private var folder: URL!
    private var tab: FavoritePatternsSettingsViewController!

    override func setUp() {
        super.setUp()
        (suiteName, store) = isolatedDefaults(for: self)
        FavoritePatternStore.defaults = store
        localFile = isolatedFavoritesFile(for: self)
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LibraryLocationTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        tab = nil
        FavoritePatternStore.sharedFolder = nil
        FavoritePatternStore.defaults = .standard
        discardIsolatedFavoritesFile(localFile)
        try? FileManager.default.removeItem(at: folder)
        discardIsolatedDefaults(suiteName, store)
        store = nil
        super.tearDown()
    }

    /// This machine's own file in the shared folder — the only one it writes.
    private var sharedURL: URL { LibraryLocation.file(in: folder) }

    /// Another machine's file, sitting in the same folder.
    private var theirURL: URL {
        folder.appendingPathComponent(LibraryLocation.fileName(for: "other-mac"))
    }

    private func openTab(choosing url: URL? = nil,
                         answering adoption: LibrarySync.Adoption? = nil) {
        tab = FavoritePatternsSettingsViewController()
        _ = tab.view
        if let url { tab.chooseSharedFolder = { url.deletingLastPathComponent() } }
        if let adoption { tab.askAboutExistingFile = { _ in adoption } }
        tab.reload()
    }

    private func entry(_ name: String, _ pattern: String) -> SearchPatternEntry {
        SearchPatternEntry(name: name, pattern: pattern, encoding: .hex)
    }

    /// A library sitting in the shared file, as another machine would have left
    /// it there.
    private func writeSharedFile(_ names: [String]) throws {
        var library = PatternLibrary()
        library.setOrder(names.map { entry($0, "AB") })
        library.entries = library.entries.enumerated().map { index, entry in
            var placed = entry
            placed.pattern = String(format: "%02X", 0xA0 + index)
            return placed
        }
        library.vector = VersionVector(["other-mac": 1])
        try library.fileContents().write(to: theirURL)
    }

    /// What this machine's own file says.
    private func sharedFileNames() throws -> [String] {
        try PatternLibrary(fileContents: Data(contentsOf: sharedURL)).ordered.map(\.name)
    }

    private func theirFileNames() throws -> [String] {
        try PatternLibrary(fileContents: Data(contentsOf: theirURL)).ordered.map(\.name)
    }

    // MARK: - Where it says the library is

    func testItSaysTheLibraryIsOnThisMacOnly() {
        openTab()

        XCTAssertEqual(tab.locationLabel.stringValue, "Library: on this Mac only")
        XCTAssertTrue(tab.keepHereButton.isHidden, "nothing to come back from")
    }

    /// The whole path, not just the file's name and its folder: with Desktop &
    /// Documents in iCloud, `~/Documents` *is* iCloud Drive's Documents folder,
    /// and a library there reads exactly like one in iCloud Drive's root —
    /// which is a different file, syncing to the same places, that nothing will
    /// update.
    func testAfterMovingItSaysWhereTheFileIs() {
        openTab(choosing: sharedURL)

        tab.moveButton.performClick(nil)

        XCTAssertTrue(tab.locationLabel.stringValue.contains(
                        FavoritePatternsSettingsViewController.readablePath(of: folder)),
                      tab.locationLabel.stringValue)
        XCTAssertFalse(tab.keepHereButton.isHidden)
    }

    /// The home folder is written as `~`, so the line stays readable.
    func testTheHomeFolderIsWrittenAsATilde() {
        let inside = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/DumpCompare Patterns.json")
        XCTAssertEqual(FavoritePatternsSettingsViewController.readablePath(of: inside),
                       "~/Documents/DumpCompare Patterns.json")
        let outside = URL(fileURLWithPath: "/Volumes/Stick/DumpCompare Patterns.json")
        XCTAssertEqual(FavoritePatternsSettingsViewController.readablePath(of: outside),
                       "/Volumes/Stick/DumpCompare Patterns.json")
    }

    /// Choosing a folder is what makes the permission last: a grant on a file
    /// dies with that file, and every atomic write replaces it. The folder is
    /// remembered as its own bookmark, and the name inside it is the app's.
    func testMovingRemembersTheFolderAndNamesTheFileItself() throws {
        FavoritePatternStore.add(entry("ME FPT", "$FPT"))
        openTab()
        tab.chooseSharedFolder = { self.folder }

        tab.moveButton.performClick(nil)

        let name = try XCTUnwrap(FavoritePatternStore.sharedURL?.lastPathComponent)
        XCTAssertTrue(LibraryLocation.isLibraryFile(name), name)
        XCTAssertEqual(name, LibraryLocation.fileName(for: DeviceIdentity.current),
                       "this machine's own file, which nothing else writes")
        XCTAssertEqual(FavoritePatternStore.sharedURL?.deletingLastPathComponent().path,
                       folder.path)
        XCTAssertEqual(store.string(forKey: LibraryLocation.folderPathKey), folder.path)
    }

    /// The path gets a line of its own, with the commands under it: it is the
    /// one thing here that has to be read in full — two libraries in one synced
    /// folder tree are told apart by nothing else — and a row shared with three
    /// buttons left it a few characters wide.
    func testThePathHasALineOfItsOwnAboveTheButtons() {
        FavoritePatternStore.add(entry("ME FPT", "$FPT"))
        openTab(choosing: sharedURL)
        tab.moveButton.performClick(nil)
        tab.view.layoutSubtreeIfNeeded()

        let label = tab.view.convert(tab.locationLabel.bounds, from: tab.locationLabel)
        let move = tab.view.convert(tab.moveButton.bounds, from: tab.moveButton)
        XCTAssertGreaterThan(label.width, 400, "the path has the width to be read")
        XCTAssertGreaterThan(label.minY, move.maxY, "and the buttons are under it")
        XCTAssertEqual(tab.locationLabel.toolTip, folder.path,
                       "the whole path on hover, for a folder deep enough to truncate")
    }

    /// The panel opens where the user's own sync already runs, and offers a
    /// name a stranger can read in a folder of other people's files.
    func testThePanelIsPointedAtASensiblePlace() {
        let folder = LibraryLocation.suggestedFolder()
        XCTAssertTrue(["com~apple~CloudDocs", "Documents"].contains(folder.lastPathComponent),
                      folder.path)
        let name = LibraryLocation.fileName(for: "3F7A9C21-DEAD")
        XCTAssertTrue(name.hasPrefix("DumpCompare Patterns ("), name)
        XCTAssertTrue(LibraryLocation.isLibraryFile(name), name)
    }

    /// The file is named after the **machine**, and by something that cannot
    /// move: a hash of its id.
    ///
    /// Not its hostname — a laptop takes a new one from whatever network it
    /// joins, and anyone can change one whenever they like. A file whose name
    /// moves is a machine that starts writing a second file and leaves the
    /// first behind for ever. Not the id itself either: the folder is shared,
    /// and a hash names the file just as well while saying nothing about the
    /// Mac.
    func testTheFileIsNamedAfterTheMachineAndNothingThatCanChange() {
        let name = LibraryLocation.fileName(for: "a-machine")

        XCTAssertEqual(name, LibraryLocation.fileName(for: "a-machine"),
                       "the same machine, the same file, every time")
        XCTAssertNotEqual(name, LibraryLocation.fileName(for: "another-machine"))
        XCTAssertFalse(name.contains("a-machine"), "the id itself does not go into the folder")

        let label = name.replacingOccurrences(of: "DumpCompare Patterns (", with: "")
            .replacingOccurrences(of: ").json", with: "")
        XCTAssertEqual(label.count, LibraryLocation.stampLength)
        XCTAssertTrue(label.allSatisfy { $0.isHexDigit && !$0.isLowercase }, label)
    }

    /// The id behind it is the Mac's own, taken from the hardware: it survives
    /// a rename, a new network, and this app's settings being reset.
    func testTheMachinesIdComesFromTheHardware() throws {
        let fromHardware = try XCTUnwrap(DeviceIdentity.hardware(),
                                         "a Mac always has a platform UUID")

        XCTAssertEqual(fromHardware, DeviceIdentity.hardware())
        XCTAssertEqual(fromHardware.count, LibraryLocation.stampLength)
        XCTAssertFalse(fromHardware.contains("-"), "hashed, not the UUID itself")

        // Nothing already stored is replaced by it: an id that changed would
        // leave this machine's own past looking like a stranger's.
        store.set("minted-before", forKey: DeviceIdentity.userDefaultsKey)
        XCTAssertEqual(DeviceIdentity.current, "minted-before")
    }

    // MARK: - Moving    // MARK: - Moving

    /// An empty file is nothing to reconcile, so nothing is asked — and what
    /// this machine holds is published into it.
    func testMovingIntoAnEmptyFileAsksNothing() throws {
        FavoritePatternStore.add(entry("ME FPT", "$FPT"))
        var asked = false
        openTab(choosing: sharedURL)
        tab.askAboutExistingFile = { _ in asked = true; return .merge }

        tab.moveButton.performClick(nil)

        XCTAssertFalse(asked)
        XCTAssertEqual(try sharedFileNames(), ["ME FPT"])
        XCTAssertEqual(FavoritePatternStore.sharedURL, sharedURL)
    }

    /// A file that already holds patterns is the one moment two libraries meet,
    /// and merging is the default answer: twelve here and three there make
    /// fifteen.
    func testMergingKeepsBothLists() throws {
        FavoritePatternStore.add(entry("mine", "11"))
        try writeSharedFile(["theirs"])
        openTab(choosing: sharedURL, answering: .merge)

        tab.moveButton.performClick(nil)

        XCTAssertEqual(Set(FavoritePatternStore.favorites.map(\.name)), ["mine", "theirs"])
        XCTAssertEqual(Set(try sharedFileNames()), ["mine", "theirs"])
    }

    /// Starting from the shared list: what this machine held goes.
    func testTakingTheFilesPatternsDropsThisMacs() throws {
        FavoritePatternStore.add(entry("mine", "11"))
        try writeSharedFile(["theirs"])
        openTab(choosing: sharedURL, answering: .takeTheFile)

        tab.moveButton.performClick(nil)

        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name), ["theirs"])
    }

    /// And the destructive answer does what it says — with tombstones, not by
    /// writing over anybody's file. This machine writes only its own; a
    /// deletion the other machines will honour is the honest way to say "that
    /// list is not the one we are keeping".
    func testReplacingKeepsOnlyThisMacsList() throws {
        FavoritePatternStore.add(entry("mine", "11"))
        try writeSharedFile(["theirs"])
        openTab(choosing: sharedURL, answering: .replaceTheFile)

        tab.moveButton.performClick(nil)

        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name), ["mine"])
        XCTAssertEqual(try sharedFileNames(), ["mine"])
        XCTAssertEqual(try theirFileNames(), ["theirs"],
                       "the other machine's file is not this one's to write")
        let published = try PatternLibrary(fileContents: Data(contentsOf: sharedURL))
        XCTAssertEqual(published.tombstones.count, 1,
                       "what it says instead is that the entry is deleted")
    }

    /// Backing out of the question changes nothing at all.
    func testCancellingTheQuestionLeavesEverythingAlone() throws {
        FavoritePatternStore.add(entry("mine", "11"))
        try writeSharedFile(["theirs"])
        openTab(choosing: sharedURL)
        tab.askAboutExistingFile = { _ in nil }

        tab.moveButton.performClick(nil)

        XCTAssertNil(FavoritePatternStore.sharedURL)
        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name), ["mine"])
        XCTAssertEqual(try theirFileNames(), ["theirs"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sharedURL.path),
                       "and this machine wrote nothing there")
    }

    /// And cancelling the panel does not even ask.
    func testCancellingThePanelChangesNothing() {
        openTab()
        tab.chooseSharedFolder = { nil }

        tab.moveButton.performClick(nil)

        XCTAssertNil(FavoritePatternStore.sharedURL)
    }

    // MARK: - When it cannot be written

    /// A library published to a file that has since been moved in the Finder —
    /// or to a folder this app was never given — must say so. Silence made it
    /// look like an app that had stopped saving.
    func testItSaysWhenTheFileCannotBeWritten() {
        FavoritePatternStore.add(entry("ME FPT", "$FPT"))
        let unreachable = URL(fileURLWithPath: "/System/nowhere/DumpCompare Patterns.json")
        openTab(choosing: unreachable)

        tab.moveButton.performClick(nil)

        XCTAssertNotNil(FavoritePatternStore.publishError)
        XCTAssertTrue(tab.locationLabel.stringValue.contains("Move…"),
                      tab.locationLabel.stringValue)
        XCTAssertEqual(tab.locationLabel.textColor, .systemRed)
    }

    /// And the list itself is untouched by it: the truth is this machine's, and
    /// a file it cannot reach says nothing about the patterns.
    func testAnUnreachableFileLeavesTheListAlone() {
        FavoritePatternStore.add(entry("ME FPT", "$FPT"))
        openTab(choosing: URL(fileURLWithPath: "/System/nowhere/DumpCompare Patterns.json"))
        tab.moveButton.performClick(nil)

        FavoritePatternStore.add(entry("kept while unreachable", "22"))

        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name),
                       ["ME FPT", "kept while unreachable"])
    }

    /// Moving the file in the Finder does not move the library: the place is
    /// what the app was pointed at, and Finder cannot tell it anything. What it
    /// must not do is fail quietly.
    func testMovingTheFileInTheFinderIsNotMovingTheLibrary() throws {
        FavoritePatternStore.add(entry("ME FPT", "$FPT"))
        openTab(choosing: sharedURL)
        tab.moveButton.performClick(nil)
        XCTAssertNil(FavoritePatternStore.publishError, "the premise: it published")

        let elsewhere = folder.appendingPathComponent("moved-away")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: sharedURL,
                                         to: elsewhere.appendingPathComponent(sharedURL.lastPathComponent))

        FavoritePatternStore.add(entry("after the move", "33"))
        tab.reload()

        XCTAssertEqual(FavoritePatternStore.sharedURL, sharedURL, "still pointed where it was")
        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name), ["ME FPT", "after the move"],
                       "and the library is unharmed")
    }

    /// Choosing a folder that already holds a library *is* joining it — there
    /// is one command, because it is one act: point the app at a folder, and
    /// what is in it decides whether anything is asked.
    func testChoosingAFolderThatAlreadyHasALibraryJoinsIt() throws {
        FavoritePatternStore.add(entry("mine", "11"))
        try writeSharedFile(["theirs"])
        openTab(choosing: sharedURL, answering: .merge)

        tab.moveButton.performClick(nil)

        XCTAssertEqual(Set(FavoritePatternStore.favorites.map(\.name)), ["mine", "theirs"])
    }

    /// A file that is there and cannot be read — most often one iCloud has not
    /// finished downloading — is never treated as empty. Publishing into it
    /// would write over something unread.
    func testAnUnreadableFileIsNotTakenForAnEmptyOne() throws {
        FavoritePatternStore.add(entry("mine", "11"))
        try Data("not a library at all".utf8).write(to: theirURL)
        var asked = false
        openTab(choosing: sharedURL)
        tab.askAboutExistingFile = { _ in asked = true; return .merge }

        tab.moveButton.performClick(nil)

        XCTAssertFalse(asked, "there is nothing to ask about yet")
        XCTAssertNil(FavoritePatternStore.sharedURL, "and nothing was published")
        XCTAssertEqual(try String(data: Data(contentsOf: theirURL), encoding: .utf8),
                       "not a library at all", "the file is untouched")
        XCTAssertTrue(tab.messageForTests.contains("cannot be read"), tab.messageForTests)
    }

    /// What is in the folder decides whether joining is a question at all.
    func testWhatTheFolderHoldsIsReadBeforeAnythingIsWritten() throws {
        XCTAssertEqual(FavoritePatternStore.inspectShared(in: folder), .empty,
                       "no library there yet")
        try PatternLibrary().fileContents().write(to: theirURL)
        XCTAssertEqual(FavoritePatternStore.inspectShared(in: folder), .empty,
                       "a library with nothing in it")
        try writeSharedFile(["one", "two"])
        XCTAssertEqual(FavoritePatternStore.inspectShared(in: folder), .patterns(2))
        try Data("nonsense".utf8).write(to: theirURL)
        XCTAssertEqual(FavoritePatternStore.inspectShared(in: folder), .unreadable)
    }

    // MARK: - The file left behind

    /// Moving the library to another place leaves its old file sitting there
    /// with a copy that will never be updated. The user is asked once, and
    /// "keep" is the default — the old file may be in a folder another Mac
    /// publishes to.
    func testMovingOffersToRemoveTheOldFileAndKeepsItByDefault() throws {
        FavoritePatternStore.add(entry("ME FPT", "$FPT"))
        openTab(choosing: sharedURL)
        tab.moveButton.performClick(nil)
        let elsewhere = LibraryLocation.file(in: folder.appendingPathComponent("elsewhere"))

        var offered: URL?
        tab.chooseSharedFolder = { elsewhere.deletingLastPathComponent() }
        tab.askAboutOldFile = { offered = $0; return false }   // "Keep It"
        tab.moveButton.performClick(nil)

        XCTAssertEqual(offered, sharedURL, "it asks about the one being left")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedURL.path),
                      "and keeping it means keeping it")
        XCTAssertEqual(FavoritePatternStore.sharedURL, elsewhere)
        XCTAssertEqual(try PatternLibrary(fileContents: Data(contentsOf: elsewhere))
            .ordered.map(\.name), ["ME FPT"])
    }

    /// Answering makes the command's name true: the library is in one place
    /// afterwards, not two. To the Trash rather than deleted — it is the user's
    /// file, and one that turns out to have been wanted is then a drag away.
    func testTrashingTheOldFileLeavesTheLibraryInOnePlace() throws {
        FavoritePatternStore.add(entry("ME FPT", "$FPT"))
        openTab(choosing: sharedURL)
        tab.moveButton.performClick(nil)
        let elsewhere = LibraryLocation.file(in: folder.appendingPathComponent("elsewhere"))

        tab.chooseSharedFolder = { elsewhere.deletingLastPathComponent() }
        tab.askAboutOldFile = { _ in true }
        tab.moveButton.performClick(nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sharedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path))
        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name), ["ME FPT"])
    }

    /// A removal that cannot happen is said. It used to set a message that the
    /// refresh straight after it wiped, so a file that stayed put looked
    /// exactly like one that had gone.
    func testARemovalThatCannotHappenIsSaid() throws {
        // Both folders inside this test's own directory: a path shared with
        // anything else is a path another test can leave in a state this one
        // did not choose.
        let locked = folder.appendingPathComponent("locked")
        let next = folder.appendingPathComponent("next")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)

        FavoritePatternStore.add(entry("ME FPT", "$FPT"))
        openTab()
        tab.chooseSharedFolder = { locked }
        tab.moveButton.performClick(nil)
        let published = try XCTUnwrap(FavoritePatternStore.sharedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: published.path), "the premise")

        // A folder nothing may be unlinked from.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: locked.path)
        }

        tab.chooseSharedFolder = { next }
        tab.askAboutOldFile = { _ in true }
        tab.moveButton.performClick(nil)
        XCTAssertNil(FavoritePatternStore.publishError, "the move itself worked")

        XCTAssertTrue(FileManager.default.fileExists(atPath: published.path),
                      "the old file could not be removed")
        XCTAssertTrue(tab.messageForTests.contains("could not be moved to the Trash"),
                      tab.messageForTests)
    }

    /// Coming back to this Mac leaves a file behind too, and asks the same way.
    func testKeepingOnThisMacOffersToTrashThePublishedFile() {
        FavoritePatternStore.add(entry("ME FPT", "$FPT"))
        openTab(choosing: sharedURL)
        tab.moveButton.performClick(nil)

        tab.askAboutOldFile = { _ in true }
        tab.keepHereButton.performClick(nil)

        XCTAssertNil(FavoritePatternStore.sharedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sharedURL.path))
        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name), ["ME FPT"],
                       "and the patterns are still here, where they always were")
    }

    /// Publishing to the same file again is not a move, so nothing is offered.
    func testRepublishingToTheSameFileAsksNothing() {
        FavoritePatternStore.add(entry("ME FPT", "$FPT"))
        openTab(choosing: sharedURL)
        tab.moveButton.performClick(nil)

        var asked = false
        tab.askAboutOldFile = { _ in asked = true; return true }
        tab.askAboutExistingFile = { _ in .merge }
        tab.moveButton.performClick(nil)

        XCTAssertFalse(asked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedURL.path))
    }

    /// And a move that could not publish leaves the old file strictly alone:
    /// removing it would be removing the only copy there is.
    func testAFailedMoveKeepsTheOldFile() {
        FavoritePatternStore.add(entry("ME FPT", "$FPT"))
        openTab(choosing: sharedURL)
        tab.moveButton.performClick(nil)

        var asked = false
        tab.chooseSharedFolder = { URL(fileURLWithPath: "/System/nowhere") }
        tab.askAboutOldFile = { _ in asked = true; return true }
        tab.moveButton.performClick(nil)

        XCTAssertFalse(asked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedURL.path))
    }

    // MARK: - Coming back

    /// **Keep on This Mac** unpublishes: the library carries on where it always
    /// was, and the file is left where it is.
    func testKeepingOnThisMacUnpublishesAndKeepsThePatterns() throws {
        FavoritePatternStore.add(entry("ME FPT", "$FPT"))
        openTab(choosing: sharedURL)
        tab.moveButton.performClick(nil)
        XCTAssertNotNil(FavoritePatternStore.sharedURL, "the premise")

        tab.keepHereButton.performClick(nil)

        XCTAssertNil(FavoritePatternStore.sharedURL)
        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name), ["ME FPT"])
        XCTAssertEqual(tab.locationLabel.stringValue, "Library: on this Mac only")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedURL.path),
                      "the file is not taken away from wherever it was")
    }

    // MARK: - Permission

    /// The place is remembered as a bookmark, not just a path: a path into a
    /// folder macOS protects makes the system ask the user for permission on
    /// every launch. The bookmark is refreshed after each publish, because an
    /// atomic write replaces the file the old one was taken against.
    ///
    /// A temporary directory carries no scope to bookmark, so what this can
    /// assert is that the place is remembered and that publishing does not
    /// throw away what is there.
    func testThePlaceIsRememberedForTheNextLaunch() {
        FavoritePatternStore.add(entry("ME FPT", "$FPT"))
        openTab(choosing: sharedURL)

        tab.moveButton.performClick(nil)

        XCTAssertEqual(store.string(forKey: LibraryLocation.folderPathKey),
                       folder.standardizedFileURL.path)
        let bookmark = store.data(forKey: LibraryLocation.folderBookmarkKey)

        FavoritePatternStore.add(entry("another", "22"))   // publishes again

        XCTAssertEqual(store.data(forKey: LibraryLocation.folderBookmarkKey)?.count,
                       bookmark?.count,
                       "a publish never leaves the place less reachable than it found it")
    }

    // MARK: - Across a launch

    /// Where the library was published is remembered: a launch finds it again
    /// without asking.
    func testThePublishedPlaceIsRememberedAcrossALaunch() {
        FavoritePatternStore.add(entry("ME FPT", "$FPT"))
        openTab(choosing: sharedURL)
        tab.moveButton.performClick(nil)

        FavoritePatternStore.forgetLastGood()   // as a launch would

        // The same *file*, not the same spelling of it: a place remembered
        // through a security-scoped bookmark comes back resolved
        // (`/private/var/…` for a `/var/…` that was handed in), and that is the
        // bookmark working rather than a difference worth asserting.
        XCTAssertEqual(FavoritePatternStore.sharedURL?.resolvingSymlinksInPath(),
                       sharedURL.resolvingSymlinksInPath())
        XCTAssertEqual(FavoritePatternStore.favorites.map(\.name), ["ME FPT"])
    }

    /// And "this Mac" is remembered too — unpublishing must not come back
    /// published.
    func testComingBackIsRememberedAcrossALaunch() {
        openTab(choosing: sharedURL)
        tab.moveButton.performClick(nil)
        tab.keepHereButton.performClick(nil)

        FavoritePatternStore.forgetLastGood()

        XCTAssertNil(FavoritePatternStore.sharedURL)
    }
}
