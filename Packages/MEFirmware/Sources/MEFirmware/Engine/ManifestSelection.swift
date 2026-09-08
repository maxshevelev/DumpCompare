import Foundation

/// Chooses which of a region's `$MN2`/`$MAN` candidates is the *operational*
/// manifest — the one the analyzer identifies against the database.
///
/// A flash image carries many manifests: each engine/IUP partition (FTPR, RBEP,
/// PMCP, OEMP, …) has its own `$CPD` + `$MN2`, and recovery copies add more. The
/// DB identity is the *operational* copy — on CSME 12/15 that is the FTPR (boot)
/// partition, not the RBEP (recovery) copy that happens to sit first in file
/// order (and that is why `parseFirst` reported Issue 3 "not in the database"
/// on real dumps). This mirrors upstream's two selection mechanisms in priority
/// order, plus a final fallback:
///
/// 1. **`$FPT` engine-partition jump** (upstream §11802–11825): the first `$FPT`
///    partition whose name is in `{FTPR, RCVY, OPR1, OPR, COD1}` — plus `CODE`
///    only when no RCVY/COD1 partition exists — that *contains* a candidate;
///    return the earliest candidate in its range.
/// 2. **Owning-`$CPD` partition name** (stage-1 fallback): prefer the earliest
///    candidate whose nearest preceding well-formed `$CPD` names `FTPR`, else
///    the first that names `RBEP`. A full flash usually has no `$FPT` naming the
///    CSE boot partitions (its single `$FPT` lists internal MFS/EFS volumes), so
///    this step is what actually picks the operational FTPR copy there — which is
///    why FTPR is ranked above RBEP here. An RBEP-only region (CSME 18, where the
///    boot partition is renamed RBEP) still resolves through the RBEP arm.
/// 3. **First candidate** (`parseFirst` behaviour) — single-manifest and
///    no-context regions keep working.
///
/// Pure policy: no database and no UI text; tests build synthetic regions and
/// assert the chosen manifest's partition.
enum ManifestSelection {
    /// Engine-boot partition names the `$FPT` jump targets (upstream set).
    private static let fptEngineNames = ["FTPR", "RCVY", "OPR1", "OPR", "COD1"]

    /// Owning-`$CPD` names accepted by the stage-1 fallback. FTPR first: a region
    /// holding both carries an operational FTPR copy and a recovery RBEP copy,
    /// and the DB identity is the FTPR one.
    private static let cpdEngineNames = ["FTPR", "RBEP"]

    /// Pick the operational manifest, or nil when there are no candidates.
    /// `candidates` must be sorted by region-relative `base` (as returned by
    /// `ManifestParser.parseCandidates`); `data` is the region itself, needed to
    /// back-scan owning `$CPD` headers.
    static func selectOperational(candidates: [ManifestParser.Manifest],
                                  fpt: FPTParser.Result?,
                                  in data: Data) -> ManifestParser.Manifest? {
        guard let first = candidates.first else { return nil }

        // Priority 1 — $FPT engine partition (upstream 11802–11825): first
        // partition in entry order whose name is in the engine set (CODE gated on
        // the absence of RCVY/COD1) that contains a candidate.
        if let fpt {
            let names = fpt.partitions.map(\.name)
            let hasRecoveryNames = names.contains("RCVY") || names.contains("COD1")
            for part in fpt.partitions {
                let wanted = fptEngineNames.contains(part.name)
                    || (part.name == "CODE" && !hasRecoveryNames)
                guard wanted else { continue }
                // Partition offset and candidate base are both region-relative.
                let end = part.offset + part.size
                if let hit = candidates.first(where: {
                    $0.base >= part.offset && $0.base < end
                }) {
                    return hit
                }
            }
        }

        // Priority 2 — owning-$CPD partition name. Whole-flash regions land here:
        // their single $FPT lists internal volumes (PSVN/UEP/MFS/…) rather than
        // the CSE boot partitions, so priority 1 finds nothing. Rank FTPR ahead
        // of RBEP so a recovery RBEP copy earlier in file order does not win.
        for wanted in cpdEngineNames {
            for candidate in candidates {
                guard let owner = CPDParser.findPrecedingCPD(in: data, before: candidate.base),
                      owner.header.partitionName == wanted else { continue }
                return candidate
            }
        }

        // Priority 3 — first candidate (legacy parseFirst behaviour).
        return first
    }
}
