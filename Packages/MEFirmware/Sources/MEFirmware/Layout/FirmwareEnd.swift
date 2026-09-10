import Foundation

/// Row 18's firmware size — upstream `eng_fw_end` (the per-partition walk at
/// MEA.py 11792–11798, the total at 12459–12486): how far the engine firmware
/// itself reaches, measured from the `$FPT` start. That is not the size of the
/// region or of the file carrying it: on the CSME-12 oracle the firmware ends
/// at 0x27C000 inside a 16 MiB dump whose ME region is 0x6E0000 long.
///
/// Three parts, exactly as upstream:
///
/// - the end of the partition that *starts* last in the `$FPT` — the entry
///   with the greatest offset, and that entry's own end rather than the
///   greatest end of all of them (upstream tracks `p_offset_last` and stores
///   its `eng_fw_end` alongside). An offset or size at 0 / 0xFFFFFFFF is a
///   field that says nothing, and the entry does not win.
/// - on an IFWI image, the CSE Layout Table total instead: the table itself,
///   plus the larger of that `$FPT` end and the Data partition, plus every
///   Boot/Temp/ELog partition, minus every entry nested inside another
///   (upstream's duplicate pass, 12462–12466).
/// - the whole thing rounded up to the next 4 KiB — except on CSME 16 and
///   newer, where Intel's own MFIT-built FWUpdate images are unaligned and
///   upstream stopped rounding (12481–12484).
///
/// Everything is measured in the buffer the engine was handed, the way
/// upstream measures in the file it read. The two agree wherever the answer
/// comes from the `$FPT` end, since the region's base cancels against
/// `fpt_start`; they can differ by that base in the one leg where the Data
/// partition's *size* is the larger of the two, which is an artifact of
/// upstream's frame — the number this reproduces there is upstream's own for
/// the same firmware handed over as an extracted region.
///
/// nil when the answer would need a leg that is not ported: an ME 2–6 image
/// whose last `$FPT` entry carries no size (upstream then walks that
/// partition's `$MME` submodules for the end, 12253–12301), or a table with
/// no partitions at all. The pre-CSE `$MCP` chains that upstream walks past
/// the last entry (ME 8–10 WCOD/LOCL, SPS1, 12310–12440) are not ported
/// either: on such an image the number stops at the last charted partition.
enum FirmwareEndCalculator {
    /// Upstream's `p_max_size`: an offset or size at or past this is an
    /// erased/NA field, not a position.
    static let maxSize = 0xFFFF_FFFF

    /// The 4 KiB the firmware is padded to (upstream `eng_fw_align`).
    static let alignment = 0x1000

    static func firmwareSize(
        in region: Data,
        partitions: [FPTParser.Partition],
        fptStart: Int,
        cseLayout: IFWI.LayoutInfo?,
        hasFlashDescriptor: Bool,
        ignores4KAlignment: Bool
    ) -> Int? {
        guard !partitions.isEmpty else { return nil }

        // The partition that starts last, and its own end.
        var offsetLast = 0
        var endLast = 0
        for part in partitions {
            let spi = part.offset
            let end = (spi > 0 && spi < maxSize && part.size > 0 && part.size < maxSize)
                ? spi + part.size
                : maxSize
            if offsetLast < spi, spi < maxSize {
                offsetLast = spi
                endLast = end
            }
        }
        // The ME 2–6 leg: no size on the last entry, so the end is only
        // knowable by walking its submodules. Not ported — and a 4 GiB answer
        // would be worse than none.
        guard endLast > 0, endLast != maxSize else { return nil }

        // An uncharted partition can start up to 4 KiB past the last charted
        // one, so upstream looks for its `$CPD` there and moves the end to it
        // — on an image with neither a flash descriptor nor a CSE Layout
        // Table, which are the two things that make the search unnecessary
        // (12305–12309).
        if !hasFlashDescriptor, cseLayout == nil,
           !startsWithCPD(region, at: endLast),
           let uncharted = firstCPD(in: region, from: endLast, length: 0x200B) {
            endLast = uncharted
        }

        if let cseLayout {
            endLast = layoutTotal(cseLayout, fptEnd: endLast)
        }

        let size = endLast - fptStart
        guard size > 0 else { return nil }
        let remainder = size % alignment
        guard remainder != 0, !ignores4KAlignment else { return size }
        return size + (alignment - remainder)
    }

    /// Upstream's IFWI total (12467–12468): the Layout Table, the larger of the
    /// `$FPT` end and the Data partition, every other partition, less the
    /// nested ones.
    private static func layoutTotal(_ layout: IFWI.LayoutInfo, fptEnd: Int) -> Int {
        // The table is 4 KiB unless its first real partition starts later
        // (11593), in which case that is where the table's own space ends.
        var tableSize = alignment
        let firstEntry = layout.slots
            .filter { !$0.empty }
            .map { $0.offset - layout.base }
            .min()
        if let firstEntry, firstEntry > tableSize { tableSize = firstEntry }

        let dataSize = layout.slots.first { $0.name == IFWI.dataSlotName }?.size ?? 0
        // Boot 1…5 and, on IFWI 1.7, Temp and ELog.
        let bootSize = layout.slots
            .filter { $0.name != IFWI.dataSlotName }
            .reduce(0) { $0 + $1.size }

        // A partition wholly inside another is the same flash space counted
        // twice — the redundancy layouts do this — so it is subtracted once
        // per containing partition, exactly as upstream's nested pass counts
        // it.
        var duplicate = 0
        for inner in layout.slots {
            for outer in layout.slots where inner.name != outer.name {
                if inner.offset >= outer.offset,
                   inner.offset + inner.size <= outer.offset + outer.size {
                    duplicate += inner.size
                }
            }
        }
        return tableSize + max(fptEnd, dataSize) + bootSize - duplicate
    }

    private static func startsWithCPD(_ region: Data, at offset: Int) -> Bool {
        guard offset >= 0, offset + 4 <= region.count else { return false }
        let base = region.startIndex + offset
        return region[base..<(base + 4)].elementsEqual(Data("$CPD".utf8))
    }

    /// The first `$CPD` in `length` bytes from `offset`, as a region offset.
    private static func firstCPD(in region: Data, from offset: Int, length: Int) -> Int? {
        guard offset >= 0, offset < region.count else { return nil }
        let start = region.startIndex + offset
        let end = min(region.startIndex + offset + length, region.endIndex)
        guard start < end else { return nil }
        guard let found = region.range(of: Data("$CPD".utf8), in: start..<end) else {
            return nil
        }
        return found.lowerBound - region.startIndex
    }
}
