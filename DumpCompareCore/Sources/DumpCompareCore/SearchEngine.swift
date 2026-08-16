import Foundation

/// The byte encoding of a search pattern (§11).
public enum SearchEncoding: String, CaseIterable, Sendable {
    /// Input is a hexadecimal byte sequence: `DEADBEEF`, `DE AD BE EF`, or
    /// `0xDE 0xAD`, case-insensitive.
    case hex
    case ascii
    case utf8
    case utf16LE
    case utf16BE
}

public enum SearchDirection: Sendable {
    case forward
    case backward
}

public enum SearchError: Error, Equatable, Sendable {
    /// The pattern resolved to zero bytes (e.g. empty input or an empty hex).
    case emptyPattern
    /// Hex input was malformed: non-hex characters or an odd number of digits.
    case invalidHexPattern
    /// The text could not be encoded in the requested encoding.
    case undecodableText
}

/// A resolved search pattern: the exact byte sequence to find, plus the
/// encoding it came from (for display).
public struct SearchPattern: Equatable, Sendable {
    public let bytes: [UInt8]
    public let encoding: SearchEncoding

    public init(bytes: [UInt8], encoding: SearchEncoding) {
        self.bytes = bytes
        self.encoding = encoding
    }
}

/// Finds a byte sequence in a `ByteStorage` (§11).
///
/// Search reads the current storage — including any unsaved edits layered over
/// the base — so results always reflect the latest content. The scan is
/// incremental (bounded chunks with overlap across boundaries) and accepts
/// `shouldCancel`/`progress`, so large files are searched in the background
/// without blocking the UI (§11, §13.7–8).
public enum SearchEngine {
    public static let defaultChunkSize = 1024 * 1024

    /// Resolves a pattern string to bytes for the given encoding.
    public static func parsePattern(_ text: String, encoding: SearchEncoding) throws -> SearchPattern {
        let bytes: [UInt8]
        switch encoding {
        case .hex: bytes = try parseHex(text)
        case .ascii: bytes = try encode(text, using: .ascii)
        case .utf8: bytes = try encode(text, using: .utf8)
        case .utf16LE: bytes = try encode(text, using: .utf16LittleEndian)
        case .utf16BE: bytes = try encode(text, using: .utf16BigEndian)
        }
        guard !bytes.isEmpty else { throw SearchError.emptyPattern }
        return SearchPattern(bytes: bytes, encoding: encoding)
    }

    /// Finds the first (forward) or last (backward) occurrence of `pattern` in
    /// `storage`.
    ///
    /// - Forward: the first match whose start is `>= from`.
    /// - Backward: the last match whose end is `<= from`.
    ///
    /// When `caseSensitive` is false, ASCII letters compare equal regardless of
    /// case (a file "Hi" matches a pattern "HI"). This is exactly right for the
    /// text encodings — ASCII, UTF-8's ASCII subset, and the ASCII letters of
    /// UTF-16 — and never affects hex patterns or non-ASCII letters (é, ж, …),
    /// whose bytes are always matched exactly.
    ///
    /// Returns `nil` when there is no match (or the pattern cannot fit). Throws
    /// `CancellationError` when `shouldCancel` returns true between chunks.
    public static func find(
        pattern: [UInt8],
        in storage: ByteStorage,
        from offset: UInt64 = 0,
        direction: SearchDirection = .forward,
        caseSensitive: Bool = true,
        chunkSize: Int = defaultChunkSize,
        shouldCancel: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) throws -> Range<UInt64>? {
        guard !pattern.isEmpty else { throw SearchError.emptyPattern }
        let patternLength = UInt64(pattern.count)
        let size = storage.size
        guard patternLength <= size else { return nil }

        // Folding is idempotent per byte, so pattern and data can both be
        // folded and compared with the fast Data.range(of:) path (§11).
        let patternData = caseSensitive ? Data(pattern) : Data(pattern.map(Self.foldByte))
        switch direction {
        case .forward:
            return try findForward(
                pattern: patternData, patternLength: patternLength,
                storage: storage, from: offset, size: size,
                chunkSize: chunkSize, caseSensitive: caseSensitive,
                shouldCancel: shouldCancel, progress: progress
            )
        case .backward:
            return try findBackward(
                pattern: patternData, patternLength: patternLength,
                storage: storage, from: offset, size: size,
                chunkSize: chunkSize, caseSensitive: caseSensitive,
                shouldCancel: shouldCancel, progress: progress
            )
        }
    }

    /// Finds every non-overlapping occurrence of `pattern` in `storage`, in
    /// file order (the Search All feature, §11).
    ///
    /// Shares `find`'s byte-domain semantics — case-insensitive ASCII folding
    /// for text encodings, exact bytes for hex — and its chunked scanning: each
    /// window is `chunkSize + patternLength - 1` bytes so a match crossing a
    /// boundary is still found, and only matches starting in a window's fresh
    /// portion are recorded (a match starting in the overlap is found by the
    /// next window, never counted twice). Consecutive matches never overlap: the
    /// scan resumes just past each match's end, exactly as a sequence of
    /// Find Next searches would land.
    ///
    /// Reports `progress` (0…1) as chunks are covered and throws
    /// `CancellationError` when `shouldCancel` returns true between chunks, so a
    /// Search All over a large file runs in the background like a single search.
    /// Returns an empty array when the pattern cannot fit or never occurs.
    public static func findAll(
        pattern: [UInt8],
        in storage: ByteStorage,
        caseSensitive: Bool = true,
        chunkSize: Int = defaultChunkSize,
        shouldCancel: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) throws -> [Range<UInt64>] {
        guard !pattern.isEmpty else { throw SearchError.emptyPattern }
        let patternLength = UInt64(pattern.count)
        let size = storage.size
        guard patternLength <= size else { return [] }

        let patternData = caseSensitive ? Data(pattern) : Data(pattern.map(Self.foldByte))
        var matches: [Range<UInt64>] = []
        try scanAll(
            pattern: patternData, patternLength: patternLength, storage: storage, size: size,
            caseSensitive: caseSensitive, chunkSize: chunkSize,
            shouldCancel: shouldCancel, progress: progress
        ) { matches.append($0) }
        return matches
    }

    /// The default cap on how many matches a Search All reports (§11). A pattern
    /// that occurs more often stops the scan at the cap: searching for a single
    /// byte in a large file must not scan for, or report, millions of rows.
    public static let defaultMaxResults = 1000

    /// Streaming variant of `findAll`: yields every non-overlapping match as the
    /// scan finds it — one `Range` per occurrence, in file order, delivered the
    /// moment it is found, so a results table can grow a row at a time while a
    /// large file is still being scanned. The scan runs on a detached task and
    /// reports `progress` exactly like `findAll` (§11).
    ///
    /// The stream yields at most `maxResults` matches: once the cap is reached
    /// the scan stops early and the stream finishes normally, so the caller sees
    /// a capped search as `count == maxResults` rather than an error. Cancelling
    /// the consuming task (or abandoning the stream) stops the scan promptly,
    /// though on this platform a cancelled task's `next()` returns `nil` rather
    /// than throwing `CancellationError` — the caller tells a cancelled run from
    /// a completed one by checking `Task.isCancelled` after the loop. Scan errors
    /// are forwarded as the stream's failure.
    public static func findAllStream(
        pattern: [UInt8],
        in storage: ByteStorage,
        caseSensitive: Bool = true,
        chunkSize: Int = defaultChunkSize,
        maxResults: Int = defaultMaxResults,
        // By default the scan observes the detached task's own cancellation, so
        // `onTermination` (a cancelled consumer) actually stops it mid-flight.
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled },
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) -> AsyncThrowingStream<Range<UInt64>, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    guard !pattern.isEmpty else { throw SearchError.emptyPattern }
                    let patternLength = UInt64(pattern.count)
                    let size = storage.size
                    guard patternLength <= size, maxResults > 0 else {
                        continuation.finish()
                        return
                    }
                    let patternData = caseSensitive ? Data(pattern) : Data(pattern.map(Self.foldByte))
                    var found = 0
                    var capped = false
                    try scanAll(
                        pattern: patternData, patternLength: patternLength, storage: storage, size: size,
                        caseSensitive: caseSensitive, chunkSize: chunkSize,
                        shouldCancel: shouldCancel, progress: progress, shouldStop: { capped }
                    ) { match in
                        // Past the cap, report nothing more; `shouldStop` then
                        // ends the scan at the next chunk boundary.
                        guard found < maxResults else { return }
                        continuation.yield(match)
                        found += 1
                        if found >= maxResults { capped = true }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Parsing

    /// Parses a hexadecimal byte sequence. Whitespace between bytes is ignored,
    /// and `0x`/`0X` prefixes are tolerated on each token (§11 mode 1).
    private static func parseHex(_ text: String) throws -> [UInt8] {
        var digits = ""
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            var slice = Substring(token)
            if slice.lowercased().hasPrefix("0x") {
                slice = slice.dropFirst(2)
            }
            guard !slice.isEmpty else { throw SearchError.invalidHexPattern }
            guard slice.allSatisfy({ $0.isHexDigit }) else { throw SearchError.invalidHexPattern }
            digits += slice
        }
        guard !digits.isEmpty, digits.count % 2 == 0 else { throw SearchError.invalidHexPattern }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(after: index)
            let pair = digits[index...next]
            guard let byte = UInt8(pair, radix: 16) else { throw SearchError.invalidHexPattern }
            bytes.append(byte)
            index = digits.index(after: next)
        }
        return bytes
    }

    private static func encode(_ text: String, using encoding: String.Encoding) throws -> [UInt8] {
        guard let data = text.data(using: encoding) else { throw SearchError.undecodableText }
        return Array(data)
    }

    /// Maps an ASCII letter to its lowercase form and leaves every other byte
    /// unchanged. Two bytes compare equal case-insensitively exactly when their
    /// folded forms are equal, so folding both sides lets the case-insensitive
    /// scan reuse `Data.range(of:)` instead of a byte-by-byte comparison.
    static func foldByte(_ b: UInt8) -> UInt8 {
        let lower = b | 0x20
        return (lower >= 0x61 && lower <= 0x7A) ? lower : b
    }

    // MARK: - Scanning

    /// The shared Search All scan: walks `storage` in `chunkSize`-sized windows
    /// (with `patternLength - 1` bytes of overlap) and reports every match that
    /// starts in a window's fresh portion through `matchFound`, in file order.
    /// `findAll` collects the matches; `findAllStream` yields them one at a time.
    /// Both share the non-overlap rule (resume just past each match) and the
    /// `shouldCancel`/`progress` behavior, so the two APIs stay byte-for-byte
    /// identical in their results. `shouldStop` — checked like `shouldCancel` but
    /// ending the scan early without an error — lets `findAllStream` cap the
    /// result count (§11).
    private static func scanAll(
        pattern: Data, patternLength: UInt64, storage: ByteStorage, size: UInt64,
        caseSensitive: Bool, chunkSize: Int,
        shouldCancel: () -> Bool, progress: (Double) -> Void,
        shouldStop: () -> Bool = { false },
        matchFound: (Range<UInt64>) -> Void
    ) throws {
        let windowLength = UInt64(chunkSize) + patternLength - 1
        // The first offset at which the next match may start. Carried across
        // windows so a match found in one window's overlap is not re-reported by
        // the next window (non-overlapping matches, §11).
        var nextSearchStart: UInt64 = 0
        var cursor: UInt64 = 0
        var processed: UInt64 = 0
        var stoppedEarly = false

        while cursor < size {
            if shouldCancel() { throw CancellationError() }
            if shouldStop() { stoppedEarly = true; break }
            let length = Int(min(windowLength, size - cursor))
            let bytes = try storage.read(at: cursor, length: length)
            guard !bytes.isEmpty else { break }
            let data = caseSensitive ? Data(bytes) : Data(bytes.map(Self.foldByte))

            // Record a match only while it starts in the fresh portion
            // `[cursor, cursor + chunkSize)`; one starting in the overlap is
            // found again by the next window, and recording it here would count
            // it twice. Resuming just past each match keeps the results
            // non-overlapping. `nextSearchStart` may already lie before this
            // window's cursor (a match's tail), so clamp the skip to 0.
            var searchStart = nextSearchStart > cursor ? Int(nextSearchStart - cursor) : 0
            while searchStart < chunkSize, searchStart < length {
                if shouldStop() { stoppedEarly = true; break }
                // `Data` slices keep their parent's indices, so a match's
                // `lowerBound` is already a global index — no offset by
                // `searchStart` (the search starts at `searchStart`).
                guard let match = data[searchStart..<length].range(of: pattern) else { break }
                let windowIndex = match.lowerBound
                let start = cursor + UInt64(windowIndex)
                guard start < cursor + UInt64(chunkSize) else { break }  // starts in the overlap
                matchFound(start..<(start + patternLength))
                nextSearchStart = start + patternLength
                searchStart = windowIndex + pattern.count
            }

            cursor += UInt64(chunkSize)
            processed += UInt64(bytes.count)
            if size > 0 { progress(min(Double(processed) / Double(size), 1)) }
        }
        // A scan stopped by the match cap covered only part of the file, so it
        // must not report 100% — the caller keeps the partial progress instead.
        if size > 0, !stoppedEarly { progress(1) }
    }

    /// Scans forward from `from`; each chunk is `chunkSize + patternLength - 1`
    /// bytes so matches crossing a boundary are still found, and the cursor
    /// advances `chunkSize` (overlap keeps the window gap-free).
    private static func findForward(
        pattern: Data, patternLength: UInt64, storage: ByteStorage,
        from: UInt64, size: UInt64, chunkSize: Int, caseSensitive: Bool,
        shouldCancel: () -> Bool, progress: (Double) -> Void
    ) throws -> Range<UInt64>? {
        // Last valid match start satisfies `m + patternLength <= size`.
        let limit = size - patternLength + 1
        var cursor = min(from, size)
        var processed: UInt64 = 0

        while cursor < limit {
            if shouldCancel() { throw CancellationError() }
            let length = Int(min(UInt64(chunkSize) + patternLength - 1, size - cursor))
            let bytes = try storage.read(at: cursor, length: length)
            guard !bytes.isEmpty else { break }

            let data = caseSensitive ? Data(bytes) : Data(bytes.map(Self.foldByte))
            if let match = data.range(of: pattern) {
                let start = cursor + UInt64(match.lowerBound)
                return start..<(start + patternLength)
            }

            cursor += UInt64(chunkSize)
            processed += UInt64(bytes.count)
            if size > 0 { progress(Double(processed) / Double(size)) }
        }
        if size > 0 { progress(1) }
        return nil
    }

    /// Scans backward from `from` for the last match ending at or before it.
    ///
    /// Each window is `chunkSize + patternLength - 1` bytes ending at
    /// `endExclusive`; after a miss the window end steps back by `chunkSize`,
    /// leaving `patternLength - 1` bytes of overlap so a match straddling a
    /// window boundary is still found (mirror of `findForward`).
    private static func findBackward(
        pattern: Data, patternLength: UInt64, storage: ByteStorage,
        from: UInt64, size: UInt64, chunkSize: Int, caseSensitive: Bool,
        shouldCancel: () -> Bool, progress: (Double) -> Void
    ) throws -> Range<UInt64>? {
        // Window end: the offset one past the last allowed match end. A match
        // must end at or before the caret, so a match *starting* exactly at the
        // caret is excluded — otherwise Find Previous from a caret sitting on a
        // match would keep re-finding that same match instead of moving back.
        let end = min(from, size)
        let windowLength = UInt64(chunkSize) + patternLength - 1
        var endExclusive = end

        while endExclusive > 0 {
            if shouldCancel() { throw CancellationError() }
            let windowStart = endExclusive > windowLength ? endExclusive - windowLength : 0
            let length = Int(endExclusive - windowStart)
            let bytes = try storage.read(at: windowStart, length: length)
            guard !bytes.isEmpty else { break }

            let data = caseSensitive ? Data(bytes) : Data(bytes.map(Self.foldByte))
            if let match = data.range(of: pattern, options: [.backwards]) {
                let start = windowStart + UInt64(match.lowerBound)
                return start..<(start + patternLength)
            }

            let step = UInt64(chunkSize)
            endExclusive = endExclusive > step ? endExclusive - step : 0
            if size > 0 { progress(1 - Double(endExclusive) / Double(size)) }
        }
        if size > 0 { progress(1) }
        return nil
    }
}
