import Foundation

/// A `ByteSource` that keeps the last window it read from another one, so a
/// parse pays one read per window instead of one per field.
///
/// The parser reads in small, mostly forward steps — a dword here, a GUID
/// there — and each of them is a round trip to the source. Against the app's
/// live storage that is a lock and a chunk lookup for four bytes, and the NVRAM
/// store walk of §9 asks twelve recognisers at every byte no store claimed: a
/// quarter-megabyte run of written-over padding inside one volume is three
/// million round trips for bytes that were already in hand. Measured on a
/// 16 MiB image, opening that one volume took 6.8 seconds.
///
/// Only small reads are windowed. A scan asking for its next megabyte, or a
/// free-space check walking a volume in 64 KiB chunks, is already reading in
/// bulk and would do nothing but evict the window, so anything over
/// `maximumCachedRead` goes straight through.
///
/// Not thread-safe, and it does not need to be: one of these belongs to one
/// `Parser`, and a `Parser` is built, used and dropped inside a single
/// materialization on a single thread. `@unchecked Sendable` is the price of
/// `ByteSource` being `Sendable` — nothing ever hands one across.
///
/// The window is a read cache, so a source whose bytes change under it can be
/// read inconsistently within one parse. That is already true of a live source
/// without it — a parse is not a snapshot — and it is what invalidation exists
/// to answer.
final class WindowedByteSource: ByteSource, @unchecked Sendable {
    /// Reads longer than this are the caller's own bulk reads; they pass
    /// through. Every header field this parser reads is far shorter — the
    /// longest is a 16-byte GUID.
    private static let maximumCachedRead: UInt64 = 512

    private let source: any ByteSource
    private let size: UInt64
    private var window: Range<UInt64> = 0..<0
    private var cache: [UInt8] = []

    init(_ source: any ByteSource, window size: UInt64 = 64 * 1024) {
        self.source = source
        self.size = size
    }

    var byteCount: UInt64 { source.byteCount }

    func bytes(in range: Range<UInt64>) -> [UInt8] {
        guard let start = windowStart(covering: range) else { return source.bytes(in: range) }
        let from = Int(range.lowerBound - start)
        return Array(cache[from..<(from + range.count)])
    }

    func word(at offset: UInt64, count: Int) -> UInt64 {
        let range = offset..<(offset + UInt64(count))
        guard let start = windowStart(covering: range) else {
            return ByteSourceWord.assemble(source.bytes(in: range))
        }
        var value: UInt64 = 0
        let from = Int(offset - start)
        for index in (0..<count).reversed() {
            value = value << 8 | UInt64(cache[from + index])
        }
        return value
    }

    /// Makes sure `range` is inside the window and answers where the window
    /// starts, or nil for a read that is not worth windowing.
    private func windowStart(covering range: Range<UInt64>) -> UInt64? {
        guard range.count <= Int(Self.maximumCachedRead) else { return nil }
        if window.lowerBound <= range.lowerBound, range.upperBound <= window.upperBound {
            return window.lowerBound
        }
        let end = min(range.lowerBound + size, byteCount)
        guard end >= range.upperBound else { return nil }
        cache = source.bytes(in: range.lowerBound..<end)
        guard cache.count == Int(end - range.lowerBound) else {
            cache = []
            window = 0..<0
            return nil
        }
        window = range.lowerBound..<end
        return window.lowerBound
    }
}
