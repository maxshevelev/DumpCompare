import Foundation

/// Human-readable name for a decoder table descriptor (used in menus).
public struct TextDecoderDescriptor: Sendable, Equatable {
    public let identifier: String
    public let displayName: String

    public init(identifier: String, displayName: String) {
        self.identifier = identifier
        self.displayName = displayName
    }
}

/// Maps raw bytes to display characters for the decoded text column.
///
/// Contract: exactly one display cell per byte. Multi-byte decoding is out of
/// scope for this protocol.
public protocol TextDecoder: Sendable {
    /// Stable identifier for persistence, e.g. "cp1252".
    var identifier: String { get }
    /// Human-readable name for menus, e.g. "Windows-1252".
    var displayName: String { get }
    /// Character shown for bytes without a displayable mapping.
    var placeholder: Character { get }

    /// Display character for a byte. Returns placeholder for non-displayable bytes.
    func decode(_ byte: UInt8) -> Character

    /// True if the byte maps to a real character (not placeholder).
    /// The view uses this to style placeholders (e.g. dimmed color).
    func isDisplayable(_ byte: UInt8) -> Bool

    /// Reverse mapping for editing: byte produced by typing the character,
    /// or nil if not representable in this decoding.
    func encode(_ character: Character) -> UInt8?
}

extension TextDecoder {
    /// Decode a row of bytes into a string.
    public func decode(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes.map { decode($0) })
    }
}

/// A table-based single-byte decoder: precomputed forward table (256 entries)
/// and inverse map, both built once at init. O(1) per byte.
public struct SingleByteTextDecoder: TextDecoder {
    public let identifier: String
    public let displayName: String
    public let placeholder: Character

    /// Forward table: index = byte value, value = display character.
    private let forwardTable: [Character]
    /// Inverse map: display character -> byte value (for editing).
    private let inverseMap: [Character: UInt8]
    /// Which bytes are displayable (not placeholder).
    private let displayable: [Bool]

    /// Initialize from a raw 256-entry Unicode scalar table.
    /// - Parameters:
    ///   - identifier: stable id for this table.
    ///   - displayName: human-readable name.
    ///   - placeholder: character for non-displayable bytes.
    ///   - rawScalars: 256 Unicode scalars (one per byte). A nil scalar means
    ///     the code page has no mapping for that byte.
    public init(
        identifier: String,
        displayName: String,
        placeholder: Character,
        rawScalars: [UnicodeScalar?]
    ) {
        precondition(rawScalars.count == 256, "rawScalars must have exactly 256 entries")

        self.identifier = identifier
        self.displayName = displayName
        self.placeholder = placeholder

        var fwd: [Character] = []
        var inv: [Character: UInt8] = [:]
        var disp: [Bool] = []

        fwd.reserveCapacity(256)
        disp.reserveCapacity(256)

        for byteValue in 0..<256 {
            let byte = UInt8(byteValue)
            if let scalar = rawScalars[byteValue],
               isDisplayableScalar(scalar) {
                let ch: Character
                if scalar == UnicodeScalar(0x00A0)! {
                    // NO-BREAK SPACE -> display as regular space.
                    ch = " "
                } else {
                    ch = Character(scalar)
                }
                fwd.append(ch)
                disp.append(true)
                // Inverse map: the display character maps back to the byte.
                // If multiple bytes map to the same character (e.g. 0x20 ->
                // " " and 0xA0 -> " " via NO-BREAK SPACE), the first one wins
                // (first-wins, not overwrite): ASCII space is the canonical
                // encoding, so typing space produces 0x20.
                if inv[ch] == nil {
                    inv[ch] = byte
                }
            } else {
                fwd.append(placeholder)
                disp.append(false)
            }
        }

        self.forwardTable = fwd
        self.inverseMap = inv
        self.displayable = disp
    }

    public func decode(_ byte: UInt8) -> Character {
        forwardTable[Int(byte)]
    }

    public func isDisplayable(_ byte: UInt8) -> Bool {
        displayable[Int(byte)]
    }

    public func encode(_ character: Character) -> UInt8? {
        inverseMap[character]
    }
}

/// Returns true if the scalar should be displayed as a character in the
/// decoded text column. C0/C1 controls and invisible/format (Cf) characters
/// are excluded; undefined slots are handled by the caller (nil raw scalar).
private func isDisplayableScalar(_ scalar: UnicodeScalar) -> Bool {
    let value = scalar.value

    // C0 controls (U+0000-U+001F), DEL (U+007F), and C1 controls (U+0080-U+009F).
    if value <= 0x1F || (value >= 0x7F && value <= 0x9F) {
        return false
    }

    // Invisible / format characters (Unicode Cf), e.g. U+00AD SOFT HYPHEN.
    if scalar.properties.generalCategory == .format {
        return false
    }

    return true
}
