# MEA default-output block map — how the console summary blocks are built

The documented map of MEA's **default (console) output** — which blocks appear,
which `Field/Value` rows each block consists of, and where each row's value comes
from in `MEA.py`. Written to be the single source of truth for a future "output
renderer" increment that reproduces MEA's default output from the ported engine
facts, and to surface exactly which byte-core facts the Swift engine still lacks
for that.

Line numbers refer to upstream `MEA.py` v1.312.0 r378. Companion to
`upstream-map.md` (the per-fact row ledger), `oracle-verification.md` (the
real-dump facts used to check row sets), and `result-model.md` (the additive /
DB-free UI-model contract the gap list respects).

## Scope

This map covers **only the summary `Field/Value` blocks** and the trailing
message list that MEA prints at the end of each input file's analysis
(`mass_scan`'s "Print Firmware Info" section):

1. the primary firmware table,
2. the independent PMC / PCHC / PHY tables (one per found sub-firmware),
3. the err/warn/note message list.

The deep structural per-partition tables (`$FPT`, `$CPD`, module metadata,
MFS/EFS…) are **not** catalogued here; `upstream-map.md` is the ledger for those.
They are referenced below only where a summary row draws its value from one
(e.g. the Chipset row ← MFS file-6 `mphytbl`).

## 1. Entry path & block composition

The default output is one pass of `mass_scan`'s per-file body ending in "Print
Firmware Info". `mass_scan(f_path)` (10474) walks every file under `f_path`;
the caller iterates the resulting list (`source`, 10994; per-file loop with
`cur_count`/`in_count` ~10997) and each file runs the full analysis chain, then
prints its summary blocks once:

- an app banner is drawn once at program start from the title constant
  `'ME Analyzer v1.312.0'` (line 10) plus the revision — a program-level
  preamble, *not* a per-file block;
- **one primary `Field/Value` table** titled `'<basename(file_in)[:45]> (N/M)'`
  (13687), rows 13689–13749, `print` at 13750;
- **zero or more independent `Field/Value` tables** — one per PMC (13768–13794),
  PCHC (13810–13833) and PHY (13849–13872) sub-firmware the whole-input scan
  located beyond the primary ME region (each block only exists when its
  `pmc_all_anl` / `pchc_all_anl` / `phy_all_anl` collection is non-empty);
- **the message list** — 13888–13919, deduplicated, printed last.

A whole-flash CSME dump therefore yields the primary CSE table plus any
independent tables for sub-firmware found past the ME region.

### Console-vs-export nuance (important)

After each `print`, MEA **re-titles the same table and appends** three rows —
`MEA Database Name`, `MEA Support Status`, `RSA Signature Hash` (main 13753–
13755; PMC 13796–13798, PCHC 13835–13837, PHY 13874–13876). These rows are **not
part of the console default output**; they only reach the HTML/JSON writers
(13761–13766 etc.). The worked example in §3 confirms they are absent from the
real console table.

## 2. Block 1 — the primary firmware table (row ledger)

Columns: **#** · **Row label** · **When it appears (gating)** · **Value — MEA
source** · **Swift bridge** (status letter + field).

Status letters: **[E]** exists in `FirmwareAnalysis` · **[P]** partial — engine
holds the data but mapping/formatting differs · **[A]** add — byte-core fact not
yet surfaced · **[F]** add — byte-core but no real-dump oracle (fixture-only) ·
**[X]** parked — DB-derived display text (result-model rule) · **[~]** ≈ `issues`.

| # | Row label | Gate (row added when …) | Value · MEA source | Swift |
|---|---|---|---|---|
| 1 | Family | always | `variant_p` — family *print* name (e.g. "CSE ME"), mapped at 10406–10437 | [E] `family` (enum) + `variant`; "CSE ME" is the DB/UI label of `variant` |
| 2 | Version | always | `fw_ver` — `major.minor.hotfix.build` (manifest / BPDT FIT) | [E] `MEAText.firmwareVersion(variant:…)` — `get_fw_ver`'s per-variant shaping (MEA.py 10094): a (CS)SPS version pads every field, a modern PMC its hotfix (`160.2.00.1040`), a Cannon-era one its major, a PCHC/PHY its build to four digits, and everything else reads plainly |
| 3 | Release | always | `release` + `", Engineering"` when `build >= 7000` (13691); scalar from 12641–12649 (`rel_signed` + `release_fix`, e.g. Pre-Production demotion at 10255) | [E/P] `release` enum; the Engineering suffix rule (`build>=7000`) not surfaced |
| 4 | Type | always | `fw_type` — Stock / Update / Extracted classifier at 12538–12588 (IFWI ⇒ "Extracted"; else `$FPT`-partition/FOVD/`FitBuild` heuristics) | [E] `type` = `FirmwareTypeClassifier.classify`: IFWI ⇒ `.extracted`; no `$FPT` ⇒ `.update`; SPS ⇒ `.extracted`; ME 2–7 FOVD/`KRND` axis; csmeLike ⇒ exactly `[FTPR,FTUP,NFTP]` ⇒ `.update`, marker-FIT ⇒ `.stock`/Extracted legs, real FIT ⇒ `.extracted`. Only unidentified (no-manifest) images keep `.region` (see §6) |
| 5 | SKU | **hidden** for (CSTXE & `'Unknown' in sku`) · (SPS,`'NaN'`) · variant starts `PMCAPL/PMCBXT/PMCGLK/PCHC/PMCDG/OROM` (13694–13698) | `sku` — per-family SKU block (legacy literal tables 12680–13231; CSME≥12 via `get_csme12_sku` 10287 / FW-SKU decode 13120–13127) | [E] `sku` (engine value matches the row, e.g. "Consumer H") |
| 6a | Chipset | variant starts `CS/PMC/GSC` & not `PMCDG` & `pch_init_final` non-empty | `pch_init_final[-1][0]` — combined display cell `"<chipset> <letters,comma-joined>"` (e.g. "CNP/CMP-H B,A") from `pch_init_anl` 9097–9131 | [P] `mfsVolume?.pchInit?.chipsets` (row 81) — engine keeps `[("CNP/CMP-H","BA")]`; the row is chipset + `" "` + steppings joined by `,`, using **only the last** aggregate record |
| 6b | Chipset | same gate & `sku_stp == 'Unknown'` | literal `"Unknown"` | [E] the summary's third leg, reached when neither a chipset-init table nor a recorded stepping says anything |
| 6c | Chipset Stepping | same gate & otherwise | `", ".join(sku_stp)` — stepping letters from DB (`sku_stp`, 10275–10280) or `pch_init_final[-1][1]` fallback (10308) | [E] `chipsetStepping` — `MEADatabase.cseCells` reads the firmware row's stepping cell per family (CSME 3, CSTXE 1; the CSSPS branch never fires upstream and does not here either), an IUP image keeps its descriptor letter, and the row splits the letters as upstream does ("BA" → "B, A"). Verified: old.bin C, 1.bin A, DATMAAMBAC0 BA, new.bin none (→ 6b "Unknown", as the console prints) |
| 7 | NVM Compatibility | `nvm_db` truthy — which is set from the value itself (13614: any `ext15_info[3]` other than `''`/`'Undefined'`), not from the database | `ext15_info[3]` — CSE_Ext_0F_R2 `NVMCompatibility` (SPI/UFS, 6246–6248 via `ext15_nvm_type`) | [E] `nvmCompatibility` — the raw two bits hoisted from the last `_R2` 0x0F of the operational chain (an R1 block carries no field and cannot clear one); the `ext15_nvm_type` label map is `MEAText.nvmCompatibility` |
| 8 | TCB Security Version Number | (ME & major≥8) or variant starts `TXE/CS/GSC/PMC/PCHC/PHY/OROM` | `svn` — manifest security version | [E] `securityVersion` (= manifest `svn`, zero included — only the erased word reads as nothing) |
| 9 | ARB Security Version Number | (CSME & major≥12) or variant starts `CSTXE/CSSPS/GSC/PMC/PCHC/PHY/OROM` | `ext15_info[0]` — CSE_Ext_0F `ARBSVN` (6246–6247) | [A] ARB SVN not surfaced (see §5) |
| 10 | Version Control Number | same gate as #8 | `vcn` — **CSE_Ext_03** `VCN` preferred (6185), CSE_Ext_0F fallback (6245), FTPR-manifest-header fallback (12189) | [A] top-level VCN absent; `ManifestSummary.vcn` is the R0-only `+0x34` field, not the CSE-ext VCN |
| 11 | Production Ready | `pvbit is not None` | `['No','Yes'][pvbit]` — FTPR manifest header production-ready flag (`mn2_flags_pvbit`, 12659; ME/TXE use the `$DAT…IFRP` probe 12652–12655) | [A] pv bit not surfaced (see §5) |
| 12a | Power Down Mitigation | `[variant,major]==['CSME',11]` & `pdm_status != 'NaN'` | `pdm_status` | [E] `powerDownMitigation` — the database row's PDM token (`YPDM`/`NPDM`/`UPDM*`), read for CSME 11 alone; oracle-verified on old.bin (`NPDM` → "No"). The `bup`-module Huffman scan upstream falls back to when the row is silent (13150–13161) is unported, and the row is then a promise rather than a "No" |
| 12b | Workstation Support | `[variant,major]==['CSME',11]` | `['No','Yes'][fw_0C_lbg]` (0x0C capability) | [E] `workstationSupport` — the Workstation bit of the last `CSE_Ext_0C` in the chain; oracle-verified on old.bin ("No") |
| 13 | Patsburg Support | (ME, 7) | `['No','Yes'][is_patsburg]` | [E] `patsburgSupport` — the `$SKU` attributes' Patsburg bit (`PreCSEME`, byte 4 bit 7), filled for ME 7–8 and read by the row for ME 7. Fixture-verified only: no ME-7 dump in the oracle set |
| 14 | OEM Configuration | variant in `CSME/CSTXE/CSSPS/TXE/GSC` | `['No','Yes'][int(oem_signed or oemp_found or utok_found)]` — OEM RSA-signed (`oem_signed`, 6016), OEM-partition (`oemp_found`, 11790/12133), UTOK/STKN present (`utok_found`, 11786/12129) | [E] top-level `oemCustomized: Bool?` = the `oem_signed or oemp_found or utok_found` Bool; nil ⇒ grey. `oemConfiguration` stays the separate FITC-*region* structural group (§4/§6) |
| 15 | FWUpdate Support | (CSME & major≥12) | `fwu_iup_result` — `'No'/'Yes'/'Impossible'/'Unknown'` from the IUP FWUpdate-presence check (13601–13611) | [E] `fwUpdateSupport` (`FWUpdateSupportDecider`): which of PMCP/PCOD · PCHC · PPHY/NPHY/SPHY/PHYP the region's own `$FPT` lists — a partition inside a boot `BPDT` does not count, which is why an image with a PMC still reads No — against the per-version requirement table, plus both `Impossible` legs (a Corporate extracted image with nothing uncharted or a probe hit; a padded CSME 16 at offset 0). Verified against the console on the three CSME 12/15/16 oracles: No, No, No. Upstream's `'Unknown'` initial value can never reach a printed row |
| 16 | Date | always | `date` — manifest date `"%0.4X-%0.2X-%0.2X"` (5918) | [E] `manufactureDate` (from manifest day/month/year) |
| 17 | File System State | variant in `CSME/CSTXE/CSSPS/GSC` | `mfs_state` — `'Initialized'/'Configured'/'Unconfigured'/'Error'` from the MFS scan (`mfs_parsed_idx` 7489–7493; init 11075; raised by EFS/config presence 13050–13051 etc.) | [P] `mfsState` — the reserved-index rule (7489–7490) and the configuration raise (13051: a non-empty `fitc.cfg` module or FITC/CDMD/MFSB partition). The EFS raise (13050, `efs_init`) is **not** ported: which bytes of an EFS are a file is a question only the `FileTable.dat` EFST table answers, so a written CSME 15/16 file system reads Configured where the console reads Initialized. Verified: DATMAAMBAC0 and old.bin Initialized, new.bin Configured — all three as the console; 1.bin and 2.rom one step short |
| 18 | Size | `rgn_exist` or `cse_lt_struct` or variant starts `PMC/PCHC/PHY/OROM`; (ME,6,'ROM-Bypass') ⇒ `"Unknown"`; (CSTXE, fd_devexp) ⇒ skip | `"0x%X" % eng_fw_end` — end of the analyzed firmware inside the flash (11792–11793; per-family module-end 12292–12486; OROM 13511; IUP 13538–13577) | [E] `firmwareSizeBytes` (`FirmwareEndCalculator`): the last-*starting* `$FPT` entry's end, the IFWI CSE-LT total (table + max(FPT end, Data) + Boot/Temp/ELog − nested), the uncharted-`$CPD` probe on a descriptor-less region, and the 4 KiB rounding with upstream's CSME-16 exception. Real-dump verified against the original script on all five oracles: 0x27C000 / 0x603000 / 0x3DA000 / 0x466000 / 0x466000. `sizeBytes` stays the analysed-region length, and the row falls back to it. Not ported: the ME 2–6 module-end leg (last entry with no size → nil) and the pre-CSE `$MCP` chains |
| 19 | Flash Image Tool | `fitc_ver_found` | `get_fw_ver(variant, fitc_major, fitc_minor, fitc_hotfix, fitc_build)` — IFWI: the boot BPDT header `bpdt_hdr.FitMajor/…` (12542–12545); non-IFWI: the real-FIT Extracted `else` branch sets it from the `$FPT` header `fpt_hdr` (12581–12586). Stock / Update / SPS / ME 2–7 and the marker-FIT Extracted legs never set `fitc_ver_found` | [E] IFWI row = first boot `BPDT` with a real header FIT (`BPDT.fit*`, "N/A" when a boot BPDT decodes FIT-less); non-IFWI row = model top-level `fptHeaderFIT`, surfaced only on the real-FIT Extracted branch — the sole non-IFWI leg that sets `fitc_ver_found` |
| 20 | Manifest Extension Utility | `mn2_meu_ver != '0.0.0.0000'` | `mn2_meu_ver` — FTPR manifest MEU block fields (12229) | [E] `version.meMajor…meBuild` (manifest +0x30…+0x36, R1/R2 only); the row's gate is upstream's own marker check (`MEU_Major not in (0,0xFFFF)`, 12227) and the build pads to four digits |
| 21 | Downgrade Blacklist 7.0 / 7.1 | (ME, 7) | `me7_blist_1` / `me7_blist_2` | [E] `downgradeBlacklist` — the two minor/hotfix/build triples at 0x6DF / 0x6EB past the manifest tag (upstream's `start_man_match` = manifest base + 0x1B); a zero build word is the "Empty" the row prints. Fixture-verified only |
| 22 | Chipset Support | `platform != 'NaN'` | `platform` — per-family PCH/Southbridge text (legacy literal tables 12748–12913, e.g. `ICH8`/`IBX`) | [E] `platform` — pre-CSE families from `PreCSEME`, IUP images from their descriptor, and the CSE ones from `CSEPlatformNames`: the CSME table (11–16) gated on there being no chipset-init table, plus CSTXE's three. Verified against the console on all five oracles: named only on the CSME-16 one ("ADP/RPP"), absent on the other four. Not ported: the (CS)SPS `CSE_Ext_50` SKU-platform names and the GSC ones — those stay nil, and the row absent |

**After `print` (export-only, never in console):** `MEA Database Name`
(`name_db.rsplit('_',1)[0]`), `MEA Support Status` (`['Yes','No'][is_unsupported]`),
`RSA Signature Hash` (`rsa_sig_hash`) — 13752–13755.

### Row-for-row check against the real thing (2026-09-10)

With rows 15/17/18/22 and the independent tables in, the panel's summary was
diffed against the original script's console output over the two dumps in
`~/Desktop/ME Samples`:

- **CSME 12.BIN** — identical, all 30 lines: the 16 main rows and the whole
  Power Management Controller block.
- **CSME 16.bin** — identical, all 73 lines: the 17 main rows and four
  independent blocks (PMC, PCHC and two PHY).

Two deliberate differences, normalised for the diff: the panel writes the
family as `CSME` where the console writes `CSE ME`, and it appends the decimal
byte count after every hex size. The trailing message differs in wording
(`Note: This firmware is not in the database.` against
`Error: Unsupported Intel Engine, Graphics and/or Independent firmware!`),
which is the display-only latitude §5 already grants.

## 3. Worked example — real CSME-12 console output

The user-supplied default output for `DATMAAMBAC0.BIN` (CSME 12.0.3.1091,
whole-flash) is reproduced row-for-row by the §2 ledger. Present rows (16) and
values, with their ledger row numbers:

| Row label | Value | §2 row | |
|---|---|---|---|
| Family | CSE ME | 1 | |
| Version | 12.0.3.1091 | 2 | |
| Release | Production | 3 | build 1091 < 7000 → no ", Engineering" |
| Type | Extracted | 4 | IFWI present |
| SKU | Consumer H | 5 | CSME-12 not in the skip list |
| Chipset | CNP/CMP-H B,A | 6a | `pch_init_final[-1][0]`; letters "BA" comma-joined |
| TCB Security Version Number | 1 | 8 | `variant` starts `CS` |
| ARB Security Version Number | 2 | 9 | CSME ≥ 12 |
| Version Control Number | 7 | 10 | `variant` starts `CS` |
| Production Ready | Yes | 11 | pvbit = 1 |
| OEM Configuration | No | 14 | CSME in list; all three flags false |
| FWUpdate Support | No | 15 | CSME ≥ 12 |
| Date | 2018-05-06 | 16 | manifest date |
| File System State | Initialized | 17 | EFS/config present |
| Size | 0x27C000 | 18 | `eng_fw_end` (≠ engine `sizeBytes` 0x1000000) |
| Flash Image Tool | 12.0.3.1091 | 19 | BPDT FIT version |

Absent rows confirm the gates: no `Chipset Support` (`platform == 'NaN'`), no
`Manifest Extension Utility` (`mn2_meu_ver == '0.0.0.0000'`), no `NVM
Compatibility` (`nvm_db` empty), no CSME-11/ME-7 rows, no export-only DB rows.
The trailing `Power Management Controller` block (§4) follows the main table.

## 4. Blocks 2–4 — independent PMC / PCHC / PHY tables

Each block's loop runs once per independent sub-firmware the analysis found.
Those are **not** outside the ME region, as an earlier reading of this map had
it: they are partitions *inside* it, collected from the region's own `$FPT`
(12427–12456) and from each IFWI boot partition's `BPDT` (11930–11960) — a
stitched PMC lives in one or the other depending on how the image was built.
A block's ~18 sub-fields come from that firmware's *own* manifest / CSE-ext /
SKU decode — the same machinery as the primary table, over a different image.
`name_db` / `mn2_signed_db` cells in each tuple are DB text (support-status /
signing), parked per the result-model rule.

**Swift**: done. The engine runs the same pipeline over each such partition's
bytes and returns the results as `FirmwareAnalysis.independentFirmware`
(`EngineModelRevision` 29), and `MEASummary` renders one titled block per
entry with the row sets below. Recognising them needed `get_variant`'s
module-name fallback (`VariantByModule`, MEA.py 10344–10396), since Intel
publishes no database key line for a stitched IUP. Verified against the
original script on the CSME-12 oracle (PMC 300.2.11.1012, SKU H, stepping B,
TCB 1, ARB 1, VCN 0, not production ready, 0x14000, CNP) and on the CSME-15 /
CSME-16 ones (PMC + PCHC + PHY each).

### PMC — title "Power Management Controller" (13770; rows 13778–13792)

Tuple unpack at 13772–13774. Console rows, in order:

- Family — `"PMC"`
- Version — `pmc_fw_ver`
- Release — `pmc_mn2_signed` (+ `", Engineering"` if `pmc_fw_rel >= 7000`)
- Type — `"Independent"`
- Chipset SKU — `pmc_pch_sku`, only when (CSME, major≥12) or (CSSPS, major≥5) or platform not `APL/BXT/GLK/DG`
- Chipset Stepping — `pmc_pch_rev[0]` (`"Unknown"` if `'U'`), skipped for `DG`
- TCB Security Version Number — `pmc_svn`
- ARB Security Version Number — `pmc_ext15_info[0]`
- Version Control Number — `pmc_vcn`
- Production Ready — `['No','Yes'][pmc_pvbit]`, when not `None`
- Date — `pmc_date`
- Size — `"0x%X" % pmc_size`
- Manifest Extension Utility — `pmc_meu_ver`, when ≠ `'0.0.0.0000'`
- Chipset Support — `pmc_platform`

### PCHC — title "Platform Controller Hub Configuration" (13812; rows 13820–13831)

Tuple unpack at 13814–13816. Console rows: Family `"PCHC"` · Version `pchc_fw_ver`
· Release `pchc_mn2_signed`(+Eng) · Type `"Independent"` · TCB `pchc_svn` · ARB
`pchc_ext15_info[0]` · VCN `pchc_vcn` · Production Ready `pchc_pvbit` (when not
`None`) · Date `pchc_date` · Size `pchc_size` · MEU `pchc_meu_ver` (when ≠
`0000`) · Chipset Support `pchc_platform`. (No SKU / stepping rows.)

### PHY — title "USB Type C Physical" (13851; rows 13858–13870)

Tuple unpack at 13853–13854. Console rows: Family `"PHY"` · Version `phy_fw_ver` ·
Release `phy_mn2_signed`(+Eng) · Type `"Independent"` · **SKU `phy_sku`** (the only
independent with a SKU row) · TCB `phy_svn` · ARB `phy_ext15_info[0]` · VCN
`phy_vcn` · Production Ready `phy_pvbit` (when not `None`) · Date `phy_date` ·
Size `phy_size` · MEU `phy_meu_ver` (when ≠ `0000`) · Chipset Support
`phy_platform`.

Worked-example PMC values for `DATMAAMBAC0.BIN` (same real paste): Version
300.2.11.1012, Release Production, Type Independent, Chipset SKU `H`, Chipset
Stepping `B`, TCB 1, ARB 1, VCN 0, Production Ready No, Date 2018-03-08, Size
0x14000, Chipset Support `CNP` — no MEU row (`pmc_meu_ver` zero).

## 5. Message list block

Not a `Field/Value` table: the final, **deduplicated** err/warn/note lines
printed after the summary tables (13888–13919). Terminal messages appended in
this section with their triggers:

- `Error: Unsupported Intel Engine, Graphics and/or Independent firmware!` when
  `is_unsupported` (13889);
- an `eng_size_text` warning when file size exceeds the firmware (13891);
- `Warning: Remove 0x… padding … for FWUpdate Support!` when
  `fwu_iup_result == 'Impossible'` and an uncharted/alignment region is present
  (13893–13898);
- `Note: Multiple (N) Intel Flash Partition Tables detected!` when `fpt_count>1`
  (13900) and the Flash-Descriptor analogue for `fd_count>1` (13902).

The fuller `err_stor`/`warn_stor`/`note_stor` stores accumulate throughout the
whole analysis (each appended with its own source) and are out of this map's
scope. Swift: the message list ≈ `FirmwareAnalysis.issues` (`Issue(severity,
message)`); severity classes line up (err/warn/note) but MEA's texts are colored
console strings — texts are display-only, no 1:1 text requirement.

## 6. Swift bridge & gap inventory

Consolidated status of every row for a future renderer. Grouped by what must be
done in the engine/model (additive-only `Codable` model; every additive change
bumps `EngineModelRevision`, currently **30** — see `result-model.md`).

| Status | Row(s) | Detail |
|---|---|---|
| **EXISTS** | Every row of the main table: Family, Version, Release, Type (4), SKU, Chipset/Stepping (6a–6c), NVM Compatibility (7), TCB SVN, ARB SVN (9), VCN (10), Production Ready (11), Power Down Mitigation + Workstation Support (12a/12b), Patsburg Support (13), OEM Configuration (14), Date, File System State (17), Size (18), Flash Image Tool (19), Manifest Extension Utility (20), Downgrade Blacklist (21), Chipset Support (22) | Engine `family`+`variant`, `version.text`, `release` (Engineering suffix rule unwired), `sku` (value matches), `securityVersion`, `manufactureDate`. Row 4 `type` = `FirmwareTypeClassifier` (gating per §2; ME 2–7's unported `.unknown` legs and unidentified images keep the row grey). Row 14 `oemCustomized: Bool?`. Row 19 = boot-`BPDT.fit*` on IFWI ("N/A" when FIT-less), model `fptHeaderFIT` on the non-IFWI real-FIT Extracted branch only. Row 7 `nvmCompatibility` (raw bits + UI label map), row 20 `version.me*` with upstream's marker gate, row 18 `firmwareSizeBytes`, rows 6b/6c `chipsetStepping`, rows 12a/12b `powerDownMitigation` + `workstationSupport`, row 13 `patsburgSupport`, row 21 `downgradeBlacklist`, row 22 `platform`, row 15 `fwUpdateSupport`. |
| **PARTIAL — mapping/formatting** | — | The three chipset legs (6a/6b/6c) all read now, and the summary picks between them the way the console does. |
| **ADD — byte-core fact** | File System State's EFS leg (17) | `efs_init` needs the `FileTable.dat` EFST table to know where each EFS entry starts in the assembled data area; until it is parsed, a written CSME 15/16 file system reads Configured rather than Initialized. Everything else in this class is done: rows 9, 10, 11, 17, 18 and 20 are all surfaced (`arbSvn`, `vcn`, `ManifestSummary.productionReady`, `mfsState`, `firmwareSizeBytes`, `version.me*`). |
| **ADD — fixture-only later** | — | Rows 13 and 21 are ported (`patsburgSupport`, `downgradeBlacklist`), verified by fixture only: there is still no ME-7 dump in the oracle set, so an ME 7.0/7.1 image (Cougar Point, and an X79/C600 one for a Patsburg "Yes") would confirm them. The CSME-11 rows 12a/12b are done — `old.bin` turned out to be a CSME 11.8 oracle for both. |
| **DEFERRED** | — | Nothing of the default output is left: rows 1–22 and the independent tables (§4) all read, and the message list is `issues`. What remains open is elsewhere — the EFS leg of row 17 (needs `FileTable.dat`'s EFST), the CSME-11 SKU composition, and the deep structural tables `upstream-map.md` tracks. |
| **PARKED — DB/UI display text** | the three export-only DB rows | `name_db`/support-status/RSA-hash rows never reach the console (`databaseName`/`signatureHash` exist in the model for other reasons). |
| **≈ `issues`** | Message list (§5) | Severity classes align; texts are display-only. |

## Cross-references

- `upstream-map.md` — row 81 (PCH-init, feeds the Chipset row), the `_parse`
  loops feeding the independent tables, and the ledger for all deep structural
  tables referenced above.
- `oracle-verification.md` — the real-dump facts (PCH-init stepping, MFS state,
  BPDT FIT) used to validate the §2/§3 row sets.
- `result-model.md` — the additive-only / no-DB-text contract that the §6 gap
  list respects and that a renderer must obey.
