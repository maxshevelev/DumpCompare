import Foundation

/// Parses user-entered offsets and byte counts (§10.1).
///
/// Accepted forms:
/// - `0x`/`0X` prefixed: hexadecimal (case-insensitive digits), e.g. `0x1F`.
/// - Plain digits only: decimal, e.g. `4096`.
/// - Hex-digit text without a prefix: hexadecimal, e.g. `FF` = 255.
///
/// Values must fit in a 64-bit unsigned integer. Leading/trailing whitespace is
/// ignored. Anything else — empty input, stray characters, negative signs — is
/// an invalid input error; overflowing values are an out-of-range error.
public enum OffsetParser {
    public enum ParseError: Error, Equatable, Sendable {
        case invalidInput
        case outOfRange
    }

    private static let decimalDigits = "0123456789"

    public static func parse(_ text: String) throws -> UInt64 {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.invalidInput }

        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            let digits = trimmed.dropFirst(2)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isHexDigit }) else {
                throw ParseError.invalidInput
            }
            return try parseHex(String(digits))
        }

        if trimmed.allSatisfy({ decimalDigits.contains($0) }) {
            guard let value = UInt64(trimmed, radix: 10) else { throw ParseError.outOfRange }
            return value
        }

        if trimmed.allSatisfy({ $0.isHexDigit }) {
            return try parseHex(trimmed)
        }

        throw ParseError.invalidInput
    }

    private static func parseHex(_ digits: String) throws -> UInt64 {
        guard let value = UInt64(digits, radix: 16) else { throw ParseError.outOfRange }
        return value
    }

    /// Formats `value` as a lowercase hexadecimal string.
    public static func hexString(_ value: UInt64) -> String {
        String(value, radix: 16, uppercase: false)
    }
}
