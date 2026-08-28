import Foundation

/// The byte encoding of a search pattern (§11).
/// How a scan compares letters (§11).
///
/// Folding is what makes a case-insensitive search possible without a second
/// pass over the file: fold both the pattern and the data and the fast
/// `Data.range(of:)` search does the rest. What may be folded depends on the
/// encoding, which is why this is a type rather than a `Bool`.
public enum CaseFolding: Sendable, Equatable {
    /// Byte-exact: no letter is folded. Hex is always this, and so is any
    /// encoding when the user asks for a case-sensitive search.
    case exact
    /// Fold ASCII letter *bytes*, wherever they sit — exact for a single-byte
    /// ASCII-compatible encoding (ASCII, UTF-8).
    case asciiBytes
    /// Compare UTF-16 *code units*, folding one only when it encodes an ASCII
    /// letter — that is, when its other byte is zero. A byte-wise fold cannot do
    /// this: it would fold the high byte of `U+6100` (`00 61` LE) as if it were
    /// the letter `a` and match `U+4100`, a different character (§11).
    ///
    /// Units are counted from each candidate's own start, so a string is found
    /// wherever it sits in the file. That rules out folding a whole window ahead
    /// of the search — see `firstMatch` — which costs speed and buys the truth:
    /// ~230 ms over a 16 MB dump against 3 ms for an exact scan.
    case utf16(littleEndian: Bool)

    /// The rule for an encoding and the user's choice.
    public init(encoding: SearchEncoding, caseSensitive: Bool) {
        guard !caseSensitive else { self = .exact; return }
        switch encoding {
        // Hex input is bytes; bytes have no case to fold. (The *parser* accepts
        // `de ad` and `DE AD` alike — that is the input, not the comparison.)
        case .hex: self = .exact
        case .ascii, .utf8: self = .asciiBytes
        case .utf16LE: self = .utf16(littleEndian: true)
        case .utf16BE: self = .utf16(littleEndian: false)
        }
    }
}

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
    /// `folding` decides how letters compare (§11): `.exact` is byte-for-byte,
    /// `.asciiBytes` folds ASCII letter bytes (right for ASCII and UTF-8), and
    /// `.utf16` folds a code unit only when it encodes an ASCII letter. Build it
    /// from the encoding and the user's choice with
    /// `CaseFolding(encoding:caseSensitive:)` rather than deciding here — hex is
    /// always exact, and a byte-wise fold on UTF-16 matches the wrong
    /// characters.
        public static func find(
        pattern: [UInt8],
        in storage: ByteStorage,
        from offset: UInt64 = 0,
        direction: SearchDirection = .forward,
        folding: CaseFolding = .exact,
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
        var patternBytes = pattern
        Self.foldInPlace(&patternBytes, using: folding)
        let patternData = Data(patternBytes)
        switch direction {
        case .forward:
            return try findForward(
                pattern: patternData, patternLength: patternLength,
                storage: storage, from: offset, size: size,
                chunkSize: chunkSize, folding: folding,
                shouldCancel: shouldCancel, progress: progress
            )
        case .backward:
            return try findBackward(
                pattern: patternData, patternLength: patternLength,
                storage: storage, from: offset, size: size,
                chunkSize: chunkSize, folding: folding,
                shouldCancel: shouldCancel, progress: progress
            )
        }
    }

    /// Finds every non-overlapping occurrence of `pattern` in `storage`, in
    /// file order (the Search All feature, §11).
    ///
    /// Shares `find`'s byte-domain semantics — including the caller's duty to
    /// ask for exact matching wherever byte-level folding does not model the
    /// encoding's case rules — and its chunked scanning: each
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
        folding: CaseFolding = .exact,
        chunkSize: Int = defaultChunkSize,
        shouldCancel: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) throws -> [Range<UInt64>] {
        guard !pattern.isEmpty else { throw SearchError.emptyPattern }
        let patternLength = UInt64(pattern.count)
        let size = storage.size
        guard patternLength <= size else { return [] }

        var patternBytes = pattern
        Self.foldInPlace(&patternBytes, using: folding)
        let patternData = Data(patternBytes)
        var matches: [Range<UInt64>] = []
        try scanAll(
            pattern: patternData, patternLength: patternLength, storage: storage, size: size,
            folding: folding, chunkSize: chunkSize,
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
        folding: CaseFolding = .exact,
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
                    var patternBytes = pattern
        Self.foldInPlace(&patternBytes, using: folding)
        let patternData = Data(patternBytes)
                    var found = 0
                    var capped = false
                    try scanAll(
                        pattern: patternData, patternLength: patternLength, storage: storage, size: size,
                        folding: folding, chunkSize: chunkSize,
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
    ///
    /// This is a byte operation with no notion of the encoding above it: any
    /// byte in 0x41...0x5A folds, wherever it sits. That is why case-insensitive
    /// matching is offered only for ASCII and UTF-8 (see `find`).
    @inline(__always)
    static func foldByte(_ b: UInt8) -> UInt8 {
        let lower = b | 0x20
        return (lower >= 0x61 && lower <= 0x7A) ? lower : b
    }

    /// Folds a window **in place** for the fast path, under `folding`.
    ///
    /// In place, and not `bytes.map(foldByte)`, because the window is the scan's
    /// own buffer: mapping allocated a second one for every window and handed the
    /// per-byte work to a closure the optimiser could not always inline. The
    /// caller owns `bytes` uniquely, so the mutation costs nothing to make.
    ///
    /// `.exact` has nothing to do. `.utf16` is not a position-independent map at
    /// all — a code unit is two bytes counted from the *string's* start, and a
    /// string can begin at any offset — so nothing is folded ahead of the search
    /// there; `firstMatch`/`lastMatch` compare candidates one at a time.
    static func foldInPlace(_ bytes: inout [UInt8], using folding: CaseFolding) {
        guard case .asciiBytes = folding else { return }
        // A raw pointer walk, not a buffer subscript and not `map`. Measured on
        // 16 MB, folding every byte: 48 ms this way, 918 ms through `map`, and
        // 1824 ms through `UnsafeMutableBufferPointer`'s subscript — all three
        // are the same nothing in a release build, but the suite and every debug
        // run pay the difference, and a bounds check per byte of a dump is the
        // kind of cost that hides real ones.
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var pointer = base
            let end = base + raw.count
            while pointer < end {
                pointer.pointee = Self.foldByte(pointer.pointee)
                pointer += 1
            }
        }
    }

    /// Whether the UTF-16 code unit at `a` equals the one at `b`, ignoring case.
    ///
    /// A code unit is folded only when it encodes an ASCII letter — when the byte
    /// that is not the letter is zero. So `A` (`41 00` LE) equals `a` (`61 00`),
    /// while `U+6100` (`00 61`) equals nothing but itself: the byte that would be
    /// the letter is the zero one, and its own high byte is `0x61`, which is data
    /// and not a letter (§11).
    private static func codeUnitsEqualIgnoringCase(
        _ a: (UInt8, UInt8), _ b: (UInt8, UInt8), littleEndian: Bool
    ) -> Bool {
        let (aLetter, aOther) = littleEndian ? (a.0, a.1) : (a.1, a.0)
        let (bLetter, bOther) = littleEndian ? (b.0, b.1) : (b.1, b.0)
        guard aOther == bOther else { return false }
        // Only a unit whose other byte is zero can be an ASCII letter.
        return aOther == 0 ? Self.foldByte(aLetter) == Self.foldByte(bLetter) : aLetter == bLetter
    }

    /// Whether `pattern` matches `data` at `index`, comparing UTF-16 code units
    /// taken from `index` itself — which is what makes the match independent of
    /// where the string sits in the file (no 2-byte grid, no parity).
    private static func utf16Matches(
        _ pattern: Data, in data: Data, at index: Int, littleEndian: Bool
    ) -> Bool {
        var patternIndex = pattern.startIndex
        var dataIndex = data.startIndex + index
        while patternIndex < pattern.endIndex {
            // A trailing odd byte cannot be half a code unit: compare it exactly.
            guard pattern.index(after: patternIndex) < pattern.endIndex,
                  data.index(after: dataIndex) < data.endIndex else {
                return pattern[patternIndex] == data[dataIndex]
            }
            let unitPattern = (pattern[patternIndex], pattern[pattern.index(after: patternIndex)])
            let unitData = (data[dataIndex], data[data.index(after: dataIndex)])
            guard Self.codeUnitsEqualIgnoringCase(unitPattern, unitData,
                                                  littleEndian: littleEndian) else { return false }
            patternIndex = pattern.index(patternIndex, offsetBy: 2)
            dataIndex = data.index(dataIndex, offsetBy: 2)
        }
        return true
    }

    /// The first match of `pattern` in `data` at or after `start`, as an index
    /// into `data`'s own indices.
    ///
    /// The folded encodings take `Data.range(of:)`. `.utf16` walks candidates and
    /// verifies each with `utf16Matches`, prefiltered on the pattern's first code
    /// unit so the walk costs one or two byte comparisons per offset instead of a
    /// full compare.
    static func firstMatch(of pattern: Data, in data: Data, from start: Int,
                           folding: CaseFolding) -> Int? {
        guard case .utf16(let littleEndian) = folding else {
            return data[(data.startIndex + start)...].range(of: pattern)?.lowerBound
        }
        guard !pattern.isEmpty, data.count >= pattern.count else { return nil }
        let filter = Self.firstUnitFilter(of: pattern, littleEndian: littleEndian)
        var index = max(0, start)
        let last = data.count - pattern.count
        while index <= last {
            if filter.admits(data, at: index),
               Self.utf16Matches(pattern, in: data, at: index, littleEndian: littleEndian) {
                return data.startIndex + index
            }
            index += 1
        }
        return nil
    }

    /// The last match of `pattern` in `data`, for the backward scan.
    static func lastMatch(of pattern: Data, in data: Data, folding: CaseFolding) -> Int? {
        guard case .utf16(let littleEndian) = folding else {
            return data.range(of: pattern, options: [.backwards])?.lowerBound
        }
        guard !pattern.isEmpty, data.count >= pattern.count else { return nil }
        let filter = Self.firstUnitFilter(of: pattern, littleEndian: littleEndian)
        var index = data.count - pattern.count
        while index >= 0 {
            if filter.admits(data, at: index),
               Self.utf16Matches(pattern, in: data, at: index, littleEndian: littleEndian) {
                return data.startIndex + index
            }
            index -= 1
        }
        return nil
    }

    /// The byte values a candidate's first code unit may take — the cheap gate in
    /// front of the full comparison. When that unit encodes an ASCII letter, the
    /// letter byte has two admissible values (the two cases) and the other byte
    /// must be zero; otherwise both bytes are fixed.
    private struct FirstUnitFilter {
        let byte0: (UInt8, UInt8)
        /// Nil for a one-byte pattern, where there is no second byte to gate on.
        let byte1: (UInt8, UInt8)?

        func admits(_ data: Data, at index: Int) -> Bool {
            let first = data[data.startIndex + index]
            guard first == byte0.0 || first == byte0.1 else { return false }
            guard let byte1, data.startIndex + index + 1 < data.endIndex else { return true }
            let second = data[data.startIndex + index + 1]
            return second == byte1.0 || second == byte1.1
        }
    }

    private static func firstUnitFilter(of pattern: Data, littleEndian: Bool) -> FirstUnitFilter {
        let b0 = pattern[pattern.startIndex]
        guard pattern.count >= 2 else { return FirstUnitFilter(byte0: (b0, b0), byte1: nil) }
        let b1 = pattern[pattern.index(after: pattern.startIndex)]
        let (letter, other) = littleEndian ? (b0, b1) : (b1, b0)
        let lower = letter | 0x20
        let isASCIILetter = other == 0 && lower >= 0x61 && lower <= 0x7A
        guard isASCIILetter else {
            return FirstUnitFilter(byte0: (b0, b0), byte1: (b1, b1))
        }
        let cases = (lower, lower & ~0x20)   // "a", "A"
        return littleEndian
            ? FirstUnitFilter(byte0: cases, byte1: (0, 0))
            : FirstUnitFilter(byte0: (0, 0), byte1: cases)
    }

    // MARK: - Bool-shaped compatibility    // MARK: - Bool-shaped compatibility

    /// The `Bool` form of `find`, kept for the callers that work in a
    /// single-byte encoding: `false` means the old byte-wise ASCII fold.
    public static func find(
        pattern: [UInt8],
        in storage: ByteStorage,
        from offset: UInt64 = 0,
        direction: SearchDirection = .forward,
        caseSensitive: Bool,
        chunkSize: Int = defaultChunkSize,
        shouldCancel: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) throws -> Range<UInt64>? {
        try find(pattern: pattern, in: storage, from: offset, direction: direction,
                 folding: caseSensitive ? .exact : .asciiBytes, chunkSize: chunkSize,
                 shouldCancel: shouldCancel, progress: progress)
    }

    /// The `Bool` form of `findAll`.
    public static func findAll(
        pattern: [UInt8],
        in storage: ByteStorage,
        caseSensitive: Bool,
        chunkSize: Int = defaultChunkSize,
        shouldCancel: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) throws -> [Range<UInt64>] {
        try findAll(pattern: pattern, in: storage,
                    folding: caseSensitive ? .exact : .asciiBytes, chunkSize: chunkSize,
                    shouldCancel: shouldCancel, progress: progress)
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
        folding: CaseFolding, chunkSize: Int,
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
            var bytes = try storage.read(at: cursor, length: length)
            guard !bytes.isEmpty else { break }
            Self.foldInPlace(&bytes, using: folding)
            let data = Data(bytes)

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
                guard let windowIndex = Self.firstMatch(of: pattern, in: data,
                                                        from: searchStart, folding: folding)
                else { break }
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
        from: UInt64, size: UInt64, chunkSize: Int, folding: CaseFolding,
        shouldCancel: () -> Bool, progress: (Double) -> Void
    ) throws -> Range<UInt64>? {
        // Last valid match start satisfies `m + patternLength <= size`.
        let limit = size - patternLength + 1
        var cursor = min(from, size)
        var processed: UInt64 = 0

        while cursor < limit {
            if shouldCancel() { throw CancellationError() }
            let length = Int(min(UInt64(chunkSize) + patternLength - 1, size - cursor))
            var bytes = try storage.read(at: cursor, length: length)
            guard !bytes.isEmpty else { break }
            Self.foldInPlace(&bytes, using: folding)
            let data = Data(bytes)
            if let index = Self.firstMatch(of: pattern, in: data, from: 0, folding: folding) {
                let start = cursor + UInt64(index)
                return start..<(start + patternLength)
            }

            cursor += UInt64(chunkSize)
            // Windows overlap by `patternLength - 1`, so summing their lengths
            // overshoots the file (it reported up to 1.36); report the ground
            // actually covered instead.
            processed = min(cursor, size)
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
        from: UInt64, size: UInt64, chunkSize: Int, folding: CaseFolding,
        shouldCancel: () -> Bool, progress: (Double) -> Void
    ) throws -> Range<UInt64>? {
        // Window end: the offset one past the last allowed match end. A match
        // must end at or before the caret, so a match *starting* exactly at the
        // caret is excluded — otherwise Find Previous from a caret sitting on a
        // match would keep re-finding that same match instead of moving back.
        let end = min(from, size)
        // Progress is measured over the region actually being searched — [0, end)
        // — not the whole file: a backward search from a caret near the start
        // otherwise opened at 91 % and crawled to 100 %.
        let span = end
        let windowLength = UInt64(chunkSize) + patternLength - 1
        var endExclusive = end

        while endExclusive > 0 {
            if shouldCancel() { throw CancellationError() }
            let windowStart = endExclusive > windowLength ? endExclusive - windowLength : 0
            let length = Int(endExclusive - windowStart)
            var bytes = try storage.read(at: windowStart, length: length)
            guard !bytes.isEmpty else { break }
            Self.foldInPlace(&bytes, using: folding)
            let data = Data(bytes)
            if let index = Self.lastMatch(of: pattern, in: data, folding: folding) {
                let start = windowStart + UInt64(index)
                return start..<(start + patternLength)
            }

            let step = UInt64(chunkSize)
            endExclusive = endExclusive > step ? endExclusive - step : 0
            if span > 0 { progress(Double(span - endExclusive) / Double(span)) }
        }
        if span > 0 { progress(1) }
        return nil
    }
}
