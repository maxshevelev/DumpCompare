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
| `bccb_pat` placeholder `$MN2` VEN `0xBCCB` | manifest placeholder | `Anchors.swift` | — |
| `cpd_pat` `$CPD` | Code Partition Directory | `Partition/CPD.swift` (scan inside) | ported |
| `fpt_pat` `$FPT` | Flash Partition Table | `Layout/FPT.swift` (anchor scan inside) | ported |
| `bpdt_pat` | Boot Partition Descriptor | IFWI layer / UEFI tree | — |
| `orom_pat` PCIR | GSC Option ROM | `Anchors.swift` | — |
| `fd_pat` `5AA5F00F…` | Flash Descriptor | UEFI tree (already parsed) | n/a |
| `pr_man_*_pat` + `pr_cpd_parts` | probable manifests/IUP parts | `Anchors.swift` | — |

## Flash & IFWI layout

| Upstream symbol(s) | Models | Swift home | Status |
|---|---|---|---|
| `FPT_Pre_Header`, `FPT_Header`, `FPT_Header_21` (+`_Flags`) | FPT header — shared v1/2/2.1 decode done; v2.1 redundancy/CRC-32 & `_Flags` bitfields deferred | `Layout/FPT.swift` | ported |
| `FPT_Entry` | FPT partition entry (name/owner/offset/size/tokens/scratch/flags) | `Layout/FPT.swift` | ported |
| `BPDT_Header_1`, `BPDT_Header_2`, `BPDT_Entry` | BPDT 1.6/1.7/2.0 | `Layout/IFWI.swift` | — |
| `CSE_Layout_Table_16`, `_17` | IFWI layout 1.6/1.7 | `Layout/IFWI.swift` | — |
| `fd_anl_init`, `fd_anl_rgn` | Flash Descriptor region parse | UEFI layer | n/a |
| `CSE_Layout_*` flag classes | per-format bitfields | `Layout/*.swift` | — |

## CSE manifest & partitions

| Upstream symbol(s) | Models | Swift home | Status |
|---|---|---|---|
| `MN2_Manifest_R0`, `_R1`, `_R2` (+ flags) | `$MN2`/`$MAN` pre-CSE R0, CSE R1, R2 — R0/R1/R2 dispatch, version/SVN/date/MEU + RSA key & signature slices; full `_Flags` bitfield table deferred | `Layout/Manifest.swift` | ported |
| `SKU_Attributes` (+flags) | pre-CSE `$SKU` | `Manifest.swift` | — |
| `MME_Header_Old`, `MME_Header_New` | ME2-10/TXE/SPS `$MME` | `Manifest.swift` | — |
| `MCP_Header` | | `Manifest.swift` | — |
| `CPD_Header_R1`, `CPD_Header_R2`, `CPD_Entry` (+`_OffsetAttrib`) | `$CPD` v1/v2 directory — header R1/R2 decode, entry names/offsets, owning-`$CPD` back-scan (`findPrecedingCPD`), R1 Checksum-8 + R2 CRC-32 validation (`cpd_chk`) | `Partition/CPD.swift` | ported |
| `RBE_PM_Metadata`, `_R2`, `_R3`, `_R4` | rbe/pm module metadata — **deferred to Phase 8**: `get_rbe_pm_met` reads the *decompressed* `pm`/`rbe` body (`pm` is Huffman on both dumps), so it needs the Huffman phase first | `Partition/Module.swift` | — |
| `get_rbe_pm_met`, `rbe_pm_met_hashes` | metadata leftover hashes — same deferral (decompressed input) | `Partition/Module.swift` | — |
| `cpd_entry_num_fix`, `cpd_size_calc`, `cpd_chk` | $CPD integrity — `cpd_chk` R1 Checksum-8 + R2 CRC-32 validated (`CPDParser.checksumValid`); `cpd_entry_num_fix`/`cpd_size_calc` ported as *probes* → integrity Issues (the decoder locates content per-entry, so it never needs the sequential-unpack repair to grow the module list) | `Partition/CPD.swift` + `Crypto/Checksum.swift` (`CRC32`) | ported |
| operational `$CPD` → `CodePartition` module list | the chosen partition's module directory (name/offset/IsHuffman/size + header) surfaced in the UI result model — Stage-2 of the `$CPD` port; each metadata-carrier module row (`kernel.met`, …) carries its decoded body chain and the manifest `.man` row repeats `CodePartition.extensions` (row below) | `Models/FirmwareAnalysis.swift` (`CodePartition`, `CPDModule.extensions`) + analyzer wiring | ported |

## CSE/GSC file system (VFS, MFS, FTBL/EFST, extensions)

| Upstream symbol(s) | Models | Swift home | Status |
|---|---|---|---|
| `FTBL_Header`, `FTBL_Table`, `FTBL_Entry` | CSE File Table | `FileSystem/FTBL.swift` | — |
| `EFST_Header`, `EFST_Table`, `EFST_Entry` | CSE File System Table | `FileSystem/EFST.swift` | — |
| `EFS_Page_Header`, `EFS_Page_Footer`, `EFS_File_Metadata` | EFS page/footer | `FileSystem/EFS.swift` | — |
| `MFS_Volume_Header`, `MFS_Page_Header`, `MFS_Config_Record_*`, `MFS_Home_Record_*`, `MFS_Integrity_Table_*`, `MFS_Backup_Header_R0/R1`, `MFS_Backup_Entry` | CSE MFS (older) | `FileSystem/MFS.swift` | — |
| `UTFL_Header`, `FITC_Header` | misc CSE tables | `FileSystem/Misc.swift` | — |
| `CSE_Ext_00` … `CSE_Ext_37`, `CSE_Ext_544F4F46` (+`_Mod`/`_R2` variants) | the 0x00–0x25+ extension blocks of a CPD entry, in **both** `.man` bodies (chain after the manifest struct) and `.met` companion bodies (chain = the body itself, from `entry.offset`); walker + per-tag header decoders (`0x00`/`0x02`/`0x03`/`0x0A`/`0x0C`/`0x0F`/`0x16`; 0x0A Module Attributes is the universal `.met` lead block, revision-aware R1 0x38/SHA-256 vs R2 0x48/SHA-384); the row-bearing `.met` tags `0x04`–`0x0D` and `_Mod` row sub-tables surface as envelopes only | `Partition/Extensions.swift` — `decode` (.man) + `decodeMetBody` (.met) over shared `walkBlocks` | ported* |
| `cse_part_inid`, `ext_anl`, `mod_anl`, `mfs_anl`, `mfs_home_anl`, `mfs_cfg_anl`, `efs_anl`, `fitc_anl`, `mfs_home13_anl`, `get_sec_hdr_size`, `get_cfg_rec_size`, `get_vfs_start_0`, `get_mfs_anl` | walking/decode helpers | `FileSystem/*.swift` | — |
| `get_key_usages`, `mfs_txt`, `mfs_write`, `mfs_anl_msg`, `efs_anl_msg` | manifest keys / MFS text | lower priority | — |

## Independent (IUP) firmware — PMC / PCHC / PHY / OROM

| Upstream symbol(s) | Models | Swift home | Status |
|---|---|---|---|
| `GSC_Info_FWI`, `GSC_Info_IUP` | GSC firmware image info | `IUP/GSC.swift` | — |
| `GSC_OROM_Header`, `GSC_OROM_PCI_Data` | Option ROM image/PCIR | `IUP/OROM.swift` | — |
| `pmc_anl`, `pmc_parse`, `pchc_anl`, `pchc_parse`, `phy_anl`, `phy_parse`, `pch_init_anl`, `info_anl` | PMC/PCHC/PHY/PCH init decode | `IUP/PMC.swift`, `IUP/PCHC.swift`, `IUP/PHY.swift` | — |
| `chk_iup_size` | IUP size validation | `IUP/Common.swift` | — |
| `fovd_clean` | FOVD/NVKR dirty check | `IUP/Common.swift` | — |

## Identification & database layer

| Upstream symbol(s) | Models | Swift home | Status |
|---|---|---|---|
| `get_variant` | RSA-pubkey-hash → variant + shared-pre-key override + release; *module-name fallback deferred to the $CPD port* | `Identify/Identifier.swift` (lookup + small table, not an if-chain) | ported* |
| `get_cse_db`, `release_fix` | DB query for release/SKU — `release_fix` ported (rsa_pre_keys); `get_cse_db` SKU cells deferred (needs $CPD SKU caps) | `Identify/Identifier.swift` | ported* |
| `get_csme12_sku`, `sku_db_cse` | CSME12 SKU table logic | `Identify/SKU.swift` | — |
| `note_new_fw` | report firmware absent from DB/repo — surfaced as a `.note` `Issue` by the pipeline | `Identify/Identifier.swift` (note text) | ported* |
| `get_db_json_obj` | section lookup in MEA.dat — `rsa_pre_keys` block parsed | `Data/MEADatabase.swift` | ported* |
| `get_fw_ver` | format version string (family zero-padding) | deferred — display text, needs the DB label layer | — |
| `cse_huffman_dictionary_load` | pick Huffman dict by (variant,major,minor) | `Decompress/Huffman.swift` (`HuffmanDictionaries.parse`/`version`) | ported |
| (FileTable.dat loaders, `check_ftbl_id`, `check_ftbl_pl`) | module-name/version path mapping | `DB/FileTable.swift` | — |
| `mfs_txt_json…`, `ext_table`, `pt_html`, `pt_json`, `struct_json`, `get_struct`, `ext_table` | table/JSON rendering of structs | **n/a — UI renders the result model instead** | n/a |

`ported*` = the identification core is in; the marked piece waits on the `$CPD`
port (module-name heuristics, SKU cells) or the display/DB-label layer.

## Crypto & checksums

| Upstream symbol(s) | Models | Swift home | Status |
|---|---|---|---|
| `sha_1`, `sha_256`, `sha_384`, `get_hash`, `calc_hash`, `calc_hash_hex`, `md5` | hashing — only `sha_256`/`get_hash(0x20)` (uppercase hex) ported; others join with the signature path | `Crypto/Digest.swift` | ported* |
| `mc_chk32`, `Crc16_14` | checksums | `Crypto/Checksum.swift` | — |
| `rsa_sig_val`, `pss_mgf`, `pss_verify`, `pss_final_validate`, `unmask_DB`, `parseSign`, `get_salt` | RSA-PSS signature validation | `Crypto/RSA.swift` | — |
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
| `get_manifest`, `get_fpt`, `get_cpd`, `get_bpdt` | region scanning dispatch — `get_fpt`, `get_manifest` and `get_cpd` decode live in the parsers they dispatch (`Layout/FPT.swift`, `Layout/Manifest.swift`, `Partition/CPD.swift`); `get_bpdt` deferred | `Engine/MEFirmwareAnalyzer.swift` (stage 1 scan) | ported* |
| `$FPT` re-anchor → operational partition (11802–11825) + owning-`$CPD` name fallback | pick the *operational* `$MN2` copy to identify (FTPR over the earlier RBEP recovery copy; whole-flash `$FPT` lists only internal volumes) | `Engine/ManifestSelection.swift` | ported |
| `cse_unpack`, `cse_part_inid`, `mod_anl`, `ext_anl` | full CSE/GSC unpack (incl. the `$MN2_Stage1` module-name pass `get_variant` needs) | `Engine/Unpack.swift` | — |
| per-family analysis chain (`pmc_*`, `pchc_*`, `phy_*`, `gsc_*`) | dispatch to IUP parsers | `Engine/Pipeline.swift` | — |

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
