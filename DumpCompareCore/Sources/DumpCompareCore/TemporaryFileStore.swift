import Foundation

/// Creates and tracks temporary files for copy-on-write materialization
/// (§13 of REQUIREMENTS.md: "Use file-backed temporary storage for edits when
/// necessary"). All files live in a private per-instance directory that is
/// removed when the store is deallocated.
public final class TemporaryFileStore: @unchecked Sendable {
    private let lock = NSLock()
    /// The private directory this store's files live in. Internal rather than
    /// private so a test can look at what a storage actually put there — whether
    /// a snapshot cloned the file or copied it (§23.4).
    let directory: URL
    private var created: [URL] = []

    public init() {
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DumpCompare-\(UUID().uuidString)", isDirectory: true)
    }

    /// Creates and returns a new (empty) temporary file URL.
    public func createTempURL() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let url = try reserveLocked()
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw StorageError.writeFailed
        }
        return url
    }

    /// Reserves a temporary file URL **without** creating the file, for the
    /// callers that need the path to be free: `clonefile(2)` refuses a
    /// destination that already exists (§23). The URL is tracked like a created
    /// one, so the store still removes it.
    public func reserveTempURL() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        return try reserveLocked()
    }

    /// Picks a free URL in the store's directory and records it. The caller
    /// holds the lock.
    private func reserveLocked() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString)
        created.append(url)
        return url
    }

    /// Removes every file created by this store except `url` — the one a storage
    /// has just materialized into. Keeping the earlier ones was how a typing
    /// session ended up with one full copy of the file per keystroke on disk.
    public func removeAll(except url: URL) {
        lock.lock()
        defer { lock.unlock() }
        let keep = url.standardizedFileURL
        for candidate in created where candidate.standardizedFileURL != keep {
            try? FileManager.default.removeItem(at: candidate)
        }
        created = created.filter { $0.standardizedFileURL == keep }
    }

    /// Removes every file created by this store.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        for url in created {
            try? FileManager.default.removeItem(at: url)
        }
        created.removeAll()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
