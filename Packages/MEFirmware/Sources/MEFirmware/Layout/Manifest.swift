import Foundation

/// `$MN2` / `$MAN` manifest decode — the structure `get_variant` reads to
/// identify an engine, and the source of the version / SVN / date facts.
///
/// Faithful to upstream `MEA.py`:
/// - anchor `man_pat` (line 11006): `\x86\x80` (VEN_ID 0x8086, LE) + 9 bytes +
///   `\x00` + `$MN2` or `$MAN`. The regex match begins at the VEN_ID field,
///   i.e. struct base + 0x10, so `struct base = anchor − 0x10`.
/// - struct dispatch `get_manifest` (line 9671): `HeaderVersion` (u32 @ +0x08)
///   and the u32 @ +0x20 (`NumModules` for R0, `BuildTag` for R1/R2) select
///   `MN2_Manifest_R0` / `_R1` / `_R2` (lines 795 / 835 / 932).
/// - identification offsets (main flow, ~12182–12203): version/SVN/date fields
///   are identical across R0/R1/R2; the RSA public key starts at +0x80 with
///   length `PublicKeySize * 4` (stored in dwords @ +0x78), the exponent
///   follows (`ExponentSize * 4`), and the RSA signature starts right after
///   key + exponent with the same length as the key.
///
/// The manifest is decoded from the region handed to `analyze`, so the file is
/// read once and never re-scanned for a DB that has not arrived yet.
struct ManifestParser {
    enum Format: Equatable {
        case r0   // MN2_Manifest_R0 — pre-CSE $MAN/$MN2 (no MEU fields)
        case r1   // MN2_Manifest_R1 — CSE, 2048-bit RSA
        case r2   // MN2_Manifest_R2 — CSE, 3072-bit RSA
    }

    struct Manifest {
        var base: Int             // struct base, region-relative
        var tag: String           // "$MN2" or "$MAN"
        var format: Format

        var day: Int
        var month: Int
        var year: Int

        var major: Int
        var minor: Int
        var hotfix: Int
        var build: Int
        var svn: Int

        /// MEU version block — present only in R1/R2 (R0 reuses 0x30 as SVN_8/VCN).
        var meMajor: Int?
        var meMinor: Int?

        var pvBit: Bool           // Flags bit0
        var debugSigned: Bool     // Flags bit31

        /// Raw RSA public-key bytes (PublicKeySize * 4), when fully in bounds.
        var rsaPublicKey: Data?
        /// Raw RSA signature bytes (same length as the key), when in bounds.
        var rsaSignature: Data?
    }

    /// First `$MN2`/`$MAN` with the VEN 0x8086 preamble, mirroring `man_pat`.
    /// Returns the region-relative offset of the `\x86\x80` VEN bytes
    /// (= struct base + 0x10), or nil when no plausible manifest is present.
    static func findAnchor(in data: Data) -> Int? { anchors(in: data).first }

    /// Every `$MN2`/`$MAN` VEN-anchor offset in file order. A flash image can
    /// carry many manifests — one per engine/IUP partition plus recovery copies
    /// — so identification needs all of them to pick the operational copy.
    static func anchors(in data: Data) -> [Int] {
        guard data.count >= 16 else { return [] }
        let tagMN2 = Data("$MN2".utf8)
        let tagMAN = Data("$MAN".utf8)
        var out: [Int] = []
        for off in 0...(data.count - 16) {
            guard data[data.startIndex + off] == 0x86,
                  data[data.startIndex + off + 1] == 0x80,
                  data[data.startIndex + off + 11] == 0x00 else { continue }
            let tag = data.subdata(in: (data.startIndex + off + 12)..<(data.startIndex + off + 16))
            if tag == tagMN2 || tag == tagMAN { out.append(off) }
        }
        return out
    }

    /// Decode the manifest whose VEN anchor sits at `anchor` (region-relative).
    static func decode(_ data: Data, anchor: Int) -> Manifest? {
        let base = anchor - 0x10
        guard base >= 0 else { return nil }
        let p = data.startIndex + base
        // Fields up to the exponent-size dword at +0x7C (need +0x80 for the sizes).
        guard data.count >= p + 0x80 else { return nil }

        let tagBytes = data.subdata(in: p + 0x1C..<(p + 0x20))
        guard tagBytes == Data("$MN2".utf8) || tagBytes == Data("$MAN".utf8) else {
            return nil
        }
        let tag = String(data: tagBytes, encoding: .ascii) ?? ""

        let format: Format = {
            let manVer = u32le(data, p + 0x08)
            let numInfo = u32le(data, p + 0x20)
            if manVer == 0x10000, numInfo > 0, numInfo < 0x50 { return .r0 }
            if manVer == 0x10000 { return .r1 }
            return .r2                       // 0x21000, or unknown -> R2 (upstream default)
        }()

        let flags = u32le(data, p + 0x0C)

        // Day/Month/Year are packed-BCD: Intel stores each calendar digit as a
        // hex nibble, so upstream displays them with %X (hdr_print_cse line 901)
        // and never converts. Decode nibbles as decimal digits; fall back to the
        // raw integer when the byte is not valid BCD (defensive for odd dumps).
        let bcdDay = Self.bcdByte(Int(data[p + 0x14]))
        let bcdMonth = Self.bcdByte(Int(data[p + 0x15]))
        let bcdYear = Self.bcdYear(Int(u16le(data, p + 0x16)))

        var manifest = Manifest(
            base: base,
            tag: tag,
            format: format,
            day: bcdDay ?? Int(data[p + 0x14]),
            month: bcdMonth ?? Int(data[p + 0x15]),
            year: bcdYear ?? Int(u16le(data, p + 0x16)),
            major: Int(u16le(data, p + 0x24)),
            minor: Int(u16le(data, p + 0x26)),
            hotfix: Int(u16le(data, p + 0x28)),
            build: Int(u16le(data, p + 0x2A)),
            svn: Int(u32le(data, p + 0x2C)),
            meMajor: nil,
            meMinor: nil,
            pvBit: flags & 0x1 != 0,
            debugSigned: flags & 0x8000_0000 != 0,
            rsaPublicKey: nil,
            rsaSignature: nil
        )

        if format != .r0 {
            // R1/R2 carry the MEU block at +0x30; R0 reuses those bytes as
            // SVN_8/VCN, so `is_meu` (hasattr MEU_Minor) is false there.
            manifest.meMajor = Int(u16le(data, p + 0x30))
            manifest.meMinor = Int(u16le(data, p + 0x32))
        }

        // RSA key / signature slices (main flow 12198–12203).
        let keyLen = Int(u32le(data, p + 0x78)) * 4
        let expLen = Int(u32le(data, p + 0x7C)) * 4
        if keyLen > 0 {
            let keyStart = p + 0x80
            let sigStart = keyStart + keyLen + expLen
            if data.count >= keyStart + keyLen {
                manifest.rsaPublicKey = data.subdata(in: keyStart..<(keyStart + keyLen))
            }
            if data.count >= sigStart + keyLen {
                manifest.rsaSignature = data.subdata(in: sigStart..<(sigStart + keyLen))
            }
        }
        return manifest
    }

    /// Find the first plausible `$MN2`/`$MAN` and decode it, or nil. Retained as
    /// the degenerate single-manifest case of `parseCandidates` (used by tests).
    static func parseFirst(in data: Data) -> Manifest? {
        parseCandidates(in: data).first
    }

    /// Decode every plausible `$MN2`/`$MAN` in the region, in file order. The
    /// analyzer passes the whole list to `ManifestSelection` so the operational
    /// copy is chosen rather than the first in byte order (which on a full flash
    /// is usually a recovery-partition copy).
    static func parseCandidates(in data: Data) -> [Manifest] {
        anchors(in: data).compactMap { decode(data, anchor: $0) }
    }

    private static func u16le(_ data: Data, _ p: Int) -> UInt16 {
        UInt16(data[p]) | (UInt16(data[p + 1]) << 8)
    }

    private static func u32le(_ data: Data, _ p: Int) -> UInt32 {
        UInt32(data[p])
            | (UInt32(data[p + 1]) << 8)
            | (UInt32(data[p + 2]) << 16)
            | (UInt32(data[p + 3]) << 24)
    }

    /// Decode one packed-BCD byte (`0x24` → 24). nil when a nibble exceeds 9.
    private static func bcdByte(_ value: Int) -> Int? {
        let hi = (value >> 4) & 0xF
        let lo = value & 0xF
        guard hi <= 9, lo <= 9 else { return nil }
        return hi * 10 + lo
    }

    /// Decode a 2-byte little-endian packed-BCD year (`0x2018` → 2018). nil when
    /// any of the four nibbles exceeds 9.
    private static func bcdYear(_ value: Int) -> Int? {
        let nibbles = [(value >> 12) & 0xF, (value >> 8) & 0xF,
                       (value >> 4) & 0xF, value & 0xF]
        guard nibbles.allSatisfy({ $0 <= 9 }) else { return nil }
        return nibbles[0] * 1000 + nibbles[1] * 100 + nibbles[2] * 10 + nibbles[3]
    }
}
