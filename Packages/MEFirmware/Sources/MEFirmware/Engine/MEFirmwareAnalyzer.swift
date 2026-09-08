import Foundation

/// The module's async external API (`Skills/sync-mea-engine/reference/async-api.md`):
/// an `actor` serialises parsing and keeps the main thread free, and heavy work
/// never blocks the UI.
///
/// The pipeline inside `analyze` is single-pass with one suspended dependency:
/// structures that need no database (FPT, later $CPD, manifests) decode first;
/// at the identification step the pipeline awaits the data source
/// (`MEA.dat`, live-fetched on first use, cached in memory) and then continues
/// the *same* analysis to completion — the file is never re-parsed. The region
/// is read once.
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
        // ——— Spine stage 1: container decode that needs no database. ———
        // FPT is the first ported link (upstream-map "Flash & IFWI layout").
        let fpt = FPTParser.parseFirst(in: region)
        let regions: [FPTRegion] = (fpt?.partitions ?? []).enumerated().map { index, part in
            FPTRegion(id: index, name: part.name,
                      offset: baseOffset + part.offset, size: part.size, flags: part.flags)
        }

        // ——— Stage 2 (next incremental port): identification. ———
        // `get_variant` reads the $MN2/$MAN manifest RSA public key, hashes it
        // SHA-256 and looks it up in the live `MEA.dat` this module fetched from
        // the MEAnalyzer repo — `try await data.database()` — then continues
        // here to fill family/version/SKU/release. Until that port lands the
        // identity fields below are honest unknowns and `data` is held ready.
        // See reference/async-api.md §"The pipeline inside analyze".

        var issues: [Issue] = []
        if fpt == nil {
            issues.append(Issue(id: 1, severity: .note,
                                message: "No $FPT partition table found in the region."))
        }

        return FirmwareAnalysis(
            family: .unknown,
            variant: "",
            version: Version(major: 0, minor: 0, hotfix: 0, build: 0),
            securityVersion: nil,
            release: .unknown,
            type: .region,
            sku: "",
            platform: "",
            manufactureDate: nil,
            sizeBytes: region.count,
            databaseName: nil,
            rsaSignatureValid: nil,
            checksums: nil,
            regions: regions,
            manifest: nil,
            codePartition: nil,
            issues: issues
        )
    }
}
