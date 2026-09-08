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
        // A flash image carries many $MN2/$MAN copies (one per engine/IUP
        // partition, plus recovery copies); identify the *operational* one — on
        // CSME 12/15 the FTPR copy, not the RBEP recovery copy that comes first
        // in file order (the phase-3 fix for the false "not in the database").
        let candidates = ManifestParser.parseCandidates(in: region)
        let manifest = ManifestSelection.selectOperational(candidates: candidates,
                                                           fpt: fpt, in: region)
        let manifestSummary = manifest.map { m -> ManifestSummary in
            let format: ManifestFormat
            switch m.format {
            case .r0: format = .r0
            case .r1: format = .r1
            case .r2: format = .r2
            }
            return ManifestSummary(
                offset: baseOffset + m.base,
                tag: m.tag,
                format: format,
                major: m.major, minor: m.minor, hotfix: m.hotfix, build: m.build,
                svn: m.svn, day: m.day, month: m.month, year: m.year,
                keyHash: m.rsaPublicKey.map { Digest.sha256Hex($0) },
                signatureHash: m.rsaSignature.map { Digest.sha256Hex($0) }
            )
        }

        // The operational partition's module directory: the $CPD that owns the
        // chosen manifest (the back-scan ManifestSelection's fallback uses).
        // An FPT-selected manifest with no owning $CPD yields nil (still reported
        // by the manifest summary alone).
        let codePartition = manifest.flatMap { m -> CodePartition? in
            guard let owner = CPDParser.findPrecedingCPD(in: region, before: m.base) else {
                return nil
            }
            let header = owner.header
            let modules = CPDParser.entries(of: header, in: region, cpdBase: header.base)
                .enumerated().map { index, entry in
                    CPDModule(id: index, name: entry.name, offset: entry.offset,
                              isHuffman: entry.isHuffman, size: Int(entry.size))
                }
            return CodePartition(
                name: header.partitionName,
                offset: baseOffset + header.base,
                headerVersion: header.headerVersion,
                headerLength: header.headerLength,
                entryCount: header.numModules,
                checksumValid: CPDParser.checksumValid(header, in: region),
                modules: modules)
        }

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
                checksums: nil, regions: regions, manifest: manifestSummary,
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
            manufactureDate: Self.manufactureDate(day: manifest.day,
                                                  month: manifest.month,
                                                  year: manifest.year),
            sizeBytes: region.count,
            databaseName: identity.databaseName,
            rsaSignatureValid: nil,
            checksums: nil,
            regions: regions,
            manifest: manifestSummary,
            codePartition: codePartition,
            issues: issues)
    }

    /// Compose the manifest's Day/Month/Year into the top-level manufacture date
    /// (Gregorian, UTC). Returns nil when the fields do not form a valid date.
    private static func manufactureDate(day: Int, month: Int, year: Int) -> Date? {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        return components.date
    }
}
