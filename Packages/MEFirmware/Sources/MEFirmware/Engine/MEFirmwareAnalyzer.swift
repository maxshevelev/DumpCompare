import Foundation

/// The module's async external API (`Skills/sync-mea-engine/reference/async-api.md`):
/// an `actor` serialises parsing and keeps the main thread free, and heavy work
/// never blocks the UI.
///
/// The pipeline inside `analyze` is single-pass with one suspended dependency:
/// structures that need no database (FPT, manifest) decode first; at the
/// identification step the pipeline awaits the data source (`MEA.dat`,
/// live-fetched on first use, cached in memory) and then continues the *same*
/// analysis to completion — the file is never re-parsed. The region is read
/// once.
public actor MEFirmwareAnalyzer {
    private let data: any MEADataSource

    public init(data: any MEADataSource = MEAGitHubDataRepository()) {
        self.data = data
    }

    /// Analyse one engine region (or a larger image handed as `region`, e.g.
    /// the ME partition extracted from a dump). `baseOffset` is the region's
    /// position inside the caller's larger file; reported partition offsets are
    /// shifted by it.
    public func analyze(region: Data, baseOffset: Int = 0) async throws -> FirmwareAnalysis {
        // ——— Stage 1: container decode that needs no database. ———
        // FPT and the $MN2/$MAN manifest are the ported links of the spine
        // (upstream-map "Flash & IFWI layout", "CSE manifest & partitions").
        let fpt = FPTParser.parseFirst(in: region)
        let regions: [FPTRegion] = (fpt?.partitions ?? []).enumerated().map { index, part in
            FPTRegion(id: index, name: part.name,
                      offset: baseOffset + part.offset, size: part.size, flags: part.flags)
        }
        let manifest = ManifestParser.parseFirst(in: region)

        var issues: [Issue] = []
        if fpt == nil {
            issues.append(Issue(id: 1, severity: .note,
                                message: "No $FPT partition table found in the region."))
        }

        // No manifest: nothing to identify, and no database is needed — return
        // the structural facts immediately (keeps a pure-FPT parse offline).
        guard let manifest else {
            return FirmwareAnalysis(
                family: .unknown, variant: "",
                version: Version(major: 0, minor: 0, hotfix: 0, build: 0),
                securityVersion: nil, release: .unknown, type: .region,
                sku: "", platform: "", manufactureDate: nil,
                sizeBytes: region.count, databaseName: nil, rsaSignatureValid: nil,
                checksums: nil, regions: regions, manifest: nil,
                codePartition: nil, issues: issues)
        }

        // ——— Stage 2: identification — awaits the live MEA.dat once, then
        // continues this same analysis (finish-after-data, no re-parse). ———
        let database = try await data.database()
        let hasRomBypass = regions.contains {
            $0.name == "ROMB" && $0.size != 0 && $0.size != 0xFFFF_FFFF
                && $0.offset != 0xFFFF_FFFF
        }
        let identity = Identifier.identify(manifest: manifest,
                                           database: database,
                                           hasRomBypass: hasRomBypass)

        if !identity.identified {
            // var_rsa_db == False path of get_variant: key matched nothing usable.
            issues.append(Issue(id: 2, severity: .note,
                                message: "RSA public key not found in the firmware database; "
                                    + "variant could not be determined."))
        } else if identity.databaseName == nil {
            // note_new_fw (~9958): a recognised engine whose firmware row is absent.
            issues.append(Issue(id: 3, severity: .note,
                                message: "This firmware is not in the database."))
        }

        return FirmwareAnalysis(
            family: identity.family,
            variant: identity.variant,
            version: Version(major: identity.major, minor: identity.minor,
                             hotfix: identity.hotfix, build: identity.build,
                             meMajor: identity.meMajor, meMinor: identity.meMinor),
            securityVersion: identity.securityVersion,
            release: identity.release,
            type: .region,
            sku: "",
            platform: "",
            manufactureDate: nil,
            sizeBytes: region.count,
            databaseName: identity.databaseName,
            rsaSignatureValid: nil,
            checksums: nil,
            regions: regions,
            manifest: nil,
            codePartition: nil,
            issues: issues)
    }
}
