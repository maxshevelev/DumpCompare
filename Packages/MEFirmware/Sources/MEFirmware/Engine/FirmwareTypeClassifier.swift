import Foundation

/// Classifies an identified image's firmware type — Stock / Update / Extracted
/// — a faithful port of upstream `fw_type` (MEA.py 12538–12588). The Summary
/// row-4 "Type" and the Full-Tree "Type" field are both the model's `type`, so
/// the classifier's word is the one the UI shows.
///
/// The inputs mirror upstream's own gates: whether a boot BPDT marked the image
/// an IFWI (`ifwi_exist`, → always Extracted), the decoded `$FPT` of a detected
/// region (`rgn_exist`), and the raw region bytes. No oracle exercises the
/// pre-CSE `ME` 2–7 legs — they are fixture-only, and the sub-branches upstream
/// defers to SKU / R0-manifest fixes (MEA.py 12690–12935) return `.unknown`
/// rather than guess a Stock/Extracted the engine has no facts to decide.
enum FirmwareTypeClassifier {
    /// The firmware type of an identified image. `fpt` nil (no `$FPT` region)
    /// falls through to upstream's final "no Region detected → Update".
    static func classify(family: FirmwareFamily, major: Int,
                         isIFWI: Bool, fpt: FPTParser.Result?,
                         region: Data) -> FirmwareType {
        // An IFWI image is always Extracted (upstream 12541–12547).
        if isIFWI { return .extracted }

        guard let fpt else { return .update }  // 12588: no region → Update

        // SPS 1–3 are hand-built → Extracted (12548–12549).
        if family == .sps { return .extracted }

        switch family {
        case .me where (2...7).contains(major):
            return me2to7(partitions: fpt.partitions, region: region, major: major)
        case .me where major >= 8, .csme, .cstxe, .txe, .cssps, .gsc:
            return csmeLike(fpt: fpt, region: region, variant: family, major: major)
        default:
            // Independent (PMC/PCHC/PHY/OROM) and unknown families do not sit on
            // the Stock/Update/Extracted axis (upstream labels them Independent,
            // MEA.py 13586); the engine keeps `.unknown` → Summary row stays
            // "coming soon" rather than claim an axis it does not model.
            return .unknown
        }
    }

    // MARK: - ME 2–7 (upstream 12550–12559 + fovd_clean)

    /// Pre-CSE ME 2–7: FOVD/NVKR cleanliness first, then a `KRND\x00` string
    /// marks an Extracted image. The branches upstream defers to the ME 2/3/4
    /// SKU-and-R0-manifest fixes (MEA.py 12690–12935) return `.unknown` — no
    /// oracle exercises them, and guessing would break the honesty rule.
    private static func me2to7(partitions: [FPTParser.Partition], region: Data,
                               major: Int) -> FirmwareType {
        // Check 1: FOVD (ME 3–7) / NVKR (ME 2) dirtiness → Extracted.
        let isClean = major >= 3 ? fovdClean(partitions, "FOVD")
                                 : fovdCleanME2(partitions, region: region)
        guard isClean else { return .extracted }

        // Check 2: a KRND\x00 string anywhere in the region.
        let krnd = region.range(of: Data("KRND\0".utf8)) != nil
        if krnd {
            if major == 4 { return .unknown }   // ME4-Only Fix 3 is not ported
            return .extracted                   // 12556
        }
        if major == 2 || major == 3 { return .unknown }  // ME2/3 fixes not ported
        return .stock                           // 12558
    }

    // MARK: - ME 8+ and the CSE/TXE/GSC families (upstream 12560–12586)

    private static func csmeLike(fpt: FPTParser.Result, region: Data,
                                 variant: FirmwareFamily, major: Int) -> FirmwareType {
        // Check 1: an Update image's $FPT lists only the FTPR/FTUP/NFTP trio of
        // non-empty partitions.
        let nonEmpty = fpt.partitions.filter { !$0.empty }.map(\.name).sorted()
        if nonEmpty == ["FTPR", "FTUP", "NFTP"] { return .update }

        // Check 2: a clean (CS)ME/(CS)TXE $FPT carries no FIT build (0 / 0xFFFF).
        if fpt.fitBuild == 0 || fpt.fitBuild == 0xFFFF {
            // Check 3: FOVD dirtiness means an Extracted image anyway.
            if !fovdClean(fpt.partitions, "FOVD") { return .extracted }

            // Check 4: a CSTXE FIT placeholder $FPT — its header's first 0x10
            // plus the flags..end window read as one erased run.
            let head = erased(from: region, at: fpt.fptStart, count: 0x10)
            let tail = erased(from: region, at: fpt.fptStart + 0x1C, count: 0x14)
            if head && tail { return .extracted }

            // Check 5: CSME 13+ Update images carry placeholder $FPT ROM-Bypass
            // vectors (0xFF where a stock image pads 0x00).
            if variant == .csme, major >= 13,
               erased(from: region, at: fpt.fptStart, count: 0x10) {
                return .extracted
            }
            return .stock
        }

        // A real FIT in the $FPT header — the image was built with the Flash
        // Image Tool, i.e. Extracted.
        return .extracted
    }

    // MARK: - fovd_clean (MEA.py 10113–10132)

    /// Upstream `fovd_clean('new')` (MEA.py 10113): the `partition` FPT row is
    /// clean (→ true) when empty; a non-empty FOVD is dirty (→ false). A missing
    /// row is clean.
    private static func fovdClean(_ partitions: [FPTParser.Partition],
                                  _ partition: String) -> Bool {
        for part in partitions where part.name == partition {
            return part.empty
        }
        return true
    }

    /// Upstream `fovd_clean('old')` for ME 2: the NVKR row is clean when empty,
    /// or when the run after its 3-byte little-endian length at +0x19 is all
    /// erased. A missing row is clean.
    private static func fovdCleanME2(_ partitions: [FPTParser.Partition],
                                     region: Data) -> Bool {
        for part in partitions where part.name == "NVKR" {
            if part.empty { return true }
            let base = part.offset
            guard base + 0x1C <= region.count else { return false }
            let size = Int(le24(region, base + 0x19))
            return erased(from: region, at: base + 0x1C, count: size)
        }
        return true
    }

    /// True when every byte of `region[at..<at+count]` is 0xFF, with an empty or
    /// out-of-range window read as *not* all-erased — a bounded read, mirroring
    /// upstream's byte slices (which raise nothing on a short file).
    private static func erased(from region: Data, at: Int, count: Int) -> Bool {
        guard at >= 0, count > 0, at + count <= region.count else { return false }
        for i in at..<(at + count) where region[region.startIndex + i] != 0xFF {
            return false
        }
        return true
    }

    private static func le24(_ data: Data, _ off: Int) -> UInt32 {
        let s = data.startIndex + off
        return UInt32(data[s]) | (UInt32(data[s + 1]) << 8) | (UInt32(data[s + 2]) << 16)
    }
}
