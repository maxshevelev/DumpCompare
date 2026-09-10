import Foundation

/// Identification: turns a decoded `$MN2`/`$MAN` manifest and the live `MEA.dat`
/// into the identity facts of a `FirmwareAnalysis` (family/variant/release/
/// version/SVN/database row). Faithful to upstream `MEA.py` `get_variant`
/// (10322) and the release derivation in the main flow (~12638).
///
/// Ported now (phase 2):
/// - variant from the unique DB RSA **public-key** hash (`RSAPKEY_*` lines);
/// - the shared ME/TXE pre-key override (a `TBD`-classified key re-split by
///   firmware major);
/// - release: ROM-Bypass partition → Debug/Production flag → `rsa_pre_keys`
///   correction;
/// - version / SVN / canonical DB row by the RSA **signature** hash.
///
/// Deferred to the `$CPD` port (they need CPD module names / SKU capabilities):
/// the module-name fallback heuristics of `get_variant`, and SKU
/// platform/stepping. A manifest whose key resolves to nothing therefore comes
/// back `.unknown` — the honest answer, surfaced as a note by the pipeline.
struct Identifier {
    /// A resolved identity. `identified` is false when no real engine family
    /// could be determined from the RSA key.
    struct Identity {
        var family: FirmwareFamily
        var variant: String
        var release: ReleaseType
        var major: Int
        var minor: Int
        var hotfix: Int
        var build: Int
        var meMajor: Int?
        var meMinor: Int?
        var meHotfix: Int?
        var meBuild: Int?
        var securityVersion: String?
        var databaseName: String?
        /// The PCH/SoC stepping the database records for this firmware
        /// (`get_cse_db` cell 3 / cell 1) — the main table's Chipset Stepping
        /// where no MFS chipset-init table names one.
        var chipsetStepping: String?
        /// The database's Power Down Mitigation token (`sku_pdm`), CSME only.
        var powerDownMitigation: String?
        var identified: Bool
    }

    /// The one RSA public-key hash shared across ME 6–10 / CSME 11 / TXE 0–2
    /// (`RSAPKEY_TBD_…` in MEA.dat); `get_variant` re-classifies it by major.
    /// Internal (not private) so tests can drive `preKeyOverride` against it.
    static let sharedMEKeyHash = "86C0E5EF0CFEFF6D810D68D83D8C6ECB68306A644C03C0446B646A3971D37894"

    static func identify(manifest: ManifestParser.Manifest,
                         database: MEADatabase,
                         hasRomBypass: Bool) -> Identity {
        let keyHash = manifest.rsaPublicKey.map { Digest.sha256Hex($0) }
        let sigHash = manifest.rsaSignature.map { Digest.sha256Hex($0) }

        // get_variant step 1: variant by unique DB RSA public key.
        var token: String? = keyHash.flatMap { database.variant(matchingKeyHash: $0) }

        // get_variant step 2: the shared ME/TXE pre-key, split by firmware major.
        if let override = Self.preKeyOverride(keyHash: keyHash, major: manifest.major) {
            token = override
        }

        let family = Self.family(for: token ?? "Unknown")
        let identified = family != .unknown
            && token.map { !["Unknown", "TBD"].contains($0) } ?? false

        // Release (main flow ~12638): ROM-Bypass beats the Debug/Production flag,
        // then release_fix reclassifies wrong-PRD keys from rsa_pre_keys.
        var release: ReleaseType
        if hasRomBypass {
            release = .romBypass
        } else if manifest.debugSigned {
            release = .preProduction
        } else {
            release = .production
            if let keyHash, database.isPreProductionKey(keyHash) {
                release = .preProduction
            }
        }

        // The manual CSE cells of the firmware's own database row: the
        // stepping and the PDM token upstream reads there before it looks at
        // anything in the image (`get_cse_db`).
        let cells = sigHash.flatMap {
            database.cseCells(matchingSignatureHash: $0, family: family)
        }

        return Identity(
            family: family,
            variant: identified ? (token ?? "") : "",
            release: release,
            major: manifest.major,
            minor: manifest.minor,
            hotfix: manifest.hotfix,
            build: manifest.build,
            meMajor: manifest.meMajor,
            meMinor: manifest.meMinor,
            meHotfix: manifest.meHotfix,
            meBuild: manifest.meBuild,
            securityVersion: (manifest.svn != 0 && manifest.svn != 0xFFFF_FFFF)
                ? "\(manifest.svn)" : nil,
            databaseName: sigHash.flatMap { database.firmwareRow(matchingSignatureHash: $0) },
            chipsetStepping: cells?.stepping,
            powerDownMitigation: cells?.pdm,
            identified: identified
        )
    }

    /// The shared pre-key override of `get_variant` (~10338): the one RSA key
    /// (`RSAPKEY_TBD_…`) that ME 6–10 / CSME 11 and TXE 0–2 share is re-split by
    /// firmware major — 6–10 → ME, 0–2 → TXE. Exposed separately so the
    /// classification is testable without fabricating a key whose SHA-256 equals
    /// this constant. Returns nil for any other key.
    static func preKeyOverride(keyHash: String?, major: Int) -> String? {
        guard keyHash == sharedMEKeyHash else { return nil }
        if (6...10).contains(major) { return "ME" }
        if major <= 2 { return "TXE" }         // ME2-5 / TXE 0-2 use no MEU fields
        return nil
    }

    /// Raw `get_variant` token → `FirmwareFamily`. Prefix rules cover the many
    /// per-platform PMC/PCHC/PHY/OROM tokens (`PMCICP`, `PHYPTGP`, `OROMDG2`, …).
    static func family(for variantToken: String) -> FirmwareFamily {
        switch variantToken {
        case "ME": return .me
        case "CSME": return .csme
        case "TXE": return .txe
        case "CSTXE": return .cstxe
        case "SPS": return .sps
        case "CSSPS": return .cssps
        case "GSC": return .gsc
        default:
            if variantToken.hasPrefix("PMC") { return .pmc }
            if variantToken.hasPrefix("PCHC") { return .pchc }
            if variantToken.hasPrefix("PHY") { return .phy }
            if variantToken.hasPrefix("OROM") { return .orom }
            return .unknown
        }
    }
}
