import XCTest
@testable import DumpCompare

/// §25.2: the list of extensions the File Types tab manages — what counts as an
/// extension, and what the store remembers. Runs against a defaults domain of
/// its own, so the developer's own list is never touched.
final class DefaultHandlerSettingsTests: XCTestCase {
    private let suite = "DefaultHandlerSettingsTests"
    private var store: UserDefaults!

    override func setUp() {
        super.setUp()
        store = UserDefaults(suiteName: suite)
        store.removePersistentDomain(forName: suite)
        DefaultHandlerSettings.defaults = store
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suite)
        DefaultHandlerSettings.defaults = .standard
        super.tearDown()
    }

    /// A store that has never been written offers the two extensions the app is
    /// about — listed, and with nothing recorded as displaced: the list is not a
    /// record of registrations (§25.2).
    func testAFreshStoreListsTheBuiltInExtensions() {
        XCTAssertEqual(DefaultHandlerSettings.entries.map(\.ext), ["bin", "rom"])
        XCTAssertEqual(DefaultHandlerSettings.entries.compactMap(\.displacedHandler), [])
    }

    /// What Launch Services can take as an extension, and what it cannot: a
    /// leading dot and stray case are the user typing, a slash or a star is not
    /// an extension at all (§25.2).
    func testNormalizationAcceptsWhatIsAnExtensionAndRejectsWhatIsNot() {
        XCTAssertEqual(DefaultHandlerSettings.normalize(".DUMP"), "dump")
        XCTAssertEqual(DefaultHandlerSettings.normalize("  bin "), "bin")
        XCTAssertEqual(DefaultHandlerSettings.normalize("...rom"), "rom")
        XCTAssertEqual(DefaultHandlerSettings.normalize("fd32"), "fd32")

        XCTAssertNil(DefaultHandlerSettings.normalize(""))
        XCTAssertNil(DefaultHandlerSettings.normalize("   "))
        XCTAssertNil(DefaultHandlerSettings.normalize("."))
        XCTAssertNil(DefaultHandlerSettings.normalize("*"))
        XCTAssertNil(DefaultHandlerSettings.normalize("a/b"))
        XCTAssertNil(DefaultHandlerSettings.normalize("tar.gz"), "a two-part suffix is not one extension")
        XCTAssertNil(DefaultHandlerSettings.normalize(String(repeating: "x", count: 33)))
    }

    /// Adding: the normalized extension lands at the end, an extension already
    /// in the list is answered with itself rather than duplicated, and something
    /// that is not an extension is refused.
    func testAdding() {
        XCTAssertEqual(DefaultHandlerSettings.add(".Dump"), "dump")
        XCTAssertEqual(DefaultHandlerSettings.entries.map(\.ext), ["bin", "rom", "dump"])

        XCTAssertEqual(DefaultHandlerSettings.add("bin"), "bin", "already there, and that is the answer")
        XCTAssertEqual(DefaultHandlerSettings.entries.map(\.ext), ["bin", "rom", "dump"],
                       "no duplicate row")

        XCTAssertNil(DefaultHandlerSettings.add("no/pe"))
        XCTAssertEqual(DefaultHandlerSettings.entries.count, 3)
    }

    func testRemoving() {
        DefaultHandlerSettings.remove("bin")
        XCTAssertEqual(DefaultHandlerSettings.entries.map(\.ext), ["rom"])
        DefaultHandlerSettings.remove("nothing")
        XCTAssertEqual(DefaultHandlerSettings.entries.map(\.ext), ["rom"], "removing what is not there is a no-op")
    }

    /// The one thing the store does remember: who held the type before the app
    /// took it, because macOS can only be told to point a default somewhere and
    /// never to clear one (§25.3).
    func testTheDisplacedHandlerIsRememberedAndForgotten() {
        DefaultHandlerSettings.recordDisplacedHandler("com.apple.archiveutility", for: "bin")
        XCTAssertEqual(DefaultHandlerSettings.displacedHandler(for: "bin"), "com.apple.archiveutility")
        XCTAssertNil(DefaultHandlerSettings.displacedHandler(for: "rom"))

        // It survives the list changing around it.
        DefaultHandlerSettings.add("dump")
        XCTAssertEqual(DefaultHandlerSettings.displacedHandler(for: "bin"), "com.apple.archiveutility")

        DefaultHandlerSettings.clearDisplacedHandler(for: "bin")
        XCTAssertNil(DefaultHandlerSettings.displacedHandler(for: "bin"))
    }

    func testRecordingForAnExtensionThatIsNotListedIsANoOp() {
        DefaultHandlerSettings.recordDisplacedHandler("com.example.app", for: "absent")
        XCTAssertNil(DefaultHandlerSettings.displacedHandler(for: "absent"))
        XCTAssertEqual(DefaultHandlerSettings.entries.map(\.ext), ["bin", "rom"])
    }

    func testResetGoesBackToTheBuiltInList() {
        DefaultHandlerSettings.add("dump")
        DefaultHandlerSettings.remove("bin")
        DefaultHandlerSettings.resetToDefaults()
        XCTAssertEqual(DefaultHandlerSettings.entries.map(\.ext), ["bin", "rom"])
    }
}
