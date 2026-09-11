import Foundation

/// Minimal fixed-array arithmetic for the RSA *decryption* step of manifest
/// signature validation. Upstream calls `pow(man_sign, man_pexp, man_pkey)`
/// (MEA.py 10232) on the signature / public exponent / modulus read as
/// little-endian integers; Swift has no arbitrary-precision integer, so the
/// power is computed here with Montgomery multiplication.
///
/// Numbers are little-endian arrays of `UInt32` limbs. Only the operations the
/// exponentiation needs exist: no general division — every intermediate stays
/// below 2·modulus, so reductions are single conditional subtractions and the
/// base is reduced bit-by-bit up front (a linear scan, not division).
enum BigInt {
    /// Trim high zero limbs (an empty array reads as `[0]`).
    static func trim(_ a: [UInt32]) -> [UInt32] {
        var a = a
        while a.count > 1, a.last == 0 { a.removeLast() }
        return a.isEmpty ? [0] : a
    }

    /// Limbs up to and including the highest non-zero one; 0 for a zero value
    /// (or an empty array). What `trim` reports, without the copy `trim` makes
    /// — these run inside the modular-exponentiation loop, where an allocation
    /// per comparison was most of what RSA validation cost.
    static func significantCount(_ a: [UInt32]) -> Int {
        var n = a.count
        while n > 0, a[n - 1] == 0 { n -= 1 }
        return n
    }

    /// `a >= b` ?
    static func ge(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        let ca = significantCount(a), cb = significantCount(b)
        if ca != cb { return ca > cb }
        var i = ca - 1
        while i >= 0 {
            if a[i] != b[i] { return a[i] > b[i] }
            i -= 1
        }
        return true
    }

    /// `a - b` (requires `a >= b`).
    static func subtract(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var a = a
        var borrow: UInt64 = 0
        for i in 0..<a.count {
            let orig = UInt64(a[i])
            let subtrahend = UInt64(i < b.count ? b[i] : 0) &+ borrow
            if orig < subtrahend {
                a[i] = UInt32(orig &+ 0x1_0000_0000 &- subtrahend)
                borrow = 1
            } else {
                a[i] = UInt32(orig &- subtrahend)
                borrow = 0
            }
        }
        return trim(a)
    }

    /// Full schoolbook product `a · b`.
    static func multiplyFull(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        let ca = significantCount(a), cb = significantCount(b)
        guard ca > 0, cb > 0 else { return [0] }
        var result = [UInt32](repeating: 0, count: ca + cb)
        for i in 0..<ca where a[i] != 0 {
            let ai = UInt64(a[i])
            var carry: UInt64 = 0
            for j in 0..<cb {
                let sum = UInt64(result[i + j]) + ai * UInt64(b[j]) + carry
                result[i + j] = UInt32(sum & 0xFFFF_FFFF)
                carry = sum >> 32
            }
            var k = i + cb
            while carry != 0 {
                let sum = UInt64(result[k]) + carry
                result[k] = UInt32(sum & 0xFFFF_FFFF)
                carry = sum >> 32
                k += 1
            }
        }
        return trim(result)
    }

    /// `2·x mod n` for `x < n`. Doubling keeps the value below `2n`, so a single
    /// conditional subtraction reduces it.
    static func double(_ x: [UInt32], mod n: [UInt32]) -> [UInt32] {
        var a = trim(x)
        var carry: UInt32 = 0
        for i in 0..<a.count {
            let v = a[i]
            a[i] = (v << 1) | carry
            carry = v >> 31
        }
        if carry != 0 { a.append(carry) }
        return ge(a, n) ? subtract(a, n) : a
    }

    /// `(x + 1) mod n` for `x < n`.
    static func increment(_ x: [UInt32], mod n: [UInt32]) -> [UInt32] {
        var a = trim(x)
        var i = 0
        while i < a.count, a[i] == 0xFFFF_FFFF { a[i] = 0; i += 1 }
        if i == a.count {
            a.append(1)
        } else {
            a[i] += 1
        }
        return a == n ? [0] : trim(a)
    }

    /// `a mod n` by scanning the bits of `a` through `r = 2r + bit (mod n)` —
    /// a linear-time reduction that avoids a general division primitive.
    static func reduced(_ a: [UInt32], _ n: [UInt32]) -> [UInt32] {
        let a = trim(a), n = trim(n)
        guard ge(a, n) else { return a }
        var r: [UInt32] = [0]
        for bit in stride(from: a.count * 32 - 1, through: 0, by: -1) {
            r = double(r, mod: n)
            if a[bit / 32] & (UInt32(1) << UInt32(bit % 32)) != 0 {
                r = increment(r, mod: n)
            }
        }
        return r
    }

    /// `2^exp2 mod n`, by repeated modular doubling.
    static func pow2Mod(exp2: Int, mod n: [UInt32]) -> [UInt32] {
        var x: [UInt32] = [1]
        if exp2 <= 0 { return x }
        for _ in 0..<exp2 { x = double(x, mod: n) }
        return x
    }

    /// `-n0^{-1} mod 2^32`, the Montgomery "n'₀" constant (Newton iteration).
    static func n0Inverse(_ n0: UInt32) -> UInt32 {
        var inv: UInt32 = 1
        for _ in 0..<5 { inv = inv &* (2 &- n0 &* inv) }
        return 0 &- inv
    }

    static func pad(_ a: [UInt32], to length: Int) -> [UInt32] {
        var a = trim(a)
        while a.count < length { a.append(0) }
        return a
    }

    /// Montgomery product `a·b·R⁻¹ mod n`, `R = 2^(32·k)`, for `a,b < n`, `n`
    /// odd with `k` limbs (RSA moduli qualify). Classic interleaved REDC.
    static func montgomeryProduct(_ a: [UInt32], _ b: [UInt32],
                                  n: [UInt32], k: Int, n0Inv: UInt32) -> [UInt32] {
        let a = pad(a, to: k), b = pad(b, to: k)
        var t = multiplyFull(a, b)
        while t.count < 2 * k + 2 { t.append(0) }

        for _ in 0..<k {
            let u = t[0] &* n0Inv
            var carry: UInt64 = 0
            for j in 0..<k {
                let sum = UInt64(u) * UInt64(n[j]) + UInt64(t[j]) + carry
                t[j] = UInt32(sum & 0xFFFF_FFFF)
                carry = sum >> 32
            }
            var idx = k
            while carry != 0 {
                let sum = UInt64(t[idx]) + carry
                t[idx] = UInt32(sum & 0xFFFF_FFFF)
                carry = sum >> 32
                idx += 1
            }
            for i in 0..<t.count - 1 { t[i] = t[i + 1] }
            t[t.count - 1] = 0
        }
        // After k reductions t = (a·b + m·n)·R⁻¹ < 2n. When the modulus is large
        // (top limb ≥ 0x80000000) 2n can reach past R, so the top limb — index k —
        // must survive: truncating to the low k limbs would drop R−n instead of
        // subtracting n (a data-dependent wrong result on exactly those moduli).
        var result = Array(t.prefix(k + 1))
        while ge(result, n) { result = subtract(result, n) }
        return trim(result)
    }

    /// `a^e mod n`. The modulus must be odd (as RSA moduli are); callers with a
    /// degenerate (even/zero) modulus never reach here (see `RSA.validate`).
    static func powerMod(base: [UInt32], exponent: [UInt32], modulus n: [UInt32]) -> [UInt32] {
        precondition(!n.isEmpty && (n[0] & 1) == 1, "RSA modulus must be odd")
        let n = trim(n), k = n.count
        let n0Inv = n0Inverse(n[0])

        // Montgomery constants: R mod n and R² mod n for R = 2^(32·k).
        let rMod = pow2Mod(exp2: 32 * k, mod: n)
        let r2Mod = pow2Mod(exp2: 64 * k, mod: n)

        let base = reduced(base, n)
        let exponent = trim(exponent)

        // Montgomery form of 1 is R mod n; the base enters as base·R mod n.
        var accumulator = rMod
        let baseMontgomery = montgomeryProduct(base, r2Mod, n: n, k: k, n0Inv: n0Inv)

        // Start at the exponent's highest set bit. Above it the square-and-
        // multiply loop only squares the Montgomery form of 1 into itself, and
        // an RSA public exponent is 0x10001 — seventeen bits in a thirty-two
        // bit limb, so almost half the squarings were of that kind.
        var top = exponent.count * 32 - 1
        while top > 0,
              exponent[top / 32] & (UInt32(1) << UInt32(top % 32)) == 0 { top -= 1 }

        for bit in stride(from: top, through: 0, by: -1) {
            accumulator = montgomeryProduct(accumulator, accumulator, n: n, k: k, n0Inv: n0Inv)
            if exponent[bit / 32] & (UInt32(1) << UInt32(bit % 32)) != 0 {
                accumulator = montgomeryProduct(accumulator, baseMontgomery, n: n, k: k, n0Inv: n0Inv)
            }
        }
        // Leave Montgomery form (multiply by R⁻¹) and reduce.
        return montgomeryProduct(accumulator, [1], n: n, k: k, n0Inv: n0Inv)
    }

    /// Little-endian limbs of `data` (byte 0 → limb 0), the `int.from_bytes(…,
    /// 'little')` of upstream.
    static func limbs(littleEndian data: Data) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity((data.count + 3) / 4)
        var i = 0
        while i < data.count {
            var limb: UInt32 = 0
            for shift in stride(from: 0, through: 24, by: 8) where i < data.count {
                limb |= UInt32(data[i]) << UInt32(shift)
                i += 1
            }
            out.append(limb)
        }
        return out
    }

    /// Big-endian bytes of `value`, zero-padded to `byteCount` (the width of an
    /// RSA modulus). This is the `'%0.*X' % (…, pow(…))` hex of upstream before
    /// `bytes.fromhex`.
    static func bigEndianBytes(_ value: [UInt32], byteCount: Int) -> Data {
        var little = [UInt8](repeating: 0, count: byteCount)
        for (limbIndex, limb) in trim(value).enumerated() {
            var l = limb
            for byte in 0..<4 {
                let position = limbIndex * 4 + byte
                guard position < byteCount else { break }
                little[position] = UInt8(l & 0xFF)
                l >>= 8
            }
        }
        return Data(little.reversed())
    }
}

/// RSA signature validation for CSE manifests — a faithful port of upstream
/// `rsa_sig_val` (MEA.py 10218) and the SSA-PSS chain it calls (`pss_mgf`,
/// `unmask_DB`, `parseSign`, `get_salt`, `pss_final_validate`, `pss_verify`,
/// MEA.py 10145–10215).
///
/// The manifest is signed with textbook RSA over a protected-data window: the
/// first `0x80` bytes of the struct plus everything from the header end to the
/// manifest end. The decrypted signature's low bytes are compared to that
/// window's digest — SHA-1 for `$MAN`/2048-bit, SHA-256 for `$MN2`/2048-bit
/// (PKCS #1 v1.5 DigestInfo), and SHA-384 EMSA-PSS for `$MN2`/3072-bit (and
/// any unrecognised combination).
enum RSA {
    /// `0xBC` — the EMSA-PSS trailer byte (`parseSign`, MEA.py 10162).
    private static let pssTrailer: UInt8 = 0xBC
    /// 8-byte zero salt prefix in the PSS encoded message (`pss_final_validate`,
    /// MEA.py 10190).
    private static let saltPaddingCount = 8

    /// A validation outcome. `valid` is upstream's first return element
    /// (`dec_hash == rsa_hash`); `embeddedHash`/`dataHash` are the digest read
    /// out of the decrypted signature and the digest recomputed over the
    /// protected data — nil when that branch never produced one (e.g. a PSS
    /// signature with bad padding).
    struct Outcome: Equatable {
        var valid: Bool
        var embeddedHash: String?
        var dataHash: String?

        static let emptyRSA = Outcome(valid: true, embeddedHash: nil, dataHash: nil)
    }

    /// Validate one manifest's RSA signature.
    ///
    /// - Parameters:
    ///   - tag: `$MN2` or `$MAN`.
    ///   - publicKey: the raw `RSAPublicKey` modulus bytes (LE), key-length wide.
    ///   - exponent: the public exponent (`RSAExponent`).
    ///   - signature: the raw `RSASignature` bytes (LE), same length as the key.
    ///   - protectedData: `buffer[base:base+0x80] + buffer[base+headerEnd:base+size]`.
    ///
    /// Returns nil only when the signature cannot be checked at all (an
    /// even/zero modulus — not a real RSA modulus — or empty protected data
    /// that still needs the digest window). An empty RSA block (all three inputs
    /// zero) is *valid* per upstream's "Valid/Empty RSA block" (MEA.py 10249).
    static func validate(tag: String, publicKey: Data, exponent: UInt32,
                         signature: Data, protectedData: Data) -> Outcome? {
        let keyLength = publicKey.count
        guard keyLength > 0, signature.count >= keyLength else { return nil }

        // Decrypt: signature^exponent mod modulus, as a big-endian value padded
        // to the modulus width (upstream `'%0.*X' % (key_size*2, pow(…))`).
        let modulusLimbs = BigInt.limbs(littleEndian: publicKey)
        let modulus = BigInt.trim(modulusLimbs)
        let allZero = modulus.count == 1 && modulus[0] == 0
        let exponentZero = exponent == 0
        let signatureZero = signature.allSatisfy { $0 == 0 }
        if allZero && exponentZero && signatureZero {
            return .emptyRSA
        }
        // A degenerate (even or zero) modulus cannot be exponentiated into;
        // upstream would crash here. Report "not checkable" rather than a value.
        guard !allZero, (modulus[0] & 1) == 1 else { return nil }

        let signatureLimbs = BigInt.limbs(littleEndian: signature)
        let decrypted = BigInt.bigEndianBytes(
            BigInt.powerMod(base: signatureLimbs, exponent: [exponent],
                            modulus: modulus),
            byteCount: keyLength)

        switch (tag, keyLength) {
        case ("$MAN", 0x100):
            // SHA-1: the low 160 bits of the decrypted signature.
            return compareEmbedded(suffixLength: 0x14, decrypted: decrypted,
                                   dataHash: Digest.sha1(protectedData))
        case ("$MN2", 0x100):
            // SHA-256 (PKCS #1 v1.5 DigestInfo): the low 256 bits.
            return compareEmbedded(suffixLength: 0x20, decrypted: decrypted,
                                   dataHash: Digest.sha256(protectedData))
        default:
            // 3072-bit and everything unrecognised use SHA-384 EMSA-PSS.
            return pssCheck(decrypted: decrypted, message: protectedData,
                            modulusBytes: keyLength)
        }
    }

    // MARK: - SSA-PSS (upstream 10145–10215)

    /// Compare the low `suffixLength` bytes of the decrypted signature (the
    /// plain PKCS #1 v1.5 digest) against the recomputed digest.
    private static func compareEmbedded(suffixLength: Int, decrypted: Data,
                                        dataHash: Data) -> Outcome {
        guard decrypted.count >= suffixLength else {
            return Outcome(valid: false, embeddedHash: nil, dataHash: nil)
        }
        let embedded = decrypted.suffix(suffixLength)
        return Outcome(valid: embedded == dataHash,
                       embeddedHash: Digest.hex(embedded),
                       dataHash: Digest.hex(dataHash))
    }

    /// EMSA-PSS with the digest embedded in the signature (`parseSign`) checked
    /// against the digest recomputed over `message` + extracted salt.
    private static func pssCheck(decrypted: Data, message: Data,
                                 modulusBytes: Int) -> Outcome? {
        let digestSize = 48  // SHA-384
        let hash: (Data) -> Data = Digest.sha384

        // parseSign: trailer must be 0xBC; the digest sits just before it.
        guard decrypted.count > digestSize + 1, decrypted.last == pssTrailer else {
            return Outcome(valid: false, embeddedHash: nil, dataHash: nil)
        }
        let embedded = decrypted.subdata(
            in: (decrypted.count - digestSize - 1)..<(decrypted.count - 1))
        let maskedDB = decrypted.subdata(in: 0..<(decrypted.count - digestSize - 1))

        // pss_mgf over the embedded digest, then unmask the DB.
        let mask = pssMgf(seed: embedded, maskLength: maskedDB.count,
                          digestSize: digestSize, hash: hash)
        var unmasked = Data(maskedDB)
        for i in 0..<maskedDB.count { unmasked[i] = maskedDB[i] ^ mask[i] }

        // get_salt validates the DB padding and recovers the salt.
        guard let salt = pssSalt(unmaskedDB: unmasked, modulusBytes: modulusBytes) else {
            return Outcome(valid: false, embeddedHash: nil, dataHash: nil)
        }

        // pss_final_validate: SHA-384 over 8 zero bytes + digest(message) + salt.
        var encoded = Data(repeating: 0, count: saltPaddingCount)
        encoded.append(hash(message))
        encoded.append(salt)
        let recomputed = hash(encoded)

        return Outcome(valid: embedded == recomputed,
                       embeddedHash: Digest.hex(embedded),
                       dataHash: Digest.hex(recomputed))
    }

    /// `pss_mgf` (MEA.py 10145): hash(seed ‖ counter) blocks for a mask.
    private static func pssMgf(seed: Data, maskLength: Int, digestSize: Int,
                               hash: (Data) -> Data) -> Data {
        var mask = Data()
        let blocks = (maskLength + digestSize - 1) / digestSize
        for counter in 0..<blocks {
            var big = UInt32(counter).bigEndian
            var counterBytes = Data()
            withUnsafeBytes(of: &big) { counterBytes.append(contentsOf: $0) }
            mask.append(hash(seed + counterBytes))
        }
        return mask
    }

    /// `get_salt` (MEA.py 10173): validate the leading zero bits + `00…01`
    /// padding of the unmasked DB and return everything after the separator.
    private static func pssSalt(unmaskedDB: Data, modulusBytes: Int) -> Data? {
        guard let first = unmaskedDB.first else { return nil }
        let leadingZeroBits = 8 - ((modulusBytes - 1) % 8)
        var firstByte = Int(first)
        for i in 0..<leadingZeroBits { firstByte &= ~(0x80 >> i) }
        guard firstByte == 0 else { return nil }

        let start = unmaskedDB.startIndex
        guard let separator = unmaskedDB.firstIndex(of: 0x01) else { return nil }
        // Bytes (1 ..< separator) must all be 0x00 padding.
        for byte in unmaskedDB[(start + 1)..<separator] where byte != 0x00 { return nil }
        return unmaskedDB[(separator + 1)...]
    }
}

extension Digest {
    /// Uppercase hex of `data` (the digest display form upstream uses).
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}
