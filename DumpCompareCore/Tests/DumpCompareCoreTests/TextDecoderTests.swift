import XCTest
@testable import DumpCompareCore

/// Tests for the TextDecoder protocol, SingleByteTextDecoder, the registry,
/// and the settings store (§5).
final class TextDecoderTests: XCTestCase {

    // MARK: - Helpers

    private func decoder(_ identifier: String, placeholder: Character = ".") -> any TextDecoder {
        TextDecoderRegistry.make(identifier: identifier, placeholder: placeholder)
    }

    /// Decode a whole array through the convenience extension.
    private func decodeAll(_ d: any TextDecoder, _ bytes: [UInt8]) -> String {
        d.decode(bytes[...])
    }

    // MARK: - 5.1 cp1252 vectors

    func testCp1252Vector1() {
        let d = decoder("cp1252")
        let bytes: [UInt8] = [0x11, 0x00, 0x00, 0x9C, 0x90, 0x02, 0x00, 0xD6,
                              0x00, 0x00, 0x00, 0x05, 0xFF, 0xFF, 0xFF, 0xFF]
        // Per-byte expectations (the source of truth).
        XCTAssertEqual(d.decode(bytes[3]), "œ")   // 0x9C
        XCTAssertEqual(d.decode(bytes[7]), "Ö")   // 0xD6
        XCTAssertEqual(d.decode(bytes[13]), "ÿ")  // 0xFF
        XCTAssertEqual(d.decode(bytes[15]), "ÿ")
        XCTAssertEqual(d.isDisplayable(bytes[4]), false)  // 0x90 undefined
        // 16 bytes -> 16 characters, one per byte. (The spec's example string
        // is 15 characters — an off-by-one typo; the per-byte rules above are
        // the source of truth.)
        let s = decodeAll(d, bytes)
        XCTAssertEqual(s.count, bytes.count)
        XCTAssertEqual(s, "...œ...Ö....ÿÿÿÿ")
    }

    func testCp1252Vector2() {
        let d = decoder("cp1252")
        let bytes: [UInt8] = [0x00, 0x0F, 0xA0, 0x00, 0x00, 0x0D, 0x40, 0x00,
                              0x00, 0x09, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00]
        // 0xA0 NO-BREAK SPACE displays as a regular space.
        XCTAssertEqual(d.decode(bytes[2]), " ")
        XCTAssertEqual(d.isDisplayable(bytes[2]), true)
        XCTAssertEqual(d.decode(bytes[6]), "@")  // 0x40
        XCTAssertEqual(d.decode(bytes[10]), "€") // 0x80
        // 16 bytes -> 16 characters (spec example string is 15 — off by one).
        let s = decodeAll(d, bytes)
        XCTAssertEqual(s.count, bytes.count)
        XCTAssertEqual(s, ".. ...@...€.....")
    }

    // MARK: - 5.2 Undefined cp1252 slots

    func testUndefinedCp1252Slots() {
        let d = decoder("cp1252")
        for byte: UInt8 in [0x81, 0x8D, 0x8F, 0x90, 0x9D] {
            XCTAssertEqual(d.decode(byte), ".", "0x\(String(byte, radix: 16))")
            XCTAssertFalse(d.isDisplayable(byte))
        }
    }

    // MARK: - 5.3 Controls decode to placeholder in all presets

    func testControlsDecodeToPlaceholderInAllPresets() {
        for identifier in ["cp1252", "isoLatin1", "strictASCII"] {
            let d = decoder(identifier)
            for byte in UInt8.min...0x1F {
                XCTAssertEqual(d.decode(byte), ".", "\(identifier) 0x\(String(byte, radix: 16))")
                XCTAssertFalse(d.isDisplayable(byte))
            }
            XCTAssertEqual(d.decode(0x7F), ".", identifier)
            XCTAssertFalse(d.isDisplayable(0x7F))
        }
    }

    // MARK: - 5.4 strictASCII

    func testStrictASCIIPrintable() {
        let d = decoder("strictASCII")
        for byte in UInt8(0x20)...UInt8(0x7E) {
            XCTAssertEqual(d.decode(byte), Character(UnicodeScalar(byte)))
            XCTAssertTrue(d.isDisplayable(byte))
        }
    }

    func testStrictASCIIHighBytesPlaceholder() {
        let d = decoder("strictASCII")
        for byte in UInt8(0x80)...UInt8.max {
            XCTAssertEqual(d.decode(byte), ".")
            XCTAssertFalse(d.isDisplayable(byte))
        }
    }

    // MARK: - 5.5 Round-trip and encode

    func testRoundTrip() {
        let d = decoder("cp1252")
        for byte in UInt8.min...UInt8.max where d.isDisplayable(byte) {
            let ch = d.decode(byte)
            // ASCII space (0x20) is the canonical encoding of the NBSP byte
            // 0xA0's display character; 0xA0 itself round-trips to 0x20.
            if byte == 0xA0 {
                XCTAssertEqual(ch, " ")
                XCTAssertEqual(d.encode(ch), 0x20)
            } else {
                XCTAssertEqual(d.encode(ch), byte, "byte 0x\(String(byte, radix: 16))")
            }
        }
    }

    func testExplicitEncodeVectors() {
        let d = decoder("cp1252")
        XCTAssertEqual(d.encode("ÿ"), 0xFF)
        XCTAssertEqual(d.encode("œ"), 0x9C)
        XCTAssertEqual(d.encode("€"), 0x80)
        XCTAssertEqual(d.encode(" "), 0x20)
    }

    func testNonRepresentableEncodeReturnsNil() {
        let d = decoder("cp1252")
        XCTAssertNil(d.encode("汉"))       // CJK — not in cp1252
        XCTAssertNil(d.encode("😀"))        // emoji — not in cp1252
        XCTAssertNil(d.encode("🖖"))
    }

    func testEncodePlaceholderDoesNotAffectInverse() {
        // The placeholder setting must not change encode: a decoder built with
        // a custom placeholder still encodes the same characters.
        let plain = decoder("cp1252", placeholder: ".")
        let custom = decoder("cp1252", placeholder: "·")
        for byte in UInt8.min...UInt8.max where plain.isDisplayable(byte) {
            XCTAssertEqual(custom.encode(plain.decode(byte)), plain.encode(plain.decode(byte)))
        }
    }

    // MARK: - 5.6 Alignment property

    func testAlignmentDecodedLengthEqualsByteCount() {
        var seed: UInt64 = 0x123456789ABCDEF
        for length in 0..<64 {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(length)
            for _ in 0..<length {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                bytes.append(UInt8(truncatingIfNeeded: seed >> 32))
            }
            let d = decoder("cp1252")
            XCTAssertEqual(d.decode(bytes[...]).count, bytes.count,
                           "length \(length)")
        }
    }

    // MARK: - 5.7 Custom placeholder

    func testCustomPlaceholder() {
        let d = decoder("cp1252", placeholder: "·")
        XCTAssertEqual(d.decode(0x00), "·")
        XCTAssertEqual(d.decode(0x81), "·")
        XCTAssertEqual(d.decode(0x7F), "·")
        XCTAssertFalse(d.isDisplayable(0x00))
        XCTAssertFalse(d.isDisplayable(0x81))
        // Displayable bytes unaffected.
        XCTAssertEqual(d.decode(0x41), "A")
        XCTAssertEqual(d.decode(0x9C), "œ")
        XCTAssertTrue(d.isDisplayable(0x41))
    }

    // MARK: - 5.8 Registry

    func testRegistryListsBuiltins() {
        let ids = TextDecoderRegistry.all.map { $0.identifier }
        XCTAssertEqual(ids, ["cp1252", "isoLatin1", "strictASCII"])
        let names = TextDecoderRegistry.all.map { $0.displayName }
        XCTAssertEqual(names, ["Windows-1252", "ISO-8859-1", "Strict ASCII"])
    }

    func testRegistryFallbackToCp1252() {
        let d = decoder("no-such-table")
        XCTAssertEqual(d.identifier, "cp1252")
        XCTAssertEqual(d.displayName, "Windows-1252")
        XCTAssertEqual(d.decode(0x9C), "œ")
    }

    // MARK: - 5.8 Settings store

    private func makeSuiteStore() -> (TextDecodingSettingsStore, String) {
        let suite = "TextDecodingTests-\(UUID().uuidString)"
        let store = TextDecodingSettingsStore(userDefaults: UserDefaults(suiteName: suite)!)
        return (store, suite)
    }

    private func removeSuite(_ suite: String) {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testStorePersistsAndRestores() {
        let (store, suite) = makeSuiteStore()
        defer { removeSuite(suite) }

        XCTAssertEqual(store.settings, TextDecodingSettings.default)

        store.apply(TextDecodingSettings(identifier: "isoLatin1", placeholder: "·"))
        XCTAssertEqual(store.settings.identifier, "isoLatin1")
        XCTAssertEqual(store.settings.placeholder, "·")

        // A fresh store over the same suite reads the persisted values.
        let reopened = TextDecodingSettingsStore(userDefaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(reopened.settings.identifier, "isoLatin1")
        XCTAssertEqual(reopened.settings.placeholder, "·")
    }

    func testStoreCorruptedValuesFallBack() {
        let (store, suite) = makeSuiteStore()
        defer { removeSuite(suite) }

        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("bogus-table", forKey: TextDecodingSettingsStore.identifierKey)
        defaults.set("??", forKey: TextDecodingSettingsStore.placeholderKey)

        XCTAssertEqual(store.settings, TextDecodingSettings.default)
    }

    func testStoreEmptyIdentifierAndPlaceholderFallBack() {
        let (store, suite) = makeSuiteStore()
        defer { removeSuite(suite) }

        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("", forKey: TextDecodingSettingsStore.identifierKey)
        defaults.set("", forKey: TextDecodingSettingsStore.placeholderKey)

        XCTAssertEqual(store.settings, TextDecodingSettings.default)
    }

    func testStoreResetToDefaults() {
        let (store, suite) = makeSuiteStore()
        defer { removeSuite(suite) }

        store.apply(TextDecodingSettings(identifier: "strictASCII", placeholder: "×"))
        store.resetToDefaults()
        XCTAssertEqual(store.settings, TextDecodingSettings.default)
    }
}
