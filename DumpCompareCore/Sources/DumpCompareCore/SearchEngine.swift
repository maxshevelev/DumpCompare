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
    /// Returns `nil` when there is no match (or the pattern cannot fit). Throws
    /// `CancellationError` when `shouldCancel` returns true between chunks.
    public static func find(
        pattern: [UInt8],
        in storage: ByteStorage,
        from offset: UInt64 = 0,
        direction: SearchDirection = .forward,
        chunkSize: Int = defaultChunkSize,
        shouldCancel: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) throws -> Range<UInt64>? {
        guard !pattern.isEmpty else { throw SearchError.emptyPattern }
        let patternLength = UInt64(pattern.count)
        let size = storage.size
        guard patternLength <= size else { return nil }

        let patternData = Data(pattern)
        switch direction {
        case .forward:
            return try findForward(
                pattern: patternData, patternLength: patternLength,
                storage: storage, from: offset, size: size,
                chunkSize: chunkSize, shouldCancel: shouldCancel, progress: progress
            )
        case .backward:
            return try findBackward(
                pattern: patternData, patternLength: patternLength,
                storage: storage, from: offset, size: size,
                chunkSize: chunkSize, shouldCancel: shouldCancel, progress: progress
            )
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

    // MARK: - Scanning

    /// Scans forward from `from`; each chunk is `chunkSize + patternLength - 1`
    /// bytes so matches crossing a boundary are still found, and the cursor
    /// advances `chunkSize` (overlap keeps the window gap-free).
    private static func findForward(
        pattern: Data, patternLength: UInt64, storage: ByteStorage,
        from: UInt64, size: UInt64, chunkSize: Int,
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

            let data = Data(bytes)
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
        from: UInt64, size: UInt64, chunkSize: Int,
        shouldCancel: () -> Bool, progress: (Double) -> Void
    ) throws -> Range<UInt64>? {
        // Window end: the offset one past the last allowed match end.
        let end = from >= size ? size : min(size, from + 1)
        let windowLength = UInt64(chunkSize) + patternLength - 1
        var endExclusive = end

        while endExclusive > 0 {
            if shouldCancel() { throw CancellationError() }
            let windowStart = endExclusive > windowLength ? endExclusive - windowLength : 0
            let length = Int(endExclusive - windowStart)
            let bytes = try storage.read(at: windowStart, length: length)
            guard !bytes.isEmpty else { break }

            let data = Data(bytes)
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
