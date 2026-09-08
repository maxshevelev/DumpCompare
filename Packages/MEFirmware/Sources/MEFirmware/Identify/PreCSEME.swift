import Foundation

/// Pre-CSE (classic `ME` 2–10) `$SKU` SKU_Attributes decode — the summary
/// `SKU` row (`sku`) and `Chipset Support` row (`platform`). A faithful port of
/// the upstream main-flow branch `if variant == 'ME'` (MEA.py 12644–13023) and
/// the `SKU_Attributes`/`SKU_Attributes_Flags` structs (1044–1101).
///
/// The `$SKU` structure sits a short distance after the operational manifest's
/// struct base and is located by scanning `\$SKU[\x03-\x04]\x00\x00\x00`
/// (a `$SKU` tag whose `Size` dword byte is 3 or 4). Its `FWSKUAttrib` u64
/// (@ +0x08) is interpreted exactly the way upstream's
/// `BigEndianStructure` bitfields are: `get_flags` stores the little-endian-read
/// u64 into the union and reads it back big-endian, so the eight bytes split
/// big-endian — `Value1` = bytes 0–2, the eight 1-bit `Value2…Value9` = byte 3
/// MSB-first (`Value2` is the ME7 `slim` flag), `Patsburg` + `SKUType`(3) +
/// `SKUSize`(4) = byte 4, `Value10` = bytes 5–7. For ME 2–6 the same 8 bytes
/// are not used: upstream reads the top four as a big-endian u32 (`sku_me`,
/// MEA.py 12654) and maps constant values.
enum PreCSEME {
    /// The decoded `$SKU` header + `FWSKUAttrib` split.
    struct Attributes: Equatable {
        var offset: Int       // region-relative $SKU tag offset
        var sizeDwords: Int   // Size (dwords) @ +0x04 — 3 (ME 2–6) or 4 (ME 7–10)
        /// `sku_me`: FWSKUAttrib bytes 0–3 read big-endian (ME 2–6 only).
        var skuMe: UInt32
        // FWSKUAttrib big-endian bitfield split (ME 7–10):
        var value1: Int       // 24 bits — bytes 0–2
        var slim: Bool        // Value2, byte 3 bit 7 (ME 7)
        var patsburg: Bool    // Patsburg flag, byte 4 bit 7 (ME 7)
        var skuType: Int      // 3 bits — byte 4 bits 6–4 (ME 9–10)
        var skuSize: Int      // 4 bits — byte 4 bits 3–0, units of 0.5 MB (ME 7–10)
        var value10: Int      // 24 bits — bytes 5–7
    }

    /// The two summary rows the `$SKU` fills for the `ME` family. Both are
    /// independent: a part may carry a platform (e.g. every ME7 is `CPT`) yet
    /// an unrecognised SKU, or a recognised SKU with no platform label for the
    /// minor (e.g. ME10 minor ≠ 0 → platform nil). nil when not meaningful.
    struct Summary: Equatable {
        var sku: String?
        var platform: String?
    }

    /// Decode the first `$SKU` SKU_Attributes that follows the manifest at
    /// `manifestBase` and map it to the ME summary SKU/platform for the given
    /// major/minor. Returns nil when no plausible `$SKU` follows the manifest.
    static func summary(in region: Data, manifestBase: Int,
                        major: Int, minor: Int, hotfix: Int, build: Int) -> Summary? {
        guard let a = scan(in: region, manifestBase: manifestBase) else { return nil }
        return map(a, major: major, minor: minor, hotfix: hotfix, build: build)
    }

    /// Locate + decode the first `$SKU[\x03-\x04]\x00\x00\x00` after
    /// `manifestBase`, mirroring upstream's scan (MEA.py 12647). Returns nil when
    /// none is found (the manifest is not an ME SKU carrier).
    static func scan(in region: Data, manifestBase: Int) -> Attributes? {
        let tag = Data("$SKU".utf8)
        var lo = min(max(manifestBase, 0), region.count)
        while lo + 12 <= region.count {
            guard let r = region.range(of: tag, in: lo..<region.count) else { return nil }
            let p = r.lowerBound
            guard p + 12 <= region.count else { return nil }
            let sizeByte = region[p + 4]
            guard (sizeByte == 3 || sizeByte == 4),
                  region[p + 5] == 0, region[p + 6] == 0, region[p + 7] == 0,
                  region.count >= p + 16 else {
                // `$SKU` not followed by a SKU_Attributes header — keep scanning.
                lo = p + 1
                continue
            }
            let b = (0..<8).map { region[p + 8 + $0] }
            return Attributes(
                offset: p,
                sizeDwords: Int(sizeByte),
                skuMe: (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16)
                     | (UInt32(b[2]) << 8) | UInt32(b[3]),
                value1: (Int(b[0]) << 16) | (Int(b[1]) << 8) | Int(b[2]),
                slim: b[3] & 0x80 != 0,
                patsburg: b[4] & 0x80 != 0,
                skuType: Int((b[4] >> 4) & 0x7),
                skuSize: Int(b[4] & 0xF),
                value10: (Int(b[5]) << 16) | (Int(b[6]) << 8) | Int(b[7]))
        }
        return nil
    }

    /// Map a decoded `$SKU` to the ME summary rows for one firmware major
    /// (upstream main-flow branches 12737–13023). Each major derives its own
    /// SKU (and platform) from either `sku_me` constants (ME 2–6) or the
    /// `FWSKUAttrib` bitfield (ME 7–10). Unknown SKUs surface as nil, and a
    /// platform is returned only when the branch names one for this minor.
    private static func map(_ a: Attributes, major: Int, minor: Int,
                            hotfix: Int, build: Int) -> Summary {
        switch major {
        case 2:   // ICH8 / ICH8M
            let sku: String?
            if a.skuMe == 0x0000_0000 { sku = "AMT" }        // AMT + ASF + QST
            else if a.skuMe == 0x0200_0000 { sku = "QST" }
            else { sku = nil }
            return Summary(sku: sku, platform: minor >= 5 ? "ICH8M" : "ICH8")
        case 3:   // ICH9 / ICH9DO
            let sku: String?
            if a.skuMe == 0x0E00_0000 || a.skuMe == 0x0000_0000 { sku = "AMT" }
            else if a.skuMe == 0x0600_0000 { sku = "ASF" }
            else if a.skuMe == 0x0200_0000 { sku = "QST" }
            else { sku = nil }
            return Summary(sku: sku, platform: "ICH9")
        case 4:   // ICH9M / ICH9M-E
            let sku: String?
            if a.skuMe == 0xAC20_0000 || a.skuMe == 0xAC00_0000 || a.skuMe == 0x0400_0000 {
                sku = "AMT + TPM"
            } else if a.skuMe == 0x8C20_0000 || a.skuMe == 0x8C00_0000 || a.skuMe == 0x0C00_0000 {
                sku = "AMT"
            } else if a.skuMe == 0xA020_0000 || a.skuMe == 0xA000_0000 {
                sku = "TPM"
            } else { sku = nil }
            return Summary(sku: sku, platform: "ICH9M")
        case 5:   // ICH10D / ICH10DO
            let sku: String?
            if a.skuMe == 0x3E08_0000 { sku = "Digital Office" }
            else if a.skuMe == 0x060D_0000 { sku = "Base Consumer" }
            else if a.skuMe == 0x0608_0000 { sku = "Digital Home or Base Corporate (?)" }
            else { sku = nil }
            return Summary(sku: sku, platform: "ICH10")
        case 6:   // Ibex Peak
            let ignition = a.skuMe == 0x0000_0000
            let sku: String?
            if ignition { sku = hotfix == 50 ? "Ignition CCK" : "Ignition IBX" }
            else if a.skuMe == 0x701C_0000 { sku = "1.5MB" }
            else if a.skuMe == 0x77DC_EE00 || a.skuMe == 0x77FC_EE00 || a.skuMe == 0xF7FE_FE00 {
                sku = "5MB MB"
            } else if a.skuMe == 0x77DC_6E00 || a.skuMe == 0x77FC_6E00 || a.skuMe == 0xF7FE_7E00 {
                sku = "5MB DT"
            } else { sku = nil }
            let platform = ignition && hotfix == 50 ? "CCK" : "IBX"
            return Summary(sku: sku, platform: platform)
        case 7:   // Cougar Point
            let sku: String?
            if a.slim { sku = "Slim" }
            else if a.skuSize == 3 { sku = "1.5MB" }
            else if a.skuSize == 10
                        || (build == 1041 && hotfix == 0 && minor == 0 && a.skuSize == 1) {
                sku = "5MB"
            } else { sku = nil }
            return Summary(sku: sku, platform: a.patsburg ? "CPT/PBG" : "CPT")
        case 8:   // Panther Point
            let sku: String?
            if a.skuSize == 3 { sku = "1.5MB" }
            else if a.skuSize == 10 { sku = "5MB" }
            else { sku = nil }
            return Summary(sku: sku, platform: "CPT/PBG/PPT")
        case 9:   // Lynx Point / Wildcat Point / Lynx Point-LP
            let sku = skuTypeLabel(a.skuType)
            let platform: String?
            if minor == 0 { platform = "LPT" }
            else if minor == 1 { platform = "LPT/WPT" }
            else if minor == 5 || minor == 6 { platform = "LPT-LP" }
            else { platform = nil }
            return Summary(sku: sku, platform: platform)
        case 10:  // Wildcat Point-LP
            let sku = skuTypeLabel(a.skuType)
            return Summary(sku: sku, platform: minor == 0 ? "WPT-LP" : nil)
        default:
            return Summary(sku: nil, platform: nil)
        }
    }

    /// `ext{ '0': '5MB', '1': '1.5MB', '2': 'Slim' }` — the ME 9/10 SKUType
    /// label (upstream 13000–13022). nil for any other value.
    private static func skuTypeLabel(_ skuType: Int) -> String? {
        switch skuType {
        case 0: return "5MB"
        case 1: return "1.5MB"
        case 2: return "Slim"
        default: return nil
        }
    }
}
