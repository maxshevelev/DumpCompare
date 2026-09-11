import Foundation

/// Persists security-scoped bookmarks (§D9) so files the user opened stay
/// accessible across app launches, keyed by standardized absolute path.
///
/// The app's sandbox grants are tied to the user's choice in open/save panels
/// for the current session; bookmarking re-earns access to the same URL on the
/// next launch. `record` is called whenever a document is opened or saved; the
/// bookmark is refreshed each time so it stays valid as the sandbox revokes and
/// re-grants.
final class SandboxBookmarkStore {
    static let shared = SandboxBookmarkStore()

    /// The domain the bookmarks live in. Swappable so a test host does not
    /// write one bookmark per temporary file into the *user's* own preferences
    /// — which is how 9 434 of them, pointing almost entirely at deleted temp
    /// files, came to be 14 MB of it.
    static var defaults: UserDefaults = {
        // The test host is sandboxed into the *app's* container, so the suite's
        // thousands of temporary files would each leave a bookmark in the
        // user's own preferences — and did. A throwaway domain under test, as
        // the find bar's history and the panel's sizes already do.
        guard MainViewController.isRunningTests else { return .standard }
        let suite = "SandboxBookmarkStore.tests"
        let store = UserDefaults(suiteName: suite) ?? .standard
        store.removePersistentDomain(forName: suite)
        return store
    }()
    /// Read through the type rather than captured: `shared` is built once, and
    /// a test that redirects the domain afterwards must still be obeyed.
    private var defaults: UserDefaults { Self.defaults }
    private let key = "SandboxBookmarks"
    private let orderKey = "SandboxBookmarkOrder"

    /// How many files' bookmarks are worth keeping.
    ///
    /// A bookmark is a convenience — it re-earns access to a file the user
    /// already chose once — so the store is a cache, and a cache with no bound
    /// is a leak: this one grew by one entry per file ever opened and never
    /// dropped one. A few hundred is more files than a reader keeps coming
    /// back to, and the pruning below reaches the dead ones long before the
    /// cap does.
    static let limit = 300

    /// Persists a fresh security-scoped bookmark for `url`. No-op when the
    /// bookmark cannot be created (e.g. the URL is not sandbox-scoped).
    func record(_ url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let path = url.standardizedFileURL.path
            var store = load()
            store[path] = data
            var order = [path] + loadOrder().filter { $0 != path }
            prune(&store, &order)
            defaults.set(store, forKey: key)
            defaults.set(order, forKey: orderKey)
        } catch {
            // Not sandboxed or the URL carries no scope; nothing to remember.
        }
    }

    /// Drops what is not worth keeping, newest first (§D9).
    ///
    /// A bookmark to a file that is no longer there cannot be resolved and can
    /// only be dead weight, so liveness is the first cut — and on a machine
    /// that has run the test suite it is nearly the only one needed, since the
    /// suite opens thousands of temporary files. The cap is the backstop:
    /// entries the order does not know about are from before it was kept, so
    /// they go first.
    private func prune(_ store: inout [String: Data], _ order: inout [String]) {
        let manager = FileManager.default
        for path in store.keys where !manager.fileExists(atPath: path) {
            store[path] = nil
        }
        order = order.filter { store[$0] != nil }
        guard store.count > Self.limit else { return }
        let kept = Set(order.prefix(Self.limit))
        store = store.filter { kept.contains($0.key) }
        order = Array(order.prefix(Self.limit))
    }

    /// Returns a bookmark for `path` if one was recorded, else nil.
    func bookmark(for path: String) -> Data? {
        load()[path]
    }

    /// Resolves a recorded bookmark back into a URL and takes a security scope
    /// grant. Returns nil when the bookmark is stale or access is denied.
    func resolveAndStartAccess(path: String) -> URL? {
        guard let data = bookmark(for: path) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        if stale {
            record(url)
        }
        return url
    }

    // MARK: - Internals

    private func load() -> [String: Data] {
        defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
    }

    /// The paths in the order they were last recorded, newest first. Kept
    /// beside the bookmarks rather than in them: the dictionary is what every
    /// reader wants and it has no order, and adding one to its values would
    /// mean rewriting a format whose loss costs the user a re-grant.
    private func loadOrder() -> [String] {
        defaults.array(forKey: orderKey) as? [String] ?? []
    }

    /// Prunes the store without recording anything — for a host that wants to
    /// clear out what it inherited (the app's launch).
    func pruneNow() {
        var store = load()
        var order = loadOrder().filter { store[$0] != nil }
        prune(&store, &order)
        defaults.set(store, forKey: key)
        defaults.set(order, forKey: orderKey)
    }
}
