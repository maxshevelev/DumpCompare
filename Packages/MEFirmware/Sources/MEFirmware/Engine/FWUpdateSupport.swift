import Foundation

/// Row 15's FWUpdate Support (upstream `fwu_iup_result`, MEA.py 13600–13611):
/// whether Intel's FWUpdate tool can update this image in place.
///
/// The answer is not about the engine itself but about the independent
/// firmware beside it. FWUpdate rewrites the engine's partitions and leaves
/// the independent ones where they are, so it needs each one its platform
/// requires to sit in the region's own `$FPT` — charted or uncharted. An
/// image whose PMC lives inside an IFWI boot partition instead has them in a
/// place FWUpdate does not write, and the answer is No however complete the
/// image looks (which is why the CSME-12 oracle, PMC and all, reads No).
///
/// Which ones are required is a per-version table: CSME 12 asks for the PMC
/// alone, the platforms that stitch a Platform Controller Hub Configuration
/// ask for both, and the ones with a USB Type C Physical ask for all three.
///
/// `.impossible` is upstream's own third answer: a Corporate extracted image
/// that carries no uncharted partition at all (or whose uncharted partition
/// the probe found *past* the padding rather than right at the firmware's end)
/// cannot be made updatable by adding one, and a CSME 16 firmware sitting at
/// offset 0 with its 4 KiB padding present is in the same position — upstream
/// then tells the reader to strip that padding.
enum FWUpdateSupportDecider {
    /// Which of the three independent firmware kinds the region's own `$FPT`
    /// lists (non-empty) — upstream's `pmcp_fwu_found` / `pchc_fwu_found` /
    /// `phy_fwu_found`, each set by the `$FPT` walk and cleared by the boot
    /// `BPDT` one.
    struct IUPPresence: Equatable {
        var pmc = false
        var pchc = false
        var phy = false

        /// The names each kind goes by in a `$FPT` (MEA.py 12427–12449).
        static let pmcNames = ["PMCP", "PCOD"]
        static let pchcNames = ["PCHC"]
        static let phyNames = ["PPHY", "NPHY", "SPHY", "PHYP"]

        /// The presence flags of a partition inventory.
        init(partitions: [FPTParser.Partition]) {
            for part in partitions where !part.empty {
                if Self.pmcNames.contains(part.name) { pmc = true }
                if Self.pchcNames.contains(part.name) { pchc = true }
                if Self.phyNames.contains(part.name) { phy = true }
            }
        }

        init() {}
    }

    /// The answer for a CSME 12-or-newer image, or nil for anything else —
    /// the row the console prints for no other family or major.
    ///
    /// `sku` is the engine's own SKU text ("Corporate H", "Consumer LP"): its
    /// first word carries upstream's `sku_db[:3]` (`COR`) and the letters after
    /// it upstream's `sku_result` (`H` / `LP`), which is the tie-breaker
    /// between the CSME 15.0 rules.
    static func result(
        family: FirmwareFamily, major: Int, minor: Int,
        type: FirmwareType, sku: String,
        iup: IUPPresence, layout: FirmwareEndCalculator.Layout, fptStart: Int
    ) -> FWUpdateSupport? {
        guard family == .csme, major >= 12 else { return nil }

        // A Corporate extracted image is the one FWUpdate is meant for, and
        // the one whose missing uncharted partition it cannot make up for.
        let corporate = sku.hasPrefix("Corporate")
        if type == .extracted, corporate,
           layout.unchartedProbeHit || !layout.hasUnchartedPartition {
            return .impossible
        }
        // CSME 16 at the very start of the image, with its optional padding
        // present: MFIT builds these unaligned, and FWUpdate will not take one
        // that is padded.
        if major >= 16, layout.alignmentPresent > 0, fptStart == 0 {
            return .impossible
        }

        let letters = sku.split(separator: " ").last.map(String.init) ?? ""
        let needsPCHC: Bool
        let needsPHY: Bool
        switch (major, minor) {
        case (12, _):
            needsPCHC = false
            needsPHY = false
        case (13, 0), (13, 50), (14, 0), (14, 5), (15, 40), (16, 0):
            needsPCHC = true
            needsPHY = false
        case (13, 30), (14, 1):
            needsPCHC = true
            needsPHY = true
        case (15, 0):
            // The Tiger Point split: an LP part needs no Physical, an H one
            // does — and upstream's fall-through asks for all three of
            // anything else.
            needsPCHC = true
            needsPHY = letters != "LP"
        default:
            needsPCHC = true
            needsPHY = true
        }

        let complete = iup.pmc
            && (!needsPCHC || iup.pchc)
            && (!needsPHY || iup.phy)
        return complete ? .yes : .no
    }
}
