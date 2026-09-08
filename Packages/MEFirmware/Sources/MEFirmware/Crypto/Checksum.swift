import Foundation

private let crc32Table: [UInt32] = {
    var table = [UInt32](repeating: 0, count: 256)
    for n in 0..<256 {
        var value = UInt32(n)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        table[n] = value
    }
    return table
}()

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
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
