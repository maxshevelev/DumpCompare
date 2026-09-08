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
