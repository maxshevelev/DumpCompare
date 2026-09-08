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
    }

    struct Result {
        var headerVersion: UInt8
        var resolvedVersion: UInt8   // get_fpt()'s dispatch, incl. the v2.1-with-v2.0-tag quirk
        var partitions: [Partition]
    }

    /// The first `$FPT` anchor that passes upstream's plausibility filter.
    static func findAnchor(in data: Data) -> Int? {
        let tag = Data("$FPT".utf8)
        var scan = data.startIndex
        while let found = data.range(of: tag, in: scan..<data.endIndex) {
            let base = found.lowerBound
            if base + 8 <= data.endIndex {
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
    static func decode(_ data: Data, anchor: Int) -> Result? {
        let p = data.startIndex + anchor
        guard p + 0x20 + 0x20 <= data.endIndex else { return nil }  // header + one entry
        let count = Int(u32le(data, p + 0x04))
        guard count > 0, p + 0x20 + count * 0x20 <= data.endIndex else { return nil }

        let headerVersion = data[p + 0x08]
        var resolved = headerVersion
        if headerVersion == 0x20 {
            // get_fpt(): a v2.0 tag whose second CRC word is not FF/00 is really
            // a v2.1 (FIT quirk — a v2.1 header written with a v2.0 tag).
            let secondCrcWord = u16le(data, p + 0x16)
            if secondCrcWord != 0 && secondCrcWord != 0xFFFF {
                resolved = 0x21
            }
        }

        var partitions: [Partition] = []
        partitions.reserveCapacity(count)
        for index in 0..<count {
            let entry = p + 0x20 + index * 0x20
            // Upstream: erased names (FF fill) or a wrong NumPartitions reading
            // past real entries produce empty names. ASCII decode yields nil for
            // invalid bytes (e.g. FF fill) and "\0…" for zeroed ones — trim both.
            let raw = String(data: data.subdata(in: entry..<(entry + 4)), encoding: .ascii)
            let name = raw?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
            partitions.append(Partition(
                name: name,
                // Region-relative: upstream's p_offset_spi = fpt_start + Offset,
                // where fpt_start is the anchor itself when the region begins at $FPT.
                offset: anchor + Int(u32le(data, entry + 0x08)),
                size: Int(u32le(data, entry + 0x0C)),
                flags: u32le(data, entry + 0x1C)
            ))
        }
        return Result(headerVersion: headerVersion, resolvedVersion: resolved, partitions: partitions)
    }

    /// Find the first `$FPT` and decode it, or nil when none is present.
    static func parseFirst(in data: Data) -> Result? {
        guard let anchor = findAnchor(in: data) else { return nil }
        return decode(data, anchor: anchor)
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
