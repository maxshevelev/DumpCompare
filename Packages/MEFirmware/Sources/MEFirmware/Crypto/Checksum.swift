import Foundation

/// Slice-by-8 CRC-32 tables, flattened: slice `k` occupies
/// `[k * 256 ..< (k + 1) * 256]`, and holds the contribution of a byte `k`
/// positions further back in the stream. Eight input bytes then cost eight
/// independent table lookups instead of eight dependent register updates — the
/// byte-at-a-time walk was ~50% of a whole firmware parse, because a
/// region-wide CRC-32 runs over the entire image. Same polynomial
/// (0xEDB88320, reflected), so the same answer.
private let crc32Slices: [UInt32] = {
    var slices = [UInt32](repeating: 0, count: 8 * 256)
    for n in 0..<256 {
        var value = UInt32(n)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        slices[n] = value
    }
    for k in 1..<8 {
        for n in 0..<256 {
            let previous = slices[(k - 1) * 256 + n]
            slices[k * 256 + n] = (previous >> 8) ^ slices[Int(previous & 0xFF)]
        }
    }
    return slices
}()

/// Slice 0 on its own — the short-span callers below stay on the simple walk,
/// where the wide loop's setup would cost more than it saves.
private let crc32Table: [UInt32] = Array(crc32Slices[0..<256])

/// CRC-32 checksums.
///
/// `crc32(_:)` is the *standard* reflected CRC-32 (poly 0xEDB88320, init and
/// final xor 0xFFFFFFFF) — bit-for-bit equal to Python `zlib.crc32` and to the
/// `crccheck.crc.Crc32` upstream MEA.py uses. It therefore matches upstream
/// `mc_chk32` (line 9916) and the R2 `$CPD` directory CRC (`cpd_chk`, line 9635,
/// which zeroes the 4-byte CRC field at +0x10 before hashing). Verified against
/// the stored CRC-32 of all nine R2 `$CPD`s in the CSME 15.0.30 dump and, later,
/// against module-body CRCs.
enum CRC32 {
    /// Standard CRC-32 of `data`.
    static func crc32(_ data: Data) -> UInt32 {
        register(over: data, from: 0xFFFF_FFFF) ^ 0xFFFF_FFFF
    }

    /// CRC-32 of `data` run from a zero initial register with *no* final XOR —
    /// the raw register value. Matches upstream `efs_anl`'s
    /// `~crccheck.crc.Crc32.calc(data, initvalue=0) & 0xFFFFFFFF`: crccheck's
    /// `calc(_:initvalue: 0)` finalizes a zeroed register (register XOR
    /// 0xFFFFFFFF), and the outer `~` in MEA.py inverts that back to the raw
    /// register value. The EFS System Page header, index-area and Data Page
    /// header/footer checks compare their stored CRC-32 against this — the
    /// standard `crc32(_:)` does *not* match them. Byte-verified on the CSME
    /// 15.0.30 EFS region (all stored CRCs equal this of their spans).
    static func crc32IV0Raw(_ data: Data) -> UInt32 {
        register(over: data, from: 0)
    }

    /// The table walk both spellings share, slice-by-8 over raw bytes rather
    /// than `for byte in data` (`Data.Iterator` was one of the hottest frames
    /// in a parse, and these run over whole regions and module bodies).
    private static func register(over data: Data, from initial: UInt32) -> UInt32 {
        var crc = initial
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress else { return }
            crc32Slices.withUnsafeBufferPointer { table in
                let count = bytes.count
                var offset = 0
                let blockEnd = count - (count % 8)
                while offset < blockEnd {
                    // The running register is folded into the first four bytes;
                    // the next four ride the higher slices.
                    let folded: UInt32 = crc ^ le32(base + offset)
                    let high: UInt32 = le32(base + offset + 4)
                    var next: UInt32 = table[1792 + Int(folded & 0xFF)]
                    next ^= table[1536 + Int((folded >> 8) & 0xFF)]
                    next ^= table[1280 + Int((folded >> 16) & 0xFF)]
                    next ^= table[1024 + Int((folded >> 24) & 0xFF)]
                    next ^= table[768 + Int(high & 0xFF)]
                    next ^= table[512 + Int((high >> 8) & 0xFF)]
                    next ^= table[256 + Int((high >> 16) & 0xFF)]
                    next ^= table[Int((high >> 24) & 0xFF)]
                    crc = next
                    offset += 8
                }
                while offset < count {
                    crc = table[Int((crc ^ UInt32(base[offset])) & 0xFF)] ^ (crc >> 8)
                    offset += 1
                }
            }
        }
        return crc
    }

    /// Four bytes at `pointer` as a little-endian word, unaligned-safe.
    private static func le32(_ pointer: UnsafePointer<UInt8>) -> UInt32 {
        UInt32(pointer[0])
            | UInt32(pointer[1]) << 8
            | UInt32(pointer[2]) << 16
            | UInt32(pointer[3]) << 24
    }
}

/// Upstream `Crc16_14` (MEA.py 9027) — the reverse de-obfuscation primitive for
/// MFS System Page chunk indexes (used at MEA.py 7745: `chunk_index =
/// Crc16_14(chunk_index) ^ index_value`). A CCITT-16 table (poly 0x1021) walks
/// the two little-endian bytes of `value`, but the running CRC is kept to 14
/// bits (init 0x3FFF, mask 0x3FFF after each byte) — the "no bits 0 and 1" of
/// the comment: a 14-bit code space whose values 0 and 1 are never produced, so
/// an obfuscated index can never collide with the 0xC000 "unused entry" marker.
enum CRC16_14 {
    private static let table: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 256)
        for i in 0..<256 {
            var r = UInt16(i) << 8
            for _ in 0..<8 {
                r = (r & 0x8000) != 0 ? (r << 1) ^ 0x1021 : (r << 1)
            }
            table[i] = r
        }
        return table
    }()

    /// The 14-bit obfuscation transform of `value`. Matches upstream: a wide
    /// running value is masked to 0x3FFF only after each byte step.
    static func transform(_ value: UInt16) -> UInt16 {
        var crc: UInt32 = 0x3FFF
        for byte in [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] {
            let index = Int(byte ^ UInt8((crc >> 8) & 0xFF))
            crc = (UInt32(table[index]) ^ (crc << 8)) & 0x3FFF
        }
        return UInt16(crc)
    }
}
