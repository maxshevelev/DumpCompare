import Foundation

/// Persists an `EditOverlayStorage` to disk (§5.2 of REQUIREMENTS.md).
///
/// Two strategies:
/// - **Patch in place** when the storage holds only overwrites (no offset-shift):
///   the changed ranges are written straight into the file with `pwrite(2)`,
///   preserving every untouched byte and the file identity.
/// - **Full rewrite** otherwise: the full current content is streamed to a
///   temporary file next to the target and atomically swapped over it, so a
///   failed save never corrupts the original. The sandboxed app has no access
///   to the target's directory, so when the sibling temp file cannot be created
///   the content is written straight into the user-selected file instead.
public enum StorageSaver {
    public static func save(_ storage: EditOverlayStorage, to url: URL) throws {
        // Patching in place is safe only when the target is the very file the
        // storage's base reads from: untouched offsets on disk must still match
        // the base. A Save As to a new location must always rewrite fully.
        let isOriginalFile = storage.originalURL.map { areSameFile($0, url) } ?? false
        if storage.canPatchInPlace && isOriginalFile {
            try patchInPlace(storage, to: url)
        } else {
            try rewriteAtomically(storage, to: url)
        }
    }

    private static func areSameFile(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath() == b.standardizedFileURL.resolvingSymlinksInPath()
    }

    // MARK: - Patch in place

    private static func patchInPlace(_ storage: EditOverlayStorage, to url: URL) throws {
        let ranges = storage.changedRanges
        guard !ranges.isEmpty else { return }

        let fd = Darwin.open(url.path, O_WRONLY)
        guard fd >= 0 else { throw StorageError.fromOpenError(errno) }
        defer { Darwin.close(fd) }

        for range in ranges {
            let bytes = try storage.read(at: range.lowerBound, length: Int(range.count))
            try pwriteAll(fd, bytes: bytes, at: off_t(range.lowerBound))
        }
        if Darwin.fsync(fd) != 0 {
            throw StorageError.writeFailed
        }
    }

    // MARK: - Full rewrite

    /// Writes the full current content to `url`, atomically when the environment
    /// allows. The primary path materializes the content in a temp file next to
    /// the target and swaps it over, so a failed save never corrupts the
    /// original. The sandboxed app has access only to the user-selected file,
    /// not to its directory, so it cannot create the sibling temp file — in that
    /// case the content is written straight into the file the user chose, which
    /// the sandbox does cover.
    private static func rewriteAtomically(_ storage: EditOverlayStorage, to url: URL) throws {
        do {
            try rewriteViaSiblingTemp(storage, to: url)
        } catch let error as StorageError where error == .writeFailed {
            // The sibling temp file could not be created (sandboxed app, or the
            // directory is otherwise not writable). Fall back to a direct write.
            try rewriteDirectly(storage, to: url)
        }
    }

    /// Materializes the content in a temp file next to `url` and swaps it into
    /// place, so a failed save leaves the original untouched.
    private static func rewriteViaSiblingTemp(_ storage: EditOverlayStorage, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).dc-\(UUID().uuidString).tmp"
        )
        let fileManager = FileManager.default

        do {
            guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw StorageError.writeFailed
            }
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try writeContent(of: storage, to: handle)
            try handle.synchronize()
            try handle.close()

            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// Writes the full content into `url` itself, for when the atomic swap is
    /// impossible because the target's directory is not writable (the sandbox:
    /// the app owns the user-selected file but not the folder around it, so
    /// `open(2)` succeeds where creating a sibling does not). Not atomic — a
    /// failed save can leave a partial file — but it is the only option the
    /// sandbox permits.
    ///
    /// The content is materialized into the app's OWN temporary directory first,
    /// and only then does the target get opened for writing. That order is the
    /// whole point: on a plain Save the target *is* the file the overlay still
    /// reads its base from, and opening it for writing empties it — so reading
    /// the content afterwards read a truncated base and wrote its zero padding
    /// over the user's dump. A three-byte file with one inserted byte was saved
    /// as `00 FF 00 00`.
    private static func rewriteDirectly(_ storage: EditOverlayStorage, to url: URL) throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("DumpCompare-save-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: staging.path, contents: nil) else {
            throw StorageError.writeFailed
        }
        defer { try? fileManager.removeItem(at: staging) }

        let staged = try FileHandle(forWritingTo: staging)
        do {
            try writeContent(of: storage, to: staged)
            try staged.synchronize()
            try staged.close()
        } catch {
            try? staged.close()
            throw error
        }

        // Nothing reads the target any more, so it can be emptied and refilled.
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw StorageError.fromOpenError(errno) }
        defer { Darwin.close(fd) }

        let reader = try FileHandle(forReadingFrom: staging)
        defer { try? reader.close() }
        var offset: UInt64 = 0
        while let chunk = try reader.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try pwriteAll(fd, bytes: [UInt8](chunk), at: off_t(offset))
            offset += UInt64(chunk.count)
        }
        if Darwin.fsync(fd) != 0 {
            throw StorageError.writeFailed
        }
    }

    // MARK: - Helpers

    /// Streams the storage's full content to `handle` in bounded chunks.
    private static func writeContent(of storage: EditOverlayStorage, to handle: FileHandle) throws {
        var offset: UInt64 = 0
        let size = storage.size
        while offset < size {
            let step = min(UInt64(1024 * 1024), size - offset)
            let bytes = try storage.read(at: offset, length: Int(step))
            guard !bytes.isEmpty else { break }
            try handle.write(contentsOf: Data(bytes))
            offset += UInt64(bytes.count)
        }
    }

    /// Loops `pwrite(2)` until all bytes are written, retrying on EINTR.
    private static func pwriteAll(_ fd: Int32, bytes: [UInt8], at offset: off_t) throws {
        try bytes.withUnsafeBytes { raw -> Void in
            var total = 0
            while total < raw.count {
                let n = Darwin.pwrite(fd, raw.baseAddress!.advanced(by: total), raw.count - total, offset + off_t(total))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw StorageError.writeFailed
                }
                if n == 0 { throw StorageError.writeFailed }
                total += n
            }
        }
    }
}
