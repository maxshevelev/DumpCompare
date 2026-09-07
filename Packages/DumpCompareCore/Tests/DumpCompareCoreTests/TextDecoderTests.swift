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

    /// The spec's two 16-byte vectors, decoded whole. One character per byte, so
    /// each expected string states every byte's rendering at its own position.
    /// (Both spec example strings are 15 characters — an off-by-one typo; the
    /// one-character-per-byte rule is the source of truth.)
    func testCp1252Vectors() {
        let d = decoder("cp1252")
        let cases: [(name: String, bytes: [UInt8], expected: String,
                     displayable: [Int], undisplayable: [Int])] = [
            // 0x9C œ at 3, 0xD6 Ö at 7, 0xFF ÿ in the tail; 0x90 at 4 is one of
            // cp1252's undefined slots.
            ("vector 1",
             [0x11, 0x00, 0x00, 0x9C, 0x90, 0x02, 0x00, 0xD6,
              0x00, 0x00, 0x00, 0x05, 0xFF, 0xFF, 0xFF, 0xFF],
             "...œ...Ö....ÿÿÿÿ", [3, 7, 15], [4]),
            // 0xA0 NO-BREAK SPACE at 2 displays as a regular space, 0x40 @ at 6,
            // 0x80 € at 10.
            ("vector 2",
             [0x00, 0x0F, 0xA0, 0x00, 0x00, 0x0D, 0x40, 0x00,
              0x00, 0x09, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00],
             ".. ...@...€.....", [2, 6, 10], []),
        ]
        for testCase in cases {
            let decoded = decodeAll(d, testCase.bytes)
            XCTAssertEqual(decoded.count, testCase.bytes.count,
                           "\(testCase.name): one character per byte")
            XCTAssertEqual(decoded, testCase.expected, testCase.name)
            for index in testCase.displayable {
                XCTAssertTrue(d.isDisplayable(testCase.bytes[index]),
                              "\(testCase.name): byte \(index) is displayable")
            }
            for index in testCase.undisplayable {
                XCTAssertFalse(d.isDisplayable(testCase.bytes[index]),
                               "\(testCase.name): byte \(index) is not displayable")
            }
        }
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

    // MARK: - 5.4b ISO-8859-1 against cp1252

    /// The one difference that makes the ISO-8859-1 menu item worth having:
    /// 0x80–0x9F is the C1 control block there, so every byte in it is a
    /// placeholder — where cp1252 spends the same range on €, œ, ™ and the rest.
    /// The Latin-1 accents above it must still decode, or a decoder that
    /// placeholdered everything would pass this.
    func testISOLatin1LeavesTheC1RangeAsPlaceholdersWhereCp1252HasCharacters() {
        let iso = decoder("isoLatin1")
        let cp = decoder("cp1252")

        for byte in UInt8(0x80)...UInt8(0x9F) {
            XCTAssertEqual(iso.decode(byte), ".", "isoLatin1 0x\(String(byte, radix: 16))")
            XCTAssertFalse(iso.isDisplayable(byte), "isoLatin1 0x\(String(byte, radix: 16))")
        }
        XCTAssertEqual(cp.decode(0x80), "€")
        XCTAssertEqual(cp.decode(0x9C), "œ")
        XCTAssertEqual(cp.decode(0x99), "™")
        XCTAssertNil(iso.encode("€"), "€ is not representable in ISO-8859-1")

        // The high half above C1 is plain Latin-1 in both tables.
        XCTAssertEqual(iso.decode(0xE9), "é")
        XCTAssertEqual(iso.decode(0xFF), "ÿ")
        XCTAssertEqual(iso.decode(0xA0), " ", "NO-BREAK SPACE shows as a space")
        XCTAssertTrue(iso.isDisplayable(0xE9))
        XCTAssertEqual(iso.encode("é"), 0xE9)
    }

    /// 0xAD is SOFT HYPHEN — an invisible format character, so it is filtered to
    /// a placeholder in both tables rather than drawn as nothing at all.
    func testSoftHyphenIsFilteredInBothLatinTables() {
        for identifier in ["cp1252", "isoLatin1"] {
            let d = decoder(identifier)
            XCTAssertEqual(d.decode(0xAD), ".", identifier)
            XCTAssertFalse(d.isDisplayable(0xAD), identifier)
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
        let seed: UInt64 = 0x0123_4567_89AB_CDEF
        var rng = SeededGenerator(seed: seed)
        let d = decoder("cp1252")
        for length in 0..<64 {
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) }
            XCTAssertEqual(d.decode(bytes[...]).count, bytes.count,
                           "seed \(String(seed, radix: 16)) length \(length)")
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

    /// A stored value the app cannot use is ignored in favour of the default —
    /// whether it names no table, is more than one character, or is empty. Each
    /// field falls back on its own: an unusable table does not discard a
    /// perfectly good placeholder.
    func testStoreFallsBackOnUnusableValues() {
        let cases: [(name: String, identifier: String, placeholder: String,
                     expected: TextDecodingSettings)] = [
            ("an unknown table and a two-character placeholder",
             "bogus-table", "??", .default),
            ("empty strings",
             "", "", .default),
            ("a usable placeholder but no such table",
             "bogus-table", "·",
             TextDecodingSettings(identifier: TextDecodingSettings.default.identifier,
                                  placeholder: "·")),
        ]
        for testCase in cases {
            let (store, suite) = makeSuiteStore()
            defer { removeSuite(suite) }

            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(testCase.identifier, forKey: TextDecodingSettingsStore.identifierKey)
            defaults.set(testCase.placeholder, forKey: TextDecodingSettingsStore.placeholderKey)

            XCTAssertEqual(store.settings, testCase.expected, testCase.name)
        }
    }

    func testStoreResetToDefaults() {
        let (store, suite) = makeSuiteStore()
        defer { removeSuite(suite) }

        store.apply(TextDecodingSettings(identifier: "strictASCII", placeholder: "×"))
        store.resetToDefaults()
        XCTAssertEqual(store.settings, TextDecodingSettings.default)
    }
}
