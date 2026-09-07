import Foundation

/// The arithmetic every layer of this format checks itself with
/// (`Design/UEFI/UEFI_IMAGE_FORMAT.md` §0).
///
/// One idea underneath all of it: the checksum field is chosen so that the sum
/// of the structure *including* the field is zero. So verifying and computing
/// are the same operation, and a tool-module that rewrites a field can put the
/// structure back in order by summing what it wrote — which is exactly what the
/// FIT and FFS update procedures ask for.
public enum Checksums {
    /// Sum of the bytes, modulo 256.
    public static func sum8(_ bytes: some Sequence<UInt8>) -> UInt8 {
        bytes.reduce(into: UInt8(0)) { $0 = $0 &+ $1 }
    }

    /// The value that makes the byte sum come out at zero.
    public static func checksum8(_ bytes: some Sequence<UInt8>) -> UInt8 {
        0 &- sum8(bytes)
    }

    /// Sum of the little-endian 16-bit words, modulo 65536. An odd length has
    /// no answer rather than a rounded one: the FV header length that produced
    /// it is itself the corruption worth reporting (§3.3).
    public static func sum16(_ bytes: [UInt8]) -> UInt16? {
        guard bytes.count % 2 == 0 else { return nil }
        var sum: UInt16 = 0
        for index in stride(from: 0, to: bytes.count, by: 2) {
            sum = sum &+ (UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
        }
        return sum
    }

    public static func checksum16(_ bytes: [UInt8]) -> UInt16? {
        guard let sum = sum16(bytes) else { return nil }
        return 0 &- sum
    }

    /// Sum of the bytes of `range`, read in chunks so that a file body of any
    /// size costs one buffer. Nil when the range is not inside the image.
    public static func sum8(of range: Range<UInt64>, in reader: ImageReader) -> UInt8? {
        guard reader.has(range) else { return nil }
        var sum: UInt8 = 0
        reader.forEachChunk(of: range) { chunk in
            sum = sum &+ sum8(chunk)
            return true
        }
        return sum
    }

    /// Sum of the little-endian 32-bit words of `range` — how an Intel
    /// microcode image checks out (§7.1: the sum of every dword is zero). The
    /// length must be a multiple of four, and the chunking keeps it so.
    public static func sum32(of range: Range<UInt64>, in reader: ImageReader) -> UInt32? {
        guard reader.has(range), range.count % 4 == 0 else { return nil }
        var sum: UInt32 = 0
        reader.forEachChunk(of: range, size: 64 * 1024) { chunk in
            for index in stride(from: 0, to: chunk.count, by: 4) {
                sum = sum &+ (UInt32(chunk[index])
                    | UInt32(chunk[index + 1]) << 8
                    | UInt32(chunk[index + 2]) << 16
                    | UInt32(chunk[index + 3]) << 24)
            }
            return true
        }
        return sum
    }

    /// How a checksum and whether the structure says it counts read together:
    /// the value in hex, and the validity in words — `0x5C (Valid)` or
    /// `0x5C (Invalid)`. One spelling of it, so a checksum that carries a
    /// validity bit reads the same in every panel that shows it.
    public static func text(_ value: some BinaryInteger, valid: Bool, digits: Int = 2) -> String {
        let v = UInt64(truncatingIfNeeded: value)
        let hexText = String(v, radix: 16, uppercase: true)
        let padded = "0x" + String(repeating: "0", count: max(0, digits - hexText.count)) + hexText
        return "\(padded) (\(valid ? "Valid" : "Invalid"))"
    }
}

/// Rounds `value` up to the next multiple of `alignment`, or nil when that
/// would overflow — which is not a theoretical worry here, since the value
/// being aligned is usually `offset + size` with both fields read out of a
/// corrupt image (§11).
public func alignUp(_ value: UInt64, to alignment: UInt64) -> UInt64? {
    guard alignment > 0 else { return nil }
    let remainder = value % alignment
    guard remainder != 0 else { return value }
    let (aligned, overflowed) = value.addingReportingOverflow(alignment - remainder)
    return overflowed ? nil : aligned
}
