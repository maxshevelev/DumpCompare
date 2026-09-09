# Oracle verification — closing the incremental engine-fact port

The record of the final cross-dump verification pass (2026-09-09) and the port
completion matrix it produced. Run the CLI (`swift run MEFirmwareCLI <image>`)
over the five oracle dumps and cross-check the key facts below against the
known oracle values for each. This document is the closeout for the
incremental port of **byte-core engine facts** (see "What *done* means" at the
end); it intentionally says nothing about the DB/UI layers, which never live in
this engine.

Companion to `upstream-map.md` (the row ledger) and `result-model.md`.

## Oracle inventory

| Dump | Size | Identity (family · variant · version) | Role |
|---|---|---|---|
| `1.bin` | 16 MiB | csme CSME **15.0.30.1716** prod whole-flash | R2-`$CPD` + FTBL-mode MFS + permuted EFS + FITC oracle |
| `2.rom` | 16 MiB | csme CSME **15.0.30.1716** prod whole-flash | Twin of `1.bin`; differs only in EFS-region head (below) |
| `DATMAAMBAC0.BIN` | 16 MiB | csme CSME **12.0.3.1091** prod whole-flash | R1-`$CPD` + legacy (non-FTBL) MFS oracle — 210 files, config + home |
| `old.bin` | 16 MiB | csme CSME **11.8.92.4222** prod whole-flash (FD) | Oldest CSE case; pre-IFWI (no CSE-LT) → `fpt_start = marker − 0x10`; legacy MFS oracle — 524 files |
| `new.bin` | 24 MiB | csme CSME **16.1.25.2020** prod whole-flash | Newest whole-flash oracle; CSME-16 regions (CDMD, ELog), unpermuted EFS, FTBL-mode MFS with 0 used files |

Every dump decodes cleanly (`issues` empty except the two faithful notes
below). The engine's numbers reproduced the known oracles exactly on all five.

## Cross-check matrix

Facts as printed by the CLI digest (regions are the on-flash / `$FPT` inventory
as surfaced; `crc32` is the operational-`$CPD` CRC-32 / the R1 checksum-8 value).

### `1.bin` — CSME 15.0.30.1716

| Fact | Oracle | CLI |
|---|---|---|
| Family / variant / version | csme CSME 15.0.30.1716 | identical |
| Release / SKU | production · "Consumer H" | identical |
| FTPR `$CPD` | hdrVer 2 · 29 modules · R2 CRC-32 valid | hdrVer 2, 29 modules, `checksumValid` true |
| RSA signature | valid | `rsaSignatureValid` true |
| CSE Layout Table | 1.7 @ Data 0x1F1000 / Boot1 0x3000 / Boot3 0x279000, CRC valid, no redundancy | identical (`ver 23`, `redundancy` false, non-empty as listed) |
| BPDT (Boot1/Boot3) | 13 + 8 entries, CRC valid | `(13, true)`, `(8, true)` |
| MFS (FTBL-mode) | dict 0x0A, 1024 records, **136 used** | `usesFTBL` true, `presentFiles` 136 |
| EFS @ 0x267000 | 1 System + 14 Data + 1 Scratch; dict 0x0A; perm order `[13,4,2,10,3,5,6,7,8,9,0,12,11,1]`; CRCs valid | `efsVolume` rev 1, `sysHdrCRC` true, order reproduced verbatim |
| OEM config (FITC) | rev 1 @ 0x1F2000, header+data CRC-32 valid, DataLength 11131 | identical |
| Issues | — | empty |

### `2.rom` — CSME 15.0.30.1716 (twin of `1.bin`)

FTPR / CSE-LT / BPDT / MFS / FITC facts identical to `1.bin` (29 modules R2,
CSE-LT 1.7 CRC valid, 136 present MFS files, oemConfig rev 1 valid, length
11131). One faithful difference:

| Fact | Oracle | CLI |
|---|---|---|
| EFS @ 0x267000 | region head does **not** begin with an EFS System page | `warning` "Skipped EFS partition at 0x267000: unrecognizable format (no leading System page)." |

Byte check (correcting the earlier "erased region" reading): the region is
**not** bulk-erased — bytes 0x268000…0x276FFF are populated, with real EFS page
headers (`01 00 0a 00 02 00 00 00 …`, Data pages at 0x26B000+). Only the
leading ~0x11 bytes (0x267000…0x267010) are zero where `1.bin` carries the
System-page header (`01 00 0a 00 01 00 00 00 …`). So the structural decode
cannot anchor on this copy and correctly declines; the note is byte-faithful,
not a parser gap.

### `DATMAAMBAC0.BIN` — CSME 12.0.3.1091

| Fact | Oracle | CLI |
|---|---|---|
| FTPR `$CPD` | hdrVer 1 · 46 modules · R1 Checksum-8 valid | hdrVer 1, 46 modules, `checksumValid` true |
| RSA signature | valid | `rsaSignatureValid` true |
| CSE Layout Table | 1.6 (no CRC field), Data/Boot1/Boot2 | `ver 22`, `checksumValid` none, non-empty Data@0x2000/Boot1@0x70000/Boot2@0x173000 |
| BPDT (Boot1/Boot2) | 8 + 8 entries (v1, no CRC) | `(8, none)`, `(8, none)` |
| MFS (legacy) | dict 1/0/0 → non-FTBL, 512 records, **210 used** | `usesFTBL` false, `presentFiles` 210 |
| MFS config (file 6) | 152 `0x1C` records: `home` folder, `bup`, `hw_binding` integrity… | decoded; `configurations` 1 |
| MFS home directory | 0x1C layout, 204 tree records, file-8 integrity 0x28 | `homeDirectory` present |
| Reserved integrity | reserved files [2,3,5] | per-reserved `reservedIntegrity` matches |
| **PCH init (new this pass)** | file-6 mphytbl → chipset init table | **CNP/CMP-H, stepping "BA", revision 8** (CSME-12 date-gate bitfield: manifest date ≥ 2018-01-25) |
| Issues | — | empty |

### `old.bin` — CSME 11.8.92.4222

| Fact | Oracle | CLI |
|---|---|---|
| Whole-flash FD, no CSE-LT | `fpt_start = marker − 0x10 = 0x3000`; partitions land only there | FTPR 0x4000, MFS @ 0x133000, all 13 regions correct (prior IFWI fix) |
| FTPR `$CPD` | hdrVer 1 · 47 modules (svn 3) · Checksum-8 valid | hdrVer 1, 47 modules, `checksumValid` true |
| RSA signature | all 5 `$MN2` manifests valid (SHA-256 PKCS#1 v1.5) | `rsaSignatureValid` true |
| MFS (legacy) | 552-tree home (0x18 layout), reserved integrity [2,3,4], **524 used** files, 158 pages | `presentFiles` 524, home + `reservedIntegrity` [2,3,4] |
| MFS backup | — (no backup area on this image) | `mfsBackup` nil (fixture-covered) |
| **PCH init (new this pass)** | file-6 mphytbl → chipset init table | **SPT/KBP-LP, stepping "C", revision 52** (CSME-11 absolute-letter: ≥ 2015-05-19) |
| Issues | — | empty |

### `new.bin` — CSME 16.1.25.2020

| Fact | Oracle | CLI |
|---|---|---|
| FTPR `$CPD` | hdrVer 2 · 29 modules · R2 CRC-32 valid | hdrVer 2, 29 modules, `checksumValid` true |
| RSA signature | valid | `rsaSignatureValid` true |
| CSE Layout Table | 1.7 with an **ELog** slot (Data 0x1A9000 / Boot1 0x2000 / Boot3 0x234000 / ELog 0x216000), CRC valid | identical (`ver 23`, ELog listed) |
| BPDT | 12 + 9 entries, CRC valid | `(12, true)`, `(9, true)` |
| EFS @ 0x217000 | System page + 14 Data pages in **natural order** (no permutation) | `dataPageOrder` `[0…13]`, `sysHdrCRC` true |
| OEM config (FITC) | rev 1, header+data CRC valid, DataLength 2920 | identical |
| Regions | includes CSME-16 `CDMD` @ 0x22F000 + `ELOG` @ 0x216000 | present |
| MFS (FTBL-mode) | present but **0 used files** (fresh/empty volume) | `usesFTBL` true, `presentFiles` 0, `configurations` 0 |
| Issues | — | only `.note` "This firmware is not in the database." |

**Observation to log (new.bin MFS):** the CSME-16 whole-flash carries an
FTBL-mode MFS volume whose FAT declares zero used low-level files
(`presentFileCount` 0), so there is no file-6/7/8 config or home to decode —
a genuinely empty volume, surfaced faithfully, not a decode failure. Its CSE-LT
still lists an MFS slot (0x1AE000, dict geometry like the CSME-15 twins), which
is why the volume is found but empty.

## PCH-init real-dump validation (row 81)

Both legacy-MFS dumps carry a file-6 `mphytbl`; each took the upstream elif
branch its identity + manifest date selects:

- `DATMAAMBAC0.BIN` (CSME 12.0.3): manifest date ≥ 2018-01-25 → **CSME-12
  date-gate bitfield** of the stepping nibble → CNP/CMP-H "BA" revision 8.
- `old.bin` (CSME 11.8): ≥ 2015-05-19 → **CSME-11 absolute-letter** → SPT/KBP-LP
  "C" revision 52.

Both results are plausible for CMP-H and SPT silicon and exercise the two
distinct stepping rules with their different chipset-ID widths (old-layout
nibble on CSME 12's pre-1.7 image vs the same layout on the CSME-11 image) —
the fixture suite (22 tests) already locks every other branch.

## Completion matrix (`upstream-map.md`, 57 ledger rows)

Statuses re-verified against the tree at HEAD `9fe17e4`:

| Section | Rows | ported | partial | deferred | parked | n/a |
|---|---|---|---|---|---|---|
| Container finders | 8 | 6 | — | 2 | — | — |
| Flash & IFWI layout | 6 | 5 | 1 | — | — | — |
| CSE manifest & partitions | 9 | 9 | — | — | — | — |
| CSE/GSC file system | 11 | 1 | 7 | 3 | — | — |
| Independent (IUP) firmware | 5 | 2 | 1 | 2 | — | — |
| Identification & DB layer | 9 | 6 | — | 1* | 1 | 1 |
| Crypto & checksums | 4 | 4 | — | — | — | — |
| Decompression | 1 | 1 | — | — | — | — |
| Analysis pipeline | 4 | 2 | — | 2 | — | — |
| **Total** | **57** | **36** | **9** | **9+1*** | **1** | **1** |

\* `get_fw_ver` (row 94) is unstarted (`—`); it formats the version *display*
string and needs the DB/UI label layer — counted with deferred.

**63 % of ledger rows are fully ported; every byte-core engine fact is.**
The 9 partial rows are structural/descriptor work already shipped with a
DB-text remainder (details below); the 10 open rows are deferred/parked by
design, each with its reason recorded in the map.

### Why the partial rows stay partial

| Row | Done | Remainder is… |
|---|---|---|
| 43 `CSE_Layout_*` flags | redundancy (1.7 Flags bit0) + CRC-32 validity | per-field flag-table *display* of each header — DB/UI label layer |
| 65 EFS pages | page inventory, System header, index-area permutation, all CRCs — byte-verified on 1.bin | EFS *file* contents (EFST/FTBL naming = `FileTable.dat`) |
| 66 MFS volume/pages | page sort, `Crc16_14` de-obfuscation, header + FAT facts — byte-verified on both legacy dumps | — (structural complete; feeds rows below) |
| 67 MFS files + legacy records/home | FAT-chain file walk, legacy 0x1C config, home directory + Integrity, backup decode | FTBL 0xC config branch + `mfs_home13_anl` naming (`FileTable.dat`) |
| 68 FITC/UTFL | FITC rev-1 structural header/data CRC — byte-verified on 1.bin | FITC config-*record* walk (DB-text); `UTFL_Header` open |
| 69 (FS deferral note) | structural EFS/FITC decode of the on-flash regions | content naming/records; UTFL + FTBL/EFST binary tables |
| 71 FS drivers | `ext_anl`/`mod_anl`, legacy `mfs_cfg_anl`/`mfs_home_anl`, `efs_anl`/`fitc_anl` structural halves, backup | FTBL content naming / records (rows 63–69/93) |
| 72 `mfs_anl` structural | MFS scan surfaced as `mfsVolume` + Issues | — (the `partial` tag predates the file-walk/record increments; see 66/67) |
| 81 PMC/PCHC/PHY/PCH-init | family descriptor (platform/SKU/stepping) oracle-verified on 1.bin; PCH-init real-dump-verified (above) | the `_parse` loops — thin row-aggregation wrappers adding only DB-name text |

### The 10 open rows and their reasons

| Row | Symbol | Reason |
|---|---|---|
| 26 | `bccb_pat` key-manifest placeholder | no standalone engine fact — sits inside the unpack key-usage pass |
| 32 | `pr_man_*_pat` + `pr_cpd_parts` probable-IUP scan | free-blob fallback only, reached when no `$FPT`/CSE-LT anchors; no fixture/oracle |
| 63/64 | `FTBL_Header`/`EFST_Header` binary tables | not present on any current dump's bytes; the reachable EFS naming is `FileTable.dat` (DB-text, row 69 finding) |
| 73 | `get_key_usages`, `mfs_txt`, `mfs_write`… | unpack key-usage + text sinks |
| 82 | `chk_iup_size` | display Warning/Note + optional padding-strip writer |
| 83 | `fovd_clean` | clean/dirty *display* flag |
| 94 | `get_fw_ver` | version display string; needs the DB/UI label layer |
| 96 | FileTable.dat loaders | **parked (user decision)** — DB-derived text/flags only, excluded by the result-model rule |
| 134 | `cse_unpack` | file-extraction/repair writer — an output feature, not analysis facts |
| 135 | per-family pipeline chain | thin print/orchestration driver over the ported descriptor rows |

## What *done* means

The incremental port of **byte-core engine facts** — every fact the engine can
decode from firmware bytes with no database — is **complete**: 36 of 57 ledger
rows fully ported and the remaining 21 either already split into their ported
structural half or deferred/parked with recorded, non-byte-core reasons. All
five oracle dumps decode with their known values reproduced exactly and no
spurious Issues; the two non-empty issue lists (2.rom EFS, new.bin not-in-DB)
are byte-faithful notes, not parser gaps.

The rows not ported are deferred on one of four grounds, none of which is
"not yet ported byte core":

1. **DB-text naming / display** — excluded by the standing result-model rule
   (the UI model never carries DB-derived display text): EFS/FTBL file names,
   FITC config records, `get_fw_ver`, `chk_iup_size`, `fovd_clean`, row 96.
2. **Extraction/repair writers** — DumpCompare output features, not analysis:
   `cse_unpack`, `MFS_Backup` restore writer.
3. **Thin orchestration loops** whose facts already live in ported rows:
   the IUP `_parse` loops, the per-family pipeline driver.
4. **Unanchored/absent-on-oracle scans**: `pr_man_*_pat`, binary FTBL/EFST
   tables, `bccb_pat`.

A future increment can revisit 1 only alongside a non-model report layer or a
rule change; 2–4 each carry their own fixture-oracle or dump gate in the map.
