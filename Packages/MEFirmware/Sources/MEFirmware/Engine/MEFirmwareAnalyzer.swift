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
        // by the manifest summary alone). Directory *integrity* (R1 Checksum-8 /
        // R2 CRC-32, trailing-empty-entry overrun, content-overflow) surfaces as
        // Issues next to the decoded facts.
        var codePartition: CodePartition? = nil
        var cpdIssues: [Issue] = []
        if let m = manifest,
           let owner = CPDParser.findPrecedingCPD(in: region, before: m.base) {
            let header = owner.header
            let entries = CPDParser.entries(of: header, in: region, cpdBase: header.base)
            let checksumValid = CPDParser.checksumValid(header, in: region)
            if let checksumValid, !checksumValid {
                cpdIssues.append(Issue(id: 4, severity: .warning,
                    message: "Checksum of $CPD partition \"\(header.partitionName)\" is INVALID."))
            }
            let trailing = CPDParser.trailingEmptyEntryCount(of: header, in: region)
            if trailing > 0 {
                let noun = trailing == 1 ? "entry" : "entries"
                cpdIssues.append(Issue(id: 5, severity: .note,
                    message: "$CPD partition \"\(header.partitionName)\" has \(trailing) empty "
                        + "trailing module \(noun) beyond its declared count "
                        + "(\(header.numModules))."))
            }
            let contentEnd = CPDParser.moduleContentEnd(of: header, entries: entries)
            if contentEnd > region.count {
                cpdIssues.append(Issue(id: 6, severity: .warning,
                    message: "Modules of $CPD partition \"\(header.partitionName)\" extend past "
                        + "the end of the region (content end 0x\(String(contentEnd, radix: 16)) "
                        + "> region size 0x\(String(region.count, radix: 16)))."))
            }
            // Header-revision family, chosen from the manifest alone (stage-1,
            // no DB): decides which tag headers decode as their `_R2` structs.
            let family = CPDExtensionParser.family(
                major: m.major, minor: m.minor, hotfix: m.hotfix, build: m.build,
                year: m.year, month: m.month, keyLength: m.rsaPublicKey?.count)

            // CSE extension chain of the chosen manifest's own module (upstream
            // ext_anl .man): the entry whose content base holds the manifest is
            // the partition's manifest module. Its size bounds the walk; the
            // chain starts right after the manifest struct.
            let extensions: [CPDExtension]? = entries.first { entry in
                !entry.isHuffman && header.base + entry.offset == m.base && entry.size > 0
            }.map { module in
                CPDExtensionParser.decode(
                    in: region,
                    moduleContentBase: m.base,
                    moduleSize: Int(module.size),
                    chainStart: m.base + m.headerLengthBytes,
                    family: family,
                    baseOffset: baseOffset)
            }

            // Per-module metadata: a `.met` companion (name suffix `.met`, always
            // uncompressed) has a body that *is* an extension chain starting at
            // its content base — its leading 0x0A block carries the owner
            // module's compression / encryption / sizes / hash. The manifest
            // module's own `.man` chain (surfaced as `CodePartition.extensions`)
            // is attached to its row too, so every carrier shows its blocks.
            var modules: [CPDModule] = []
            for (index, entry) in entries.enumerated() {
                var rowExtensions: [CPDExtension]? = nil
                if !entry.isHuffman, entry.size > 0 {
                    if entry.name.hasSuffix(".met") {
                        rowExtensions = CPDExtensionParser.decodeMetBody(
                            in: region,
                            contentBase: header.base + entry.offset,
                            bodySize: Int(entry.size),
                            family: family,
                            baseOffset: baseOffset)
                    } else if header.base + entry.offset == m.base {
                        rowExtensions = extensions   // the manifest module itself
                    }
                }
                modules.append(CPDModule(
                    id: index, name: entry.name, offset: entry.offset,
                    isHuffman: entry.isHuffman, size: Int(entry.size),
                    extensions: rowExtensions))
            }
            codePartition = CodePartition(
                name: header.partitionName,
                offset: baseOffset + header.base,
                headerVersion: header.headerVersion,
                headerLength: header.headerLength,
                entryCount: header.numModules,
                checksumValid: checksumValid,
                modules: modules,
                extensions: extensions)
        }

        var issues: [Issue] = []
        if fpt == nil {
            issues.append(Issue(id: 1, severity: .note,
                                message: "No $FPT partition table found in the region."))
        }
        issues.append(contentsOf: cpdIssues)

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
        } else {
            if identity.databaseName == nil {
                // note_new_fw (~9958): a recognised engine whose firmware row is absent.
                issues.append(Issue(id: 3, severity: .note,
                                    message: "This firmware is not in the database."))
            }
            if let cp = codePartition, Self.hasHuffmanModuleToValidate(cp) {
                // Phase 8 integrity: every declared-Huffman module backed by a `.met`
                // that advertises Huffman compression (and no encryption) must
                // decompress — against the live Huffman.dat dictionary for this
                // (variant, major, minor) — to exactly its `.met`-declared uncompressed
                // size. Best-effort: a missing/unfetchable dictionary just skips the
                // check rather than failing the analysis; families whose modules are
                // LZMA/uncompressed (CSME 15+, IUP) never trigger the fetch.
                let dictionaries = try? await data.huffmanDictionaries()
                issues.append(contentsOf: Self.huffmanValidationIssues(
                    for: cp, in: region, baseOffset: baseOffset,
                    variant: identity.variant, major: identity.major, minor: identity.minor,
                    dictionaries: dictionaries))
            }
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

    /// True when any module is a declared-Huffman row backed by a `.met` whose
    /// `CSE_Ext_0A` advertises Huffman compression and no encryption — the only
    /// case the Phase 8 check can validate (it needs a declared target size and a
    /// decryptable blob). Gates the (relatively costly) Huffman.dat fetch.
    private static func hasHuffmanModuleToValidate(_ cp: CodePartition) -> Bool {
        cp.modules.contains { module in
            module.isHuffman && module.size > 0 && cp.modules.contains { candidate in
                candidate.name == module.name + ".met"
                    && (candidate.extensions?.compactMap { $0.moduleAttributes }
                        .contains { $0.compression == 1 && $0.encryption == 0 } ?? false)
            }
        }
    }

    /// Phase 8 cross-check (`mod_anl`'s Huffman branch). A code module whose
    /// paired `.met` (name suffix `.met`) decodes a `CSE_Ext_0A` advertising
    /// Huffman compression and no encryption is decompressed and its length
    /// compared to the declared uncompressed size. The `.met`'s 0x0A *compressed*
    /// size (chunk directory included) bounds the slice — that is exactly the
    /// `compressed_size` upstream passes (MEA.py 6906/7186). Never throws; a nil
    /// dictionary set skips everything.
    private static func huffmanValidationIssues(
        for codePartition: CodePartition, in region: Data, baseOffset: Int,
        variant: String, major: Int, minor: Int,
        dictionaries: HuffmanDictionaries?) -> [Issue] {
        guard let dictionaries,
              let dictionary = dictionaries.dictionary(variant: variant,
                                                       major: major, minor: minor),
              major != 0, variant != "" else { return [] }
        let headerBase = codePartition.offset - baseOffset
        var issues: [Issue] = []

        for module in codePartition.modules where module.isHuffman && module.size > 0 {
            guard let attrs = codePartition.modules
                .first(where: { $0.name == module.name + ".met" })?
                .extensions?
                .compactMap({ $0.moduleAttributes })
                .first,
                attrs.compression == 1, attrs.encryption == 0,
                attrs.compressedSize > 0, attrs.uncompressedSize > 0 else { continue }
            let moduleBase = headerBase + module.offset
            guard moduleBase + attrs.compressedSize <= region.count else {
                issues.append(Issue(id: 7, severity: .warning,
                    message: "Huffman module \"\(module.name)\" extends past the end of "
                        + "the region; cannot verify its decompression."))
                continue
            }
            let blob = region.subdata(in: moduleBase..<(moduleBase + attrs.compressedSize))
            let result = HuffmanDecoder.decompress(
                module: blob, compressedSize: attrs.compressedSize,
                decompressedSize: attrs.uncompressedSize, dictionary: dictionary)
            if result.output.count != attrs.uncompressedSize {
                issues.append(Issue(id: 7, severity: .warning,
                    message: "Huffman module \"\(module.name)\" did not decompress to its "
                        + ".met-declared size (got 0x\(String(result.output.count, radix: 16)) "
                        + "bytes, expected 0x\(String(attrs.uncompressedSize, radix: 16)))."))
            } else if !result.clean {
                issues.append(Issue(id: 7, severity: .warning,
                    message: "Huffman module \"\(module.name)\" decompressed to the right "
                        + "size but hit unknown codewords / an early stream end."))
            }
        }
        return issues
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
