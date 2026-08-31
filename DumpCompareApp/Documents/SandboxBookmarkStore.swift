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

    private let defaults: UserDefaults
    private let key = "SandboxBookmarks"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Persists a fresh security-scoped bookmark for `url`. No-op when the
    /// bookmark cannot be created (e.g. the URL is not sandbox-scoped).
    func record(_ url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var store = load()
            store[url.standardizedFileURL.path] = data
            defaults.set(store, forKey: key)
        } catch {
            // Not sandboxed or the URL carries no scope; nothing to remember.
        }
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
}
