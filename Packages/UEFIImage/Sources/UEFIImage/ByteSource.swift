import Foundation

/// Where an image's bytes come from.
///
/// A protocol rather than `Data`, because the app already holds the open file
/// as a chunked, zero-copy snapshot and turning that into one contiguous buffer
/// would copy tens of megabytes for a parse that only ever reads headers. The
/// package ships a `Data` conformance so `swift test` can build an image by
/// hand and hand it straight over.
///
/// Implementations may assume `range` is within `count`: `ImageReader` checks
/// every range before it asks, which is the check `Design/UEFI/UEFI_IMAGE_FORMAT.md`
/// §11 insists on and the one place worth having it.
public protocol ByteSource: Sendable {
    /// Named `byteCount` and not `count` so that `Data` and `[UInt8]` can
    /// conform without colliding with the `Int` count they already have.
    var byteCount: UInt64 { get }
    func bytes(in range: Range<UInt64>) -> [UInt8]

    /// `count` bytes at `offset`, little-endian, as one number — `count` is
    /// 1 to 8 and the range is the caller's to have checked, exactly as for
    /// `bytes(in:)`.
    ///
    /// Every field this parser reads is one of these, and there are millions
    /// of them in a walk that steps byte by byte, so a source that can answer
    /// without building an array says so here. The default does build one, so
    /// conforming to this protocol still costs one method.
    func word(at offset: UInt64, count: Int) -> UInt64
}

extension ByteSource {
    public func word(at offset: UInt64, count: Int) -> UInt64 {
        ByteSourceWord.assemble(bytes(in: offset..<(offset + UInt64(count))))
    }
}

/// The little-endian assembly every `word(at:count:)` ends in, in one place.
public enum ByteSourceWord {
    public static func assemble(_ bytes: [UInt8]) -> UInt64 {
        var value: UInt64 = 0
        for index in (0..<bytes.count).reversed() {
            value = value << 8 | UInt64(bytes[index])
        }
        return value
    }
}

extension Data: ByteSource {
    public var byteCount: UInt64 { UInt64(count) }

    public func bytes(in range: Range<UInt64>) -> [UInt8] {
        let start = index(startIndex, offsetBy: Int(range.lowerBound))
        let end = index(startIndex, offsetBy: Int(range.upperBound))
        return [UInt8](self[start..<end])
    }

    public func word(at offset: UInt64, count: Int) -> UInt64 {
        var value: UInt64 = 0
        for step in (0..<count).reversed() {
            value = value << 8 | UInt64(self[index(startIndex, offsetBy: Int(offset) + step)])
        }
        return value
    }
}

extension Array: ByteSource where Element == UInt8 {
    public var byteCount: UInt64 { UInt64(count) }

    public func bytes(in range: Range<UInt64>) -> [UInt8] {
        Array(self[Int(range.lowerBound)..<Int(range.upperBound)])
    }

    public func word(at offset: UInt64, count: Int) -> UInt64 {
        var value: UInt64 = 0
        for step in (0..<count).reversed() {
            value = value << 8 | UInt64(self[Int(offset) + step])
        }
        return value
    }
}

/// Bounds-checked, little-endian reads over a `ByteSource`.
///
/// Every field the parser reads comes from untrusted data, so every read
/// returns an optional and every range is built through `range(at:count:)`,
/// which is written to survive the additions that overflow — `offset + size` on
/// a 64-bit type where both came out of a corrupt image (§11). A parser that
/// bounds-checks in one place is a parser where "did we check?" has one answer.
///
/// Offsets are absolute, from the start of the image, never relative to a
/// parent. Nesting is deep here — volume, file, section, volume again — and
/// relative offsets that far down are how a node ends up drawn in the wrong
/// place.
public struct ImageReader: Sendable {
    public let source: ByteSource

    public init(_ source: ByteSource) {
        self.source = source
    }

    public var count: UInt64 { source.byteCount }

    /// The whole image as one range.
    public var all: Range<UInt64> { 0..<count }

    /// `offset..<(offset + count)`, or nil if that would overflow or run past
    /// the end of the image.
    public func range(at offset: UInt64, count: UInt64) -> Range<UInt64>? {
        let (end, overflowed) = offset.addingReportingOverflow(count)
        guard !overflowed, end <= self.count else { return nil }
        return offset..<end
    }

    public func has(_ range: Range<UInt64>) -> Bool {
        range.upperBound <= count
    }

    public func bytes(_ range: Range<UInt64>) -> [UInt8]? {
        guard has(range) else { return nil }
        guard !range.isEmpty else { return [] }
        return source.bytes(in: range)
    }

    public func bytes(at offset: UInt64, count: UInt64) -> [UInt8]? {
        guard let range = range(at: offset, count: count) else { return nil }
        return bytes(range)
    }

    /// The fields, all through `ByteSource.word(at:count:)`: bounds-checked
    /// here, assembled by whoever can do it cheapest. A source with the bytes
    /// already in hand answers without building an array, which is what keeps
    /// a walk that reads a dword at every byte from allocating millions of
    /// them.
    public func uint8(at offset: UInt64) -> UInt8? {
        guard range(at: offset, count: 1) != nil else { return nil }
        return UInt8(truncatingIfNeeded: source.word(at: offset, count: 1))
    }

    public func uint16(at offset: UInt64) -> UInt16? {
        guard range(at: offset, count: 2) != nil else { return nil }
        return UInt16(truncatingIfNeeded: source.word(at: offset, count: 2))
    }

    /// The three-byte size field FFS files and sections use (§0).
    public func uint24(at offset: UInt64) -> UInt32? {
        guard range(at: offset, count: 3) != nil else { return nil }
        return UInt32(truncatingIfNeeded: source.word(at: offset, count: 3))
    }

    public func uint32(at offset: UInt64) -> UInt32? {
        guard range(at: offset, count: 4) != nil else { return nil }
        return UInt32(truncatingIfNeeded: source.word(at: offset, count: 4))
    }

    public func uint64(at offset: UInt64) -> UInt64? {
        guard range(at: offset, count: 8) != nil else { return nil }
        return source.word(at: offset, count: 8)
    }

    public func guid(at offset: UInt64) -> EFIGUID? {
        guard let bytes = bytes(at: offset, count: 16) else { return nil }
        return EFIGUID(bytes: bytes)
    }

    /// Whether every byte of `range` is `byte` — how free space, an empty
    /// padding element and an empty microcode slot are told apart from data.
    /// Reads in chunks: free space is routinely megabytes, and the answer is
    /// usually decided by the first one.
    public func isFilled(_ range: Range<UInt64>, with byte: UInt8) -> Bool {
        guard has(range) else { return false }
        var filled = true
        forEachChunk(of: range) { chunk in
            filled = chunk.allSatisfy { $0 == byte }
            return filled
        }
        return filled
    }

    /// The first byte of `range` that is not `byte`, or nil if there is none.
    /// This is how the end of a volume's free space is found (§5.8), so it has
    /// to read in chunks: the range is usually most of a volume.
    public func firstOffset(in range: Range<UInt64>, notEqualTo byte: UInt8) -> UInt64? {
        var found: UInt64?
        var scanned: UInt64 = 0
        forEachChunk(of: range) { chunk in
            if let index = chunk.firstIndex(where: { $0 != byte }) {
                found = range.lowerBound + scanned + UInt64(index)
                return false
            }
            scanned += UInt64(chunk.count)
            return true
        }
        return found
    }

    /// Walks `range` in chunks, stopping early when `body` returns false. Out
    /// of bounds is no chunks at all, which every caller reads as "nothing
    /// matched" rather than as a silent success.
    public func forEachChunk(
        of range: Range<UInt64>,
        size: UInt64 = 64 * 1024,
        _ body: ([UInt8]) -> Bool
    ) {
        guard has(range), size > 0 else { return }
        var offset = range.lowerBound
        while offset < range.upperBound {
            let end = min(offset + size, range.upperBound)
            guard body(source.bytes(in: offset..<end)) else { return }
            offset = end
        }
    }
}
