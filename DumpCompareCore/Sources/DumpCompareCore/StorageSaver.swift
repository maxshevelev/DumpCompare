import Foundation

/// Persists an `EditOverlayStorage` to disk (§5.2 of REQUIREMENTS.md).
///
/// Two strategies:
/// - **Patch in place** when the storage holds only overwrites (no offset-shift):
///   the changed ranges are written straight into the file with `pwrite(2)`,
///   preserving every untouched byte and the file identity.
/// - **Atomic rewrite** otherwise: the full current content is streamed to a
///   temporary file next to the target and atomically swapped over it, so a
///   failed save never corrupts the original.
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

    // MARK: - Atomic rewrite

    private static func rewriteAtomically(_ storage: EditOverlayStorage, to url: URL) throws {
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

            var offset: UInt64 = 0
            let size = storage.size
            while offset < size {
                let step = min(UInt64(1024 * 1024), size - offset)
                let bytes = try storage.read(at: offset, length: Int(step))
                guard !bytes.isEmpty else { break }
                try handle.write(contentsOf: Data(bytes))
                offset += UInt64(bytes.count)
            }
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

    // MARK: - Helpers

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
