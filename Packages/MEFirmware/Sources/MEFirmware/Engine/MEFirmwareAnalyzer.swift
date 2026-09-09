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

        // Boot Partition Descriptor Tables: each non-empty CSE-LT Boot partition
        // opens with a BPDT directory of the ME sub-partitions packed inside it
        // (upstream bpdt_anl, MEA.py 11850–12107). A pre-IFWI engine has no CSE
        // LT and therefore no boot partitions → nil. No Issue is raised on a bad
        // 1.7 CRC: upstream only displays that Checksum, it does not error.
        let bootPartitions: [BPDT]? = fpt?.cseLayout.flatMap { layout in
            layout.slots.compactMap { slot in
                guard slot.name.hasPrefix("Boot"), !slot.empty else { return nil }
                let hi = min(slot.offset + slot.size, region.count)
                guard let bpdtBase = IFWI.firstBpdt(in: region, lo: slot.offset, hi: hi),
                      let info = IFWI.bpdtTable(in: region, at: bpdtBase,
                                                partitionName: slot.name)
                else { return nil }
                return BPDT(
                    offset: baseOffset + info.base,
                    partitionName: slot.name,
                    version: info.version,
                    redundancy: info.redundancy,
                    checksumValid: info.checksumValid,
                    entries: info.slots.enumerated().map { index, slot in
                        BPDTPartition(id: index, name: slot.name, type: slot.type,
                                      offset: baseOffset + slot.offset,
                                      size: slot.size, empty: slot.empty)
                    })
            }
        }

        // Phase 9: the CSE file system. The oldest layout — MFS — appears as a
        // raw flash region on both real dumps (CSME 12.0.3 and CSME 15.0.30), in
        // an FPT partition named "MFS". Decode its volume (page inventory →
        // system chunk assembly → volume header + FAT) entirely from bytes,
        // verified byte-for-byte on both. The newer EFST/EFS/FTBL layout lives
        // inside the Huffman vfs/fpf module bodies (needs decompression targets)
        // and is a later increment.
        var mfsVolume: MFSVolume? = nil
        // The parsed low-level volume facts are retained so the identity-gated
        // Home-Directory / per-file Integrity decode below can re-walk the file
        // bytes once variant/major/minor (both layout selectors) are known.
        var mfsInfo: MFSVolumeInfo? = nil
        var mfsIssues: [Issue] = []
        // An MFS *backup* area — an FPT partition named "MFSB" (upstream
        // mfsb_found) or a main "MFS" region in backup state — decodes as MFSB
        // header/entry records, not as a paged volume. Resolved after the page
        // decode below: a page-less main region falls back here; a dedicated
        // "MFSB" partition always lands here.
        var mfsBackup: MFSBackup? = nil
        var mfsBackupIssues: [Issue] = []
        if let mfsRegion = regions.first(where: { $0.name == "MFS" }) {
            let volumeOffset = mfsRegion.offset - baseOffset
            if let info = MFSParser.parse(in: region, offset: volumeOffset,
                                          size: mfsRegion.size) {
                mfsInfo = info
                // The present low-level files are the used records whose FAT chain
                // assembled real content; upstream lists those, not empty records.
                let present = info.files.filter { !$0.content.isEmpty }
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
                    usesFTBL: info.usesFTBL,
                    presentFileCount: present.count,
                    fileBytes: present.reduce(0) { $0 + $1.content.count },
                    files: present.map { MFSFile(index: $0.index, size: $0.content.count) },
                    configurations: info.configurations.map {
                        MFSConfiguration(owningFile: $0.owningFile,
                                         records: $0.records.map {
                            MFSConfigRecord(name: $0.name, isFolder: $0.isFolder,
                                            size: $0.size, offset: $0.offset,
                                            unixRights: $0.unixRights,
                                            integrityProtection: $0.integrity,
                                            encryptionProtection: $0.encryption,
                                            antiReplayProtection: $0.antiReplay,
                                            oemConfigurable: $0.oemConfigurable,
                                            mcaConfigurable: $0.mcaConfigurable,
                                            reserved: $0.reserved,
                                            ownerUserID: $0.ownerUserID,
                                            ownerGroupID: $0.ownerGroupID)
                        })
                    })
                if !info.volumeSignatureValid {
                    mfsIssues.append(Issue(id: 8, severity: .warning,
                        message: "MFS volume at 0x\(String(mfsRegion.offset, radix: 16)) "
                            + "is present but its assembled System volume header is "
                            + "missing or its signature is invalid."))
                } else if !info.fileChainsIntact {
                    mfsIssues.append(Issue(id: 13, severity: .warning,
                        message: "MFS volume at 0x\(String(mfsRegion.offset, radix: 16)) "
                            + "has a low-level file whose FAT chunk chain is corrupt "
                            + "(ends early or cycles)."))
                }
            } else {
                // A main MFS region that carries no MFS pages may instead be in
                // *backup* state — its first bytes are the MFSB signature (a
                // hot/corrupt volume). Upstream mfs_anl enters the same R0/R1
                // branches there (MEA.py 7528), so try the backup decode before
                // declaring the partition unrecognizable.
                mfsBackup = MFSBackupDecoder.parse(in: region,
                                                   offset: volumeOffset,
                                                   size: mfsRegion.size,
                                                   absoluteOffset: mfsRegion.offset)
                if mfsBackup == nil {
                    mfsIssues.append(Issue(id: 8, severity: .warning,
                        message: "Skipped MFS partition at 0x\(String(mfsRegion.offset, radix: 16)): "
                            + "unrecognizable format (no MFS pages found)."))
                }
            }
        }

        // A dedicated MFS Backup partition (FPT name "MFSB") is decoded as a
        // backup area outright; it outranks the main-region fallback above.
        if mfsBackup == nil,
           let mfsbRegion = regions.first(where: { $0.name == "MFSB" }) {
            mfsBackup = MFSBackupDecoder.parse(in: region,
                                               offset: mfsbRegion.offset - baseOffset,
                                               size: mfsbRegion.size,
                                               absoluteOffset: mfsbRegion.offset)
            if mfsBackup == nil {
                mfsBackupIssues.append(Issue(id: 8, severity: .warning,
                    message: "Skipped MFS Backup partition at 0x\(String(mfsbRegion.offset, radix: 16)): "
                        + "unrecognizable format."))
            }
        }

        // Mirror the errors upstream raises for a decoded backup area
        // (MEA.py 7540–7542 / 7560–7562 / 7569–7572 / 7588–7614) into two
        // aggregated warnings: one for the header, one for the body/entries.
        if let backup = mfsBackup {
            switch backup.format {
            case .r0:
                if !backup.headerCRCValid {
                    mfsBackupIssues.append(Issue(id: 17, severity: .warning,
                        message: "MFS Backup at 0x\(String(backup.offset, radix: 16)) "
                            + String(format: "(R0) Header CRC-32 0x%08X is INVALID.",
                                     backup.headerCRCStored)))
                }
                if backup.reconstructedVolumeParses == false {
                    mfsBackupIssues.append(Issue(id: 18, severity: .warning,
                        message: "MFS Backup at 0x\(String(backup.offset, radix: 16)) (R0) "
                            + "body does not reconstruct into a valid MFS volume."))
                }
            case .r1:
                var headerDefects: [String] = []
                if backup.headerRevisionValid == false {
                    headerDefects.append(String(format: "Revision %d, expected 1",
                                                 backup.headerRevision ?? 0))
                }
                if !backup.headerCRCValid {
                    headerDefects.append(String(format: "Header CRC-32 0x%08X is INVALID",
                                                backup.headerCRCStored))
                }
                if !headerDefects.isEmpty {
                    mfsBackupIssues.append(Issue(id: 17, severity: .warning,
                        message: "MFS Backup at 0x\(String(backup.offset, radix: 16)) (R1): "
                            + headerDefects.joined(separator: "; ") + "."))
                }
                var entryDefects: [String] = []
                for entry in backup.entries {
                    var defects: [String] = []
                    if !entry.revisionValid {
                        defects.append(String(format: "Revision %d, expected 1", entry.revision))
                    }
                    if !entry.headerCRCValid {
                        defects.append(String(format: "Entry Header CRC-32 0x%08X is INVALID",
                                              entry.headerCRCStored))
                    }
                    if !entry.dataCRCValid {
                        defects.append(String(format: "Entry Data CRC-32 0x%08X is INVALID",
                                              entry.dataCRCStored))
                    }
                    if !defects.isEmpty {
                        entryDefects.append("entry \(entry.fileIndex) "
                            + defects.joined(separator: ", "))
                    }
                }
                if !entryDefects.isEmpty {
                    mfsBackupIssues.append(Issue(id: 18, severity: .warning,
                        message: "MFS Backup at 0x\(String(backup.offset, radix: 16)) (R1): "
                            + entryDefects.joined(separator: "; ") + "."))
                }
            }
        }

        // Phase 9 (newer FS): the EFS paged filesystem and the FITC
        // ("OEM Configuration") store appear as raw FPT partitions named "EFS"
        // and "FITC" on the newest whole-flash layout (CSME 15.0.30 — the 1.bin
        // dump; EFS @0x267000, FITC @0x1F2000), not inside a Huffman module
        // body. Their decode is purely on-flash bytes: the EFS page inventory,
        // System-page header fields, index permutation and the CRC-32s of the
        // page header / index area / Data Page headers and footers; and the FITC
        // header/length/checksum facts. The EFS *files* (names + per-file
        // integrity) and the FITC *config records* are named and checked through
        // the external FileTable.dat EFST/FTBL rows — a parked DB increment, same
        // wall as the MFS FTBL naming. The older CSME 11/12 layouts carry no EFS
        // region → both stay nil there.
        var efsVolume: EFSVolume? = nil
        var oemConfiguration: OEMConfiguration? = nil
        var fsIssues: [Issue] = []
        if let efsRegion = regions.first(where: { $0.name == "EFS" }) {
            if let efs = EFSParser.parse(in: region,
                                         offset: efsRegion.offset - baseOffset,
                                         size: efsRegion.size,
                                         absoluteOffset: efsRegion.offset,
                                         mfsDictionary: mfsInfo?.ftblDictionary) {
                efsVolume = efs
                // Mirror the errors upstream raises while still decoding the
                // structure: fold the non-expected structural/CRC findings into
                // one warning rather than one Issue per line.
                var defects: [String] = []
                if efs.systemPageCount != 1 {
                    defects.append("detected \(efs.systemPageCount) System "
                        + "page(s), expected 1")
                }
                if !efs.scratchPagesEmpty {
                    defects.append("data in Empty/Scratch page(s)")
                }
                if efs.revision != 1 || efs.unknown1 != 2 {
                    defects.append(String(format:
                        "Revision,Unknown1 = 0x%X,0x%X, expected 0x1,0x2",
                        efs.revision, efs.unknown1))
                }
                if !efs.systemHeaderCRCValid {
                    defects.append("System Page Header CRC-32 is INVALID")
                }
                if !efs.firstIndexPaddingEmpty {
                    defects.append("data in System Page 1st Index Area Padding")
                }
                if !efs.indexesCRCValid {
                    defects.append("System Page Indexes CRC-32 is INVALID")
                }
                if !efs.dataPageCountMatchesSystem {
                    defects.append("detected \(efs.dataPageCount) Data Page(s), "
                        + "expected \(efs.dataPagesCommitted + efs.dataPagesReserved)")
                }
                if !efs.dataPageHeaderCRCsValid {
                    defects.append("a Data Page Header CRC-32 is INVALID")
                }
                if !efs.dataPageFooterCRCsValid {
                    defects.append("a Data Page Footer CRC-32 is INVALID")
                }
                if !defects.isEmpty {
                    fsIssues.append(Issue(id: 15, severity: .warning,
                        message: "EFS partition at 0x\(String(efsRegion.offset, radix: 16)): "
                            + defects.joined(separator: "; ") + "."))
                }
            } else {
                fsIssues.append(Issue(id: 14, severity: .warning,
                    message: "Skipped EFS partition at 0x\(String(efsRegion.offset, radix: 16)): "
                        + "unrecognizable format (no leading System page)."))
            }
        }
        if let fitcRegion = regions.first(where: { $0.name == "FITC" }),
           let cfg = FITCParser.parse(in: region,
                                      offset: fitcRegion.offset - baseOffset,
                                      size: fitcRegion.size,
                                      absoluteOffset: fitcRegion.offset) {
            oemConfiguration = cfg
            var defects: [String] = []
            if cfg.headerCRCValid == false {
                defects.append("Header CRC-32 is INVALID")
            }
            if cfg.dataCRCValid == false {
                defects.append("Data CRC-32 is INVALID")
            }
            if cfg.paddingAllFF == false {
                defects.append("data in padding, possibly unknown Header revision")
            }
            if !defects.isEmpty {
                fsIssues.append(Issue(id: 16, severity: .warning,
                    message: "FITC partition at 0x\(String(fitcRegion.offset, radix: 16)): "
                        + defects.joined(separator: "; ") + "."))
            }
        }

        // Phase 12 (GSC, upstream-map row 79): a GSC "INFO" $FPT partition.
        // Upstream info_anl (MEA.py 9134) decodes one during the partition walk
        // of a GSC-family image — a u32 revision (must be 1) then a GSC_Info_FWI
        // image header and the trailing GSC_Info_IUP rows. Only such images name
        // an FPT partition "INFO", so the name gates the decode (it stays nil on
        // the CSME/IUP dumps, none of which carry one). No GSC dump exists among
        // the oracles — this path is fixture-exercised.
        var gscInfo: GSCInfo? = nil
        var gscInfoIssues: [Issue] = []
        if let infoRegion = regions.first(where: { $0.name == "INFO" }),
           let info = GSCInfoParser.decode(in: region,
                                           offset: infoRegion.offset - baseOffset,
                                           size: infoRegion.size,
                                           baseOffset: baseOffset) {
            gscInfo = info
            if !info.revisionValid {
                gscInfoIssues.append(Issue(id: 12, severity: .warning,
                    message: "Unknown GSC Information Partition revision "
                        + "\(info.revision) at 0x\(String(infoRegion.offset, radix: 16)); "
                        + "expected 1."))
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
                signatureHash: m.rsaSignature.map { Digest.sha256Hex($0) },
                vcn: m.vcn,
                // Row 11 (Production Ready): R0 pre-CSE reads its own probe
                // upstream (12652–12655, no oracle); only R1/R2 operational
                // manifests surface Flags bit0 as the pvbit.
                productionReady: m.format == .r0 ? nil : m.pvBit
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
        issues.append(contentsOf: mfsBackupIssues)
        issues.append(contentsOf: fsIssues)
        issues.append(contentsOf: gscInfoIssues)
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
                cseLayoutTable: cseLayoutTable, bootPartitions: bootPartitions,
                mmeDirectory: nil, gscInfo: gscInfo,
                efsVolume: efsVolume, oemConfiguration: oemConfiguration,
                issues: issues)
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

        // Phase 12 (IUP): the Independent PMC/PCHC/PHY families fill the
        // top-level Chipset Support platform, Chipset SKU letter and PMC chipset
        // stepping straight from their manifest identity (pmc/pchc/phy_anl) —
        // no MFS/PCH-init involved. CSE families return nil here and keep the
        // Phase-10 CSME SKU / empty platform.
        let iup = IUPDescriptor.facts(family: identity.family,
                                      variant: identity.variant,
                                      major: identity.major,
                                      minor: identity.minor,
                                      hotfix: identity.hotfix)

        // Phase 12 (pre-CSE ME, upstream-map row 50): the classic `$SKU`
        // SKU_Attributes (SKU_Attributes/`get_flags`, MEA.py 1044–12654) fills
        // the `SKU` and `Chipset Support` rows of the `.me` family (major 2–10)
        // — e.g. ME10 `SKUType 0` → "5MB", `minor 0` → "WPT-LP". The decode is
        // DB-free (pure byte scan from the manifest), so it runs once identity
        // has named the family `.me`; other families return nil here and keep
        // the Phase-10 CSME SKU / empty platform / IUP path above.
        let preCSE = identity.family == .me
            ? PreCSEME.summary(in: region, manifestBase: manifest.base,
                               major: identity.major, minor: identity.minor,
                               hotfix: identity.hotfix, build: identity.build)
            : nil

        // Phase 12 (pre-CSE ME, upstream-map rows 51/52): the `$MME` module
        // directory (+ trailing `$MCP`) of an R0 `.me` manifest (`$MN2` ME 6–10,
        // `$MAN` ME 2–5). Upstream walks these rows only for region-size /
        // uncharted-partition math, so the directory facts are surfaced as a
        // self-contained inventory (see `MMEModuleDirectory`). An R0 manifest
        // whose declared directory under-decodes (a row's tag was not `$MME`,
        // upstream's sanity break) is noted, never repaired.
        var moduleInventory: MMEModuleDirectory? = nil
        if identity.family == .me, manifest.format == .r0 {
            let mme = PreCSEModule.decode(
                in: region, manifestBase: manifest.base,
                headerLengthBytes: manifest.headerLengthBytes,
                manifestTag: manifest.tag,
                declaredModules: manifest.numModules ?? 0,
                baseOffset: baseOffset)
            if let mme, mme.modules.count < mme.declaredModules {
                issues.append(Issue(id: 11, severity: .note,
                    message: "Pre-CSE \(manifest.tag) module directory declares "
                        + "\(mme.declaredModules) modules but only "
                        + "\(mme.modules.count) `$MME` rows decoded."))
            }
            moduleInventory = mme
        }

        // Phase 12 (GSC OROM, upstream-map rows 30/80): when the region is an
        // OROM firmware image (upstream `is_orom_img`), scan it for `orom_pat`
        // and decode each GSC_OROM_Header + GSC_OROM_PCI_Data pair (MEA.py
        // 12149–12179). Non-OROM regions keep nil. No OROM dump exists among
        // the oracles — the gate is dormant until an OROM RSA key matches the
        // database, and the decoder is fixture-exercised.
        let oromImages: [GSCOROMImage]? = identity.family == .orom
            ? GSCOROM.decode(in: region, baseOffset: baseOffset) : nil

        // Phase 12 (upstream-map rows 54/55): the RBE/PM metadata table of the
        // operational code partition. Upstream `get_rbe_pm_met` (MEA.py 9711)
        // scans the decompressed body of the `pm`/`rbe` module for the run of
        // contiguous `RBE_PM_Metadata` rows (VEN_ID 0x8086). An uncompressed body
        // decodes purely structurally; a Huffman one (the real dumps) needs the
        // live dictionary for this identity and is skipped when the fetch fails
        // or the identity carries no variant/major. Both are best-effort: nil
        // simply means no decodable pm/rbe module body was present.
        let rbePm: [RBE_PMMetadata]?
        if let cp = codePartition {
            let huffmanPM = cp.modules.contains {
                ($0.name == "pm" || $0.name == "rbe") && $0.isHuffman
            }
            let dictionaries = huffmanPM ? try? await data.huffmanDictionaries() : nil
            rbePm = Self.rbePmMetadata(for: cp, in: region, baseOffset: baseOffset,
                                       variant: identity.variant, major: identity.major,
                                       minor: identity.minor, dictionaries: dictionaries)
        } else {
            rbePm = nil
        }

        // Phase 9 (identity-gated): the legacy file-8 Home Directory and the
        // per-reserved-file Integrity tables of a `vfs_starts_at_0`-false volume
        // (CSME 11–14 + SPS/TXE analogues), mirroring upstream `mfs_home_anl` and
        // the reserved walk (get_sec_hdr_size / get_vfs_start_0). Both selectors
        // need variant/major/minor, so this decode is deferred past identity; a
        // no-manifest region (guard above) or a volume whose files start at 0 /
        // that uses the FTBL naming keeps nil. The decode is best-effort and adds
        // no Issues — a dirty file-8 simply yields no Home Directory.
        if !MFSHomeDecoder.vfsStartsAtZero(variant: identity.variant,
                                           major: identity.major,
                                           minor: identity.minor),
           mfsVolume?.usesFTBL == false,
           let info = mfsInfo {
            mfsVolume?.homeDirectory = MFSHomeDecoder.homeDirectory(
                files: info.files, variant: identity.variant,
                major: identity.major, minor: identity.minor,
                hotfix: identity.hotfix, platform: info.ftblPlatform)
            mfsVolume?.reservedIntegrity = MFSHomeDecoder.reservedIntegrity(
                files: info.files, variant: identity.variant,
                major: identity.major, minor: identity.minor,
                hotfix: identity.hotfix, platform: info.ftblPlatform,
                isAFS: false)
        }

        // Phase 9 (identity-gated): the file-6 Intel Configuration's Chipset
        // Initialization Tables (upstream mphytbl/pch_init_anl). mphytbl* file
        // records are already sliced out of file 6 by the config decode retained
        // in `mfsInfo`; only their *stepping letters* are identity-gated
        // (variant/major/minor/build + manifest date decide absolute vs bitfield
        // vs build rules), so the decode is deferred past identity. Unlike the
        // Home Directory it is not gated on `vfs_starts_at_0` — a legacy volume's
        // config stream is decoded regardless of where its files start. Best-
        // effort: no mphytbl records → nil, no Issues.
        if mfsVolume?.usesFTBL == false, let info = mfsInfo {
            mfsVolume?.pchInit = PCHInitDecoder.decode(
                files: info.files, configurations: info.configurations,
                variant: identity.variant, major: identity.major,
                minor: identity.minor, build: identity.build,
                year: manifest.year, month: manifest.month, day: manifest.day)
        }

        // Default-output rows 9/10 (ARB Security Version Number / Version
        // Control Number): hoisted from the operational chain's CSE_Ext_0F
        // ARBSVN/VCN and CSE_Ext_03 VCN (last seen per tag; upstream 6185 and
        // 6245–6246, where 0x03 is preferred and 0x0F is the fallback). The
        // pre-CSE R0 manifest has no extension chain — its +0x34 VCN (already
        // `ManifestSummary.vcn`) is the top-level fallback.
        let chainHoist = CPDExtensionParser.hoist(codePartition?.extensions ?? [])

        return FirmwareAnalysis(
            family: identity.family,
            variant: identity.variant,
            version: Version(major: identity.major, minor: identity.minor,
                             hotfix: identity.hotfix, build: identity.build,
                             meMajor: identity.meMajor, meMinor: identity.meMinor,
                             meHotfix: identity.meHotfix, meBuild: identity.meBuild),
            securityVersion: identity.securityVersion,
            release: identity.release,
            type: .region,
            sku: preCSE?.sku ?? iup?.sku ?? skuText,
            platform: preCSE?.platform ?? iup?.platform ?? "",
            chipsetStepping: iup?.chipsetStepping,
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
            mfsBackup: mfsBackup,
            cseLayoutTable: cseLayoutTable,
            bootPartitions: bootPartitions,
            mmeDirectory: moduleInventory,
            gscInfo: gscInfo,
            oromImages: oromImages,
            rbePmMetadata: rbePm,
            efsVolume: efsVolume,
            oemConfiguration: oemConfiguration,
            arbSvn: chainHoist.arbSvn,
            vcn: chainHoist.vcn03 ?? chainHoist.vcn0F ?? manifestSummary?.vcn,
            mfsState: mfsInfo.map {
                MFSStateDecoder.state(usesFTBL: $0.usesFTBL,
                                      presentFileIndices: $0.files
                                        .filter { !$0.content.isEmpty }
                                        .map(\.index))
            },
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

    /// Phase 12 (upstream-map rows 54/55): decode the RBE/PM metadata table of
    /// the operational code partition — upstream `get_rbe_pm_met` (MEA.py 9711)
    /// over the body of its `pm`/`rbe` module. The `pm` module is found on the
    /// FTPR partition and the `rbe` module on an RBEP one; whichever the region
    /// carries, its body is sliced the same way the module row locates content.
    /// An uncompressed body (older layouts) is decoded directly; a Huffman body
    /// is decompressed against the `.met`-declared sizes and the live dictionary
    /// for the identity. Best-effort — any unreadable/short body returns nil.
    private static func rbePmMetadata(
        for codePartition: CodePartition, in region: Data, baseOffset: Int,
        variant: String, major: Int, minor: Int,
        dictionaries: HuffmanDictionaries?) -> [RBE_PMMetadata]? {
        guard let module = codePartition.modules
                .first(where: { $0.name == "pm" || $0.name == "rbe" }),
              module.size > 0 else { return nil }
        let moduleBase = codePartition.offset - baseOffset + module.offset
        guard moduleBase >= 0 else { return nil }
        guard !module.isHuffman else {
            // Huffman body: `.met` gives the blob bounds; the dictionary picks the
            // variant/major/minor's codebook (major/variant must be usable).
            guard let dictionaries,
                  let dictionary = dictionaries.dictionary(variant: variant,
                                                           major: major, minor: minor),
                  major != 0, variant != "" else { return nil }
            guard let attrs = codePartition.modules
                .first(where: { $0.name == module.name + ".met" })?
                .extensions?
                .compactMap({ $0.moduleAttributes })
                .first,
                attrs.compression == 1, attrs.encryption == 0,
                attrs.compressedSize > 0, attrs.uncompressedSize > 0,
                moduleBase + attrs.compressedSize <= region.count else { return nil }
            let blob = region.subdata(in: moduleBase..<(moduleBase + attrs.compressedSize))
            let result = HuffmanDecoder.decompress(
                module: blob, compressedSize: attrs.compressedSize,
                decompressedSize: attrs.uncompressedSize, dictionary: dictionary)
            guard result.output.count == attrs.uncompressedSize, result.clean else { return nil }
            return RBEPMMetadataParser.decode(in: result.output)
        }
        guard moduleBase + module.size <= region.count else { return nil }
        let body = region.subdata(in: moduleBase..<(moduleBase + module.size))
        return RBEPMMetadataParser.decode(in: body)
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
