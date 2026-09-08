import Foundation

/// IFWI (Intel Firmware Image) pieces the `$FPT` spine needs to anchor
/// partitions faithfully — the CSE Layout Table *presence* probe and the Flash
/// Descriptor ME-region read that locates that table on whole-flash images.
///
/// Upstream map: `CSE_Layout_Table_16` (MEA.py 507), `CSE_Layout_Table_17`
/// (556) and their detection (MEA.py 11507–11545); the FLREG2 Engine/Graphics
/// region read of `fd_anl_rgn` (MEA.py 10045). Only the facts that gate
/// `fpt_start` are decoded here; the LT's full Data/Boot/Temp/ELog *partition*
/// table surfacing (rows 40–41) is a later increment.
///
/// Why this exists: upstream decides the `$FPT` partition base with
/// `fpt_start = marker if cse_lt_struct … else marker − 0x10` (MEA.py 11667).
/// A pre-IFWI engine (CSME 11 and older) has no CSE Layout Table, so its `$FPT`
/// sits 0x10 into the ME region and partitions measure from the region base —
/// not from the `$FPT` marker. The engine's partition base was the raw marker
/// (+0x10 too high on those images), which is exactly the false Issue id 8 that
/// old.bin (CSME 11.8) surfaced.
enum IFWI {
    /// One slot of the CSE Layout Table partition inventory (upstream
    /// `cse_lt_hdr_info` / `cse_lt_part_all`, MEA.py 11549–11600). `name` is
    /// upstream's label ("Data", "Boot 1"…"Boot 5", plus "Temp"/"ELog" on
    /// IFWI 1.7); `offset` is the slot's SPI — the table base plus its raw
    /// offset field — in region-relative coordinates; `empty` is upstream's flag
    /// (offset/size NA in [0, 0xFFFFFFFF] or the whole content erased). Empty
    /// slots are still listed, exactly as upstream shows them.
    struct LayoutSlot {
        let name: String
        let offset: Int
        let size: Int
        let empty: Bool
    }

    /// The decoded CSE Layout Table (upstream `cse_lt_struct` region analysis,
    /// MEA.py 11546–11605). `base` is the table's own region-relative offset
    /// (the FD Engine/Graphics base on whole-flash images). `redundancy` is the
    /// 1.7 Flags bit 0 (BP1's backup in BP2); false when the version is 1.6.
    /// `checksumValid` is the 1.7 pointer-block CRC-32 result; nil for 1.6.
    struct LayoutInfo {
        let base: Int
        let version: Int        // 0x16 or 0x17
        let redundancy: Bool
        let checksumValid: Bool?
        let slots: [LayoutSlot]
    }

    /// IFWI 1.6/1.7 Layout Table / 2.0 Boot Partition Descriptor signatures.
    static let bpdtSignatures: Set<Data> = [
        Data([0xAA, 0x55, 0x00, 0x00]),
        Data([0xAA, 0x55, 0xAA, 0x00]),
    ]

    /// Version (0x16 or 0x17) of the CSE Layout Table validated at region offset
    /// `off`, or nil when none is present. Faithful port of upstream's
    /// `cse_lt_struct` detection (MEA.py 11519–11543): a BPDT 2.0 header here is
    /// not a Layout Table; otherwise an IFWI 1.6 (Data + BP1 + erased padding)
    /// table, IFWI 1.7, then the without-Data variants, each gated on the
    /// Data/BP1 pointers and 0x1000 header padding.
    static func detectCseLayoutTable(in data: Data, at off: Int) -> Int? {
        guard off >= 0, off + 0x48 <= data.count else { return nil }
        let head = subrange(data, off, 4)
        if head == nil || bpdtSignatures.contains(head!) { return nil }  // 2.0 BPx, skip

        let lt16DataOffset = Int(le32(data, off + 0x10))
        let lt16BP1Offset = Int(le32(data, off + 0x18))
        let lt17DataOffset = Int(le32(data, off + 0x18))
        let lt17BP1Offset = Int(le32(data, off + 0x20))

        let pad16 = headerPadding(data, off: off, from: 0x48)   // after the 1.6 struct
        let pad17 = headerPadding(data, off: off, from: 0x58)   // after the 1.7 struct

        func dataSig(_ field: Int) -> Bool {
            subrange(data, off + field, 4) == Data("$FPT".utf8)
        }
        func bpSig(_ field: Int) -> Bool {
            guard let bytes = subrange(data, off + field, 4) else { return false }
            return bpdtSignatures.contains(bytes)
        }
        func allFF(_ pad: Data?) -> Bool {
            guard let pad, !pad.isEmpty else { return false }
            return pad.allSatisfy { $0 == 0xFF }
        }

        if dataSig(lt16DataOffset), bpSig(lt16BP1Offset), allFF(pad16) { return 0x16 }
        if dataSig(lt17DataOffset), bpSig(lt17BP1Offset), allFF(pad17) { return 0x17 }
        if bpSig(lt16BP1Offset), allFF(pad16) { return 0x16 }
        if bpSig(lt17BP1Offset), allFF(pad17) { return 0x17 }
        return nil
    }

    /// Full decode of the CSE Layout Table validated at region offset `off`
    /// (upstream `cse_lt_struct` region analysis, MEA.py 11546–11605): the
    /// Data/Boot1-5(/Temp/ELog) partition inventory, the 1.7 CRC-32 validity and
    /// the 1.7 CSE-Redundancy flag. Returns nil when no 1.6/1.7 table is present
    /// at `off`. `off` is the table base — on a whole-flash image the FD
    /// Engine/Graphics base, which is also where the presence probe keys.
    static func layoutTable(in data: Data, at off: Int) -> LayoutInfo? {
        guard let version = detectCseLayoutTable(in: data, at: off) else { return nil }
        let is17 = version == 0x17
        // Struct header bounds for safe field reads.
        let structEnd = off + (is17 ? 0x58 : 0x48)
        guard structEnd <= data.count else { return nil }

        // Partition pointer/size field offsets relative to the table base.
        // 1.6 (MEA.py 507): Data@0x10, BP1@0x18 … BP5@0x38. 1.7 (556) inserts a
        // Size/Flags/Checksum prefix, so Data@0x18 … BP5@0x40, then Temp@0x48
        // and ELog@0x50.
        let slots: [(name: String, offOff: Int, sizeOff: Int)]
        if is17 {
            slots = [
                ("Data", 0x18, 0x1C), ("Boot 1", 0x20, 0x24), ("Boot 2", 0x28, 0x2C),
                ("Boot 3", 0x30, 0x34), ("Boot 4", 0x38, 0x3C), ("Boot 5", 0x40, 0x44),
            ]
        } else {
            slots = [
                ("Data", 0x10, 0x14), ("Boot 1", 0x18, 0x1C), ("Boot 2", 0x20, 0x24),
                ("Boot 3", 0x28, 0x2C), ("Boot 4", 0x30, 0x34), ("Boot 5", 0x38, 0x3C),
            ]
        }

        // NA offsets/sizes upstream treats as "no partition here".
        let na: Set<UInt32> = [0, 0xFFFF_FFFF]

        var redundancy = false
        var checksumValid: Bool? = nil

        if is17 {
            // 1.7 CRC-32 (MEA.py 11554): Size..Flags+Reserved (0x10..0x14),
            // the CRC word zeroed, then DataOffset .. 0x10+Size.
            let sizeField = le16(data, off + 0x10)
            let flags = data[data.startIndex + off + 0x12]
            redundancy = (flags & 0x01) != 0
            let windowStart = off + 0x18
            let windowEnd = off + 0x10 + Int(sizeField)
            if sizeField > 0, windowStart <= data.count, windowEnd <= data.count {
                var window = subrange(data, off + 0x10, 0x04) ?? Data()
                window.append(Data([0, 0, 0, 0]))
                window.append(subrange(data, windowStart, windowEnd - windowStart) ?? Data())
                let stored = le32(data, off + 0x14)
                checksumValid = CRC32.crc32(window) == stored
            }
        }

        var inventory: [LayoutSlot] = []
        inventory.reserveCapacity(slots.count + (is17 ? 2 : 0))
        for slot in slots {
            inventory.append(slotEntry(data, off: off, name: slot.name,
                                      offsetField: slot.offOff, sizeField: slot.sizeOff, na: na))
        }
        if is17 {
            // Temp is always appended on 1.7; ELog only when Size declares it
            // (0x48 with ELog, 0x40 without, MEA.py 11557–11562).
            inventory.append(slotEntry(data, off: off, name: "Temp",
                                       offsetField: 0x48, sizeField: 0x4C, na: na))
            if le16(data, off + 0x10) >= 0x48 {
                inventory.append(slotEntry(data, off: off, name: "ELog",
                                           offsetField: 0x50, sizeField: 0x54, na: na))
            }
        }
        return LayoutInfo(base: off, version: version, redundancy: redundancy,
                          checksumValid: checksumValid, slots: inventory)
    }

    /// One inventory slot: SPI = table base + raw offset field; empty when the
    /// offset/size is NA or the whole content is erased (upstream MEA.py
    /// 11584–11591). Slot reads are bounded so a field pointing outside the
    /// region yields the slot with an out-of-range content check skipped.
    private static func slotEntry(_ data: Data, off: Int, name: String,
                                  offsetField: Int, sizeField: Int,
                                  na: Set<UInt32>) -> LayoutSlot {
        let rawOffset = le32(data, off + offsetField)
        let rawSize = le32(data, off + sizeField)
        let spi = off + Int(rawOffset)
        let size = Int(rawSize)
        var empty = na.contains(rawOffset) || na.contains(rawSize)
        if !empty, spi >= 0, spi + size <= data.count, size > 0 {
            let content = subrange(data, spi, size) ?? Data()
            empty = content.allSatisfy { $0 == 0x00 } || content.allSatisfy { $0 == 0xFF }
        }
        return LayoutSlot(name: name, offset: spi, size: size, empty: empty)
    }

    /// The erased (0xFF) header padding of a Layout Table at `off`, from the end
    /// of its struct (`from`) up to the usual 0x1000 table size — truncated to
    /// the region end. nil when the region ends inside the struct.
    private static func headerPadding(_ data: Data, off: Int, from: Int) -> Data? {
        let lo = off + from
        guard lo <= data.count else { return nil }
        let hi = min(off + 0x1000, data.count)
        return hi > lo ? subrange(data, lo, hi - lo) : nil
    }

    private static func subrange(_ data: Data, _ off: Int, _ len: Int) -> Data? {
        guard off >= 0, off + len <= data.count else { return nil }
        let s = data.startIndex + off
        return data.subdata(in: s..<(s + len))
    }
}

/// Minimal Flash Descriptor region reader — the one fact the `$FPT` spine needs
/// on a whole-flash image: where the Engine/Graphics (ME) region begins. Reads
/// FLREG2 the way `fd_anl_rgn` does (MEA.py 10045) and returns nil when `data`
/// does not start with a descriptor (an extracted ME region).
enum FlashDescriptor {
    /// The on-image descriptor signature, bytes `5A A5 F0 0F` at 0x10 (upstream
    /// fd_pat, MEA.py 11024). Compared as raw bytes — a little-endian u32 read
    /// yields 0x0FF0_A55A, not the big-endian-looking 0x5AA5_F00F.
    private static let signature = Data([0x5A, 0xA5, 0xF0, 0x0F])

    static func meRegion(in data: Data) -> (base: Int, size: Int)? {
        // upstream fd_pat (MEA.py 11024): descriptor signature, strap/FCBA byte,
        // then a 16-byte erased run at 0xC0.
        guard data.count >= 0x1000,
              subrange(data, 0x10, 4) == signature else { return nil }
        let strap = data[data.startIndex + 0x14]
        guard (0x01...0x10).contains(strap) else { return nil }
        let erased = subrange(data, 0xC0, 0x10)
        guard let erased, erased.allSatisfy({ $0 == 0xFF }) else { return nil }
        // Region table base 0x40 (descriptor at image start → fd_rgn_base);
        // FLREG2 (Engine/Graphics) = base field u16 @0x48, limit u16 @0x4A.
        let base = Int(le16(data, 0x48))
        let limit = Int(le16(data, 0x4A))
        guard limit != 0, base <= limit else { return nil }
        let start = base * 0x1000
        let size = (limit + 1 - base) * 0x1000
        guard start + size <= data.count else { return nil }
        return (start, size)
    }

    private static func subrange(_ data: Data, _ off: Int, _ len: Int) -> Data? {
        guard off >= 0, off + len <= data.count else { return nil }
        let s = data.startIndex + off
        return data.subdata(in: s..<(s + len))
    }
}

private func le16(_ data: Data, _ off: Int) -> UInt16 {
    let s = data.startIndex + off
    return UInt16(data[s]) | (UInt16(data[s + 1]) << 8)
}

private func le32(_ data: Data, _ off: Int) -> UInt32 {
    let s = data.startIndex + off
    return UInt32(data[s])
        | (UInt32(data[s + 1]) << 8)
        | (UInt32(data[s + 2]) << 16)
        | (UInt32(data[s + 3]) << 24)
}
