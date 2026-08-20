import Foundation

/// Creates and tracks temporary files for copy-on-write materialization
/// (§13 of REQUIREMENTS.md: "Use file-backed temporary storage for edits when
/// necessary"). All files live in a private per-instance directory that is
/// removed when the store is deallocated.
public final class TemporaryFileStore: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private var created: [URL] = []

    public init() {
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DumpCompare-\(UUID().uuidString)", isDirectory: true)
    }

    /// Creates and returns a new (empty) temporary file URL.
    public func createTempURL() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw StorageError.writeFailed
        }
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
