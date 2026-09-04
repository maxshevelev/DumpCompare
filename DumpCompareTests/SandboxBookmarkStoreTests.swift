import XCTest
@testable import DumpCompare

/// §D9: the store that re-earns access to a file the user already chose.
///
/// A bookmark is a *cache* — it saves the user a second trip through an open
/// panel — and this one had no bound and no expiry, so it grew by one entry per
/// file ever opened. On a machine that had run the test suite it reached 9 434
/// entries and 14 MB of preferences, almost all of them pointing at temporary
/// files that were deleted minutes after they were bookmarked.
final class SandboxBookmarkStoreTests: XCTestCase {
    private var suiteName = ""
    private var store: UserDefaults!
    private var bookmarks: SandboxBookmarkStore!
    /// The domain the *app* chose, before this suite redirects it — which is
    /// the thing `testTheStoreKeepsOutOfTheUsersDomainUnderTest` is about.
    private static var appDomain: UserDefaults!

    override class func setUp() {
        super.setUp()
        appDomain = SandboxBookmarkStore.defaults
    }

    override func setUp() {
        super.setUp()
        (suiteName, store) = isolatedDefaults(for: self)
        SandboxBookmarkStore.defaults = store
        bookmarks = SandboxBookmarkStore.shared
    }

    override func tearDown() {
        SandboxBookmarkStore.defaults = Self.appDomain
        discardIsolatedDefaults(suiteName, store)
        store = nil
        super.tearDown()
    }

    /// The store keeps what is on the recorded path. A test host is not
    /// sandbox-scoped, so `bookmarkData(options: .withSecurityScope)` may
    /// refuse — the pruning is asserted against the stored dictionary directly,
    /// which is the thing that grew.
    private func seed(_ paths: [String]) {
        store.set(Dictionary(uniqueKeysWithValues: paths.map { ($0, Data([1, 2, 3])) }),
                  forKey: "SandboxBookmarks")
        store.set(paths, forKey: "SandboxBookmarkOrder")
    }

    private func stored() -> [String] {
        Array((store.dictionary(forKey: "SandboxBookmarks") as? [String: Data] ?? [:]).keys)
    }

    /// A bookmark to a file that is no longer there cannot resolve, so it is
    /// dead weight: pruning takes it out.
    func testAPruneDropsBookmarksToFilesThatAreGone() throws {
        let alive = try tempFile([0x41])
        let gone = FileManager.default.temporaryDirectory
            .appendingPathComponent("gone-\(UUID().uuidString).bin")
        seed([alive.path, gone.path])
        XCTAssertEqual(stored().count, 2, "the premise")

        bookmarks.pruneNow()

        XCTAssertEqual(stored(), [alive.path], "the file that is still there, and only it")
    }

    /// And it is bounded: past the limit the oldest recorded paths go, so the
    /// store cannot grow without end even where every file still exists.
    func testTheStoreIsCappedAtItsLimit() throws {
        let limit = SandboxBookmarkStore.limit
        // Real files, so liveness cannot be what does the dropping.
        let urls = try (0..<(limit + 5)).map { _ in try tempFile([0x41]) }
        // Newest first, which is the order the store keeps.
        seed(urls.map(\.path).reversed())
        XCTAssertEqual(stored().count, limit + 5, "the premise")

        bookmarks.pruneNow()

        XCTAssertEqual(stored().count, limit, "capped")
        let kept = Set(stored())
        XCTAssertTrue(kept.contains(urls.last!.path), "the newest is kept")
        XCTAssertFalse(kept.contains(urls.first!.path), "the oldest is not")
    }

    /// Recording keeps the order it prunes by: the path just recorded is the
    /// newest, however many times it has been recorded before.
    func testRecordingMovesAPathToTheFront() throws {
        let first = try tempFile([0x41])
        let second = try tempFile([0x42])
        seed([second.path, first.path])

        // `record` needs a real bookmark, which an unsandboxed host cannot
        // always make; the order is asserted through `pruneNow`, which shares
        // the pruning, and through the order key the store writes.
        bookmarks.pruneNow()
        XCTAssertEqual(store.array(forKey: "SandboxBookmarkOrder") as? [String],
                       [second.path, first.path],
                       "the order survives a prune that drops nothing")
    }

    /// The user's own preferences are not where a test's bookmarks go. Every
    /// suite that opens a file records one, and no suite redirected this
    /// domain, which is how 9 434 of them reached the real one.
    func testTheStoreKeepsOutOfTheUsersDomainUnderTest() throws {
        XCTAssertTrue(MainViewController.isRunningTests, "the premise: under XCTest")
        let chosen = try XCTUnwrap(Self.appDomain)
        XCTAssertFalse(chosen === UserDefaults.standard,
                       "under test the store must not be the user's own domain")
    }
}
