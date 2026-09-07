import Foundation

/// Converts between raw bytes, pasteboard data, and hex text (§12).
///
/// The primary pasteboard representation is raw bytes (§12.1, §12.4). Hex text
/// is produced only for debugging/interop, and text is only ever parsed back
/// into bytes when it unambiguously reads as hexadecimal byte pairs — anything
/// else is rejected rather than guessed at (§12.4).
public enum ClipboardCodec {
    public enum CodecError: Error, Equatable, Sendable {
        /// The text is not an unambiguous hexadecimal byte sequence.
        case invalidHexText
    }

    // MARK: - Raw bytes roundtrip (§12.1)

    public static func data(from bytes: [UInt8]) -> Data {
        Data(bytes)
    }

    public static func bytes(from data: Data) -> [UInt8] {
        Array(data)
    }

    // MARK: - Hex text

    /// Uppercase, unseparated hex dump (e.g. `DEADBEEF`), for interop/debug.
    public static func hexText(from bytes: [UInt8]) -> String {
        bytes.map { byte in
            let hex = String(byte, radix: 16).uppercased()
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }

    /// Parses text as hexadecimal byte pairs.
    ///
    /// Accepted: `DEADBEEF`, `DE AD BE EF`, `0xDE 0xAD` (case-insensitive).
    /// Whitespace and per-token `0x` prefixes are ignored. Rejects anything
    /// else — non-hex characters, an odd number of digits, or empty input —
    /// with `CodecError.invalidHexText`.
    public static func bytes(fromHexText text: String) throws -> [UInt8] {
        var digits = ""
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            var slice = Substring(token)
            if slice.lowercased().hasPrefix("0x") {
                slice = slice.dropFirst(2)
            }
            guard !slice.isEmpty else { throw CodecError.invalidHexText }
            guard slice.allSatisfy({ $0.isHexDigit }) else { throw CodecError.invalidHexText }
            digits += slice
        }
        guard !digits.isEmpty, digits.count % 2 == 0 else { throw CodecError.invalidHexText }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(after: index)
            guard let byte = UInt8(digits[index...next], radix: 16) else {
                throw CodecError.invalidHexText
            }
            bytes.append(byte)
            index = digits.index(after: next)
        }
        return bytes
    }
}
