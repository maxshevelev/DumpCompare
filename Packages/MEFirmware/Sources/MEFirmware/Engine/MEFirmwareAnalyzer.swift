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

        // The CSE Layout Table that precedes the operational $FPT on IFWI
        // whole-flash images (upstream cse_lt region analysis): its Data/Boot/
        // Temp/ELog partition inventory, plus 1.7 redundancy + CRC-32 validity.
        // A pre-IFWI engine (CSME 11, e.g. old.bin) has none → nil. A wrong 1.7
        // CRC is the same warning upstream raises (MEA.py 11553).
        let cseLayoutTable: CSELayoutTable? = fpt?.cseLayout.map { layout in
            CSELayoutTable(
                offset: baseOffset + layout.base,
                version: layout.version,
                redundancy: layout.redundancy,
                checksumValid: layout.checksumValid,
                partitions: layout.slots.enumerated().map { index, slot in
                    CSELayoutPartition(id: index, name: slot.name,
                                       offset: baseOffset + slot.offset,
                                       size: slot.size, empty: slot.empty)
                })
        }
        var cseLayoutIssues: [Issue] = []
        if let layout = fpt?.cseLayout, layout.version == 0x17, layout.checksumValid == false {
            cseLayoutIssues.append(Issue(id: 10, severity: .warning,
                message: "Checksum of the IFWI 1.7 CSE Layout Table at "
                    + "0x\(String(baseOffset + layout.base, radix: 16)) is INVALID."))
        }

        // Phase 9: the CSE file system. The oldest layout — MFS — appears as a
        // raw flash region on both real dumps (CSME 12.0.3 and CSME 15.0.30), in
        // an FPT partition named "MFS". Decode its volume (page inventory →
        // system chunk assembly → volume header + FAT) entirely from bytes,
        // verified byte-for-byte on both. The newer EFST/EFS/FTBL layout lives
        // inside the Huffman vfs/fpf module bodies (needs decompression targets)
        // and is a later increment.
        var mfsVolume: MFSVolume? = nil
        var mfsIssues: [Issue] = []
        if let mfsRegion = regions.first(where: { $0.name == "MFS" }) {
            let volumeOffset = mfsRegion.offset - baseOffset
            if let info = MFSParser.parse(in: region, offset: volumeOffset,
                                          size: mfsRegion.size) {
                mfsVolume = MFSVolume(
                    offset: mfsRegion.offset, pageSize: info.pageSize,
                    pageCount: info.systemPageCount + info.dataPageCount,
                    systemPageCount: info.systemPageCount,
                    dataPageCount: info.dataPageCount,
                    signatureValid: info.volumeSignatureValid,
                    volumeSize: info.volumeSize,
                    computedVolumeSize: info.computedVolumeSize,
                    fileRecordCount: info.fileRecordCount,
                    usedFileCount: info.usedFileCount,
                    ftblDictionary: info.ftblDictionary,
                    ftblPlatform: info.ftblPlatform,
                    ftblReserved: info.ftblReserved,
                    usesFTBL: info.usesFTBL)
                if !info.volumeSignatureValid {
                    mfsIssues.append(Issue(id: 8, severity: .warning,
                        message: "MFS volume at 0x\(String(mfsRegion.offset, radix: 16)) "
                            + "is present but its assembled System volume header is "
                            + "missing or its signature is invalid."))
                }
            } else {
                mfsIssues.append(Issue(id: 8, severity: .warning,
                    message: "Skipped MFS partition at 0x\(String(mfsRegion.offset, radix: 16)): "
                        + "unrecognizable format (no MFS pages found)."))
            }
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

        // Phase 11: checksums of the region (whole analyzed buffer) plus the
        // chosen manifest's RSA signature validity. Both model fields are
        // pre-declared nil, so filling them is not a schema change. The signature
        // is nil when not checkable — no RSA block decoded, a window that does not
        // fit the region, or a degenerate modulus (synthetic fixtures) — and that
        // stays nil rather than raising an issue (upstream's "Empty RSA block"
        // is reported *valid*, its pow crash is a different, non-real edge).
        let checksums: Checksums? = region.isEmpty ? nil : Checksums(
            sha256: Digest.sha256Hex(region),
            sha384: Digest.sha384Hex(region),
            crc32: CRC32.crc32(region))
        let rsaSignatureValid = manifest.flatMap { Self.rsaSignatureValid(for: $0, in: region) }

        var issues: [Issue] = []
        if fpt == nil {
            issues.append(Issue(id: 1, severity: .note,
                                message: "No $FPT partition table found in the region."))
        }
        issues.append(contentsOf: cpdIssues)
        issues.append(contentsOf: mfsIssues)
        issues.append(contentsOf: cseLayoutIssues)
        if rsaSignatureValid == false {
            let m = manifest
            issues.append(Issue(id: 9, severity: .error,
                message: "RSA Signature of \(m?.tag ?? "manifest") at "
                    + "0x\(String(baseOffset + (m?.base ?? 0), radix: 16)) is INVALID."))
        }

        // No manifest: nothing to identify, and no database is needed — return
        // the structural facts immediately (keeps a pure-FPT parse offline).
        guard let manifest else {
            return FirmwareAnalysis(
                family: .unknown, variant: "",
                version: Version(major: 0, minor: 0, hotfix: 0, build: 0),
                securityVersion: nil, release: .unknown, type: .region,
                sku: "", platform: "", manufactureDate: nil,
                sizeBytes: region.count, databaseName: nil,
                rsaSignatureValid: nil, checksums: checksums,
                regions: regions, manifest: manifestSummary,
                codePartition: nil, mfsVolume: mfsVolume,
                cseLayoutTable: cseLayoutTable, issues: issues)
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

        // Phase 10: CSME 12+ SKU ("Consumer H") from the operational partition's
        // CSE_Ext_0C/0x0F_R2 facts + the matched MEA.dat row's platform cell.
        // The top-level `platform` (chipset support, e.g. "CNP"/"TGP") is gated on
        // the MFS PCH-init decode (`pch_init_final`) upstream — a later increment
        // — so it stays empty for the MFS-carrying dumps.
        let skuText = Self.skuText(identity: identity, codePartition: codePartition,
                                   year: manifest.year, month: manifest.month)

        return FirmwareAnalysis(
            family: identity.family,
            variant: identity.variant,
            version: Version(major: identity.major, minor: identity.minor,
                             hotfix: identity.hotfix, build: identity.build,
                             meMajor: identity.meMajor, meMinor: identity.meMinor),
            securityVersion: identity.securityVersion,
            release: identity.release,
            type: .region,
            sku: skuText,
            platform: "",
            manufactureDate: Self.manufactureDate(day: manifest.day,
                                                  month: manifest.month,
                                                  year: manifest.year),
            sizeBytes: region.count,
            databaseName: identity.databaseName,
            rsaSignatureValid: rsaSignatureValid,
            checksums: checksums,
            regions: regions,
            manifest: manifestSummary,
            codePartition: codePartition,
            mfsVolume: mfsVolume,
            cseLayoutTable: cseLayoutTable,
            issues: issues)
    }

    /// Validate the chosen manifest's RSA signature against its protected-data
    /// window, mirroring upstream `rsa_sig_val` (MEA.py 10218):
    /// `hash_data = buffer[base:base+0x80] + buffer[base+HeaderLength*4 : base+Size*4]`.
    /// Returns nil when the signature cannot be checked — no key/signature/exponent
    /// decoded, the struct is not fully in the region, or the modulus is
    /// degenerate (RSA.validate returns nil there; a synthetic even modulus is
    /// "not checkable", not "invalid").
    private static func rsaSignatureValid(for m: ManifestParser.Manifest,
                                          in region: Data) -> Bool? {
        guard let key = m.rsaPublicKey, let signature = m.rsaSignature,
              let exponent = m.rsaExponent else { return nil }
        // Window 1: first 0x80 of the struct; window 2: header-end … manifest-end.
        let hdrEnd = m.base + m.headerLengthBytes
        let sizeEnd = m.base + m.sizeBytes
        guard m.base + 0x80 <= region.count, hdrEnd <= sizeEnd,
              sizeEnd <= region.count else { return nil }
        var protected = region.subdata(in: m.base..<(m.base + 0x80))
        if sizeEnd > hdrEnd {
            protected.append(region.subdata(in: hdrEnd..<sizeEnd))
        }
        return RSA.validate(tag: m.tag, publicKey: key, exponent: exponent,
                            signature: signature, protectedData: protected)?.valid
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

    /// The CSME 12+ `SKU` summary value (e.g. "Consumer H"), built from the
    /// decoded `CSE_Ext_0C`/`CSE_Ext_0F_R2` facts of the operational partition's
    /// manifest chain plus the matched MEA.dat row (see `Identify/SKU.swift`).
    /// Empty for any other family, an unrecognised manifest, or when the chain
    /// gives nothing determinate (no 0x0C/0x0F SKU source).
    private static func skuText(identity: Identifier.Identity,
                                codePartition: CodePartition?,
                                year: Int, month: Int) -> String {
        guard identity.identified, identity.family == .csme, identity.major >= 12,
              codePartition != nil else { return "" }
        // The walker surfaces one payload per tag; multiple 0x0C/0x0F blocks are
        // possible, and upstream keeps the last of each seen.
        var clientSystemInfo: ClientSystemInfoExtension?
        var fwSku: Int?
        for ext in codePartition?.extensions ?? [] {
            if let info = ext.clientSystemInfo { clientSystemInfo = info }
            if let f = ext.signedPackage?.fwSku { fwSku = f }
        }
        return SKU.csme(SKU.Facts(
            variant: identity.variant,
            major: identity.major, minor: identity.minor,
            hotfix: identity.hotfix, build: identity.build,
            year: year, month: month,
            skuType: clientSystemInfo?.skuType,
            skuCaps: clientSystemInfo?.skuCaps,
            skuPlatform: clientSystemInfo?.skuPlatform,
            fwSku: fwSku,
            databaseRow: identity.databaseName)) ?? ""
    }
}
