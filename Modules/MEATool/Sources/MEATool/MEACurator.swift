import Foundation
import MEFirmware

/// Turns a `FirmwareAnalysis` into the curated tree the «Full Tree» tab
/// shows — hand-named groups in a fixed order, one per *present* top-level
/// structure of the model, leaves carrying the byte ranges the panel reveals.
///
/// This is the pure target's only entry point, mirroring `UEFIPresenter`: the
/// controller never reads the model, it only lays out what `present` returns.
/// Everything a row can show — title, subtitle, detail rows, byte range,
/// children — is baked into the returned value nodes, so a selection never
/// needs to re-query the analysis.
///
/// The trade-off of a curated tree is explicit: a *new* top-level field of
/// `FirmwareAnalysis` is surfaced here by adding one group builder, and opaque
/// sub-structures that are not worth hand-mapping (extension payload rows,
/// EFS/OEM fact groups) are dumped field-by-field by `MEAValueText`. Both
/// choices are recorded in the increment plan.
public enum MEACurator {
    /// The presented tree roots, in reading order: identity first, then the
    /// structural groups, then the fact groups of whatever else decoded.
    public static func present(_ analysis: FirmwareAnalysis) -> [MEANode] {
        var roots: [MEANode] = []
        let add: (MEANode?) -> Void = { if let n = $0 { roots.append(n) } }

        add(firmware(analysis))
        add(regions(analysis))
        add(cseLayout(analysis))
        add(bootPartitions(analysis))
        add(codePartition(analysis))
        add(manifest(analysis))
        add(mfsVolume(analysis))

        // Fact groups — everything else a dump carried, each only when present.
        add(backupGroup(analysis))
        add(efsGroup(analysis))
        add(oemGroup(analysis))
        add(mmeGroup(analysis))
        add(gscGroup(analysis))
        add(oromGroup(analysis))
        add(rbeGroup(analysis))
        add(checksumsGroup(analysis))
        add(issuesGroup(analysis))

        for (index, var node) in roots.enumerated() {
            node.path = [index]
            assignChildPaths(&node)
            roots[index] = node
        }
        return roots
    }

    // MARK: - Identity

    private static func firmware(_ a: FirmwareAnalysis) -> MEANode {
        var fields: [MEAField] = []
        append(&fields, "Family", MEAText.family(a.family))
        append(&fields, "Variant", a.variant, dropEmpty: true)
        append(&fields, "Version", a.version.text)
        if let me = a.version.meText { append(&fields, "MEU Version", me) }
        append(&fields, "Security Version", a.securityVersion, dropEmpty: true)
        append(&fields, "Release", MEAText.title(a.release.rawValue))
        append(&fields, "Type", MEAText.title(a.type.rawValue))
        append(&fields, "SKU", a.sku, dropEmpty: true)
        append(&fields, "Platform", a.platform, dropEmpty: true)
        append(&fields, "Chipset Stepping", a.chipsetStepping, dropEmpty: true)
        append(&fields, "Manufacture Date", a.manufactureDate.map(MEAText.date))
        append(&fields, "Size", MEAText.size(a.sizeBytes))
        append(&fields, "Database Name", a.databaseName, dropEmpty: true)
        append(&fields, "RSA Signature Valid", a.rsaSignatureValid.map(MEAText.yesNo))
        append(&fields, "ARB SVN", a.arbSvn)
        append(&fields, "VCN", a.vcn)
        if let state = a.mfsState { append(&fields, "File System State", MEAText.title(state.rawValue)) }
        return MEANode(path: [], title: "Firmware",
                       subtitle: "\(MEAText.family(a.family)) · \(a.version.text)",
                       fields: fields)
    }

    // MARK: - Regions (FPT)

    private static func regions(_ a: FirmwareAnalysis) -> MEANode? {
        guard !a.regions.isEmpty else { return nil }
        let rows = a.regions.map { region -> MEANode in
            var fields: [MEAField] = []
            append(&fields, "Name", region.name, dropEmpty: true)
            append(&fields, "Offset", MEAText.offset(region.offset))
            append(&fields, "Size", MEAText.size(region.size))
            append(&fields, "Flags", MEAText.hex32(region.flags))
            return MEANode(path: [],
                           title: region.name.isEmpty ? "(unnamed)" : region.name,
                           subtitle: MEAText.range(region.offset, region.size),
                           range: MEAText.rangeValue(region.offset, region.size),
                           fields: fields)
        }
        return MEANode(path: [], title: "Regions (FPT)",
                       subtitle: MEAText.count(rows.count, "region"),
                       children: rows)
    }

    // MARK: - CSE Layout Table

    private static func cseLayout(_ a: FirmwareAnalysis) -> MEANode? {
        guard let table = a.cseLayoutTable else { return nil }
        var header: [MEAField] = []
        append(&header, "Offset", MEAText.offset(table.offset))
        append(&header, "Version", MEAText.hex(table.version))
        append(&header, "Redundancy", MEAText.yesNo(table.redundancy))
        append(&header, "Checksum Valid",
               table.checksumValid.map(MEAText.yesNo) ?? "— (1.6 has none)")
        let rows = table.partitions.map { p -> MEANode in
            var fields: [MEAField] = []
            append(&fields, "Name", p.name, dropEmpty: true)
            append(&fields, "Offset", MEAText.offset(p.offset))
            append(&fields, "Size", MEAText.size(p.size))
            append(&fields, "Empty", MEAText.yesNo(p.empty))
            return MEANode(path: [],
                           title: p.name.isEmpty ? "(unnamed)" : p.name,
                           subtitle: MEAText.range(p.offset, p.size),
                           range: p.empty ? nil : MEAText.rangeValue(p.offset, p.size),
                           fields: fields)
        }
        return MEANode(path: [], title: "CSE Layout Table",
                       subtitle: MEAText.count(table.partitions.count, "partition"),
                       fields: header, children: rows)
    }

    // MARK: - Boot Partitions (BPDT)

    private static func bootPartitions(_ a: FirmwareAnalysis) -> MEANode? {
        guard let tables = a.bootPartitions, !tables.isEmpty else { return nil }
        let rows = tables.map { bpdt -> MEANode in
            var header: [MEAField] = []
            append(&header, "Offset", MEAText.offset(bpdt.offset))
            append(&header, "Boot Slot", bpdt.partitionName)
            append(&header, "Version", "IFWI \(bpdt.version == 2 ? "1.7" : "1.6")")
            append(&header, "Redundancy", MEAText.yesNo(bpdt.redundancy))
            append(&header, "Checksum Valid",
                   bpdt.checksumValid.map(MEAText.yesNo) ?? "— (version 1 has none)")
            // The FIT version the image was built with (row 19 Flash Image
            // Tool). The quartet is nil together (a no-FIT marker); when only
            // part of it decodes, no row is drawn rather than a partial one.
            if let major = bpdt.fitMajor, let minor = bpdt.fitMinor,
               let hotfix = bpdt.fitHotfix, let build = bpdt.fitBuild {
                append(&header, "FIT Version",
                       MEAText.firmwareImageTool(family: a.family, major: major,
                                                 minor: minor, hotfix: hotfix,
                                                 build: build))
            }
            let entries = bpdt.entries.map { e -> MEANode in
                var fields: [MEAField] = []
                append(&fields, "Name", e.name, dropEmpty: true)
                append(&fields, "Type", MEAText.hex16(e.type))
                append(&fields, "Offset", MEAText.offset(e.offset))
                append(&fields, "Size", MEAText.size(e.size))
                append(&fields, "Empty", MEAText.yesNo(e.empty))
                return MEANode(path: [],
                               title: e.name.isEmpty ? "(unnamed)" : e.name,
                               subtitle: MEAText.range(e.offset, e.size),
                               range: e.empty ? nil : MEAText.rangeValue(e.offset, e.size),
                               fields: fields)
            }
            return MEANode(path: [], title: bpdt.partitionName,
                           subtitle: MEAText.count(bpdt.entries.count, "entry"),
                           fields: header, children: entries)
        }
        return MEANode(path: [], title: "Boot Partitions (BPDT)",
                       subtitle: MEAText.count(tables.count, "table"),
                       children: rows)
    }

    // MARK: - Code Partition ($CPD)

    private static func codePartition(_ a: FirmwareAnalysis) -> MEANode? {
        guard let cp = a.codePartition else { return nil }
        var header: [MEAField] = []
        append(&header, "Name", cp.name)
        append(&header, "Offset", MEAText.offset(cp.offset))
        append(&header, "Header", cp.headerVersion == 1 ? "R1" : cp.headerVersion == 2 ? "R2"
            : "R\(cp.headerVersion)")
        append(&header, "Header Length", MEAText.hex(cp.headerLength))
        append(&header, "Declared Modules", String(cp.entryCount))
        append(&header, "Decoded Modules", String(cp.modules.count))
        if let ok = cp.checksumValid { append(&header, "Checksum Valid", MEAText.yesNo(ok)) }

        var children: [MEANode] = []
        if !cp.modules.isEmpty {
            let moduleRows = cp.modules.map { m -> MEANode in
                let absolute = cp.offset + m.offset
                var fields: [MEAField] = []
                append(&fields, "Name", m.name)
                append(&fields, "Offset in $CPD", MEAText.offset(m.offset))
                append(&fields, "Size", MEAText.size(m.size))
                append(&fields, "Huffman", MEAText.yesNo(m.isHuffman))
                // Only non-Huffman modules stand for real bytes: a compressed
                // module's stored size is the packed size, and the decompressed
                // body sits elsewhere — no reliable range to reveal.
                return MEANode(path: [],
                               title: m.name.isEmpty ? "(module \(m.id))" : m.name,
                               subtitle: m.isHuffman
                                   ? MEAText.size(m.size)
                                   : MEAText.range(absolute, m.size),
                               range: m.isHuffman ? nil : MEAText.rangeValue(absolute, m.size),
                               fields: fields)
            }
            children.append(MEANode(path: [], title: "Modules",
                                    subtitle: MEAText.count(moduleRows.count, "module"),
                                    children: moduleRows))
        }
        if let extensions = cp.extensions, !extensions.isEmpty {
            let extRows = extensions.map { MEACurator.extensionRow($0) }
            children.append(MEANode(path: [], title: "Extensions",
                                    subtitle: MEAText.count(extRows.count, "block"),
                                    children: extRows))
        }
        return MEANode(path: [], title: "Code Partition ($CPD)",
                       subtitle: "\(cp.name) · \(cp.headerVersion == 1 ? "R1" : "R2")",
                       fields: header, children: children)
    }

    private static func extensionRow(_ ext: CPDExtension) -> MEANode {
        var fields: [MEAField] = []
        append(&fields, "Tag", MEAText.hexByte(ext.tag))
        append(&fields, "Offset", MEAText.offset(ext.offset))
        append(&fields, "Size", MEAText.size(ext.size))
        // The one payload group decoded for this tag — dumped field-by-field;
        // the sub-table rows of the _Mod variants surface as counts (see the
        // curator doc comment).
        if let payload = MEACurator.payload(of: ext) {
            fields.append(contentsOf: MEAValueText.fields(of: payload))
        }
        let known = extensionTagNames[ext.tag]
        return MEANode(path: [],
                       title: known ?? "CSE_Ext \(MEAText.hexByte(ext.tag))",
                       subtitle: MEAText.range(ext.offset, ext.size),
                       range: MEAText.rangeValue(ext.offset, ext.size),
                       fields: fields)
    }

    /// The decoded payload group of an extension block, if its tag carries one.
    private static func payload(of ext: CPDExtension) -> Any? {
        if let v = ext.signedPackage { return v }
        if let v = ext.partitionInfo { return v }
        if let v = ext.systemInfo { return v }
        if let v = ext.clientSystemInfo { return v }
        if let v = ext.featurePermissions { return v }
        if let v = ext.moduleAttributes { return v }
        if let v = ext.sharedLibrary { return v }
        if let v = ext.processAttributes { return v }
        if let v = ext.threadAttributes { return v }
        if let v = ext.deviceTypes { return v }
        if let v = ext.mmioRanges { return v }
        if let v = ext.specialFiles { return v }
        if let v = ext.lockedRanges { return v }
        if let v = ext.userInfo { return v }
        return nil
    }

    private static let extensionTagNames: [Int: String] = [
        0x00: "System Info", 0x01: "Init Script", 0x02: "Feature Permissions",
        0x03: "Partition Info", 0x04: "Shared Library", 0x05: "Process Attributes",
        0x06: "Thread Attributes", 0x07: "Device Types", 0x08: "MMIO Ranges",
        0x09: "Special Files", 0x0A: "Module Attributes", 0x0B: "Locked Ranges",
        0x0C: "Client System Info", 0x0D: "User Info", 0x0F: "Signed Package",
        0x16: "Partition Info",
    ]

    // MARK: - Manifest

    private static func manifest(_ a: FirmwareAnalysis) -> MEANode? {
        guard let m = a.manifest else { return nil }
        var fields: [MEAField] = []
        append(&fields, "Tag", m.tag)
        append(&fields, "Format", MEAText.manifestFormat(m.format))
        append(&fields, "Offset", MEAText.offset(m.offset))
        append(&fields, "Version", MEAText.version(m.major, m.minor, m.hotfix, m.build))
        append(&fields, "SVN", String(m.svn))
        append(&fields, "Date", MEAText.date(year: m.year, month: m.month, day: m.day))
        append(&fields, "Key SHA-256", m.keyHash, dropEmpty: true)
        append(&fields, "Signature SHA-256", m.signatureHash, dropEmpty: true)
        if let vcn = m.vcn { append(&fields, "VCN", String(vcn)) }
        if let ready = m.productionReady {
            append(&fields, "Production Ready", MEAText.yesNo(ready))
        }
        return MEANode(path: [], title: "Manifest",
                       subtitle: "\(m.tag) · \(MEAText.manifestFormat(m.format))",
                       fields: fields)
    }

    // MARK: - File System (MFS)

    private static func mfsVolume(_ a: FirmwareAnalysis) -> MEANode? {
        guard let vol = a.mfsVolume else { return nil }
        var header: [MEAField] = []
        append(&header, "Offset", MEAText.offset(vol.offset))
        append(&header, "Page Size", MEAText.size(vol.pageSize))
        append(&header, "Page Count", String(vol.pageCount))
        append(&header, "System / Data Pages", "\(vol.systemPageCount) / \(vol.dataPageCount)")
        append(&header, "Signature Valid", MEAText.yesNo(vol.signatureValid))
        append(&header, "Volume Size", MEAText.size(vol.volumeSize))
        append(&header, "Computed Volume Size", MEAText.size(vol.computedVolumeSize))
        append(&header, "File Records", String(vol.fileRecordCount))
        append(&header, "Used Records", String(vol.usedFileCount))
        append(&header, "Present Files", String(vol.presentFileCount))
        append(&header, "File Bytes", MEAText.size(vol.fileBytes))
        append(&header, "FTBL Dictionary", MEAText.hex(vol.ftblDictionary))
        append(&header, "FTBL Platform", MEAText.hex(vol.ftblPlatform))
        append(&header, "Uses FileTable.dat", MEAText.yesNo(vol.usesFTBL))

        var children: [MEANode] = []
        if !vol.files.isEmpty {
            let rows = vol.files.map { f -> MEANode in
                var fields: [MEAField] = []
                append(&fields, "Index", String(f.index))
                append(&fields, "Size", MEAText.size(f.size))
                // A present file has content, but its byte position is the FAT
                // chain walk the engine does not expose — no reliable range.
                return MEANode(path: [], title: "File \(f.index)",
                               subtitle: MEAText.size(f.size), fields: fields)
            }
            children.append(MEANode(path: [], title: "Files",
                                    subtitle: MEAText.count(rows.count, "file"),
                                    children: rows))
        }
        if !vol.configurations.isEmpty {
            let rows = vol.configurations.enumerated().map { i, c -> MEANode in
                MEANode(path: [], title: "Configuration \(i)",
                        fields: MEAValueText.fields(of: c))
            }
            children.append(MEANode(path: [], title: "Configurations",
                                    subtitle: MEAText.count(rows.count, "record"),
                                    children: rows))
        }
        if let home = vol.homeDirectory {
            children.append(homeGroup(home))
        }
        if let pch = vol.pchInit {
            children.append(pchGroup(pch))
        }
        if !vol.reservedIntegrity.isEmpty {
            let rows = vol.reservedIntegrity.enumerated().map { i, r -> MEANode in
                MEANode(path: [], title: "Integrity \(i + 1)",
                        fields: MEAValueText.fields(of: r))
            }
            children.append(MEANode(path: [], title: "File Integrity",
                                    subtitle: MEAText.count(rows.count, "table"),
                                    children: rows))
        }
        return MEANode(path: [], title: "File System (MFS)",
                       subtitle: MEAText.count(vol.presentFileCount, "file"),
                       fields: header, children: children)
    }

    private static func homeGroup(_ home: MFSHomeDirectory) -> MEANode {
        var fields: [MEAField] = []
        append(&fields, "Record Size", MEAText.hex(home.homeRecordSize))
        append(&fields, "Root Records", String(home.rootRecordCount))
        let rows = home.entries.map { homeRow($0) }
        return MEANode(path: [], title: "Home Directory",
                       subtitle: MEAText.count(home.entries.count, "entry"),
                       fields: fields, children: rows)
    }

    private static func homeRow(_ record: MFSHomeRecord) -> MEANode {
        var fields: [MEAField] = []
        append(&fields, "File Index", String(record.fileIndex))
        append(&fields, "Kind", record.isFolder ? "Folder" : "File")
        append(&fields, "File System", String(record.fileSystemID))
        if !record.isFolder { append(&fields, "Size", MEAText.size(record.size)) }
        let kind = record.isFolder ? "folder" : "file"
        let title = record.name.isEmpty
            ? "\(record.isFolder ? "Folder" : "File") \(record.fileIndex)"
            : record.name
        return MEANode(path: [], title: title,
                       subtitle: "\(kind) #\(record.fileIndex)",
                       fields: fields,
                       children: record.children.map { homeRow($0) })
    }

    private static func pchGroup(_ pch: MFSPCHInit) -> MEANode {
        var fields: [MEAField] = []
        append(&fields, "Records", String(pch.records.count))
        append(&fields, "Chipsets", String(pch.chipsets.count))
        let rows = pch.chipsets.map { c -> MEANode in
            MEANode(path: [], title: c.chipset, subtitle: c.steppings,
                    fields: [MEAField("Chipset", c.chipset),
                             MEAField("Steppings", c.steppings)])
        }
        return MEANode(path: [], title: "Chipset Initialization",
                       fields: fields, children: rows)
    }

    // MARK: - Fact groups (opaque structures, dumped)

    private static func backupGroup(_ a: FirmwareAnalysis) -> MEANode? {
        guard let backup = a.mfsBackup else { return nil }
        var fields: [MEAField] = []
        append(&fields, "Format", backup.format == .r1 ? "R1" : "R0")
        append(&fields, "Offset", MEAText.offset(backup.offset))
        append(&fields, "Header CRC", MEAText.hex32(backup.headerCRCStored))
        append(&fields, "Header CRC Valid", MEAText.yesNo(backup.headerCRCValid))
        if let allFF = backup.reservedAllFF {
            append(&fields, "Reserved All 0xFF", MEAText.yesNo(allFF))
        }
        if let parses = backup.reconstructedVolumeParses {
            append(&fields, "Reconstructed Volume Parses", MEAText.yesNo(parses))
        }
        if let rev = backup.headerRevision {
            append(&fields, "Header Revision", String(rev))
            if let valid = backup.headerRevisionValid {
                append(&fields, "Header Revision Valid", MEAText.yesNo(valid))
            }
        }
        let rows = backup.entries.map { entry -> MEANode in
            var fields: [MEAField] = []
            append(&fields, "File Index", String(entry.fileIndex))
            append(&fields, "File",
                   backupFileNames[entry.fileIndex] ?? "Low-level file \(entry.fileIndex)")
            append(&fields, "Blob Offset", MEAText.offset(entry.blobOffset))
            append(&fields, "Blob Size", MEAText.size(entry.blobSize))
            append(&fields, "Data Size", MEAText.size(entry.dataSize))
            append(&fields, "Revision Valid", MEAText.yesNo(entry.revisionValid))
            append(&fields, "Header CRC", MEAText.hex32(entry.headerCRCStored))
            append(&fields, "Header CRC Valid", MEAText.yesNo(entry.headerCRCValid))
            append(&fields, "Data CRC", MEAText.hex32(entry.dataCRCStored))
            append(&fields, "Data CRC Valid", MEAText.yesNo(entry.dataCRCValid))
            return MEANode(path: [], title: "Entry \(entry.fileIndex)",
                           subtitle: backupFileNames[entry.fileIndex]
                               ?? "low-level file \(entry.fileIndex)",
                           fields: fields)
        }
        return MEANode(path: [], title: "MFS Backup",
                       subtitle: backup.format == .r1 ? "R1" : "R0",
                       fields: fields, children: rows)
    }

    private static let backupFileNames: [Int: String] = [
        6: "Intel Configuration", 7: "OEM Configuration", 9: "Manifest Backup",
    ]

    private static func efsGroup(_ a: FirmwareAnalysis) -> MEANode? {
        guard let efs = a.efsVolume else { return nil }
        return MEANode(path: [], title: "EFS Volume",
                       subtitle: MEAText.offset(efs.offset),
                       fields: MEAValueText.fields(of: efs))
    }

    private static func oemGroup(_ a: FirmwareAnalysis) -> MEANode? {
        guard let oem = a.oemConfiguration else { return nil }
        return MEANode(path: [], title: "OEM Configuration",
                       fields: MEAValueText.fields(of: oem))
    }

    private static func mmeGroup(_ a: FirmwareAnalysis) -> MEANode? {
        guard let dir = a.mmeDirectory else { return nil }
        var fields: [MEAField] = []
        append(&fields, "Manifest", dir.manifestTag)
        append(&fields, "Offset", MEAText.offset(dir.offset))
        append(&fields, "Declared Modules", String(dir.declaredModules))
        append(&fields, "Decoded Modules", String(dir.modules.count))
        let rows = dir.modules.enumerated().map { i, m -> MEANode in
            MEANode(path: [], title: "Module \(i + 1)",
                    fields: MEAValueText.fields(of: m))
        }
        return MEANode(path: [], title: "$MME Directory", fields: fields, children: rows)
    }

    private static func gscGroup(_ a: FirmwareAnalysis) -> MEANode? {
        guard let gsc = a.gscInfo else { return nil }
        return MEANode(path: [], title: "GSC Info",
                       fields: MEAValueText.fields(of: gsc))
    }

    private static func oromGroup(_ a: FirmwareAnalysis) -> MEANode? {
        guard let images = a.oromImages, !images.isEmpty else { return nil }
        let rows = images.enumerated().map { i, img -> MEANode in
            MEANode(path: [], title: "Image \(i + 1)",
                    subtitle: MEAText.offset(img.offset),
                    fields: MEAValueText.fields(of: img))
        }
        return MEANode(path: [], title: "OROM Images",
                       subtitle: MEAText.count(rows.count, "image"),
                       children: rows)
    }

    private static func rbeGroup(_ a: FirmwareAnalysis) -> MEANode? {
        guard let rows = a.rbePmMetadata, !rows.isEmpty else { return nil }
        let children = rows.enumerated().map { i, r -> MEANode in
            var fields = MEAValueText.fields(of: r)
            fields.removeAll { $0.label == "Unknown0" }   // raw open word, low signal
            return MEANode(path: [], title: "R\(r.variant.rawValue.uppercased()) #\(r.id)",
                           fields: fields)
        }
        return MEANode(path: [], title: "RBE/PM Metadata",
                       subtitle: MEAText.count(children.count, "row"),
                       children: children)
    }

    private static func checksumsGroup(_ a: FirmwareAnalysis) -> MEANode? {
        guard let checks = a.checksums else { return nil }
        var fields: [MEAField] = []
        append(&fields, "SHA-256", checks.sha256, dropEmpty: true)
        append(&fields, "SHA-384", checks.sha384, dropEmpty: true)
        if let crc = checks.crc32 { append(&fields, "CRC-32", MEAText.hex32(crc)) }
        guard !fields.isEmpty else { return nil }
        return MEANode(path: [], title: "Checksums", fields: fields)
    }

    private static func issuesGroup(_ a: FirmwareAnalysis) -> MEANode? {
        guard !a.issues.isEmpty else { return nil }
        let rows = a.issues.map { issue -> MEANode in
            let name = MEAText.title(issue.severity.rawValue)
            return MEANode(path: [], title: name,
                           subtitle: issue.message,
                           fields: [MEAField("Severity", name),
                                    MEAField("Message", issue.message)])
        }
        return MEANode(path: [], title: "Issues",
                       subtitle: MEAText.count(rows.count, "issue"),
                       children: rows)
    }

    // MARK: - Path assignment

    /// Fills in every node's `path` from its position under an already-named root.
    private static func assignChildPaths(_ parent: inout MEANode) {
        for i in parent.children.indices {
            parent.children[i].path = parent.path + [i]
            assignChildPaths(&parent.children[i])
        }
    }

    // MARK: - Field building

    /// Appends `label`/`value` unless the value is nil or (when `dropEmpty`) an
    /// empty string. Optional strings arrive here already unwrapped by the caller.
    private static func append(_ fields: inout [MEAField], _ label: String,
                               _ value: String?, dropEmpty: Bool = false) {
        guard let value, !(dropEmpty && value.isEmpty) else { return }
        fields.append(MEAField(label, value))
    }

    private static func append(_ fields: inout [MEAField], _ label: String,
                               _ value: String) {
        fields.append(MEAField(label, value))
    }

    private static func append(_ fields: inout [MEAField], _ label: String,
                               _ value: Int?) {
        guard let value else { return }
        fields.append(MEAField(label, String(value)))
    }
}
