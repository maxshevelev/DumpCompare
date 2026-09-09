import Foundation

/// Flash Partition Table decode — the first ported spine link.
///
/// Faithful to upstream `MEA.py`:
/// - anchor `fpt_pat` (line ~11015): `$FPT` + a nonzero small partition-count
///   low byte followed by zero bytes;
/// - header version dispatch `get_fpt` (line ~9682) between the v1.0/v2.0
///   `FPT_Header` (line 193) and v2.1 `FPT_Header_21` (line 235);
/// - `FPT_Entry` (line 298), a fixed 0x20 row: name, owner, offset, size,
///   start/max tokens, scratch sectors, flags.
///
/// The v2.1 entry starts at the same 0x20 offset as v1/v2 and `NumPartitions`
/// sits at 0x04 in both, so one decoder reads every version; only the *header*
/// flags/checksum handling (v2.1 CRC-32 over header+entries, v2.1 redundancy)
/// differs, and that is deferred to the full FPT port. Offsets are relative to
/// the start of the region handed in — matching how a caller analyses a slice.
struct FPTParser {
    struct Partition {
        var name: String
        var offset: Int
        var size: Int
        var flags: UInt32
        /// Upstream's FPT empty flag (MEA.py 11724 `p_empty`): the raw offset
        /// field is NA (0 / 0xFFFFFFFF), the size is 0, or — for a bounded
        /// non-NA size — the whole content is erased to 0xFF.
        var empty: Bool
    }

    struct Result {
        var headerVersion: UInt8
        var resolvedVersion: UInt8   // get_fpt()'s dispatch, incl. the v2.1-with-v2.0-tag quirk
        var fptStart: Int            // upstream's resolved fpt_start (partition base, region-relative)
        /// The header's FIT fields (u16 @ anchor+0x18..0x1E, MEA.py 193–234).
        /// Raw values — upstream's `fw_type` tests `FitBuild`/`FitMajor` against
        /// the 0 / 0xFFFF marker itself (MEA.py 12567), so the marker is kept.
        var fitMajor: Int
        var fitMinor: Int
        var fitHotfix: Int
        var fitBuild: Int
        var partitions: [Partition]
        var cseLayout: IFWI.LayoutInfo?  // the CSE Layout Table that precedes the $FPT, when present
    }

    /// The first `$FPT` anchor that passes upstream's plausibility filter. When
    /// `range` is given the search is confined to it (upstream scans only the FD
    /// Engine/Graphics region on whole-flash images, MEA.py 11618).
    static func findAnchor(in data: Data, in range: Range<Int>? = nil) -> Int? {
        let tag = Data("$FPT".utf8)
        let low = data.startIndex + (range?.lowerBound ?? 0)
        let high = data.startIndex + (range?.upperBound ?? data.count)
        var scan = low
        while scan < high, let found = data.range(of: tag, in: scan..<high) {
            let base = found.lowerBound
            if base + 8 <= high {
                let lowCount = data[base + 4]
                if (0x01...0x7F).contains(lowCount)
                    && data[base + 5] == 0 && data[base + 6] == 0 && data[base + 7] == 0 {
                    return base - data.startIndex
                }
            }
            scan = found.lowerBound + 1
        }
        return nil
    }

    /// Decode an FPT whose header begins at `anchor` (region-relative offset).
    /// Partition bases are upstream's `fpt_start`, not the raw marker: resolve it
    /// from the CSE Layout Table presence (IFWI engine) and the header fields, so
    /// a pre-IFWI engine whose `$FPT` sits 0x10 into the region still measures
    /// partitions from the region base (fixes the false Issue id 8 on CSME 11).
    static func decode(_ data: Data, anchor: Int) -> Result? {
        let p = data.startIndex + anchor
        guard p + 0x20 + 0x20 <= data.endIndex else { return nil }  // header + one entry
        let count = Int(u32le(data, p + 0x04))
        guard count > 0, p + 0x20 + count * 0x20 <= data.endIndex else { return nil }

        let headerVersion = data[p + 0x08]
        let headerLength = data[p + 0x0A]
        var resolved = headerVersion
        if headerVersion == 0x20 {
            // get_fpt(): a v2.0 tag whose second CRC word is not FF/00 is really
            // a v2.1 (FIT quirk — a v2.1 header written with a v2.0 tag).
            let secondCrcWord = u16le(data, p + 0x16)
            if secondCrcWord != 0 && secondCrcWord != 0xFFFF {
                resolved = 0x21
            }
        }

        // A whole-flash region carries its Flash Descriptor; the CSE Layout Table
        // (if any) sits at the FD Engine/Graphics base. A bare ME region probed at
        // its own start (offset 0). Either way the probe mirrors upstream, which
        // keys `cse_lt_struct` off that location (MEA.py 11508/11519).
        let meRegion = FlashDescriptor.meRegion(in: data)
        let cseLayoutOffset = meRegion?.base ?? 0
        let cseLayout = IFWI.layoutTable(in: data, at: cseLayoutOffset)
        let cseLayoutPresent = cseLayout != nil
        let start = fptStart(anchor: anchor, version: headerVersion, length: headerLength,
                             cseLayoutTablePresent: cseLayoutPresent, in: data)

        var partitions: [Partition] = []
        partitions.reserveCapacity(count)
        for index in 0..<count {
            let entry = p + 0x20 + index * 0x20
            // Upstream: erased names (FF fill) or a wrong NumPartitions reading
            // past real entries produce empty names. ASCII decode yields nil for
            // invalid bytes (e.g. FF fill) and "\0…" for zeroed ones — trim both.
            let raw = String(data: data.subdata(in: entry..<(entry + 4)), encoding: .ascii)
            let name = raw?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
            let rawOffset = u32le(data, entry + 0x08)
            let rawSize = u32le(data, entry + 0x0C)
            // Upstream's p_empty (MEA.py 11724): NA raw offset/size, a zero
            // size, or — for a bounded non-NA size — content erased to FF.
            let empty = rawOffset == 0 || rawOffset == 0xFFFF_FFFF
                || rawSize == 0
                || (rawSize != 0xFFFF_FFFF && erasedFF(data,
                                                     from: start + Int(rawOffset),
                                                     count: Int(rawSize)))
            partitions.append(Partition(
                name: name,
                // Region-relative: upstream's p_offset_spi = fpt_start + Offset.
                offset: start + Int(rawOffset),
                size: Int(rawSize),
                flags: u32le(data, entry + 0x1C),
                empty: empty
            ))
        }
        return Result(
            headerVersion: headerVersion, resolvedVersion: resolved,
            fptStart: start,
            fitMajor: Int(u16le(data, p + 0x18)), fitMinor: Int(u16le(data, p + 0x1A)),
            fitHotfix: Int(u16le(data, p + 0x1C)), fitBuild: Int(u16le(data, p + 0x1E)),
            partitions: partitions, cseLayout: cseLayout)
    }

    /// Upstream's `fpt_start` resolution (MEA.py 11667–11681): the partition
    /// base is the `$FPT` marker minus 0x10 unless a CSE Layout Table marks this
    /// `$FPT` as the IFWI engine's data table, or a CSE-header erase window / a
    /// v1.0 0x20 header say the marker is the base itself.
    static func fptStart(anchor: Int, version: UInt8, length: UInt8,
                         cseLayoutTablePresent: Bool, in data: Data) -> Int {
        if anchor == 0 { return 0 }
        var start = anchor - 0x10

        if cseLayoutTablePresent, version == 0x20 || version == 0x21, length == 0x20 {
            start = anchor
        } else {
            // Erased CSE-header window 0x1000 before the marker: 0x48 zeros + 0x10
            // FF (or the 0x50 variant) — upstream treats that $FPT as region-base.
            let w = anchor - 0x1000
            if w >= 0 {
                let zeroCount: Int? = {
                    if w + 0x60 <= data.count,
                       zeroThenFF(data, at: w, zeros: 0x50) { return 0x50 }
                    if w + 0x58 <= data.count,
                       zeroThenFF(data, at: w, zeros: 0x48) { return 0x48 }
                    return nil
                }()
                if zeroCount != nil {
                    start = anchor
                }
            }
        }
        if start == anchor - 0x10, version == 0x10, length == 0x20 {
            start = anchor
        }
        return start
    }

    /// True when `data[w...]` is `zeros` zero bytes followed by 0x10 erased (FF)
    /// bytes — the CSE header pad immediately before a region-base `$FPT`.
    private static func zeroThenFF(_ data: Data, at w: Int, zeros: Int) -> Bool {
        for i in 0..<zeros where data[data.startIndex + w + i] != 0 { return false }
        for i in zeros..<(zeros + 0x10)
        where data[data.startIndex + w + i] != 0xFF { return false }
        return true
    }

    /// Find the first `$FPT` inside the FD Engine/Graphics region when the image
    /// is whole-flash (upstream MEA.py 11618), else the whole region, and decode
    /// it — or nil when none is present.
    static func parseFirst(in data: Data) -> Result? {
        if let me = FlashDescriptor.meRegion(in: data) {
            guard let anchor = findAnchor(in: data, in: me.base..<(me.base + me.size)) else {
                return nil
            }
            return decode(data, anchor: anchor)
        }
        guard let anchor = findAnchor(in: data) else { return nil }
        return decode(data, anchor: anchor)
    }

    /// True when the `count` bytes at region offset `off` are in range and all
    /// erased to 0xFF (or the window is empty — upstream treats an empty read
    /// as erased). Out-of-range content is *not* erased, so a partition whose
    /// fields point past the region stays non-empty, matching upstream's
    /// bounded read.
    private static func erasedFF(_ data: Data, from off: Int, count: Int) -> Bool {
        let start = data.startIndex
        guard off >= 0, count > 0 else { return true }
        guard off + count <= data.count else { return false }
        for i in off..<(off + count) where data[start + i] != 0xFF { return false }
        return true
    }

    private static func u16le(_ data: Data, _ p: Int) -> UInt16 {
        UInt16(data[p]) | (UInt16(data[p + 1]) << 8)
    }

    private static func u32le(_ data: Data, _ p: Int) -> UInt32 {
        UInt32(data[p])
            | (UInt32(data[p + 1]) << 8)
            | (UInt32(data[p + 2]) << 16)
            | (UInt32(data[p + 3]) << 24)
    }
}
