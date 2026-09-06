import Foundation

/// `EFI_GUID`: sixteen bytes, and the reason half of this format is a lookup
/// table (`Design/UEFI/UEFI_IMAGE_FORMAT.md` §0).
///
/// Stored as the two 64-bit halves of its raw bytes rather than as an array,
/// so that comparing one against a table of known GUIDs — which the parser does
/// for every volume, every file and every GUID-defined section — is two integer
/// compares and no allocation.
///
/// The textual form is the mixed-endian one everyone writes GUIDs in: the first
/// three fields are little-endian numbers, the last eight bytes are printed in
/// the order they are stored. That asymmetry is not ours to fix — a GUID copied
/// out of a specification has to match a GUID read out of an image.
public struct EFIGUID: Hashable, Sendable, CustomStringConvertible {
    /// Bytes 0..<8, read as a little-endian number.
    public let low: UInt64
    /// Bytes 8..<16, read as a little-endian number.
    public let high: UInt64

    public init(low: UInt64, high: UInt64) {
        self.low = low
        self.high = high
    }

    /// Sixteen bytes as they lie in the image. Fewer or more is a programming
    /// error, not a malformed image — the callers that read from an image go
    /// through `ImageReader.guid(at:)`, which bounds-checks first.
    public init(bytes: [UInt8]) {
        precondition(bytes.count == 16, "an EFI_GUID is sixteen bytes")
        var low: UInt64 = 0
        var high: UInt64 = 0
        for index in 0..<8 {
            low |= UInt64(bytes[index]) << (8 * UInt64(index))
            high |= UInt64(bytes[index + 8]) << (8 * UInt64(index))
        }
        self.init(low: low, high: high)
    }

    /// `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, with or without braces. Case is
    /// ignored, because specifications and vendors disagree about it.
    public init?(_ string: String) {
        var digits = string
        if digits.hasPrefix("{") && digits.hasSuffix("}") {
            digits = String(digits.dropFirst().dropLast())
        }
        let fields = digits.split(separator: "-", omittingEmptySubsequences: false)
        let widths = [8, 4, 4, 4, 12]
        guard fields.count == widths.count else { return nil }
        var nibbles: [UInt8] = []
        for (field, width) in zip(fields, widths) {
            guard field.count == width else { return nil }
            for character in field {
                guard let value = character.hexDigitValue else { return nil }
                nibbles.append(UInt8(value))
            }
        }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: nibbles.count, by: 2) {
            bytes.append(nibbles[index] << 4 | nibbles[index + 1])
        }
        // The first three fields are little-endian numbers; the rest is a byte
        // string. So only the first eight bytes get reversed, in three pieces.
        var reordered = Array(bytes[0..<4].reversed())
        reordered += bytes[4..<6].reversed()
        reordered += bytes[6..<8].reversed()
        reordered += bytes[8..<16]
        self.init(bytes: reordered)
    }

    /// The sixteen bytes, in image order.
    public var bytes: [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: low >> (8 * UInt64($0))) }
            + (0..<8).map { UInt8(truncatingIfNeeded: high >> (8 * UInt64($0))) }
    }

    public var description: String {
        let bytes = bytes
        func hex(_ bytes: some Sequence<UInt8>) -> String {
            bytes.map { String(format: "%02X", $0) }.joined()
        }
        return hex(bytes[0..<4].reversed())
            + "-" + hex(bytes[4..<6].reversed())
            + "-" + hex(bytes[6..<8].reversed())
            + "-" + hex(bytes[8..<10])
            + "-" + hex(bytes[10..<16])
    }

    /// All sixteen bytes `0x00`, which is how an absent GUID is written.
    public static let zero = EFIGUID(low: 0, high: 0)
}
