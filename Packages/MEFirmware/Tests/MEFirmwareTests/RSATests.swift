import XCTest
import Foundation
@testable import MEFirmware

/// Phase 11 — RSA manifest signature validation (`rsa_sig_val` + the SSA-PSS
/// chain) and the Montgomery big-int exponentiation it sits on.
///
/// The real manifest vectors live in `RealManifests.swift` (generated from the
/// two oracle whole-flash images): CSME12 = 2048-bit PKCS#1 v1.5 / SHA-256,
/// CSME15 = 3072-bit SSA-PSS / SHA-384. Reference validity confirmed with a
/// line-for-line Python mirror of `rsa_sig_val` (valid=True for both).
final class RSATests: XCTestCase {
    // ——— Real-dump signature validation ———

    func testCSME12ManifestSignatureValid() throws {
        // 2048-bit, PKCS#1 v1.5 SHA-256: the decrypted low 256 bits match.
        let outcome = RSA.validate(
            tag: "$MN2",
            publicKey: RealManifests.CSME12Key,
            exponent: RealManifests.CSME12Exp,
            signature: RealManifests.CSME12Sig,
            protectedData: RealManifests.CSME12Protected)
        let o = try XCTUnwrap(outcome)
        XCTAssertTrue(o.valid)
        // The embedded hash is the last 32 bytes of the decrypted signature —
        // a SHA-256 that must equal the digest of the protected data.
        XCTAssertEqual(o.embeddedHash?.count, 64)
        XCTAssertEqual(o.embeddedHash, o.dataHash)
    }

    func testCSME15ManifestSignatureValid() throws {
        // 3072-bit, SSA-PSS SHA-384: parseSign → unmask → get_salt →
        // pss_final_validate must reproduce the embedded digest.
        let outcome = RSA.validate(
            tag: "$MN2",
            publicKey: RealManifests.CSME15Key,
            exponent: RealManifests.CSME15Exp,
            signature: RealManifests.CSME15Sig,
            protectedData: RealManifests.CSME15Protected)
        let o = try XCTUnwrap(outcome)
        XCTAssertTrue(o.valid)
        XCTAssertEqual(o.embeddedHash?.count, 96)   // SHA-384 hex
        XCTAssertEqual(o.embeddedHash, o.dataHash)
    }

    func testCSME16ManifestSignatureValid() throws {
        // A third real 3072-bit SSA-PSS / SHA-384 manifest, chosen because its
        // modulus top limb is >= 0x80000000 — the geometry that once broke the
        // Montgomery 2n-vs-R top-limb truncation (regression guard).
        let outcome = RSA.validate(
            tag: "$MN2",
            publicKey: RealManifests.CSME16Key,
            exponent: RealManifests.CSME16Exp,
            signature: RealManifests.CSME16Sig,
            protectedData: RealManifests.CSME16Protected)
        let o = try XCTUnwrap(outcome)
        XCTAssertTrue(o.valid)
        XCTAssertEqual(o.embeddedHash?.count, 96)   // SHA-384 hex
        XCTAssertEqual(o.embeddedHash, o.dataHash)
    }

    func testTamperedProtectedDataInvalidatesBothPaths() throws {
        // Flip one byte in the protected window → both signature schemes fail.
        for (key, sig, exp, prot) in [
            (RealManifests.CSME12Key, RealManifests.CSME12Sig,
             RealManifests.CSME12Exp, RealManifests.CSME12Protected),
            (RealManifests.CSME15Key, RealManifests.CSME15Sig,
             RealManifests.CSME15Exp, RealManifests.CSME15Protected),
            (RealManifests.CSME16Key, RealManifests.CSME16Sig,
             RealManifests.CSME16Exp, RealManifests.CSME16Protected),
        ] {
            var tampered = Data(prot)
            tampered[tampered.count - 1] ^= 0x01
            let outcome = RSA.validate(tag: "$MN2", publicKey: key,
                                       exponent: exp, signature: sig,
                                       protectedData: tampered)
            let o = try XCTUnwrap(outcome)
            XCTAssertFalse(o.valid)
        }
    }

    func testEmptyRSABlockIsValid() {
        // Upstream: an all-zero exponent/key/signature is a "Valid/Empty RSA
        // block" — reported valid, never a crash.
        let zero = Data(repeating: 0, count: 0x100)
        let outcome = RSA.validate(tag: "$MN2", publicKey: zero,
                                   exponent: 0, signature: zero,
                                   protectedData: Data(repeating: 0xAA, count: 0x80))
        XCTAssertEqual(outcome?.valid, true)
    }

    func testEvenModulusIsNotCheckable() {
        // A degenerate modulus (even low byte) cannot be exponentiated into —
        // upstream would crash. Report nil (not checkable), never false.
        var even = Data(repeating: 0xFF, count: 0x100)
        even[0] = 0x00   // even
        let outcome = RSA.validate(tag: "$MN2", publicKey: even,
                                   exponent: 65537,
                                   signature: RealManifests.CSME12Sig,
                                   protectedData: RealManifests.CSME12Protected)
        XCTAssertNil(outcome)
    }

    func testMissingKeyMaterialIsNotCheckable() {
        let outcome = RSA.validate(tag: "$MN2", publicKey: Data(),
                                   exponent: 0, signature: Data(),
                                   protectedData: Data())
        XCTAssertNil(outcome)
    }

    // ——— Montgomery modpow against independent vectors ———

    func testPowerModMatchesReference() throws {
        // pow(2, 65537, n) for both real moduli, computed with Python's bignum
        // (independent of the Montgomery implementation under test).
        let cases: [(Data, String, Int)] = [
            (RealManifests.CSME12Key,
             "A1232A3002629754CB38C489590D6091F88C18B2589A2690437ADD72BDAF69CE00021203B5322744192B651736C0C7EB150A903A2D7C439082FB894F7F43BD2F612AC4192A496F6B2E281B85374F303C19B5FC005F48AAAA8B9F6C7AC8C51263FCF4E730F4085F1751070A43851EDA537E93CF3314C5614FB406FE4CD14CCF6EAE7B7FD904F956356832802BD6998EAD86E961A900B03223A0A6F9A4247EDF4EEFFACA1615BA015174C0646F9C88B7B8B1B1C4E3226AEBC332CB274EEC19EB0D83577B97D3A351318F9F029E96F94000DAEAC76118CD8C63E9F1068D3DFD66B3ED67E7D139664FB0ACBE2709DC6EC7A56E2CFE4489F7B92D6367B2F5A794F19A",
             0x100),
            (RealManifests.CSME15Key,
             "403AA550B420A4003CEB48248D5032BEC70B1D22EDD88F79B5BE61DA1A2159D23EEF57BCE072E9DA3CBE39B5B80115246AF02FD3F3CD47D7F7A352C0375635DAA8F90FB17D64C067CC446357451D438620EC1C9993688B1412172A7EAAA8DD408C3083E225D0C81B8B34D9D433266B1BBD5DDA5BD9C68764BFBCCB13B37251712E189D6F761F8F689534B8158FFDFDAFC4B8B4A8333D56DD88682CAA9EAE37778018A831B0E4ED11769EB0A0089202E75E5C422738BF32A6B514A7577E6650D7099CC76771AEF43866A45B7E8D101B6CEFF3FA315F9A4696AFE220C58FBDAFD8D156042F32DB82A033864444B07EA0F9A942FD535DA4101E338E79B68794D1A495085169716AD4F5F6DF0AE2656D8B8CF4097156153FDC009E761B02AE2FAA01DC72A65B893E02ADBF5B10937A0168719AE43E99E6DC428D68FA56F9C4064C89274E906C65DB1B0FE4255B0D0F4029279A2849C4256C2BEE500479619AEB2D894BC8E57DF4231E4FF404848F5281FCF921F98E97DB47291BDF3A7658256501C2",
             0x180),
        ]
        for (modulusData, expectedHex, width) in cases {
            let n = BigInt.limbs(littleEndian: modulusData)
            let result = BigInt.powerMod(base: [2], exponent: [65537], modulus: n)
            let bytes = BigInt.bigEndianBytes(result, byteCount: width)
            XCTAssertEqual(Digest.hex(bytes), expectedHex)
        }
    }

    /// The exponent walk starts at the highest set bit now, so the cases that
    /// used to be carried by the leading zeros have to be stated.
    func testPowerModHandlesTheExponentsEdges() {
        // a^0 = 1, whatever the base; a^1 = a mod n.
        XCTAssertEqual(BigInt.powerMod(base: [7], exponent: [0], modulus: [17]),
                       BigInt.trim([1]))
        XCTAssertEqual(BigInt.powerMod(base: [20], exponent: [1], modulus: [17]),
                       BigInt.trim([3]))
        // 0^5 = 0.
        XCTAssertEqual(BigInt.powerMod(base: [0], exponent: [5], modulus: [17]),
                       BigInt.trim([0]))
        // A leading zero limb is not part of the number: same answer as without.
        XCTAssertEqual(BigInt.powerMod(base: [3], exponent: [4, 0], modulus: [17]),
                       BigInt.powerMod(base: [3], exponent: [4], modulus: [17]))
        // A set top bit of the limb is a real bit of the exponent, and the
        // walk has to start there: the exponent is the number 2^31, and 2 has
        // order 8 mod 17 (2^8 = 256 = 15·17 + 1), so 2^(2^31) ≡ 1.
        XCTAssertEqual(BigInt.powerMod(base: [2], exponent: [0x8000_0000],
                                       modulus: [17]),
                       BigInt.trim([1]))
    }

    func testPowerModSmallNumbers() {
        // Hand-computed: 3^4 mod 17 = 81 mod 17 = 13; 2^10 mod 999 = 25.
        XCTAssertEqual(BigInt.powerMod(base: [3], exponent: [4],
                                       modulus: [17]),
                       BigInt.trim([13]))
        XCTAssertEqual(BigInt.powerMod(base: [2], exponent: [10],
                                       modulus: BigInt.trim([999])),
                       BigInt.trim([25]))
    }
}
