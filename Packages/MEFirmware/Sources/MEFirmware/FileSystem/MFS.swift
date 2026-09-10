import Foundation

/// CSE MFS (CSME "Management"/Flash File System) — a faithful structural port of
/// upstream `mfs_anl` (MEA.py 7499): the page inventory, the system-area chunk
/// assembly (CRC-16/14 reverse de-obfuscation), the volume header + FAT read and
/// the low-level *file* walk that follows them.
///
/// An MFS volume is a paged flash area: `pageSize`-byte pages, each starting
/// with a `MFS_Page_Header` (tag `0xAA557887` = bytes `87 78 55 AA`). Pages whose
/// `FirstChunkIndex == 0` are *System* pages, the rest *Data* pages; their 0x40-
/// byte payload chunks (plus a 2-byte CRC-16) are scattered for wear levelling.
/// The System pages' chunk indexes are stored obfuscated and must be recovered
/// with the reverse `Crc16_14` transform; the *logical* volume header lives in
/// assembled System chunk index 0 (signature `0x724F6201`). A raw `MFS` region
/// is present in both real dumps — CSME 12.0.3 (`DATMAAMBAC0.BIN` @0x7000: 49
/// pages, 512 file records, 210 used, FTBL dict 1/0/0 → `usesFTBL` false) and
/// CSME 15.0.30 (`1.bin`: 49 pages, 1024 records, 136 used, dict 0x0A/0x04 →
/// `usesFTBL` true) — both byte-verified.
///
/// The **low-level file walk** (upstream 7849–7884) reads the FAT as two u16
/// arrays over the assembled System area: the first `FileRecordCount` values are
/// the file records (0x0000 unused / 0xFFFE erased / 0xFFFF used-but-empty), each
/// used record holding the *first data-FAT slot* of its file; the values that
/// follow chain chunk to chunk (data-FAT slot `f` ≥ `FileRecordCount` maps to
/// data chunk `SystemChunkCount + f − FileRecordCount`) until a small value
/// `1…0x40` marks EOF and gives the final chunk's used byte count. Each present
/// file is therefore its chain of raw data chunks, assembled in order. The
/// reserved roles upstream prints by index (0–9: Anti-Replay, SVN Migration,
/// Quota Storage, Intel/OEM Configuration, Manifest Backup — `mfs_dict`, MEA.py
/// 10859) select the decode over that content: the legacy (non-FTBL) Intel/OEM
/// Configuration record streams (`mfs_cfg_anl` / `MFS_Config_Record_0x1C`) are
/// decoded here; the file-8 Home Directory records and the per-file Integrity
/// tables of a `vfs_starts_at_0`-false volume are decoded by `MFSHomeDecoder`
/// below. The FTBL 0xC naming (FileTable.dat, upstream `mfs_home13_anl`) is a
/// later increment.
struct MFSVolumeInfo {
    var pageSize: Int
    var systemPageCount: Int
    var dataPageCount: Int
    var volumeSignatureValid: Bool
    var volumeSize: Int                 // declared VolumeSize (system + data)
    var computedVolumeSize: Int         // system+data chunk payload area
    var fileRecordCount: Int
    var usedFileCount: Int              // FAT: file records whose 1st-chunk ≠ unused
    var ftblDictionary: Int             // 1 when FTBL/EFST unused (the "Revision" case)
    var ftblPlatform: Int
    var ftblReserved: Int
    var usesFTBL: Bool                  // not (dict,plat,reserved) == (1,0,0)
    var files: [MFSLowLevelFile]        // present (non-empty) records, by index
    var fileChainsIntact: Bool          // every used chain hit a clean EOF marker
    var configurations: [MFSConfigDecode]  // legacy MFS only: decoded low-level
                                           // files 6/7 (Intel/OEM Configuration)
}

/// One present low-level MFS file (upstream 7849–7877): the raw bytes of its
/// FAT chain. `content` is nil for unused/erased/empty records — those are not
/// listed in `MFSVolumeInfo.files`.
struct MFSLowLevelFile {
    var index: Int
    var content: Data
}

/// A decoded legacy MFS Configuration stream (upstream `mfs_cfg_anl` MEA.py
/// 8467 over `MFS_Config_Record_0x1C`, MEA.py 1319). A config low-level file
/// (6 = Intel Configuration, 7 = OEM Configuration) begins with a u32 record
/// count then that many 0x1C records — a flat, ordered list whose *folder*
/// entries nest by name and pop back out on a ".." entry. File entries carry a
/// size and an offset into the owning low-level file where their content lives.
struct MFSConfigDecode {
    var owningFile: Int        // 6 = Intel Configuration, 7 = OEM Configuration
    var records: [MFSRawConfigRecord]
}

/// One decoded `MFS_Config_Record_0x1C`. (Distinct from the public Codable
/// `MFSConfigRecord` the analyzer maps this into.)
struct MFSRawConfigRecord {
    var name: String             // FileName (folders may be "..")
    var isFolder: Bool           // AccessMode.RecordType: 0 File, 1 Folder
    var size: Int                // FileSize (0 for folder entries)
    var offset: Int              // FileOffset into the owning low-level file
    var unixRights: Int          // AccessMode.UnixRights (9-bit)
    var integrity: Bool          // AccessMode.Integrity
    var encryption: Bool         // AccessMode.Encryption
    var antiReplay: Bool         // AccessMode.AntiReplay
    var oemConfigurable: Bool    // DeployOptions bit0
    var mcaConfigurable: Bool    // DeployOptions bit1
    var reserved: Int            // Reserved
    var ownerUserID: Int
    var ownerGroupID: Int
}

enum MFSParser {
    static let pageSize = 0x2000
    static let pageHeaderSize = 0x12
    static let chunkAllSize = 0x42
    static let chunkRawSize = 0x40
    static let systemIndexSize = 2
    static let dataIndexSize = 1
    static let volumeHeaderSize = 0xE
    static let pageTag: UInt32 = 0xAA55_7887          // MFS Page Header signature
    static let volumeTag: UInt32 = 0x724F_6201        // assembled System chunk 0

    /// Parse the MFS volume occupying `region[offset ..< offset+size]`. Returns
    /// nil when the area carries no MFS pages at all (upstream's "unrecognizable
    /// format" skip). A volume whose page tag is present but whose assembled
    /// System chunk 0 is not the expected volume header is reported with
    /// `volumeSignatureValid == false` rather than failing.
    static func parse(in region: Data, offset: Int, size: Int) -> MFSVolumeInfo? {
        guard offset >= 0, size >= pageSize, offset + size <= region.count else { return nil }
        let buffer = region.subdata(in: offset..<(offset + size))

        let pageCount = buffer.count / pageSize
        guard pageCount >= 1 else { return nil }

        // ——— Page inventory: collect System pages (by logical PageNumber) and
        // Data pages (by FirstChunkIndex). Other tags are Scratch pages.
        var systemPages: [(page: Int, number: Int)] = []
        var dataPages: [(page: Int, firstChunk: Int)] = []
        var systemChunkCountTarget = 0xFFFF  // first Data chunk index ⇒ System area size
        for page in 0..<pageCount {
            let base = page * pageSize
            let tag = readUInt32(buffer, at: base)
            guard tag == pageTag else { continue }          // Scratch / erased page
            let firstChunk = Int(readUInt16(buffer, at: base + 0x0E))
            let pageNumber = Int(readUInt32(buffer, at: base + 0x04))
            if firstChunk == 0 {
                systemPages.append((page, pageNumber))
            } else {
                dataPages.append((page, firstChunk))
                systemChunkCountTarget = min(systemChunkCountTarget, firstChunk)
            }
        }
        guard !systemPages.isEmpty || !dataPages.isEmpty else { return nil }

        systemPages.sort { $0.number < $1.number }
        dataPages.sort { $0.firstChunk < $1.firstChunk }

        // ——— Assemble the System chunk area. Indexes are 14-bit de-obfuscated
        // per System page (upstream resets the running value each page).
        let systemChunkCount = (pageSize - pageHeaderSize - systemIndexSize)
            / (systemIndexSize + chunkAllSize)
        let systemIndexSizeTotal = systemChunkCount * systemIndexSize + systemIndexSize
        var chunks: [Int: Data] = [:]
        for (page, _) in systemPages {
            let base = page * pageSize
            var running: UInt16 = 0
            var used: [Int] = []
            for i in 0...systemChunkCount {          // chunk_count + 1 index entries
                let value = readUInt16(buffer, at: base + pageHeaderSize + i * systemIndexSize)
                if value & 0xC000 != 0 { break }     // unused entry
                running = CRC16_14.transform(running) ^ value
                used.append(Int(running))
            }
            let chunkStart = pageHeaderSize + systemIndexSizeTotal
            for (slot, index) in used.enumerated() {
                let at = base + chunkStart + slot * chunkAllSize
                guard at + chunkRawSize <= base + pageSize else { break }
                chunks[index] = buffer.subdata(in: at..<(at + chunkRawSize))
            }
        }

        // ——— Data pages contribute the file payload chunks (a 1-byte index:
        // 0x00 used, 0xFF unused), but the volume facts below only need the
        // System area; still fill so sizes are honest.
        let dataChunkCount = (pageSize - pageHeaderSize) / (dataIndexSize + chunkAllSize)
        let dataIndexSizeTotal = dataChunkCount * dataIndexSize
        for (page, firstChunk) in dataPages {
            let base = page * pageSize
            let chunkStart = pageHeaderSize + dataIndexSizeTotal
            for slot in 0..<dataChunkCount {
                let indexByte = buffer[base + pageHeaderSize + slot]
                guard indexByte == 0 else { continue }
                let at = base + chunkStart + slot * chunkAllSize
                guard at + chunkRawSize <= base + pageSize else { break }
                chunks[firstChunk + slot] = buffer.subdata(in: at..<(at + chunkRawSize))
            }
        }

        // The logical System area is System chunk 0..<systemChunkCount laid
        // contiguously (unused chunks are all-zero); the volume header is chunk
        // 0. Its declared size bounds the FAT read below.
        let maxDataChunks = dataPages.count * dataChunkCount
        var effectiveSystemChunkCount = systemChunkCountTarget
        if effectiveSystemChunkCount == 0xFFFF {
            effectiveSystemChunkCount = (chunks.keys.max() ?? -1) + 1   // no Data page
        }
        let systemAreaSize = effectiveSystemChunkCount * chunkRawSize

        var info = MFSVolumeInfo(pageSize: pageSize,
                                 systemPageCount: systemPages.count,
                                 dataPageCount: dataPages.count,
                                 volumeSignatureValid: false,
                                 volumeSize: 0,
                                 computedVolumeSize: systemAreaSize + maxDataChunks * chunkRawSize,
                                 fileRecordCount: 0,
                                 usedFileCount: 0,
                                 ftblDictionary: 0,
                                 ftblPlatform: 0,
                                 ftblReserved: 0,
                                 usesFTBL: false,
                                 files: [],
                                 fileChainsIntact: true,
                                 configurations: [])

        guard let volume = chunks[0], volume.count >= volumeHeaderSize else {
            return info                       // no System chunk 0 ⇒ signature invalid
        }
        let signature = readUInt32(volume, at: 0)
        info.volumeSignatureValid = signature == volumeTag
        guard info.volumeSignatureValid else { return info }

        info.ftblDictionary = Int(volume[4])
        info.ftblPlatform = Int(volume[5])
        info.ftblReserved = Int(readUInt16(volume, at: 6))
        info.usesFTBL = !(info.ftblDictionary == 1 && info.ftblPlatform == 0
            && info.ftblReserved == 0)
        info.volumeSize = Int(readUInt32(volume, at: 8))
        info.fileRecordCount = Int(readUInt16(volume, at: 12))

        // ——— File Allocation Table: `fileRecordCount` volume entries (each a
        // low-level file's first Data-FAT slot, or an empty marker) follow the
        // volume header inside the System area, two bytes each, then one slot
        // per Data chunk of the whole volume. Read through the sparse chunk
        // map (a byte at System-area offset `f` lives in chunk f / 0x40 at
        // f % 0x40; absent chunks read as 0x00).
        if info.fileRecordCount > 0,
           volumeHeaderSize + info.fileRecordCount * 2 <= systemAreaSize {
            var used = 0
            for record in 0..<info.fileRecordCount {
                let areaOffset = volumeHeaderSize + record * 2
                let value = readSystemAreaUInt16(chunks, at: areaOffset)
                if value != 0x0000, value != 0xFFFE, value != 0xFFFF { used += 1 }
            }
            info.usedFileCount = used
        }

        // ——— Low-level file walk (upstream 7849–7884): every *used* file record
        // holds the first Data-FAT slot of its file; the slots that follow chain
        // chunk to chunk (Data slot `f` ≥ FileRecordCount maps to Data chunk
        // `SystemChunkCount + f − FileRecordCount`) until a small value 1…0x40
        // marks EOF and gives the final chunk's used byte count. Assembled in
        // order, that is the file's raw content. A chain that runs out of the
        // FAT / chunk area (corrupt volume) ends with what it has and clears
        // `fileChainsIntact`, mirroring upstream's error-and-continue.
        if info.fileRecordCount > 0 {
            let dataPageEstimate = max(0, pageCount - pageCount / 12 - 1)
            let maxDataChunks = dataPageEstimate * dataChunkCount
            func fatValue(_ slot: Int) -> UInt16 {
                guard slot >= 0 else { return 0 }
                let areaOffset = volumeHeaderSize + slot * 2
                guard areaOffset + 2 <= systemAreaSize else { return 0 }
                return readSystemAreaUInt16(chunks, at: areaOffset)
            }
            var files: [MFSLowLevelFile] = []
            var intact = true
            for record in 0..<info.fileRecordCount {
                var value = fatValue(record)
                if value == 0x0000 || value == 0xFFFE || value == 0xFFFF { continue }
                var body = Data()
                var steps = 0
                while true {
                    // A file chain can never visit more distinct Data chunks than
                    // exist, so bound the walk (a cyclic/corrupt FAT upstream would
                    // spin on; the engine must not).
                    steps += 1
                    if steps > maxDataChunks + 1 {
                        intact = false
                        break
                    }
                    if value < info.fileRecordCount {   // points back into the records
                        intact = false
                        break
                    }
                    let dataSlot = Int(value) - info.fileRecordCount
                    guard dataSlot >= 0, dataSlot < maxDataChunks else {
                        intact = false
                        break
                    }
                    let chunkIndex = effectiveSystemChunkCount + dataSlot
                    guard let chunk = chunks[chunkIndex] else {   // missing chunk
                        intact = false
                        break
                    }
                    value = fatValue(Int(value))                  // next slot in the chain
                    if value >= 1 && value <= UInt16(chunkRawSize) {   // EOF marker
                        body.append(chunk.prefix(Int(value)))
                        break
                    }
                    body.append(chunk)
                }
                files.append(MFSLowLevelFile(index: record, content: body))
            }
            info.files = files
            info.fileChainsIntact = intact
        }

        // ——— Legacy Configuration record decode. Only the old-style MFS
        // (usesFTBL == false, CSME ≤ 12) lays out Intel/OEM Configuration
        // (low-level files 6/7) as `MFS_Config_Record_0x1C` streams; the FTBL
        // layout's 0xC records name their files through FileTable.dat (the
        // DB/FileTable increment). Decode whichever of 6/7 the volume carries.
        if !info.usesFTBL {
            var configs: [MFSConfigDecode] = []
            for owner in [6, 7] {
                guard let file = info.files.first(where: { $0.index == owner }),
                      !file.content.isEmpty else { continue }
                if let records = Self.decodeConfigRecords(file.content) {
                    configs.append(MFSConfigDecode(owningFile: owner, records: records))
                }
            }
            info.configurations = configs
        }
        return info
    }

    /// Decode a legacy Configuration record stream: a u32 record count then
    /// that many 0x1C `MFS_Config_Record_0x1C` entries. The count bounds the
    /// walk; a stream shorter than the declared table decodes the complete
    /// records that fit and stops (mirroring upstream error-and-continue).
    static func decodeConfigRecords(_ content: Data) -> [MFSRawConfigRecord]? {
        guard content.count >= 4 else { return nil }
        let count = Int(readUInt32(content, at: 0))
        var records: [MFSRawConfigRecord] = []
        for i in 0..<count {
            let base = 4 + i * 0x1C
            guard base + 0x1C <= content.count else { break }
            let nameBytes = content.subdata(in: base..<(base + 12))
            let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
            let accessMode = readUInt16(content, at: base + 0x0E)
            let deployOptions = readUInt16(content, at: base + 0x10)
            records.append(MFSRawConfigRecord(
                name: name,
                isFolder: accessMode & (1 << 12) != 0,      // RecordType
                size: Int(readUInt16(content, at: base + 0x12)),
                offset: Int(readUInt32(content, at: base + 0x18)),
                unixRights: Int(accessMode & 0x1FF),
                integrity: accessMode & (1 << 9) != 0,
                encryption: accessMode & (1 << 10) != 0,
                antiReplay: accessMode & (1 << 11) != 0,
                oemConfigurable: deployOptions & 1 != 0,
                mcaConfigurable: deployOptions & (1 << 1) != 0,
                reserved: Int(readUInt16(content, at: base + 0x0C)),
                ownerUserID: Int(readUInt16(content, at: base + 0x14)),
                ownerGroupID: Int(readUInt16(content, at: base + 0x16))))
        }
        return records
    }

    /// A little-endian UInt16 at logical System-area offset `areaOffset`,
    /// resolved through the sparse chunk map.
    private static func readSystemAreaUInt16(_ chunks: [Int: Data],
                                             at areaOffset: Int) -> UInt16 {
        var value: UInt16 = 0
        for byteSlot in 0..<2 {
            let offset = areaOffset + byteSlot
            let chunkIndex = offset / chunkRawSize
            let inChunk = offset % chunkRawSize
            let byte: UInt8
            if let chunk = chunks[chunkIndex], inChunk < chunk.count {
                byte = chunk[inChunk]
            } else {
                byte = 0
            }
            value |= UInt16(byte) << UInt16(8 * byteSlot)
        }
        return value
    }

    // MARK: - little-endian reads (bounds-checked)

    private static func readUInt32(_ data: Data, at index: Int) -> UInt32 {
        guard index >= 0, index + 4 <= data.count else { return 0 }
        return UInt32(data[index])
            | (UInt32(data[index + 1]) << 8)
            | (UInt32(data[index + 2]) << 16)
            | (UInt32(data[index + 3]) << 24)
    }

    private static func readUInt16(_ data: Data, at index: Int) -> UInt16 {
        guard index >= 0, index + 2 <= data.count else { return 0 }
        return UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
    }
}

/// Default-output **File System State** (row 17): the `mfs_state` value of
/// upstream `get_mfs_anl` (MEA.py 7480–7493). Once an MFS volume is decoded,
/// the *semantic* low-level file indices it carries decide the state — any of
/// the reserved/indexed set {0–5, 8} → Initialized (the volume was initialised),
/// else any of {7, 9} (OEM Configuration / Home Directory) → Configured, else
/// the upstream default Unconfigured (init 11075). `.error` is never derived
/// here — upstream raises it only when `mfs_anl` throws, which the engine's
/// decoders do not.
///
/// Deliberately scoped to the *legacy* membership rule: an FTBL-mode volume
/// (CSME 15/16) names its files through the FileTable.dat tables (a later
/// increment), so its raw FAT indices do not map to upstream's semantic set and
/// the row stays Unconfigured even when the volume carries files. The CSME
/// EFS/OEM-config/CDMD upgrade rules of MEA.py 13050–13051 are likewise out of
/// this row's scope. Both decisions are recorded in the increment plan.
enum MFSStateDecoder {
    /// The File System State (row 17), in upstream's three steps:
    ///
    /// 1. the reserved low-level files the volume holds — indices 0–5/8 mean
    ///    the file system has been initialised, 7/9 that it has been
    ///    configured (`get_mfs_anl`, MEA.py 7489–7490). A volume whose files
    ///    start at offset 0 (CSME 15/16, `usesFTBL`) has no reserved files by
    ///    index at all: upstream's own loop breaks out on `vfs_starts_at_0`
    ///    before reading one, so nothing is claimed from indices there;
    /// 2. failing that, a configuration partition of any kind — a `fitc.cfg`
    ///    module, a FITC / CDMD / MFSB partition — means the firmware has at
    ///    least been configured (13051).
    ///
    /// One step between the two is not ported: an EFS volume that holds file
    /// contents raises the state to Initialized from any state (13050,
    /// `efs_init`). Which bytes of an EFS are a file is a question only the
    /// `FileTable.dat` EFST table answers — it names each entry's offset in
    /// the volume's assembled data area — and that table is not parsed here
    /// yet. So a CSME 15/16 image whose file system is written but whose
    /// configuration partitions are present reads Configured where the console
    /// reads Initialized: one step short, from a rule that does hold, rather
    /// than a guess at the one that is missing.
    static func state(usesFTBL: Bool, presentFileIndices: [Int],
                      hasConfiguration: Bool) -> MFSState {
        var state = MFSState.unconfigured
        if !usesFTBL {
            if presentFileIndices.contains(where: { [0, 1, 2, 3, 4, 5, 8].contains($0) }) {
                state = .initialized
            } else if presentFileIndices.contains(where: { [7, 9].contains($0) }) {
                state = .configured
            }
        }
        if state == .unconfigured, hasConfiguration {
            state = .configured
        }
        return state
    }
}

/// Legacy (non-FTBL) MFS reserved-file Integrity and file-8 Home Directory
/// decode (upstream 7887–8301), driven by the identity layout selectors
/// `get_sec_hdr_size` (MEA.py 7449) / `get_vfs_start_0` (MEA.py 7467). These
/// run only for a volume whose files do *not* start at offset 0 — CSME 11–14
/// and their SPS/TXE analogues — because a `vfs_starts_at_0` volume (CSME 15/16)
/// names its reserved files through the FTBL/EFST tables (`mfs_home13_anl`), not
/// by raw index. The decoders work over the already-walked low-level file bytes
/// (`MFSVolumeInfo.files`) and are gated upstream by
/// `if vfs_starts_at_0 or not mfs_has_files: break` (7888).
enum MFSHomeDecoder {

    // MARK: Layout selectors (get_sec_hdr_size / get_vfs_start_0)

    /// `get_sec_hdr_size`: the length of the trailing `MFS_Integrity_Table` a
    /// reserved / Home-Directory file carries — 0x28 (HMAC-MD5 + AES-GCM nonce)
    /// or 0x34 (HMAC-SHA-256 + 128-bit nonce). Only `variant`/`major`/`minor` and
    /// `platform` (`vol_ftbl_pl`) influence the choice; `hotfix` is unused
    /// upstream.
    static func secHeaderSize(variant: String, major: Int, minor: Int,
                              platform: Int) -> Int {
        if (variant, major, minor) == ("CSME", 14, 5) { return 0x34 }
        if (variant, major, minor) == ("CSSPS", 4, 4)
            || (variant, major, platform) == ("CSSPS", 5, 10) { return 0x28 }
        if (variant, major) == ("CSME", 11) || (variant, major) == ("CSTXE", 3)
            || (variant, major) == ("CSTXE", 4) || (variant, major) == ("CSSPS", 4)
            || (variant, major) == ("CSSPS", 5) { return 0x34 }
        if (variant, major) == ("CSME", 12) || (variant, major) == ("CSME", 13)
            || (variant, major) == ("CSME", 14) || (variant, major) == ("CSME", 15) {
            return 0x28 }
        return 0x28
    }

    /// `get_vfs_start_0`: whether the volume's files start at System offset 0.
    /// When true, upstream breaks out of the reserved-file walk before decoding
    /// anything (7888) — those volumes name their files through FTBL/EFST.
    static func vfsStartsAtZero(variant: String, major: Int, minor: Int) -> Bool {
        if (variant, major, minor) == ("CSME", 13, 30) { return true }
        if (variant, major) == ("CSME", 15) || (variant, major) == ("CSME", 16) {
            return true }
        if (variant, major) == ("CSME", 11) || (variant, major) == ("CSME", 12)
            || (variant, major) == ("CSME", 13) || (variant, major) == ("CSME", 14)
            || (variant, major) == ("CSTXE", 3) || (variant, major) == ("CSTXE", 4)
            || (variant, major) == ("CSSPS", 4) || (variant, major) == ("CSSPS", 5)
            || (variant, major) == ("CSSPS", 6) { return false }
        return true
    }

    // MARK: Reserved-file Integrity (upstream 7901–7929)

    /// True when a reserved file's *whole* content is data (no trailing
    /// Integrity table): file 5 (Quota Storage) at CSME < 12 / non-CSME, and
    /// file 4 (SVN Migration) at AFS/CSTXE (upstream 7914).
    private static func reservedCarriesNoIntegrity(fileIndex: Int,
                                                   variant: String,
                                                   major: Int, isAFS: Bool) -> Bool {
        (fileIndex == 5 && !(variant == "CSME" && major >= 12))
            || (fileIndex == 4 && isAFS)
    }

    /// Decode the trailing Integrity tables of the reserved low-level files a
    /// non-FTBL volume carries (1–5; 6/7 additionally at AFS). Files whose role
    /// carries no Integrity — the `reservedCarriesNoIntegrity` exemption — or
    /// that are absent/empty are omitted. `contentSize` is the file's data length
    /// with the Integrity header removed (upstream `file_data`).
    static func reservedIntegrity(files: [MFSLowLevelFile], variant: String,
                                  major: Int, minor: Int, hotfix: Int,
                                  platform: Int, isAFS: Bool)
        -> [MFSReservedFileIntegrity] {
        let sec = secHeaderSize(variant: variant, major: major, minor: minor,
                                platform: platform)
        var result: [MFSReservedFileIntegrity] = []
        for file in files where !file.content.isEmpty {
            guard file.index >= 1, file.index <= 5
                || (isAFS && (file.index == 6 || file.index == 7)) else { continue }
            guard !reservedCarriesNoIntegrity(fileIndex: file.index,
                                              variant: variant, major: major,
                                              isAFS: isAFS) else { continue }
            guard file.content.count >= sec else { continue }
            let tail = Data(file.content.suffix(sec))
            guard let table = integrityTable(tail) else { continue }
            result.append(MFSReservedFileIntegrity(
                fileIndex: file.index,
                contentSize: file.content.count - sec,
                integrity: table))
        }
        return result
    }

    // MARK: File-8 Home Directory (upstream 8021–8301)

    /// Detect the Home Directory record size by scanning the root buffer for its
    /// `.`/`..` marker rows, mirroring the upstream regex `\x2E[\x00\xAA]{10}` —
    /// a dot followed by ten bytes that are each 0x00 (NUL name padding) or 0xAA.
    /// The first match is the Current `.` name; the `..` name's *second* dot is
    /// the second match (its first dot is followed by a second dot, which is not
    /// in the pattern set), so `start₁ − start₀ − 1 == record size`. Returns nil
    /// when fewer than two markers exist — upstream prints an error and then
    /// crashes (8029); the engine reports no Home Directory instead.
    static func homeRecordSize(in content: Data) -> Int? {
        var matches: [Int] = []
        var index = 0
        while index + 11 <= content.count, matches.count < 2 {
            if content[index] == 0x2E {
                var isMarker = true
                for offset in 1...10 where content[index + offset] != 0x00
                    && content[index + offset] != 0xAA {
                    isMarker = false
                    break
                }
                if isMarker {
                    matches.append(index)
                    index += 11          // matches don't overlap (regex finditer)
                    continue
                }
            }
            index += 1
        }
        guard matches.count == 2 else { return nil }
        return matches[1] - matches[0] - 1
    }

    /// Decode the file-8 Home Directory of a legacy volume (upstream
    /// `mfs_home_anl`, 8152–8301). Returns nil when the volume isn't laid out for
    /// it (`vfs_starts_at_0` true), file 8 is absent/empty, or its marker pattern
    /// doesn't resolve (a dirty / non-home file-8). The tree in `entries` is
    /// decoded from the root buffer — file-8's content minus its own trailing
    /// Integrity table — with each Folder row's pointed-to file parsed as that
    /// folder's own rows.
    static func homeDirectory(files: [MFSLowLevelFile], variant: String,
                              major: Int, minor: Int, hotfix: Int,
                              platform: Int) -> MFSHomeDirectory? {
        guard !vfsStartsAtZero(variant: variant, major: major, minor: minor)
            else { return nil }
        let sec = secHeaderSize(variant: variant, major: major, minor: minor,
                                platform: platform)
        guard let file8 = files.first(where: { $0.index == 8 }),
              !file8.content.isEmpty else { return nil }
        guard let recordSize = homeRecordSize(in: file8.content) else { return nil }
        let dataLength = file8.content.count >= sec ? file8.content.count - sec : 0
        let rootBuffer = Data(file8.content.prefix(dataLength))
        let rootIntegrity = file8.content.count >= sec
            ? integrityTable(Data(file8.content.suffix(sec))) : nil
        let contentByIndex = Dictionary(uniqueKeysWithValues:
            files.map { ($0.index, $0.content) })
        let entries = walkHome(buffer: rootBuffer, recordSize: recordSize,
                               secHeaderSize: sec, contentByIndex: contentByIndex,
                               path: [8])
        return MFSHomeDirectory(homeRecordSize: recordSize,
                                rootRecordCount: rootBuffer.count / recordSize,
                                integrity: rootIntegrity, entries: entries)
    }

    /// Walk one Home Directory record buffer (the file-8 root, or a folder row's
    /// pointed-to file content) into the tree of `MFSHomeRecord` rows. `path` is
    /// the stack of file indexes currently being walked — recursion into a folder
    /// whose file is already on it would not terminate upstream (a dirty marker
    /// like CSME 12 file-25's `.\0faults…` self-reference is stopped by the NUL
    /// truncation below instead), so it yields empty children rather than
    /// re-walking. This, and truncating `FileName` at its first NUL before the
    /// marker test / naming, are the two documented divergences from a literal
    /// transcription (see `MFSHomeDirectory`).
    private static func walkHome(buffer: Data, recordSize: Int,
                                 secHeaderSize: Int,
                                 contentByIndex: [Int: Data],
                                 path: [Int]) -> [MFSHomeRecord] {
        guard recordSize > 0, buffer.count >= recordSize else { return [] }
        var entries: [MFSHomeRecord] = []
        for i in 0..<(buffer.count / recordSize) {
            let base = i * recordSize
            let slice = buffer.subdata(in: base..<(base + recordSize))
            let flags = homeRecordFlags(slice)
            let nameOffset = recordSize - 12          // FileName is the last 12 bytes
            let nameBytes = slice.subdata(in: nameOffset..<(nameOffset + 12))
            let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
            // Current/Parent markers — never surfaced, never re-walked.
            if name == "." || name == ".." { continue }

            // The row's pointed-to file content; Integrity-protected rows strip
            // that file's trailing table (upstream 8203–8205).
            let raw = contentByIndex[flags.fileIndex] ?? Data()
            var fileData = raw
            var fileIntegrity: MFSIntegrityTable? = nil
            if flags.integrity {
                if raw.count >= secHeaderSize {
                    fileData = Data(raw.prefix(raw.count - secHeaderSize))
                    fileIntegrity = integrityTable(Data(raw.suffix(secHeaderSize)))
                } else {
                    fileData = Data()   // upstream content[:-sec] on a short file → empty
                }
            }

            var children: [MFSHomeRecord] = []
            if flags.recordType == 1, fileData.count >= recordSize,
               !path.contains(flags.fileIndex) {
                children = walkHome(buffer: fileData, recordSize: recordSize,
                                    secHeaderSize: secHeaderSize,
                                    contentByIndex: contentByIndex,
                                    path: path + [flags.fileIndex])
            }
            let saltWidth = recordSize == 0x1C ? 6 : 2      // UnknownSalt u16 vs u16[3]
            let salt = leInt(slice, at: 0x0A, length: saltWidth)
            entries.append(MFSHomeRecord(
                fileIndex: flags.fileIndex, name: name,
                isFolder: flags.recordType == 1,
                fileSystemID: flags.fileSystemID,
                unixRights: flags.unixRights,
                ownerUserID: Int(le16(slice, at: 6)),
                ownerGroupID: Int(le16(slice, at: 8)),
                integrityProtection: flags.integrity,
                encryptionProtection: flags.encryption,
                antiReplayProtection: flags.antiReplay,
                accessUnknown0: flags.unknown0,
                accessUnknown1: flags.unknown1,
                keyType: flags.keyType,
                integritySalt: flags.integritySalt,
                unknownSalt: salt,
                size: fileData.count,
                integrity: fileIntegrity,
                children: children))
        }
        return entries
    }

    /// The flag bit-fields of one `MFS_Home_Record` (shared by the 0x18/0x1C
    /// structs): FileInfo u32 — FileIndex 12b / IntegritySalt 16b / FileSystemID
    /// 4b — and AccessMode u16 — UnixRights 9b / Integrity 1b / Encryption 1b /
    /// AntiReplay 1b / Unknown0 1b / KeyType 1b / RecordType 1b / Unknown1 1b.
    private static func homeRecordFlags(_ slice: Data)
        -> (fileIndex: Int, integritySalt: Int, fileSystemID: Int,
            unixRights: Int, integrity: Bool, encryption: Bool, antiReplay: Bool,
            unknown0: Bool, unknown1: Bool, keyType: Int, recordType: Int) {
        let fileInfo = Int(le32(slice, at: 0))
        let access = Int(le16(slice, at: 4))
        return (fileIndex: fileInfo & 0xFFF,
                integritySalt: (fileInfo >> 12) & 0xFFFF,
                fileSystemID: (fileInfo >> 28) & 0xF,
                unixRights: access & 0x1FF,
                integrity: access & (1 << 9) != 0,
                encryption: access & (1 << 10) != 0,
                antiReplay: access & (1 << 11) != 0,
                unknown0: access & (1 << 12) != 0,
                unknown1: access & (1 << 15) != 0,
                keyType: (access >> 13) & 1,
                recordType: (access >> 14) & 1)
    }

    // MARK: MFS_Integrity_Table (0x28 / 0x34)

    /// Decode a trailing `MFS_Integrity_Table` — 0x28 (HMAC-MD5: hmac + Flags +
    /// ARRandom + ARCounter + AES-GCM nonce) or 0x34 (HMAC-SHA-256: hmac + Flags +
    /// 128-bit ARValues/CTR-nonce region). Returns nil for any other length.
    static func integrityTable(_ table: Data) -> MFSIntegrityTable? {
        let flagsRaw: Int
        let hmacBytes: Data
        let arRandom: Int
        let arCounter: Int
        let nonceBytes: Data
        let encryptionBit: Int
        let arIndexShift: Int
        let svnShift: Int
        switch table.count {
        case 0x28:
            flagsRaw = Int(le32(table, at: 0x10))
            hmacBytes = table.subdata(in: 0..<16)
            arRandom = Int(le32(table, at: 0x14))
            arCounter = Int(le32(table, at: 0x18))
            nonceBytes = table.subdata(in: 0x1C..<0x28)
            encryptionBit = 3      // Unknown0/AR/Unknown1 then Encryption
            arIndexShift = 11
            svnShift = 22
        case 0x34:
            flagsRaw = Int(le32(table, at: 0x20))
            hmacBytes = table.subdata(in: 0..<32)
            arRandom = Int(le32(table, at: 0x24))    // ARValues_Nonce word 0
            arCounter = Int(le32(table, at: 0x28))   // ARValues_Nonce word 1
            nonceBytes = table.subdata(in: 0x24..<0x34)
            encryptionBit = 2      // Unknown0/AR then Encryption
            arIndexShift = 10
            svnShift = 21
        default:
            return nil
        }
        return MFSIntegrityTable(
            size: table.count,
            hmacHex: hex(hmacBytes),
            flagsRaw: flagsRaw,
            antiReplayProtection: flagsRaw & 0x2 != 0,
            encryptionProtection: flagsRaw & (1 << encryptionBit) != 0,
            antiReplayIndex: (flagsRaw >> arIndexShift) & 0x3FF,
            securityVersion: (flagsRaw >> svnShift) & 0xFF,
            arRandom: arRandom,
            arCounter: arCounter,
            nonceHex: hex(nonceBytes))
    }

    // MARK: - little-endian reads (bounds-checked)

    private static func le16(_ data: Data, at index: Int) -> UInt16 {
        guard index >= 0, index + 2 <= data.count else { return 0 }
        return UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
    }

    private static func le32(_ data: Data, at index: Int) -> UInt32 {
        guard index >= 0, index + 4 <= data.count else { return 0 }
        return UInt32(data[index])
            | (UInt32(data[index + 1]) << 8)
            | (UInt32(data[index + 2]) << 16)
            | (UInt32(data[index + 3]) << 24)
    }

    /// `length` bytes at `index`, little-endian (up to an 8-byte salt's width
    /// here, so no overflow in an `Int`).
    private static func leInt(_ data: Data, at index: Int, length: Int) -> Int {
        var value = 0
        for byte in data[index..<(index + length)].reversed() {
            value = value * 256 + Int(byte)
        }
        return value
    }

    /// Uppercase natural-order hex (the codebase's digest-hash convention —
    /// e.g. `imageHash`, `Digest.sha256Hex`), *not* upstream's
    /// `int.from_bytes(…, 'little')` byte reversal.
    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}
