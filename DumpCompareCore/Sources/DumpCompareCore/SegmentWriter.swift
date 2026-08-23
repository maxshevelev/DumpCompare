import Foundation

/// Errors thrown by `SegmentWriter`.
///
/// The presentation layer maps these to user-facing alerts (§16). Cancellation
/// is signalled with the standard `CancellationError`, not a case here, so a
/// cancelled write is indistinguishable from any other cooperative cancellation
/// the app already handles (§14.4).
public enum SegmentWriteError: Error, Equatable, Sendable {
    /// A part could not be created or written (the directory is not writable,
    /// the disk is full, …).
    case writeFailed
    /// A part could not be renamed into place.
    case moveFailed
}

/// Writes a set of byte ranges out of a source storage as separate files, all or
/// nothing (§21.5).
///
/// The primary path writes each part to a temporary name in the target directory
/// and fsyncs it; only when every part is a complete, fsynced temp are they
/// renamed into place. A failure or a cancellation removes every temporary and
/// publishes nothing, so the directory is left exactly as it was. The read is
/// chunked (bounded slices), so a large part is streamed rather than loaded whole
/// into RAM.
///
/// This is the multi-file generalization of `StorageSaver.rewriteViaSiblingTemp`
/// (the single-file atomic write, and the lesson behind `5bbef2a`): stage each
/// part fully before any of them is published.
///
/// The sandboxed app is granted the file a panel chose, not the folder around it
/// (§5.2). A save panel therefore grants one file and its directory is not
/// writable, so the sibling temp cannot be created. When that happens and there
/// is a single part, the write falls back to writing that part straight into the
/// file the user chose — the same fallback `StorageSaver` takes for a Save As —
/// which is not atomic but is the only option the sandbox permits.
public enum SegmentWriter {
    /// One part to write: the source byte range and the file name it becomes.
    /// The range is half-open `[lowerBound, upperBound)`, the app's internal
    /// convention (§2).
    public struct Part: Sendable, Equatable {
        public let range: Range<UInt64>
        public let name: String
        public init(range: Range<UInt64>, name: String) {
            self.range = range
            self.name = name
        }
    }

    /// The read/write step; matches `StorageSaver`'s 1 MiB so a large part never
    /// loads whole into RAM.
    static let chunkSize = 1024 * 1024

    /// Writes every part of `parts` out of `source` into `directory`, all or
    /// nothing. See the type's documentation for the guarantee.
    ///
    /// `shouldCancel` is polled at each part boundary and between chunks; when it
    /// returns true the write stops, removes its temporaries, and throws
    /// `CancellationError`. `progress` is called with a fraction in [0, 1] as
    /// bytes are written and may be called from a background context. Both
    /// default to a no-op so a small write can be issued without either.
    public static func write(
        _ parts: [Part],
        from source: any ByteStorage,
        to directory: URL,
        shouldCancel: @escaping () -> Bool = { false },
        progress: @escaping (Double) -> Void = { _ in }
    ) throws {
        let total = parts.reduce(UInt64(0)) { $0 + UInt64($1.range.count) }
        guard total > 0 else { return }

        do {
            try writeViaSiblingTemps(parts, from: source, to: directory, total: total,
                                     shouldCancel: shouldCancel, progress: progress)
        } catch let error as SegmentWriteError where error == .writeFailed && parts.count == 1 {
            // The sibling temp could not be created: the sandbox grants the file
            // a save panel chose but not its folder, so a temp next to it is
            // impossible. With a single part there is nothing to keep atomic
            // against — write it straight into the file the user chose, which the
            // sandbox does cover. A multi-part write has no such fallback: it
            // needs the directory the open panel in directory mode grants.
            try writeDirectly(parts[0], from: source,
                              to: directory.appendingPathComponent(parts[0].name),
                              shouldCancel: shouldCancel, progress: progress)
        }
    }

    /// The all-or-nothing path: stage every part as a temp in `directory`, then
    /// rename them all into place. Throws `writeFailed` when a temp cannot be
    /// created (the caller decides whether a direct write is a fallback).
    private static func writeViaSiblingTemps(
        _ parts: [Part], from source: any ByteStorage, to directory: URL, total: UInt64,
        shouldCancel: @escaping () -> Bool, progress: @escaping (Double) -> Void
    ) throws {
        let fileManager = FileManager.default
        var written: UInt64 = 0
        // The (temp, final) pairs, in part order. Nothing is renamed until every
        // part is a complete, fsynced temp — that is the whole of the
        // all-or-nothing guarantee: a failure on part N leaves parts 1..N-1 as
        // temps that the cleanup below removes, so no part is ever published on
        // its own.
        var staged: [(temporary: URL, final: URL)] = []
        do {
            for part in parts {
                if shouldCancel() { throw CancellationError() }
                let final = directory.appendingPathComponent(part.name)
                let temporary = directory.appendingPathComponent(
                    ".\(part.name).dc-\(UUID().uuidString).tmp"
                )
                guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
                    throw SegmentWriteError.writeFailed
                }
                staged.append((temporary, final))
                try writePart(part, from: source, to: temporary,
                              written: &written, total: total,
                              shouldCancel: shouldCancel, progress: progress)
            }
            // Every part is a complete, fsynced temp. Rename them all into place;
            // a rename is atomic per file, so each part appears whole or not at
            // all.
            for pair in staged {
                if shouldCancel() { throw CancellationError() }
                if fileManager.fileExists(atPath: pair.final.path) {
                    _ = try fileManager.replaceItemAt(pair.final, withItemAt: pair.temporary)
                } else {
                    try fileManager.moveItem(at: pair.temporary, to: pair.final)
                }
            }
        } catch {
            // A failure (or a cancel) publishes nothing: remove every temp that
            // was staged. A temp already renamed is gone from `staged`'s temp
            // side only if we got that far — but we rename only after every part
            // is staged, so on any write-phase failure none have been renamed.
            for pair in staged {
                try? fileManager.removeItem(at: pair.temporary)
            }
            throw error
        }
    }

    /// The sandbox fallback for a single part: the app owns the file the user
    /// chose but not the folder around it, so the atomic swap is impossible and
    /// the part is written straight into the file. Not atomic — a failed write can
    /// leave a partial file — but it is the only option the sandbox permits.
    ///
    /// The part's bytes are materialized into the app's OWN temporary directory
    /// first, and only then is the target opened for writing. That order is the
    /// whole point: the target may be the very file the source reads its base
    /// from, and opening it for writing empties it — so every byte is read out
    /// before the target is touched (the lesson behind `StorageSaver`'s direct
    /// write).
    private static func writeDirectly(
        _ part: Part, from source: any ByteStorage, to file: URL,
        shouldCancel: @escaping () -> Bool, progress: @escaping (Double) -> Void
    ) throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("DumpCompare-segment-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: staging.path, contents: nil) else {
            throw SegmentWriteError.writeFailed
        }
        defer { try? fileManager.removeItem(at: staging) }

        do {
            let staged = try FileHandle(forWritingTo: staging)
            var offset = part.range.lowerBound
            let end = part.range.upperBound
            let count = part.range.count
            while offset < end {
                if shouldCancel() { throw CancellationError() }
                let step = min(UInt64(chunkSize), end - offset)
                let bytes = try source.read(at: offset, length: Int(step))
                guard !bytes.isEmpty else { break }
                try staged.write(contentsOf: Data(bytes))
                offset += UInt64(bytes.count)
                progress(Double(offset - part.range.lowerBound) / Double(count))
            }
            try staged.synchronize()
            try staged.close()
        } catch {
            throw error
        }

        // Nothing reads the target any more, so it can be emptied and refilled.
        let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw SegmentWriteError.writeFailed }
        defer { Darwin.close(fd) }

        let reader = try FileHandle(forReadingFrom: staging)
        defer { try? reader.close() }
        var copied: UInt64 = 0
        while let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty {
            try writeAll(fd, bytes: [UInt8](chunk), at: off_t(copied))
            copied += UInt64(chunk.count)
        }
        if Darwin.fsync(fd) != 0 { throw SegmentWriteError.writeFailed }
    }

    /// Streams one part's bytes out of `source` into its temp file, in bounded
    /// chunks, and fsyncs the temp. The temp is removed by the caller on failure.
    private static func writePart(
        _ part: Part, from source: any ByteStorage, to temporary: URL,
        written: inout UInt64, total: UInt64,
        shouldCancel: @escaping () -> Bool, progress: @escaping (Double) -> Void
    ) throws {
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        var offset = part.range.lowerBound
        let end = part.range.upperBound
        while offset < end {
            if shouldCancel() { throw CancellationError() }
            let step = min(UInt64(chunkSize), end - offset)
            let bytes = try source.read(at: offset, length: Int(step))
            guard !bytes.isEmpty else { break }
            try handle.write(contentsOf: Data(bytes))
            offset += UInt64(bytes.count)
            written += UInt64(bytes.count)
            progress(Double(written) / Double(total))
        }
        try handle.synchronize()
    }

    /// Loops `write(2)` until all bytes are written, retrying on EINTR.
    private static func writeAll(_ fd: Int32, bytes: [UInt8], at offset: off_t) throws {
        try bytes.withUnsafeBytes { raw -> Void in
            var total = 0
            while total < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: total), raw.count - total)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SegmentWriteError.writeFailed
                }
                if n == 0 { throw SegmentWriteError.writeFailed }
                total += n
            }
        }
    }
}
