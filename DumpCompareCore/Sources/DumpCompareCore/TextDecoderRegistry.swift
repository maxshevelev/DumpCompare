import Foundation

/// Descriptors and factory for built-in text decoder tables.
public enum TextDecoderRegistry {

    // MARK: - Built-in descriptors

    /// All built-in tables, in menu display order.
    public static var all: [TextDecoderDescriptor] {
        [
            TextDecoderDescriptor(identifier: "cp1252", displayName: "Windows-1252"),
            TextDecoderDescriptor(identifier: "isoLatin1", displayName: "ISO-8859-1"),
            TextDecoderDescriptor(identifier: "strictASCII", displayName: "Strict ASCII"),
        ]
    }

    /// The default table identifier (Windows-1252).
    public static let defaultIdentifier = "cp1252"

    /// Build a decoder for the given identifier and placeholder.
    /// Unknown identifiers fall back to the cp1252 table.
    public static func make(identifier: String, placeholder: Character) -> any TextDecoder {
        let table: [UnicodeScalar?]
        let name: String
        switch identifier {
        case "isoLatin1":
            table = isoLatin1Scalars
            name = "ISO-8859-1"
        case "strictASCII":
            table = strictASCIIScalars
            name = "Strict ASCII"
        default:
            table = cp1252Scalars
            name = "Windows-1252"
        }
        return SingleByteTextDecoder(
            identifier: identifier == "isoLatin1" || identifier == "strictASCII" ? identifier : Self.defaultIdentifier,
            displayName: name,
            placeholder: placeholder,
            rawScalars: table
        )
    }

    // MARK: - cp1252 raw scalars

    /// Windows-1252 mapping table (256 entries). Nil = undefined slot.
    ///
    /// 0x00-0x7F: C0 controls (nil) + printable ASCII.
    /// 0x80-0x9F: the cp1252-specific punctuation/Euro symbols.
    /// 0xA0-0xFF: same as ISO-8859-1 (direct Unicode scalar mapping).
    private static let cp1252Scalars: [UnicodeScalar?] = {
        var table: [UnicodeScalar?] = .init(repeating: nil, count: 256)

        // Printable ASCII (0x20-0x7E). C0 controls and 0x7F stay nil.
        for value in 0x20...0x7E {
            table[value] = UnicodeScalar(value)
        }

        // Windows-1252 specials (0x80-0x9F). Undefined slots stay nil.
        table[0x80] = UnicodeScalar(0x20AC)  // € EURO SIGN
        // 0x81 undefined
        table[0x82] = UnicodeScalar(0x201A)  // ‚ SINGLE LOW-9 QUOTATION MARK
        table[0x83] = UnicodeScalar(0x0192)  // ƒ LATIN SMALL F WITH HOOK
        table[0x84] = UnicodeScalar(0x201E)  // „ DOUBLE LOW-9 QUOTATION MARK
        table[0x85] = UnicodeScalar(0x2026)  // … HORIZONTAL ELLIPSIS
        table[0x86] = UnicodeScalar(0x2020)  // † DAGGER
        table[0x87] = UnicodeScalar(0x2021)  // ‡ DOUBLE DAGGER
        table[0x88] = UnicodeScalar(0x02C6)  // ˆ MODIFIER LETTER CIRCUMFLEX
        table[0x89] = UnicodeScalar(0x2030)  // ‰ PER MILLE SIGN
        table[0x8A] = UnicodeScalar(0x0160)  // Š LATIN CAPITAL S WITH CARON
        table[0x8B] = UnicodeScalar(0x2039)  // ‹ SINGLE LEFT-POINTING ANGLE QUOTE
        table[0x8C] = UnicodeScalar(0x0152)  // Œ LATIN CAPITAL LIGATURE OE
        // 0x8D undefined
        table[0x8E] = UnicodeScalar(0x017D)  // Ž LATIN CAPITAL Z WITH CARON
        // 0x8F undefined
        // 0x90 undefined
        table[0x91] = UnicodeScalar(0x2018)  // ‘ LEFT SINGLE QUOTATION MARK
        table[0x92] = UnicodeScalar(0x2019)  // ’ RIGHT SINGLE QUOTATION MARK
        table[0x93] = UnicodeScalar(0x201C)  // “ LEFT DOUBLE QUOTATION MARK
        table[0x94] = UnicodeScalar(0x201D)  // ” RIGHT DOUBLE QUOTATION MARK
        table[0x95] = UnicodeScalar(0x2022)  // • BULLET
        table[0x96] = UnicodeScalar(0x2013)  // – EN DASH
        table[0x97] = UnicodeScalar(0x2014)  // — EM DASH
        table[0x98] = UnicodeScalar(0x02DC)  // ˜ SMALL TILDE
        table[0x99] = UnicodeScalar(0x2122)  // ™ TRADE MARK SIGN
        table[0x9A] = UnicodeScalar(0x0161)  // š LATIN SMALL S WITH CARON
        table[0x9B] = UnicodeScalar(0x203A)  // › SINGLE RIGHT-POINTING ANGLE QUOTE
        table[0x9C] = UnicodeScalar(0x0153)  // œ LATIN SMALL LIGATURE OE
        // 0x9D undefined
        table[0x9E] = UnicodeScalar(0x017E)  // ž LATIN SMALL Z WITH CARON
        table[0x9F] = UnicodeScalar(0x0178)  // Ÿ LATIN CAPITAL Y WITH DIAERESIS

        // 0xA0-0xFF: same as ISO-8859-1 (direct Unicode scalar mapping).
        // 0xAD (U+00AD SOFT HYPHEN, a Cf format char) is filtered by the
        // decoder's displayability rule.
        for value in 0xA0...0xFF {
            table[value] = UnicodeScalar(value)
        }

        return table
    }()

    // MARK: - ISO-8859-1 raw scalars

    /// ISO-8859-1 (Latin-1) mapping table.
    /// 0x00-0x7F: same as ASCII (C0 controls nil).
    /// 0x80-0x9F: C1 controls (not displayable — nil).
    /// 0xA0-0xFF: direct Unicode scalar mapping.
    private static let isoLatin1Scalars: [UnicodeScalar?] = {
        var table: [UnicodeScalar?] = .init(repeating: nil, count: 256)

        for value in 0x20...0x7E {
            table[value] = UnicodeScalar(value)
        }
        for value in 0xA0...0xFF {
            table[value] = UnicodeScalar(value)
        }
        return table
    }()

    // MARK: - Strict ASCII raw scalars

    /// Strict ASCII: only 0x20-0x7E are mapped.
    private static let strictASCIIScalars: [UnicodeScalar?] = {
        var table: [UnicodeScalar?] = .init(repeating: nil, count: 256)
        for value in 0x20...0x7E {
            table[value] = UnicodeScalar(value)
        }
        return table
    }()
}
