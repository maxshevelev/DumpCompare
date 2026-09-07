import Foundation

/// Where every occurrence of one search pattern is, in one file
/// (`Design/FIND_HIGHLIGHT_PLAN.md`, §11).
///
/// Activating a search scans the whole file, so that one scan is the single
/// source for everything downstream: the dump's greys, the find indicator, Find
/// Next (an index step, not a fresh scan), the count in the Find bar, the
/// results panel and both minimap modes. They cannot disagree, because they read
/// this.
///
/// A match is one number — its start — because every match has the pattern's
/// byte length. How those numbers are held follows their density, and the
/// representation is what keeps the set exact instead of truncated:
///
/// - `sparse`: sorted starts, 8 bytes each. What a signature search produces.
/// - `bitmap`: a bit per offset, `extent / 8` bytes, exact at *any* count. Taken
///   over from `sparse` at `extent / 64` matches — the count where the two cost
///   the same — so a 16 MB dump costs at most 2 MB whatever the pattern is.
/// - `counted`: the total alone. Only for an image so large that even its bitmap
///   would not fit `maxIndexBytes`; the count stays exact there, and the app
///   turns highlighting off and says why rather than showing a partial one.
///
/// The set knows nothing about which match the user is standing on: "3 of 128"
/// is a question about the caret, and the caret belongs to the pane.
public struct MatchSet: Equatable, Sendable {
    public enum Storage: Equatable, Sendable {
        case sparse([UInt64])
        case bitmap(MatchBitmap)
        case counted
    }

    /// What was searched — kept so the app can tell "the same search" from a new
    /// one without holding the pattern beside the set.
    public let pattern: SearchPattern
    public let folding: CaseFolding
    /// The size of the file the scan covered. Bit `i` of a bitmap is offset `i`,
    /// so this is also the bitmap's bit count.
    public let extent: UInt64
    /// Exact at any count, and the only number the Find bar shows: `> 1000` is
    /// not a diagnosis, since 1001 and 3 000 000 call for different actions.
    public private(set) var total: Int
    public private(set) var storage: Storage

    /// How much of the file the scan behind this set has covered, half-open:
    /// every match below it is in here, and nothing is yet known above it.
    ///
    /// A set is published while it is still being built, because the index is
    /// not what shows a user their match — a scan from the caret does that in
    /// about a millisecond, while indexing sixteen million occurrences takes
    /// seconds (`Design/FIND_HIGHLIGHT_PLAN.md`). So the greys, the rows and
    /// the marks arrive in file order as the scan advances, and the things that
    /// need the *whole* file — the total, the wrap, an ordinal — wait for
    /// `isComplete`.
    public private(set) var indexedUpTo: UInt64

    /// Whether the scan reached the end of the file. Only then is `total` the
    /// number of occurrences, rather than the number found so far.
    public var isComplete: Bool { indexedUpTo >= extent }

    /// The ceiling on the index itself, not on the number of matches: 32 MB,
    /// which a bitmap reaches at an extent of 256 MB. Below that nothing
    /// degrades however common the pattern is.
    public static let maxIndexBytes = 32 << 20

    public init(pattern: SearchPattern, folding: CaseFolding, extent: UInt64,
                total: Int, storage: Storage, indexedUpTo: UInt64? = nil) {
        self.pattern = pattern
        self.folding = folding
        self.extent = extent
        self.total = total
        self.storage = storage
        self.indexedUpTo = indexedUpTo ?? extent
    }

    /// Direct form for tests and callers holding starts already: picks the
    /// representation the builder would have picked.
    public init(pattern: SearchPattern, folding: CaseFolding, extent: UInt64,
                starts: [UInt64], indexedUpTo: UInt64? = nil) {
        var builder = MatchSetBuilder(pattern: pattern, folding: folding, extent: extent)
        builder.add(starts)
        self = builder.snapshot(indexedUpTo: indexedUpTo ?? extent)
    }

    public var patternLength: Int { max(pattern.bytes.count, 1) }
    public var isEmpty: Bool { total == 0 }

    /// Whether the matches can be pointed at individually — false only for a
    /// `counted` set, where the greys have to be withheld.
    public var isHighlightable: Bool {
        switch storage {
        case .counted: return false
        case .sparse, .bitmap: return total > 0
        }
    }

    /// Whether the results panel should list the matches at all. Past the limit
    /// a list of four thousand rows impersonates a tool, so the panel states the
    /// count and refuses instead (§11).
    public var isListable: Bool { total > 0 && total <= SearchEngine.defaultMaxResults }

    // MARK: - Reading the set

    /// The full match ranges that overlap `range`, in file order.
    ///
    /// A match starting *before* the range can still reach into it, so the
    /// lookup begins `patternLength - 1` bytes earlier — which is what makes a
    /// match straddling the top edge of a drawn row range highlighted rather
    /// than half-drawn.
    public func matches(intersecting range: Range<UInt64>) -> [Range<UInt64>] {
        guard !range.isEmpty, total > 0 else { return [] }
        let length = UInt64(patternLength)
        let reach = length - 1
        let from = range.lowerBound > reach ? range.lowerBound - reach : 0
        var result: [Range<UInt64>] = []
        switch storage {
        case .counted:
            return []
        case .sparse(let starts):
            var i = Self.firstIndex(in: starts, atOrAfter: from)
            while i < starts.count, starts[i] < range.upperBound {
                result.append(starts[i]..<starts[i] + length)
                i += 1
            }
        case .bitmap(let bitmap):
            var offset: UInt64? = bitmap.firstSet(atOrAfter: from)
            while let start = offset, start < range.upperBound {
                result.append(start..<start + length)
                offset = start + 1 < extent ? bitmap.firstSet(atOrAfter: start + 1) : nil
            }
        }
        return result
    }

    /// One step through the set: the next match from `offset`, wrapping at the
    /// ends, and whether it had to wrap to find one.
    ///
    /// Both directions, and the wrap, belong here rather than to a caller. A
    /// step past the last match is the first match again — the *set* is what
    /// knows that is what happened, and a view that had to work it out from a
    /// nil would work it out twice, once per direction (§11).
    ///
    /// Nil when there is nothing to step to: an empty set, or one that kept
    /// only a count and so cannot point at a match.
    public func step(_ direction: SearchDirection, from offset: UInt64) -> Step? {
        guard total > 0, isHighlightable else { return nil }
        let found: Int?
        switch direction {
        case .forward: found = index(atOrAfter: offset)
        case .backward: found = index(before: offset)
        }
        let target = found ?? (direction == .forward ? 0 : total - 1)
        guard let range = range(at: target) else { return nil }
        return Step(index: target, range: range, wrapped: found == nil)
    }

    public struct Step: Equatable, Sendable {
        public let index: Int
        public let range: Range<UInt64>
        /// True when the step came round the end of the file: a single match
        /// steps onto itself, which is a wrap too.
        public let wrapped: Bool

        public init(index: Int, range: Range<UInt64>, wrapped: Bool) {
            self.index = index
            self.range = range
            self.wrapped = wrapped
        }
    }

    /// The `index`-th match's start, or nil when the index is out of the set or
    /// the set is only counted.
    public func start(at index: Int) -> UInt64? {
        guard index >= 0, index < total else { return nil }
        switch storage {
        case .counted: return nil
        case .sparse(let starts): return starts[index]
        case .bitmap(let bitmap): return bitmap.select(index)
        }
    }

    /// The `index`-th match as a byte range.
    public func range(at index: Int) -> Range<UInt64>? {
        guard let start = start(at: index) else { return nil }
        return start..<start + UInt64(patternLength)
    }

    /// The ordinal of the match starting exactly at `offset` — the "3" in
    /// "3 of 128" after a jump landed on a match.
    public func index(startingAt offset: UInt64) -> Int? {
        switch storage {
        case .counted:
            return nil
        case .sparse(let starts):
            let i = Self.firstIndex(in: starts, atOrAfter: offset)
            return i < starts.count && starts[i] == offset ? i : nil
        case .bitmap(let bitmap):
            guard bitmap.contains(offset) else { return nil }
            return bitmap.count(before: offset)
        }
    }

    /// The first match starting at or after `offset` — where Find Next lands
    /// from a caret that is not on a match.
    public func index(atOrAfter offset: UInt64) -> Int? {
        switch storage {
        case .counted:
            return nil
        case .sparse(let starts):
            let i = Self.firstIndex(in: starts, atOrAfter: offset)
            return i < starts.count ? i : nil
        case .bitmap(let bitmap):
            guard let start = bitmap.firstSet(atOrAfter: offset) else { return nil }
            return bitmap.count(before: start)
        }
    }

    /// The last match starting strictly before `offset` — where Find Previous
    /// lands.
    public func index(before offset: UInt64) -> Int? {
        switch storage {
        case .counted:
            return nil
        case .sparse(let starts):
            let i = Self.firstIndex(in: starts, atOrAfter: offset)
            return i > 0 ? i - 1 : nil
        case .bitmap(let bitmap):
            guard let start = bitmap.lastSet(before: offset) else { return nil }
            return bitmap.count(before: start)
        }
    }

    // MARK: - Following an edit

    /// Replaces the matches starting in `range` with `starts`, which the caller
    /// found by rescanning it. For an overwrite — where no byte moves — this is
    /// the whole update: only matches touching the edited bytes can appear or
    /// vanish, so the caller widens the edited range by `patternLength - 1`
    /// either side and rescans that much.
    ///
    /// Returns false when the set cannot be updated in place (it is only
    /// counted), which is the caller's signal to rescan the file instead.
    @discardableResult
    public mutating func splice(_ starts: [UInt64], replacing range: Range<UInt64>) -> Bool {
        switch storage {
        case .counted:
            return false
        case .sparse(var existing):
            let first = Self.firstIndex(in: existing, atOrAfter: range.lowerBound)
            let last = Self.firstIndex(in: existing, atOrAfter: range.upperBound)
            existing.replaceSubrange(first..<last, with: starts)
            total = existing.count
            storage = .sparse(existing)
            return true
        case .bitmap(var bitmap):
            bitmap.clear(in: range)
            for start in starts { bitmap.set(start) }
            bitmap.sealRanks()
            total = bitmap.total
            storage = .bitmap(bitmap)
            return true
        }
    }

    /// First index whose value is >= `value`, in a sorted array.
    static func firstIndex(in starts: [UInt64], atOrAfter value: UInt64) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// A bit per byte offset, set where a match starts, with a block rank table so
/// "which match is this" stays O(1) instead of a walk.
///
/// This is the representation that makes an uncapped highlight affordable: a
/// pattern occurring at a third of a file's offsets costs the same as one
/// occurring once. The rank table adds 4 bytes per 4096 bits — 0.1 %.
public struct MatchBitmap: Equatable, Sendable {
    /// Offsets per rank block. One `Int` of prefix count per block.
    static let bitsPerBlock = 4096
    static let wordsPerBlock = bitsPerBlock / 64

    public let bitCount: UInt64
    private var words: [UInt64]
    /// Set bits before each block's start. Empty until `sealRanks()`; the
    /// accumulating scan does not need it.
    private var blockRanks: [Int]
    public private(set) var total: Int

    public init(bitCount: UInt64) {
        self.bitCount = bitCount
        self.words = [UInt64](repeating: 0, count: Int((bitCount + 63) / 64))
        self.blockRanks = []
        self.total = 0
    }

    /// The bytes a bitmap over `bitCount` offsets occupies, rank table included
    /// — what decides whether it fits `MatchSet.maxIndexBytes`.
    public static func byteCost(bitCount: UInt64) -> Int {
        let words = Int((bitCount + 63) / 64)
        let blocks = (words + wordsPerBlock - 1) / wordsPerBlock
        return words * 8 + blocks * MemoryLayout<Int>.size
    }

    public mutating func set(_ offset: UInt64) {
        guard offset < bitCount else { return }
        let word = Int(offset >> 6)
        let bit = UInt64(1) << (offset & 63)
        guard words[word] & bit == 0 else { return }
        words[word] |= bit
        total += 1
    }

    public func contains(_ offset: UInt64) -> Bool {
        guard offset < bitCount else { return false }
        return words[Int(offset >> 6)] & (UInt64(1) << (offset & 63)) != 0
    }

    /// Clears every bit in `range` — the first half of splicing an overwrite.
    public mutating func clear(in range: Range<UInt64>) {
        var offset = range.lowerBound
        while offset < min(range.upperBound, bitCount) {
            let word = Int(offset >> 6)
            let bit = UInt64(1) << (offset & 63)
            if words[word] & bit != 0 {
                words[word] &= ~bit
                total -= 1
            }
            offset += 1
        }
    }

    /// Builds the rank table. Called once the scan is done, and again after a
    /// splice: one pass over the words, which is milliseconds for the largest
    /// bitmap the budget allows.
    public mutating func sealRanks() {
        let blocks = (words.count + Self.wordsPerBlock - 1) / Self.wordsPerBlock
        var ranks = [Int](repeating: 0, count: max(blocks, 1))
        var running = 0
        for block in 0..<max(blocks, 1) {
            ranks[block] = running
            let start = block * Self.wordsPerBlock
            let end = min(start + Self.wordsPerBlock, words.count)
            for word in start..<end { running += words[word].nonzeroBitCount }
        }
        blockRanks = ranks
        total = running
    }

    /// How many matches start before `offset` — the ordinal lookup.
    public func count(before offset: UInt64) -> Int {
        let limit = min(offset, bitCount)
        guard limit > 0 else { return 0 }
        let lastWord = Int((limit - 1) >> 6)
        let block = lastWord / Self.wordsPerBlock
        var count = blockRanks.indices.contains(block) ? blockRanks[block] : 0
        let start = block * Self.wordsPerBlock
        if start < lastWord {
            for word in start..<lastWord { count += words[word].nonzeroBitCount }
        }
        // The partial word: only the bits below `limit`.
        let bitsInLast = Int(limit - UInt64(lastWord) * 64)
        if bitsInLast > 0 {
            let mask = bitsInLast >= 64 ? UInt64.max : (UInt64(1) << UInt64(bitsInLast)) - 1
            count += (words[lastWord] & mask).nonzeroBitCount
        }
        return count
    }

    public func firstSet(atOrAfter offset: UInt64) -> UInt64? {
        guard offset < bitCount else { return nil }
        var word = Int(offset >> 6)
        var current = words[word] & (UInt64.max << (offset & 63))
        while true {
            if current != 0 {
                let bit = UInt64(word) * 64 + UInt64(current.trailingZeroBitCount)
                return bit < bitCount ? bit : nil
            }
            word += 1
            guard word < words.count else { return nil }
            current = words[word]
        }
    }

    public func lastSet(before offset: UInt64) -> UInt64? {
        let limit = min(offset, bitCount)
        guard limit > 0 else { return nil }
        var word = Int((limit - 1) >> 6)
        let bitsInLast = Int(limit - UInt64(word) * 64)
        let mask = bitsInLast >= 64 ? UInt64.max : (UInt64(1) << UInt64(bitsInLast)) - 1
        var current = words[word] & mask
        while true {
            if current != 0 {
                return UInt64(word) * 64 + UInt64(63 - current.leadingZeroBitCount)
            }
            guard word > 0 else { return nil }
            word -= 1
            current = words[word]
        }
    }

    /// The `index`-th set bit: the rank table narrows it to a block, then the
    /// walk is at most one block long.
    public func select(_ index: Int) -> UInt64? {
        guard index >= 0, index < total else { return nil }
        // The last block whose prefix count is <= index.
        var low = 0
        var high = blockRanks.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if blockRanks[mid] <= index { low = mid } else { high = mid - 1 }
        }
        var remaining = index - (blockRanks.isEmpty ? 0 : blockRanks[low])
        var word = low * Self.wordsPerBlock
        while word < words.count {
            let count = words[word].nonzeroBitCount
            if remaining < count { break }
            remaining -= count
            word += 1
        }
        guard word < words.count else { return nil }
        var value = words[word]
        for _ in 0..<remaining { value &= value - 1 }
        return UInt64(word) * 64 + UInt64(value.trailingZeroBitCount)
    }
}

/// Accumulates a `MatchSet` from a scan's matches, switching representation as
/// the density demands and giving up the positions — never the count — when
/// even a bitmap would not fit.
///
/// Fed in batches: the scan delivers a chunk's matches at once rather than one
/// at a time, because a million hops onto the main actor is a cost the count
/// does not justify.
public struct MatchSetBuilder {
    private let pattern: SearchPattern
    private let folding: CaseFolding
    private let extent: UInt64
    private let maxIndexBytes: Int
    private var storage: MatchSet.Storage
    private var total = 0
    /// The count at which a sparse list costs more than the bitmap would.
    private let sparseLimit: Int

    public init(pattern: SearchPattern, folding: CaseFolding, extent: UInt64,
                maxIndexBytes: Int = MatchSet.maxIndexBytes) {
        self.pattern = pattern
        self.folding = folding
        self.extent = extent
        self.maxIndexBytes = maxIndexBytes
        self.storage = .sparse([])
        self.sparseLimit = max(Int(extent / 64), 1)
    }

    public mutating func add(_ starts: [UInt64]) {
        guard !starts.isEmpty else { return }
        total += starts.count
        switch storage {
        case .counted:
            break
        case .sparse(var existing):
            guard existing.count + starts.count > sparseLimit else {
                existing.append(contentsOf: starts)
                storage = .sparse(existing)
                return
            }
            // The sparse list has grown past what a bitmap would cost. Convert
            // if the bitmap fits the ceiling; otherwise the positions go and
            // the count carries on alone.
            guard MatchBitmap.byteCost(bitCount: extent) <= maxIndexBytes else {
                storage = .counted
                return
            }
            var bitmap = MatchBitmap(bitCount: extent)
            for start in existing { bitmap.set(start) }
            for start in starts { bitmap.set(start) }
            storage = .bitmap(bitmap)
        case .bitmap(var bitmap):
            for start in starts { bitmap.set(start) }
            storage = .bitmap(bitmap)
        }
    }

    public func finish() -> MatchSet {
        snapshot(indexedUpTo: extent)
    }

    /// The set as it stands, covering the file up to `indexedUpTo` — what a
    /// still-running scan publishes so the dump can grey what is known while
    /// the rest is still being found (§11).
    ///
    /// Cheap enough to do on a cadence: the copy is the representation, which
    /// is bounded by the smaller of the bitmap (one bit per byte) and the list
    /// of starts, and sealing the ranks is a pass over the bitmap's blocks.
    public func snapshot(indexedUpTo: UInt64) -> MatchSet {
        var sealed = storage
        if case .bitmap(var bitmap) = sealed {
            bitmap.sealRanks()
            sealed = .bitmap(bitmap)
        }
        return MatchSet(pattern: pattern, folding: folding, extent: extent,
                        total: total, storage: sealed,
                        indexedUpTo: min(indexedUpTo, extent))
    }
}
