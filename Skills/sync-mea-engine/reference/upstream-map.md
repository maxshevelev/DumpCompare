# Upstream map — `MEA.py` → Swift engine

The ledger the `sync-mea-engine` skill ports against. Left column is upstream
(`MEA.py`, single ~14k-line file); right is the intended Swift home under
`Packages/MEFirmware/Sources/MEFirmware/`. **Keep this file current**: mark a
symbol `ported` in the Status column when you port it, and add new upstream
symbols here (the `check` report lists them) before or while porting them.

Measured at upstream `v1.312.0 r378` (2026-09): ~202 top-level `class`
(most are `ctypes.LittleEndianStructure` layouts) and ~110 top-level `def`.
Grouped by concern; `class` names list the notable ones, `…` means "and its
`_Flags`/`_GetFlags`/`_Mod`/`_R2`/`_R3` siblings".

Status: `—` not yet ported · `ported` done · `n/a` deliberately not ported.

## Container finders (module-load regexes → anchors)

Upstream anchors locate structures inside a region. DumpCompare already has a
UEFI/IFWI tree, so prefer reusing its region offsets; scan only inside a raw
ME region. Swift home: `Anchors.swift` (byte-pattern scans) + reuse of
`UEFIImage` region results.

| Upstream anchor (regex) | Finds | Swift home | Status |
|---|---|---|---|
| `man_pat` `$MN2`/`$MAN`, VEN `0x8086` | CSE/GSC/IUP manifest | `Layout/Manifest.swift` (anchor scan inside) | ported |
| `bccb_pat` placeholder `$MN2` VEN `0xBCCB` | key-manifest *placeholder* scan (`\xCB\xBC.{9}\x00\$MN2`, MEA.py 11009) — used inside the module key-usage / `oem.key`-empty passes of `cse_unpack` (6015, 6760), which sit behind the `.met`/key-usage boundary (row 73); no standalone engine fact | — | deferred — unpack key-usage heuristic (rows 71/73/134) |
| `cpd_pat` `$CPD` | Code Partition Directory | `Partition/CPD.swift` (scan inside) | ported |
| `fpt_pat` `$FPT` | Flash Partition Table | `Layout/FPT.swift` (anchor scan inside) | ported |
| `bpdt_pat` | Boot Partition Descriptor — signature scan `\xAA\x55[\x00\xAA]\x00…` (MEA.py 11018) ported as `IFWI.firstBpdt` over each non-empty CSE-LT Boot slot; header v1/v2 + entries read by `IFWI.bpdtTable` | `Layout/IFWI.swift` (`firstBpdt`, `bpdtTable`) | ported |
| `orom_pat` PCIR | GSC Option ROM | `IUP/OROM.swift` (fixed-offset signature scan inside) | ported |
| `fd_pat` `5AA5F00F…` | Flash Descriptor | whole-flash ME-region read in `Layout/IFWI.swift` (`FlashDescriptor.meRegion`) | ported (ME-region base only) |
| `pr_man_*_pat` + `pr_cpd_parts` | probable-IUP-part scans (`cpd_pat` + `.{1}` + one of PMCP/PCOD/PCHC/SPHY/PPHY/PHYP/NPHY, MEA.py 11032) used to locate IUP `$CPD`s when no `$FPT`/CSE-LT structure anchors them (11437) — the IUP CPD decode itself already runs off the operational-manifest scan (IUP rows); the unanchored probable-part fallback has no fixture/oracle | — | deferred — free-blob scan (unanchored-part fallback only) |

## Flash & IFWI layout

| Upstream symbol(s) | Models | Swift home | Status |
|---|---|---|---|
| `FPT_Pre_Header`, `FPT_Header`, `FPT_Header_21` (+`_Flags`) | FPT header — shared v1/2/2.1 decode done; v2.1 redundancy/CRC-32 & `_Flags` bitfields deferred | `Layout/FPT.swift` | ported |
| `FPT_Entry` | FPT partition entry (name/owner/offset/size/tokens/scratch/flags) | `Layout/FPT.swift` | ported |
| `BPDT_Header_1`, `BPDT_Header_2`, `BPDT_Entry` | BPDT — **decode ported** (`IFWI.firstBpdt` ports `bpdt_pat` 11018; `bpdtTable` reads header v1/v2 by the +0x06 tag + `DescCount` entries, MEA.py 11850–12107): each non-empty CSE-LT Boot partition's BPDT surfaced as `FirmwareAnalysis.bootPartitions` (name via `$CPD`-header read else `bpdt_dict`, offset = base+raw, empty flag); 1.7 CRC-32 (`checksumValid`, fact only — upstream never errors on it) | `Layout/IFWI.swift` | ported |
| `CSE_Layout_Table_16`, `_17` | IFWI layout 1.6/1.7 — **full decode ported** (`IFWI.layoutTable`, MEA.py 11507–11605): version probe (drives `fpt_start`), Data/Boot1-5(+Temp/ELog) partition inventory (`cse_lt_hdr_info`), 1.7 CRC-32 validity + CSE-Redundancy flag; surfaced as `FirmwareAnalysis.cseLayoutTable`, invalid 1.7 CRC → Issue id 10 | `Layout/IFWI.swift` | ported |
| `fd_anl_init`, `fd_anl_rgn` | Flash Descriptor region parse — FLREG2 Engine/Graphics (ME) base/size read, the one fact `fpt_start` needs (MEA.py 10045) | `Layout/IFWI.swift` (`FlashDescriptor.meRegion`) | ported (ME-region only) |
| `CSE_Layout_*` flag classes | per-format bitfields — the meaningful decode (redundancy from the 1.7 Flags bit0, 1.7 CRC-32 validity over `[0x10:0x14]` zeroed + `[0x18:…]`) is ported in `IFWI.layoutTable`; the remaining per-field flag-table *display* of each header stays behind the DB/UI label layer | `Layout/IFWI.swift` (`layoutTable`) | partial |

## CSE manifest & partitions

| Upstream symbol(s) | Models | Swift home | Status |
|---|---|---|---|
| `MN2_Manifest_R0`, `_R1`, `_R2` (+ flags) | `$MN2`/`$MAN` pre-CSE R0, CSE R1, R2 — R0/R1/R2 dispatch, version/SVN/date/MEU + RSA key & signature slices; full `_Flags` bitfield table deferred | `Layout/Manifest.swift` | ported |
| `SKU_Attributes` (+flags) | pre-CSE `$SKU` — **decode ported** (`PreCSEME`, MEA.py 1044–1101 structs + main-flow 12644–13023): byte-scan `\$SKU[\x03-\x04]\x00\x00\x00` from the manifest, `FWSKUAttrib` split exactly as upstream's ctypes BigEndianStructure (Value1 bytes0–2, 8 slim/patsburg/etc 1-bit + SKUType/SKUSize byte4, Value10 bytes5–7; `sku_me` = big-endian u32 for ME 2–6) → ME 2–10 top-level `sku` + `platform` rows (oracle: T450 ME10 → 5MB / WPT-LP); R0 VCN (u32 @+0x34) surfaced as `ManifestSummary.vcn` | `Identify/PreCSEME.swift` + `Layout/Manifest.swift` | ported |
| `MME_Header_Old`, `MME_Header_New` | pre-CSE `$MME` — **decode ported** (`PreCSEModule`, MEA.py 1107/1125 structs + 12256–12369): the R0 `.me` manifest's module directory surfaced as `FirmwareAnalysis.mmeDirectory` — list head `manifest base + HeaderLength*4 + 0xC`, `MME_Header_New` after `$MN2` (ME 6–10, stride 0x60) / `MME_Header_Old` after `$MAN` (ME 2–5, stride 0x50), decoded verbatim up to `Manifest.numModules` with the sanity break on a non-`$MME` row (note Issue id 11 when truncated); fields never resolved to content (OffMN2 is not unique); `Manifest.numModules` added to the R0 decode | `Identify/PreCSEModule.swift` + `Models/FirmwareAnalysis.swift` | ported |
| `MCP_Header` | `$MCP` — **decode ported** (`PreCSEModule`, MEA.py 1145 struct + 12326): trailing header one 0x60 stride past the declared `$MME` directory of an `$MN2` (ME 8–10), surfaced as `MMEModuleDirectory.mcp` (HeaderSize/CodeSize/Offset_Code_MN2/Offset_Part_FPT/hash); oracle: T450 ME10 `$MCP` @0x1605F0 — 8 modules, CodeSize 0xAF6F4, OffCodeMN2 0x90C | `Identify/PreCSEModule.swift` + `Models/FirmwareAnalysis.swift` | ported |
| `CPD_Header_R1`, `CPD_Header_R2`, `CPD_Entry` (+`_OffsetAttrib`) | `$CPD` v1/v2 directory — header R1/R2 decode, entry names/offsets, owning-`$CPD` back-scan (`findPrecedingCPD`), R1 Checksum-8 + R2 CRC-32 validation (`cpd_chk`) | `Partition/CPD.swift` | ported |
| `RBE_PM_Metadata`, `_R2`, `_R3`, `_R4` | rbe/pm module metadata — **decode ported** (`RBEPMMetadataParser`, MEA.py 9711 + structs 5161–5295): scan the operational partition's `pm`/`rbe` module body for three consecutive `VEN_ID` 0x8086 words spaced `stride − 2` apart and pick the struct by which spacing matches (R1 0x48 extended SHA-256 / R2 0x30 compact SHA-256 / R3 0x58 extended SHA-384 / R4 0x40 compact SHA-384), chain every contiguous 0x8086 row; hash hex = the LE-int uppercase form upstream prints (`int.from_bytes(Hash,'little')`). Uncompressed bodies decode structurally; Huffman ones (the real dumps) decompress against the `.met`-declared sizes + the live dictionary. Surfaced as `FirmwareAnalysis.rbePmMetadata` (result-model rev 14) | `Partition/RBEPM.swift` + `Models/FirmwareAnalysis.swift` + analyzer wiring | ported |
| `get_rbe_pm_met`, `rbe_pm_met_hashes` | the table scan + per-row hash surface of the row above (`rbe_pm_met_hashes`'s leftover-hash consumer is the module-without-metadata validation, which stays behind the `.met` phase boundary); full row scalars mirror the structs | `Partition/RBEPM.swift` | ported |
| `cpd_entry_num_fix`, `cpd_size_calc`, `cpd_chk` | $CPD integrity — `cpd_chk` R1 Checksum-8 + R2 CRC-32 validated (`CPDParser.checksumValid`); `cpd_entry_num_fix`/`cpd_size_calc` ported as *probes* → integrity Issues (the decoder locates content per-entry, so it never needs the sequential-unpack repair to grow the module list) | `Partition/CPD.swift` + `Crypto/Checksum.swift` (`CRC32`) | ported |
| operational `$CPD` → `CodePartition` module list | the chosen partition's module directory (name/offset/IsHuffman/size + header) surfaced in the UI result model — Stage-2 of the `$CPD` port; each metadata-carrier module row (`kernel.met`, …) carries its decoded body chain and the manifest `.man` row repeats `CodePartition.extensions` (row below) | `Models/FirmwareAnalysis.swift` (`CodePartition`, `CPDModule.extensions`) + analyzer wiring | ported |

## CSE/GSC file system (VFS, MFS, FTBL/EFST, extensions)

| Upstream symbol(s) | Models | Swift home | Status |
|---|---|---|---|
| `FTBL_Header`, `FTBL_Table`, `FTBL_Entry` | CSE File Table | `FileSystem/FTBL.swift` | deferred — lives in the compressed `vfs`/`fpf` module bodies (row 67 note) |
| `EFST_Header`, `EFST_Table`, `EFST_Entry` | CSE File System Table | `FileSystem/EFST.swift` | deferred — same |
| `EFS_Page_Header`, `EFS_Page_Footer`, `EFS_File_Metadata` | EFS page/footer | `FileSystem/EFS.swift` | deferred — same |
| `MFS_Volume_Header`, `MFS_Page_Header` | MFS volume + page header decode: page inventory (System/Data via FirstChunkIndex), per-page System chunk-index de-obfuscation (`Crc16_14`), System-area chunk assembly, volume header (Signature/FTBL dict/plat/res/VolumeSize/file-record count) + FAT `usedFileCount` from chunk 0. Byte-verified on **both** real dumps — CSME 12.0.3 (512 records/210 used, dict 1/0/0 → `usesFTBL` false) and CSME 15.0.30 (1024/136, dict 0x0A/0x04 → `usesFTBL` true). All 445 CSME-12 System chunks validate their stored chunk CRC-16 | `FileSystem/MFS.swift` (`MFSParser`, `CRC16_14`) | partial |
| `MFS_Config_Record_*`, `MFS_Home_Record_*`, `MFS_Integrity_Table_*`, `MFS_Backup_Header_R0/R1`, `MFS_Backup_Entry` | MFS low-level *file* walk (FAT chain → home/config/integrity/backup records) | `FileSystem/MFS.swift` | deferred — needs `FileTable.dat` naming (row 93) |
| `UTFL_Header`, `FITC_Header` | misc CSE tables | `FileSystem/Misc.swift` | deferred — same |
| (deferral note) | The raw `MFS` region exists on **both** real dumps (CSME 12 & 15), but the newer EFST/EFS/FTBL/UTFL/FITC tables and the MFS low-level *file* walk sit inside the Huffman-compressed `vfs`/`fpf`/module bodies — decoding them needs the decompression size targets (Phase 8) plus `FileTable.dat` naming (row 93), so they stay open | — | deferred |
| `CSE_Ext_00` … `CSE_Ext_37`, `CSE_Ext_544F4F46` (+`_Mod`/`_R2` variants) | the 0x00–0x25+ extension blocks of a CPD entry, in **both** `.man` bodies (chain after the manifest struct) and `.met` companion bodies (chain = the body itself, from `entry.offset`); walker + per-tag header decoders (`0x00`/`0x02`/`0x03`/`0x04`/`0x05`/`0x06`/`0x07`/`0x08`/`0x09`/`0x0A`/`0x0B`/`0x0C`/`0x0D`/`0x0F`/`0x16`; 0x0A Module Attributes is the universal `.met` lead block, revision-aware R1 0x38/SHA-256 vs R2 0x48/SHA-384); the row-bearing `.met` tags `0x04` (SharedLibrary, 0x1C header-only) /`0x05` (ProcessAttributes + `_Mod` GroupID rows, stride 0x02) /`0x06` (ThreadAttributes + stride 0x10 rows) /`0x07` (DeviceTypes + stride 0x08 rows) /`0x08` (MmioRanges + stride 0x0C rows) /`0x09` (SpecialFiles + stride 0x18 rows, 12-byte names) /`0x0B` (LockedRanges + stride 0x08 rows) /`0x0D` (UserInfo + stride 0x10 `_Mod_R2` on csme12/15, else `_Mod` 0x34 rows with char[36] WorkingDir) decode their headers + `_Mod` rows; the `_R2`/`_R3` row variants for 0x05/0x07 (GSC/OROM-100 families) and the bitfield label dicts (process flags etc.) stay deferred | `Partition/Extensions.swift` — `decode` (.man) + `decodeMetBody` (.met) over shared `walkBlocks` | ported |
| `cse_part_inid`, `ext_anl`, `mod_anl`, `mfs_anl`, `mfs_home_anl`, `mfs_cfg_anl`, `efs_anl`, `fitc_anl`, `mfs_home13_anl`, `get_sec_hdr_size`, `get_cfg_rec_size`, `get_vfs_start_0`, `get_mfs_anl` | walking/decode drivers — the *structural portions* already split out: `ext_anl`/`mod_anl` row facts (70), `mfs_anl` volume decode (72), CSE-LT/BPDT (40–41); the low-level file/config walkers (`mfs_home*`, `mfs_cfg`, `efs`, `fitc`) sit inside the compressed module bodies + need `FileTable.dat` naming, so they follow rows 63–69 | `FileSystem/*.swift` | deferred — with the file walk (rows 63–69/96) |
| `mfs_anl` (structural portion) | MFS page scan → System/Data sort → `Crc16_14` de-obfuscation → System-area assembly → volume header + FAT facts (surfaced as `FirmwareAnalysis.mfsVolume` + an `Issue` when a present MFS region fails to decode) | `Engine/MEFirmwareAnalyzer.swift` Stage 1 | partial |
| `get_key_usages`, `mfs_txt`, `mfs_write`, `mfs_anl_msg`, `efs_anl_msg` | manifest key-usage pass + MFS text writers — `get_key_usages` keys off the module key-manifest scan (row 26) inside `cse_unpack`; the `_txt`/`_write`/`_msg` helpers are text/report sinks | — | deferred — lower priority (unpack key usage + text sinks) |

## Independent (IUP) firmware — PMC / PCHC / PHY / OROM

| Upstream symbol(s) | Models | Swift home | Status |
|---|---|---|---|
| `GSC_Info_FWI`, `GSC_Info_IUP` | GSC firmware image info — **decode ported** (`info_anl`, MEA.py 9134 + structs 358/410): an FPT partition literally named "INFO" (only GSC-family images carry one, so the name gates it) decodes as a u32 revision — 1 expected, warning Issue id 12 otherwise, decode still proceeds — then one `GSC_Info_FWI` (0x20) and the trailing `GSC_Info_IUP` rows (0x10 each) to the partition end, surfaced as `FirmwareAnalysis.gscInfo` (result-model rev 12). Raw ints + NUL-trimmed ASCII names; the FWType/FWSKU ext15 labels stay raw. Fixture-only — no GSC dump among the oracles | `IUP/GSCInfo.swift` + `Models/FirmwareAnalysis.swift` | ported |
| `GSC_OROM_Header`, `GSC_OROM_PCI_Data` | Option ROM image/PCIR — **decode ported** (`orom_pat` scan 11021 over a region identifying as the `.orom` family, MEA.py 11451; whole-image decode 12149–12179): each match reads the 0x1C `GSC_OROM_Header` (struct 433) and — at `match + PCIDataHdrOff` — the 0x1C `GSC_OROM_PCI_Data` (struct 466), plus `data_off = max(PCIDataHdrOff + PCIR.PCIDataHdrLen, EFIImageOffset, OROMPayloadOff)` and the `$CPD` payload probe (12169–12170), surfaced as `FirmwareAnalysis.oromImages` (result-model rev 13). Fixture-only — no OROM dump among the oracles (`.orom` family identity needs a DB RSA-hash match, so the analyzer gate is dormant) | `IUP/OROM.swift` + `Models/FirmwareAnalysis.swift` | ported |
| `pmc_anl`, `pmc_parse`, `pchc_anl`, `pchc_parse`, `phy_anl`, `phy_parse`, `pch_init_anl`, `info_anl` | PMC/PCHC/PHY/PCH init decode — **family descriptor ported** (`IUP/IUPDescriptor`, MEA.py 9164/9277/9342): Chipset Support platform + Chipset SKU letter + PMC chipset stepping from the manifest identity, mirroring the per-token SKU/stepping branches and the main-summary row gating (SKU hidden for APL/BXT/GLK/DG, stepping hidden for DG). Fills the top-level `platform`/`sku` + new `chipsetStepping` (result-model rev 9). Oracle-verified on the three 1.bin IUP partitions. The `_parse` loops and `pch_init_anl` (MFS PCH-init → CSE `platform`) remain open (`info_anl` → row 79) | `IUP/IUP.swift` + analyzer wiring | partial |
| `chk_iup_size` | IUP engine-end vs file-end compare (MEA.py 9655) — emits *display* Warning/Note text about excess padding or data loss (and optionally strips padding in a debug `--check` rewrite); no model fact, no fixture value | — | deferred — display/lab machinery |
| `fovd_clean` | FOVD(new)/NVKR(old) dirty/clean Bool (MEA.py 10113) from the GSC/IUP `$FPT`-partition walk, consumed only to print a clean/dirty status — no model fact, and its input is the per-family partition inventory behind the pipeline rows | — | deferred — display (per-family partition walk, rows 134/135) |

## Identification & database layer

| Upstream symbol(s) | Models | Swift home | Status |
|---|---|---|---|
| `get_variant` | RSA-pubkey-hash → variant + shared-pre-key override + release; *module-name fallback deferred to the $CPD port* | `Identify/Identifier.swift` (lookup + small table, not an if-chain) | ported* |
| `get_cse_db`, `release_fix` | DB query for release/SKU — release + platform/SKU cell (cell 2 PCH platform) feed `Identify/SKU.swift`; `release_fix` ported (rsa_pre_keys) | `Identify/Identifier.swift`, `Identify/SKU.swift` | ported* |
| `get_csme12_sku`, `sku_db_cse` | CSME 12+ SKU table logic — `SKU.csme`: 0x0C/0x0F_R2 type label ladder + DB-cell override + CSME 12.0.0-alpha `SKUPlatform`/caps fallback + 14.5 H→V & 13 Slim-LP→N corrections; fills `FirmwareAnalysis.sku` | `Identify/SKU.swift` | ported |
| `note_new_fw` | report firmware absent from DB/repo — surfaced as a `.note` `Issue` by the pipeline | `Identify/Identifier.swift` (note text) | ported* |
| `get_db_json_obj` | section lookup in MEA.dat — `rsa_pre_keys` block parsed | `Data/MEADatabase.swift` | ported* |
| `get_fw_ver` | format version string (family zero-padding) | deferred — display text, needs the DB label layer | — |
| `cse_huffman_dictionary_load` | pick Huffman dict by (variant,major,minor) | `Decompress/Huffman.swift` (`HuffmanDictionaries.parse`/`version`) | ported |
| (FileTable.dat loaders, `check_ftbl_id`, `check_ftbl_pl`) | MFS/FTBL low-level file naming (name the FAT-chain files the MFS walk reads — *not* the `$CPD` module names, which already live in the directory) | `DB/FileTable.swift` | deferred — with the MFS file walk (rows 66–67) |
| `mfs_txt_json…`, `ext_table`, `pt_html`, `pt_json`, `struct_json`, `get_struct`, `ext_table` | table/JSON rendering of structs | **n/a — UI renders the result model instead** | n/a |

`ported*` = the identification core is in; the marked piece waits on the `$CPD`
port (module-name heuristics) or the display/DB-label layer.

## Crypto & checksums

| Upstream symbol(s) | Models | Swift home | Status |
|---|---|---|---|
| `sha_1`, `sha_256`, `sha_384`, `get_hash`, `calc_hash`, `calc_hash_hex`, `md5` | hashing — raw + uppercase-hex SHA-1/SHA-256/SHA-384 (`calc_hash_hex`/`calc_hash` feed the PSS check; MD5 unused) | `Crypto/Digest.swift` | ported |
| `mc_chk32`, `Crc16_14` | checksums — `mc_chk32` = `CRC32.crc32` (zlib-equal, fills `checksums.crc32`); `Crc16_14` unused | `Crypto/Checksum.swift` | ported* |
| `rsa_sig_val`, `pss_mgf`, `pss_verify`, `pss_final_validate`, `unmask_DB`, `parseSign`, `get_salt` | RSA-PSS signature validation — Montgomery modpow (`BigInt.powerMod`) replaces Python's `pow`; dispatch `$MAN`→SHA-1 / `$MN2` 2048→SHA-256 (PKCS#1 v1.5) / 3072 + unknown→SHA-384 EMSA-PSS; empty-RSA block → valid, even/zero modulus → not checkable (nil); fills `rsaSignatureValid` | `Crypto/RSA.swift` | ported |
| `release_fix` (key-hash tie-out) | RSA-key → release — lives with identification (calls into `MEADatabase.isPreProductionKey`) | `Identify/Identifier.swift` | ported |

## Decompression

| Upstream symbol(s) | Models | Swift home | Status |
|---|---|---|---|
| `cse_huffman_decompress` | Huffman module decompression | `Decompress/Huffman.swift` (`HuffmanDecoder`) | ported |

The port exposes a `Data`-returning API (`decompress(module:compressedSize:decompressedSize:dictionary:) -> (output, clean)`),
never early-returns — a chunk that runs out of stream / overflows / hits an unknown
codeword is 0x7F-filled to its 0x1000 boundary and later chunks still decode (upstream
`huff_error`). Dictionaries come live over `MEADataSource.huffmanDictionaries()`
(`MEAGitHubDataRepository`, single-flight fetch of `Huffman.dat`); the analyzer runs a
best-effort Phase 8 integrity check (Issue id 7) on declared-Huffman modules that have a
`.met` 0x0A advertising Huffman + no encryption — oracle: CSME 12.0.3 22/22 modules
decompress to their exact `.met` sizes, clean. (LZMA — upstream `mod_comp == 2` — is not
ported here; it decompresses whole-module with Foundation `Compression`/`lzma` when a later
phase needs it.)

## Analysis pipeline (entry flow)

| Upstream symbol(s) | Models | Swift home | Status |
|---|---|---|---|
| `get_manifest`, `get_fpt`, `get_cpd`, `get_bpdt` | region scanning dispatch — `get_fpt`, `get_manifest`, `get_cpd` decode live in the parsers they dispatch (`Layout/FPT.swift`, `Layout/Manifest.swift`, `Partition/CPD.swift`); `get_bpdt`'s v1/v2 header dispatch is `IFWI.bpdtTable` (row 29) | `Engine/MEFirmwareAnalyzer.swift` (stage 1 scan) | ported |
| `$FPT` re-anchor → operational partition (11802–11825) + owning-`$CPD` name fallback | pick the *operational* `$MN2` copy to identify (FTPR over the earlier RBEP recovery copy; whole-flash `$FPT` lists only internal volumes) | `Engine/ManifestSelection.swift` | ported |
| `cse_unpack`, `cse_part_inid`, `mod_anl`, `ext_anl` | the full GUI file-extraction unpack (incl. the `$MN2_Stage1` module-name pass and region file writes) — an output feature, not an analysis fact; the decode drivers it calls are already split into rows 70/72/133/81, so what remains is the extraction writer | `Engine/Unpack.swift` | deferred — file-extraction/repair writer (not engine-analysis facts) |
| per-family analysis chain (`pmc_*`, `pchc_*`, `phy_*`, `gsc_*`) | dispatch to the IUP parsers — the facts per family already live in the descriptor/decode rows (IUP 81, GSC 79/80), so this is the thin print/orchestration driver of the no-region-split pipeline | `Engine/Pipeline.swift` | deferred — print/orchestration driver |

## Not ported on purpose

`mea_help`, `mea_hdr`, `mea_hdr_init`, `mea_exit`, `mea_upd_check`,
`mass_scan`, `MEA_Param`, `input_col`, `copy_on_msg`, `show_exception_and_exit`,
colour/CLI helpers → replaced by DumpCompare's UI. `Thread_With_Result` →
DumpCompare's own concurrency.

## Data files consumed (not code)

`MEA.dat` (firmware DB + `RSAPKEY_*` + `rsa_pre_keys` + `cse_known_bad_hashes`
sections), `Huffman.dat` (decompression dictionaries), `FileTable.dat` (VFS
name map). **Not stored or snapshotted in the project.** The module fetches
them live from the MEAnalyzer repo on first use (single-flight, in-memory
cache, no disk) and parses them in the DB layer — see reference/async-api.md.
`MEA.dat` is parsed generically (revision header, `_`-separated entries,
`RSAPKEY_*` and `*** section ***` lines, and the `rsa_pre_keys` JSON block
between its `*BGN`/`*END` markers), so database additions never need a code
change; only a change to that *grammar* does.
