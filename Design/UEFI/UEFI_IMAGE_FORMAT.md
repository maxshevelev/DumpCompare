# The format of a UEFI firmware image — a description for writing a parser

This document describes the structure of a firmware image conforming to the UEFI
PI, in enough detail to write a parser from scratch. Every structure and
algorithm was checked against the reference implementation UEFITool NE
(`common/ffsparser.cpp`, `common/ffs.h`, `common/descriptor.h`, branch
`new_engine`, version A76).

---

## 0. Conventions

| Property | Value |
|---|---|
| Byte order | little-endian everywhere, without exception |
| Structure packing | tight, `#pragma pack(1)`, no alignment holes |
| Unused space | filled with `emptyByte`: `0xFF` at erase polarity 1, `0x00` at 0 |
| The base GUID type | `EFI_GUID` = `{UINT32 Data1; UINT16 Data2; UINT16 Data3; UINT8 Data4[8];}`, 16 bytes |

Helper operations needed throughout:

```
ALIGN4(x)  = (x + 3)  & ~3
ALIGN8(x)  = (x + 7)  & ~7
ALIGN16(x) = (x + 15) & ~15

uint24ToUint32(p) = p[0] | (p[1] << 8) | (p[2] << 16)

calculateSum8(buf, len)       = the sum of the bytes modulo 256
calculateChecksum8(buf, len)  = (0x100 - calculateSum8(buf, len)) & 0xFF
calculateChecksum16(buf, len) = the same for UINT16, len must be even
```

The "checksum8" is built so that the sum of every byte together with the
checksum field comes out at zero. The same rule holds for the FIT, for FFS files
and for microcode.

### The data model to use

The reference parser builds a tree in which every node holds:

- `type` / `subtype` — what kind of element this is,
- `offset` — the offset relative to the parent,
- `base` — the absolute offset from the start of the image (computed),
- `header`, `body`, `tail` — three non-overlapping slices of bytes,
- `fixed` — a "must not be moved when rebuilding" flag,
- `compressed` — whether the element lies inside a compressed container,
- `parsingData` — housekeeping inherited by children (erase polarity, the FFS
  version, the volume's alignment, the file's GUID).

The split into `header`/`body`/`tail` is fundamental: almost every level of
nesting is "a header plus a body", and the body of the next level down is parsed
recursively. `tail` is used only by FFSv1 files with `FFS_ATTRIB_TAIL_PRESENT`.

Parsing runs in two passes:

1. **The first pass** builds the tree from the root down, purely by offsets.
2. **The second pass** does everything that needs absolute addresses: working
   out `addressDiff`, parsing the reset vector, finding and parsing the FIT,
   checking the Boot Guard protected ranges, checking the bases of TE images.
   The second pass is possible only if a Volume Top File was found and it does
   not lie inside a compressed element.

---

## 1. The top level: what kind of image this is

The algorithm, over the whole input buffer:

```
1. If the start of the buffer is a known capsule signature → strip the capsule
   header and carry on with the body.
2. If FLASH_DESCRIPTOR_SIGNATURE (0x0FF0A55A) sits at offset 0x00 or 0x10
   → this is an Intel image with a flash descriptor.
3. Otherwise → a "generic image": the whole buffer is taken as one raw area
   (the BIOS region) and scanned heuristically (see §4).
```

Offset 0x10 is checked because the first 16 bytes of a descriptor are a
`ReservedVector`, filled with `0xFF` on x86 — while on some ARM images a real
ARM reset vector sits there.

### 1.1. Capsules

```c
typedef struct {
    EFI_GUID CapsuleGuid;
    UINT32   HeaderSize;      // the body begins at this offset
    UINT32   Flags;
    UINT32   CapsuleImageSize;
} EFI_CAPSULE_HEADER;

typedef struct {                 // Toshiba
    EFI_GUID CapsuleGuid;
    UINT32   HeaderSize;
    UINT32   FullSize;
    UINT32   Flags;
} TOSHIBA_CAPSULE_HEADER;

typedef struct {                 // AMI Aptio
    EFI_CAPSULE_HEADER CapsuleHeader;
    UINT16 RomImageOffset;       // from the start of the capsule header to the body
    UINT16 RomLayoutOffset;
} APTIO_CAPSULE_HEADER;
```

The flags: `SETUP = 0x00000001`, `PERSIST_ACROSS_RESET = 0x00010000`,
`POPULATE_SYSTEM_TABLE = 0x00020000`.

The capsule GUIDs that are recognised:

| GUID | Kind |
|---|---|
| `3B6686BD-0D76-4030-B70E-B5519E2FC5A0` | the standard EFI capsule |
| `6DCBD5ED-E82D-4C44-BDA1-7194199AD92A` | the standard FMP capsule |
| `539182B9-ABB5-4391-B69A-E3A943F72FCC` | Intel |
| `E20BAFD3-9914-4F4F-9537-3129E090EB3C` | Lenovo |
| `25B5FE76-8243-4A5C-A9BD-7EE3246198B5` | Lenovo (second) |
| `3BE07062-1D51-45D2-832B-F093257ED461` | Toshiba |
| `4A3CA68B-7723-48FB-803D-578CC1FEC44D` | AMI Aptio signed |
| `14EEBB90-890A-43DB-AED1-5D3C4588A418` | AMI Aptio unsigned |

For a signed Aptio capsule the body's size comes from `RomImageOffset`; between
the header and the body lie a `FW_CERTIFICATE` and `ROM_AREA[]`, which can be
skipped for the purposes of parsing the image. If `CapsuleImageSize` is smaller
than the actual size of the buffer, the tail is rubbish behind the capsule, and
it is worth making a node of its own rather than dropping it silently.

---

## 2. The Intel flash descriptor

The descriptor occupies the first `0x1000` bytes of the image.

```c
typedef struct {
    UINT8  ReservedVector[16];
    UINT32 Signature;            // 0x0FF0A55A
} FLASH_DESCRIPTOR_HEADER;
```

### 2.1. The descriptor map (FLMAP)

Directly behind the header, at offset `0x14`:

```c
typedef struct {
    // FLMAP0
    UINT32 ComponentBase      : 8;   // bits [11:4] of the address
    UINT32 NumberOfFlashChips : 2;   // zero-based
    UINT32                    : 6;
    UINT32 RegionBase         : 8;
    UINT32 NumberOfRegions    : 3;   // reserved in a v2 descriptor
    UINT32                    : 5;
    // FLMAP1
    UINT32 MasterBase         : 8;
    UINT32 NumberOfMasters    : 2;
    UINT32                    : 6;
    UINT32 PchStrapsBase      : 8;
    UINT32 NumberOfPchStraps  : 8;   // one-based, in UINT32s
    // FLMAP2
    UINT32 ProcStrapsBase     : 8;
    UINT32 NumberOfProcStraps : 8;
    UINT32                    : 16;
    // FLMAP3
    UINT32 DescriptorVersion;        // reserved until Coffee Lake
} FLASH_DESCRIPTOR_MAP;
```

**Important:** every `*Base` field holds bits `[11:4]` of a real offset. The real
offset is `Base << 4`. The largest valid base is `0xE0`; anything greater means
a broken descriptor.

`DescriptorVersion` (from Coffee Lake onwards) is read as:

```c
typedef struct {
    UINT32 Reserved : 14;
    UINT32 Minor    : 7;
    UINT32 Major    : 11;
} FLASH_DESCRIPTOR_VERSION;
```

The only known valid version is Major=1, Minor=0. The value `0xFFFFFFFF` means
"this field is reserved", that is, a v1 descriptor.

### 2.2. The region section

It lives at `RegionBase << 4`. Every region is a pair of `UINT16` base/limit
values holding **the top 16 bits** of the real 32-bit addresses:

```
offset = Base  << 12
limit  = (Limit << 12) | 0xFFF
size   = limit - offset + 1
```

A region is absent if `Limit == 0` (or if `Base > Limit`).

```c
typedef struct {
    UINT16 DescriptorBase, DescriptorLimit;   // the descriptor itself
    UINT16 BiosBase,       BiosLimit;         // BIOS
    UINT16 MeBase,         MeLimit;           // Management Engine
    UINT16 GbeBase,        GbeLimit;          // Gigabit Ethernet
    UINT16 PdrBase,        PdrLimit;          // Platform Data
    UINT16 DevExp1Base,    DevExp1Limit;      // Device Expansion 1
    UINT16 Bios2Base,      Bios2Limit;        // Secondary BIOS
    UINT16 MicrocodeBase,  MicrocodeLimit;    // CPU microcode
    UINT16 EcBase,         EcLimit;           // Embedded Controller
    UINT16 DevExp2Base,    DevExp2Limit;      // Device Expansion 2
    UINT16 IeBase,         IeLimit;           // Innovation Engine
    UINT16 Tgbe1Base,      Tgbe1Limit;        // 10GbE 1
    UINT16 Tgbe2Base,      Tgbe2Limit;        // 10GbE 2
    UINT16 Reserved1Base,  Reserved1Limit;
    UINT16 Reserved2Base,  Reserved2Limit;
    UINT16 PttBase,        PttLimit;          // Platform Trust Technology
} FLASH_DESCRIPTOR_REGION_SECTION;
```

How many pairs are valid depends on the descriptor's version: in v1 the first 5
are read (Descriptor, BIOS, ME, GbE, PDR), in newer ones all of them.

The correct algorithm for parsing an Intel image:

1. Collect the regions that are present as `{offset, length, type}`.
2. Sort them by `offset`.
3. Check for overlaps — overlapping regions mean a broken descriptor.
4. Add the gaps between regions as "padding" elements.
5. Parse each region with its own parser; the BIOS region and Device Expansion 1
   are parsed as raw areas (§4), while ME/GbE/PDR are opaque blobs with a
   version extracted from them.

### 2.3. The masters section

At `MasterBase << 4`. There are two formats — before Skylake and from Skylake
onwards:

```c
typedef struct {                            // v1
    UINT16 BiosId; UINT8 BiosRead, BiosWrite;
    UINT16 MeId;   UINT8 MeRead,   MeWrite;
    UINT16 GbeId;  UINT8 GbeRead,  GbeWrite;
} FLASH_DESCRIPTOR_MASTER_SECTION;

typedef struct {                            // v2, Skylake+
    UINT32 : 8; UINT32 BiosRead : 12; UINT32 BiosWrite : 12;
    UINT32 : 8; UINT32 MeRead   : 12; UINT32 MeWrite   : 12;
    UINT32 : 8; UINT32 GbeRead  : 12; UINT32 GbeWrite  : 12;
    UINT32 : 32;
    UINT32 : 8; UINT32 EcRead   : 12; UINT32 EcWrite   : 12;
} FLASH_DESCRIPTOR_MASTER_SECTION_V2;
```

The access bits in v1: `DESC=0x01, BIOS=0x02, ME=0x04, GBE=0x08, PDR=0x10,
EC=0x20`.

### 2.4. The rest of the descriptor

- `FLASH_DESCRIPTOR_UPPER_MAP` at the fixed offset `0x0EFC`:
  `{UINT8 VsccTableBase; UINT8 VsccTableSize; UINT16 ReservedZero;}`.
  The base is again bits `[11:4]`; the size is in `UINT32`s.
- The VSCC table: an array of `{UINT8 VendorId; UINT8 DeviceId0;
  UINT8 DeviceId1; UINT8 ReservedZero; UINT32 VsccRegisterValue;}`.
- The OEM section: fixed at `0x0F00`, size `0x100`.

---

## 3. The firmware volume (FV)

### 3.1. The volume header

```c
typedef struct {
    UINT8    ZeroVector[16];
    EFI_GUID FileSystemGuid;
    UINT64   FvLength;
    UINT32   Signature;        // '_FVH' = 0x4856465F, at offset 0x28
    UINT32   Attributes;
    UINT16   HeaderLength;
    UINT16   Checksum;
    UINT16   ExtHeaderOffset;  // reserved in Revision 1
    UINT8    Reserved;
    UINT8    Revision;         // 1 or 2
    // EFI_FV_BLOCK_MAP_ENTRY FvBlockMap[];
} EFI_FIRMWARE_VOLUME_HEADER;   // 0x38 bytes up to the block map

typedef struct {
    UINT32 NumBlocks;
    UINT32 Length;
} EFI_FV_BLOCK_MAP_ENTRY;       // terminated by a {0, 0} pair
```

The key detail for finding volumes: the `_FVH` signature is at the fixed offset
`EFI_FV_SIGNATURE_OFFSET = 0x28` from the start of the header. The search is for
the signature, and stepping back `0x28` gives the candidate header.

**The checks on a candidate** (all of them required, or there will be false
positives):

- `FvLength >= sizeof(header) + 2 * sizeof(EFI_FV_BLOCK_MAP_ENTRY)` and
  `< 0xFFFFFFFF`;
- `Revision` is 1 or 2;
- `HeaderLength >= sizeof(EFI_FIRMWARE_VOLUME_HEADER)` and `ALIGN8(HeaderLength)`
  does not run past the end of the data;
- the alternative size computed from the block map (`Σ NumBlocks * Length`) is
  compared with `FvLength`; a discrepancy is a sign of damage, but not a reason
  to throw the volume away — the reference parser tries both sizes in that case.

### 3.2. The extended header

If `Revision > 1` and `ExtHeaderOffset != 0`:

```c
typedef struct {
    EFI_GUID FvName;
    UINT32   ExtHeaderSize;
} EFI_FIRMWARE_VOLUME_EXT_HEADER;

typedef struct {                       // a chain of entries inside the ext header
    UINT16 ExtEntrySize;
    UINT16 ExtEntryType;               // 0x0000 = END
} EFI_FIRMWARE_VOLUME_EXT_ENTRY;
```

The entry types: `END = 0x0000`, `OEM_TYPE = 0x0001` (`UINT32 TypeMask` plus
`EFI_GUID Types[]`), `GUID_TYPE = 0x0002` (`EFI_GUID FormatType` plus data).

The resulting size of the volume header:

```
if (Revision > 1 && ExtHeaderOffset)
    headerSize = ExtHeaderOffset + extHeader->ExtHeaderSize;
else
    headerSize = HeaderLength;
headerSize = ALIGN8(headerSize);       // the ext header may end unaligned
```

### 3.3. The header checksum

A `checksum16` over the first `HeaderLength` bytes with the `Checksum` field
zeroed; the result must match the stored value. Note: the sum is taken over
`HeaderLength` and not over `headerSize` — the extended header is not part of
it.

### 3.4. Working out the volume's file system

From `FileSystemGuid`:

| GUID | Meaning |
|---|---|
| `7A9354D9-0468-444A-81CE-0BF617D890DF` | FFSv1 (`EFI_FIRMWARE_FILE_SYSTEM_GUID`) |
| `8C8CE578-8A3D-4F1C-9935-896185C32DD3` | FFSv2 |
| `5473C07A-3DCB-4DCA-BD6F-1E9689E7349A` | FFSv3 |
| `04ADEEAD-61FF-4D31-B6BA-64F8BF901F5A` | Apple immutable FV (FFSv2) |
| `BD001B8C-6A71-487B-A14F-0C2A2DCF7A5D` | Apple authentication FV (FFSv2) |
| `153D2197-29BD-44DC-AC59-887F70E41A6B` | Apple microcode volume, header fixed at `0x100` |
| `AD3FFFFF-D28B-44C4-9F13-9EA98A97F9F0` | Intel FS (FFSv2) |
| `D6A1CD70-4B33-4994-A6EA-375F2CCC5437` | Intel FS 2 (FFSv2) |
| `4F494156-AED6-4D64-A537-B8A5557BCEEC` | Sony FS (FFSv2) |
| `372B56DF-CC9F-4817-AB97-0A10A92CEAA5` | HP FS (FFSv2) |
| `FFF12B8D-7696-4C8B-A985-2747075B4F50` | NVRAM main store (VSS) |
| `00504624-8A59-4EEB-BD0F-6B36E96128E0` | NVRAM additional store |

The `FFSv2Volumes` / `FFSv3Volumes` lists in the implementation hold every GUID
treated as the corresponding version of FFS. A volume with an unknown GUID is
not parsed as FFS — its body is kept as opaque data.

### 3.5. Attributes and alignment

`EFI_FVB_ERASE_POLARITY = 0x00000800` decides `emptyByte`: set → `0xFF`, clear →
`0x00`. The value is inherited by every child.

The volume's alignment:

- **Revision 1**: the alignment bits `EFI_FVB_ALIGNMENT_2 … _64K` in
  `Attributes[31:16]` are valid only when `EFI_FVB_ALIGNMENT_CAP = 0x00008000`
  is set. In practice nobody keeps them correct, and there is no point checking.
- **Revision 2**: `alignment = 1 << ((Attributes & EFI_FVB2_ALIGNMENT) >> 16)`,
  where `EFI_FVB2_ALIGNMENT = 0x001F0000`. The range runs from `ALIGNMENT_1` (0)
  to `ALIGNMENT_2G` (0x1F). On top of that, `EFI_FVB2_WEAK_ALIGNMENT =
  0x80000000` relaxes the alignment requirement for the files inside. The
  default, where the attributes say nothing, is `0x10000` (64 KiB).

Checking a volume's alignment only makes sense for an uncompressed volume: a
compressed one is unpacked into memory at whatever address the decompressor
picks.

### 3.6. Apple CRC32 and UsedSpace in the ZeroVector

Some vendors use the reserved `ZeroVector`:

- bytes `[8..12)` — a CRC32 of the volume's body (from `HeaderLength` to the
  end). If the value is non-zero and the CRC matches, this is an Apple CRC32;
- bytes `[12..16)` — `UsedSpace`, the offset of the end of the used area from
  the start of the volume. Taken as valid if it matches the free-space boundary
  that was found.

---

## 4. Raw areas and the heuristic search

The BIOS region, Device Expansion, the body of a padding element and a "generic
image" are all parsed the same way: by scanning linearly for known signatures.

The `findNextRawAreaItem` algorithm — byte by byte (not four bytes at a time!),
checking a `UINT32` at the current offset:

```
for offset from start to size-4:
    dword = read_le32(data + offset)

    if dword == 0x00000001:                    // an Intel microcode candidate
        requires restSize >= sizeof(INTEL_MICROCODE_HEADER) (0x30)
        requires intelMicrocodeHeaderValid(header)
        requires TotalSize != 0
        → microcode found, size = TotalSize

    if dword == 0x4856465F ('_FVH'):           // a volume candidate
        requires offset >= 0x28
        check the volume header per §3.1
        compute the alternative size from the block map
        → volume found, size = FvLength, altSize = the block map's sum

    if dword == 0x5F494F5F ('_IO_'), 0x24504324 and so on → other stores
```

Everything between the elements that are found becomes padding. Padding made
entirely of `emptyByte` is marked "empty" — which matters when the image is
rebuilt later.

Raw areas are also searched for NVRAM stores, AMD microcode and BPDT/CPD (see
§7, §8).

---

## 5. FFS files

### 5.1. The headers

```c
typedef union {
    struct { UINT8 Header; UINT8 File; } Checksum;
    UINT16 TailReference;   // Revision 1
    UINT16 Checksum16;      // Revision 2
} EFI_FFS_INTEGRITY_CHECK;

typedef struct {                       // the base header, 0x18 bytes
    EFI_GUID                Name;
    EFI_FFS_INTEGRITY_CHECK IntegrityCheck;
    UINT8                   Type;
    UINT8                   Attributes;
    UINT8                   Size[3];   // UINT24, the full file size with its header
    UINT8                   State;
} EFI_FFS_FILE_HEADER;

typedef struct {                       // an FFSv3 large file, 0x20 bytes
    EFI_GUID                Name;
    EFI_FFS_INTEGRITY_CHECK IntegrityCheck;
    UINT8                   Type;
    UINT8                   Attributes;
    UINT8                   Size[3];   // 0xFFFFFF or 0x000000
    UINT8                   State;
    UINT64                  ExtendedSize;
} EFI_FFS_FILE_HEADER2;

typedef struct {                       // a Lenovo large file in FFSv2, 0x1C bytes
    EFI_GUID                Name;
    EFI_FFS_INTEGRITY_CHECK IntegrityCheck;
    UINT8                   Type;
    UINT8                   Attributes;
    UINT8                   Size[3];   // 0x000000
    UINT8                   State;
    UINT32                  ExtendedSize;
} EFI_FFS_FILE_HEADER2_LENOVO;
```

### 5.2. Working out a file's size

```
if ffsVersion == 2:
    size = uint24(Size)
    if volumeRevision == 2 and (Attributes & FFS_ATTRIB_LARGE_FILE):
        size = header2Lenovo->ExtendedSize      // a non-standard Lenovo extension
if ffsVersion == 3:
    if (Attributes & FFS_ATTRIB_LARGE_FILE):
        size = header2->ExtendedSize
    else:
        size = uint24(Size)
```

`Size` is the **full** size of the file, its header included. A size of `0` means
the volume cannot be parsed any further.

### 5.3. The attributes

```
FFS_ATTRIB_TAIL_PRESENT    0x01   // Revision 1 only
FFS_ATTRIB_RECOVERY        0x02   // Revision 1 only
FFS_ATTRIB_LARGE_FILE      0x01   // FFSv3 only (and Lenovo, in FFSv2 Rev 2)
FFS_ATTRIB_DATA_ALIGNMENT2 0x02   // Revision 2, UEFI PI 1.6+
FFS_ATTRIB_FIXED           0x04
FFS_ATTRIB_DATA_ALIGNMENT  0x38   // 3 bits of an index into the alignment table
FFS_ATTRIB_CHECKSUM        0x40
```

Note the collision: bit `0x01` means `TAIL_PRESENT` in Revision 1 volumes and
`LARGE_FILE` in FFSv3; bit `0x02` means `RECOVERY` or `DATA_ALIGNMENT2`. Which
reading applies depends on the volume's version, not on the file's.

The alignment of a file's body:

```
idx = (Attributes & FFS_ATTRIB_DATA_ALIGNMENT) >> 3;
if (Attributes & FFS_ATTRIB_DATA_ALIGNMENT2) and volumeRevision == 2:
    alignment = 1 << ffsAlignment2Table[idx];   // {17,18,19,20,21,22,23,24}
else:
    alignment = 1 << ffsAlignmentTable[idx];    // {0,4,7,9,10,12,15,16}
```

That is, the base table gives 1, 16, 128, 512, 1K, 4K, 32K and 64K bytes, and
the extended one from 128K to 16M.

### 5.4. The checksums

```
// the header: the sum of every byte of the header, less the two IntegrityCheck
// fields and State
calculatedHeader = 0x100 - (sum8(header) - IC.Checksum.Header
                                          - IC.Checksum.File
                                          - State);

// the body
if (Attributes & FFS_ATTRIB_CHECKSUM):
    calculatedData = checksum8(body)          // with an empty body this is a format error
else if volumeRevision == 1:
    calculatedData = FFS_FIXED_CHECKSUM  = 0x5A
else:
    calculatedData = FFS_FIXED_CHECKSUM2 = 0xAA
```

The body is only checked for files with a non-empty body.

### 5.5. The file's state

```
EFI_FILE_HEADER_CONSTRUCTION 0x01
EFI_FILE_HEADER_VALID        0x02
EFI_FILE_DATA_VALID          0x04
EFI_FILE_MARKED_FOR_UPDATE   0x08
EFI_FILE_DELETED             0x10
EFI_FILE_HEADER_INVALID      0x20
EFI_FILE_ERASE_POLARITY      0x80
```

The state bits are written in ascending order and are **inverted** if the
volume's erase polarity is 0. A file's `emptyByte` comes from its own
`State & EFI_FILE_ERASE_POLARITY` rather than from the volume — which is what
makes mixed cases readable.

### 5.6. File types

```
0x00 ALL (not allowed in an image)   0x0B FIRMWARE_VOLUME_IMAGE
0x01 RAW                              0x0C COMBINED_MM_DXE
0x02 FREEFORM                         0x0D MM_CORE
0x03 SECURITY_CORE                    0x0E MM_STANDALONE
0x04 PEI_CORE                         0x0F MM_CORE_STANDALONE
0x05 DXE_CORE                         0xC0..0xDF OEM
0x06 PEIM                             0xE0..0xEF DEBUG
0x07 DRIVER                           0xF0 PAD
0x08 COMBINED_PEIM_DRIVER             0xF0..0xFF FFS-specific
0x09 APPLICATION
0x0A MM (formerly SMM)
```

A type greater than `0x0F` and not equal to `0xF0` should be treated as unknown.

### 5.7. Special files

| GUID | Meaning |
|---|---|
| `1BA0062E-C779-4582-8566-336AE8F78F09` | **Volume Top File (VTF)** |
| `D6A2CB7F-6A18-4E2F-B43B-9920A733700A` | EDK2 DXE Core |
| `5AE3F37E-4EAE-41AE-8240-35465B5E81EB` | AMI DXE Core |
| `1B45CC0A-156A-428A-AF62-49864DA0E6E6` | PEI apriori |
| `FC510EE7-FFDC-11D4-BD41-0080C73C8881` | DXE apriori |
| `E4536585-7909-4A60-B5C6-ECDEA6EBFB54` | AMI padding file |
| `389CC6F2-1EA8-467B-AB8A-78E769AE2A15` | Phoenix vendor hash file |
| `CBC91F44-A4BC-4A5B-8696-703451D0B053` | AMI vendor hash file |
| `20BC8AC9-94D1-4208-AB28-5D673FD73487` | AMD compressed raw file |
| `DE3E049C-A218-4891-8658-5FC0FA84C788` | AMD microcode in TE/PE |
| `05CA01FC-…` … `05CA020B-…` | AMI ROM Hole 0..15 |

**The Volume Top File is critical.** The last byte of the last VTF in the image
is mapped at the physical address `0xFFFFFFFF`. From which:

```
addressDiff = 0xFFFFFFFF - base(lastVtf) - fullSize(lastVtf) + 1
physical_address = file_offset + addressDiff
```

Without a VTF the absolute addresses cannot be worked out at all, and the whole
second pass (FIT, reset vector, protected ranges) is skipped. The default value
`addressDiff = 0x100000000` means "the addresses are unknown".

Inside the VTF, at fixed addresses, lies the reset vector:

```c
typedef struct {
    UINT8  ApEntryVector[8];   // 0xFFFFFFD0
    UINT8  Reserved0[8];
    UINT32 PeiCoreEntryPoint;  // 0xFFFFFFE0
    UINT8  Reserved1[12];
    UINT8  ResetVector[8];     // 0xFFFFFFF0
    UINT32 ApStartupSegment;   // 0xFFFFFFF8
    UINT32 BootFvBaseAddress;  // 0xFFFFFFFC
} X86_RESET_VECTOR_DATA;
```

The value `0x12345678` in these fields means "not filled in" (EDK2 leaves a
placeholder).

### 5.8. Walking a volume's body

```
fileOffset = 0
while fileOffset < the size of the volume's body:
    fileSize = getFileSize(...)
    if fileSize == 0 → stop parsing

    if the first sizeof(EFI_FFS_FILE_HEADER) bytes are all emptyByte:
        // free space has been reached
        if the rest is not entirely emptyByte:
            find the first non-empty byte i
            align i down to 8: if i != ALIGN8(i) → i = ALIGN8(i) - 8
            [0, i)  → free space
            [i, …)  → "non-UEFI data", parse heuristically
        else:
            the whole rest → free space
        stop

    if what is left is not enough for the header or for fileSize:
        the rest → non-UEFI data, stop

    parse the file
    fileOffset = ALIGN8(fileOffset + fileSize)
```

The next file is always aligned to 8 bytes, whatever the version of FFS.

---

## 6. Sections

The body of a file of any type other than `RAW` and `PAD` is a sequence of
sections.

```c
typedef struct {
    UINT8 Size[3];             // UINT24, the full size of the section with its header
    UINT8 Type;
} EFI_COMMON_SECTION_HEADER;   // 4 bytes

typedef struct {
    UINT8  Size[3];            // == 0xFFFFFF, the marker for the extended header
    UINT8  Type;
    UINT32 ExtendedSize;
} EFI_COMMON_SECTION_HEADER2;  // 8 bytes
```

The extended header applies only in FFSv3 volumes: `Size == EFI_SECTION2_IS_USED
(0xFFFFFF)` → read `ExtendedSize`.

Sections inside a file are aligned to 4 bytes (`ALIGN4`).

### 6.1. Section types

**Encapsulating** (they hold other sections):

| Type | Name |
|---|---|
| `0x01` | `COMPRESSION` |
| `0x02` | `GUID_DEFINED` |
| `0x03` | `DISPOSABLE` |

**Leaf**:

| Type | Name | Type | Name |
|---|---|---|---|
| `0x10` | `PE32` | `0x17` | `FIRMWARE_VOLUME_IMAGE` |
| `0x11` | `PIC` | `0x18` | `FREEFORM_SUBTYPE_GUID` |
| `0x12` | `TE` | `0x19` | `RAW` |
| `0x13` | `DXE_DEPEX` | `0x1B` | `PEI_DEPEX` |
| `0x14` | `VERSION` | `0x1C` | `MM_DEPEX` |
| `0x15` | `USER_INTERFACE` | `0x20` | Insyde postcode (vendor) |
| `0x16` | `COMPATIBILITY16` | `0xF0` | Phoenix SCT postcode (vendor) |

### 6.2. The compression section (0x01)

```c
typedef struct {
    UINT32 UncompressedLength;
    UINT8  CompressionType;
} EFI_COMPRESSION_SECTION;
```

`CompressionType`: `0x00` — not compressed, `0x01` — Tiano/EFI 1.1 (the
EfiTianoDecompress algorithm), `0x02` — customized, `0x86` — LZMA with an x86
filter.

For type `0x01` both variants have to be tried — EFI 1.1 and Tiano: they differ
only in the width of a field and are told apart by which decompression succeeds.

### 6.3. The GUID-defined section (0x02)

```c
typedef struct {
    EFI_GUID SectionDefinitionGuid;
    UINT16   DataOffset;       // from the start of the section to the data
    UINT16   Attributes;
} EFI_GUID_DEFINED_SECTION;
```

The attributes: `PROCESSING_REQUIRED = 0x01`, `AUTH_STATUS_VALID = 0x02`.

The known GUIDs:

| GUID | Processing |
|---|---|
| `FC1BCDB0-7D31-49AA-936A-A4600D9DD083` | CRC32 (the data is not compressed, only checked) |
| `A31280AD-481E-41B6-95E8-127F4C984779` | Tiano |
| `EE4E5898-3914-4259-9D6E-DC7BD79403CF` | LZMA |
| `0ED85E23-F253-413F-A03C-901987B04397` | LZMA (HP) |
| `BD9921EA-ED91-404A-8B2F-B4D724747C8C` | LZMA (Microsoft) |
| `D42AE6BD-1352-4BFB-909A-CA72A6EAE889` | LZMA + x86 filter |
| `1D301FE9-BE79-4353-91C2-D23BC959AE0C` | GZip |
| `CE3233F5-2CD6-4D87-9152-4A238BB6D1C4` | Zlib (AMD) |
| `991EFAC0-E260-416B-A4B8-3B153072B804` | Zlib (AMD, second) |
| `3D532050-5CDA-4FD0-879E-0F7F630D5AFB` | Brotli |
| `0F9D89E8-9259-4F76-A5AF-0C89E34023DF` | Firmware contents signed |

The headers of the particular packers:

```c
typedef struct {                   // AMD Zlib
    UINT8  ZeroHeader[0x14];
    UINT32 CompressedSize;
    UINT8  ZeroFooter[0x100 - 4 - 0x14];
} EFI_AMD_ZLIB_SECTION_HEADER;

typedef struct {                   // Brotli
    UINT64 DecompressedSize;
    UINT64 ScratchBufferSize;
} EFI_BROTLI_SECTION_HEADER;
```

For signed sections (`FIRMWARE_CONTENTS_SIGNED`) the data is preceded by a
`WIN_CERTIFICATE_UEFI_GUID`:

```c
typedef struct { UINT32 Length; UINT16 Revision; UINT16 CertificateType; } WIN_CERTIFICATE;
typedef struct { WIN_CERTIFICATE Header; EFI_GUID CertType; } WIN_CERTIFICATE_UEFI_GUID;
typedef struct { EFI_GUID HashType; UINT8 PublicKey[256]; UINT8 Signature[256]; }
        EFI_CERT_BLOCK_RSA2048_SHA256;
```

`WIN_CERT_TYPE_EFI_GUID = 0x0EF1`, and `CertType` for RSA2048/SHA256 is
`A7717414-C616-4977-9420-844712A735BF`.

### 6.4. The other sections

```c
typedef struct { UINT16 BuildNumber; } EFI_VERSION_SECTION;        // then a UCS-2 string
typedef struct { EFI_GUID SubTypeGuid; } EFI_FREEFORM_SUBTYPE_GUID_SECTION;
typedef struct { UINT32 Postcode; } POSTCODE_SECTION;
```

`USER_INTERFACE` (0x15) — the body is entirely a UCS-2 string with a terminating
zero.

A `FIRMWARE_VOLUME_IMAGE` section (0x17) holds a nested volume — recursion back
to §3.

### 6.5. Depex sections

The body is bytecode of one-byte opcodes:

```
0x00 BEFORE (DXE only, first and only)
0x01 AFTER  (DXE only, first and only)
0x02 PUSH   + EFI_GUID (a 16-byte operand)
0x03 AND    0x04 OR     0x05 NOT
0x06 TRUE   0x07 FALSE  0x08 END
0x09 SOR    (DXE only, the first opcode)
```

---

## 7. Microcode

### 7.1. Intel

```c
typedef struct {
    UINT32 HeaderType;         // 1
    UINT32 UpdateRevision;
    UINT16 DateYear;           // BCD
    UINT8  DateDay;            // BCD
    UINT8  DateMonth;          // BCD
    UINT32 ProcessorSignature;
    UINT32 Checksum;           // the sum of every DWORD of the image == 0
    UINT32 LoaderRevision;     // 1
    UINT32 PlatformIds;
    UINT32 DataSize;           // 0 means 2000 bytes
    UINT32 TotalSize;
    UINT32 MetadataSize;       // reserved
    UINT32 UpdateRevisionMin;
    UINT32 Reserved;
} INTEL_MICROCODE_HEADER;      // 0x30 bytes
```

The validity criteria (`intelMicrocodeHeaderValid`) — all of them required:

- `DataSize % 4 == 0` and `DataSize <= 0xFFFFFF`;
- `TotalSize >= DataSize` and `TotalSize <= 0xFFFFFF`;
- `DateDay` — valid BCD in the ranges `01–09, 10–19, 20–29, 30–31`;
- `DateMonth` — valid BCD `01–09, 10–12`;
- `DateYear` — BCD in `1990–1999, 2000–2009, 2010–2019, 2020–2029, 2030–2039,
  2040–2049`;
- `HeaderType == 1`;
- `LoaderRevision == 1`.

When scanning, `TotalSize != 0` is required as well.

The extended signature table, if `TotalSize > 0x30 + DataSize`:

```c
typedef struct { UINT32 EntryCount; UINT32 Checksum; UINT8 Reserved[12]; }
        INTEL_MICROCODE_EXTENDED_HEADER;
typedef struct { UINT32 ProcessorSignature; UINT32 PlatformIds; UINT32 Checksum; }
        INTEL_MICROCODE_EXTENDED_HEADER_ENTRY;
```

An empty microcode slot has `FF FF FF FF` as its first 4 bytes. This is a legal
state: the FIT specification explicitly allows entries that point at empty slots.

### 7.2. AMD

Parsed separately (`amd_microcode.h`); the search runs both over raw areas and
inside TE/PE files with the GUID `DE3E049C-A218-4891-8658-5FC0FA84C788`.

---

## 8. IFWI: BPDT and CPD

Applies to images with a Converged Security Engine (Apollo Lake and newer).

```c
#define BPDT_GREEN_SIGNATURE  0x000055AA
#define BPDT_YELLOW_SIGNATURE 0x00AA55AA

typedef struct {
    UINT32 Signature;
    UINT16 NumEntries;
    UINT8  HeaderVersion;      // 1 or 2
    UINT8  RedundancyFlag;     // reserved in version 1
    UINT32 Checksum;
    UINT32 IfwiVersion;
    UINT16 FitcMajor, FitcMinor, FitcHotfix, FitcBuild;
} BPDT_HEADER;

typedef struct {
    UINT32 Type : 16;
    UINT32 SplitSubPartitionFirstPart  : 1;
    UINT32 SplitSubPartitionSecondPart : 1;
    UINT32 CodeSubPartition            : 1;
    UINT32 UmaCacheable                : 1;
    UINT32 Reserved : 12;
    UINT32 Offset;
    UINT32 Size;
} BPDT_ENTRY;
```

The partition types: `0 SMIP, 1 RBEP, 2 FTPR, 3 UCOD, 4 IBBP, 5 S_BPDT, 6 OBBP,
7 NFTP, 8 ISHC, 9 DLMP, 10 UEBP, 11 UTOK, 14 PMCP, 17 UEP, 18 WCOD, 19 LOCL,
20 OEMP, 21 FITC, 32 PCHC` and onwards (the full list is in `ffs.h`).

Type `5 (S_BPDT)` is a nested BPDT and is parsed recursively.

```c
#define CPD_SIGNATURE 0x44504324   // "$CPD"

typedef struct {                   // rev 1
    UINT32 Signature; UINT32 NumEntries;
    UINT8 HeaderVersion;           // 1
    UINT8 EntryVersion; UINT8 HeaderLength; UINT8 HeaderChecksum;
    UINT8 ShortName[4];
} CPD_REV1_HEADER;

typedef struct {                   // rev 2
    UINT32 Signature; UINT32 NumEntries;
    UINT8 HeaderVersion;           // 2
    UINT8 EntryVersion; UINT8 HeaderLength; UINT8 Reserved;
    UINT8 ShortName[4]; UINT32 Checksum;
} CPD_REV2_HEADER;

typedef struct {
    UINT8 EntryName[12];
    struct { UINT32 Offset : 25; UINT32 HuffmanCompressed : 1; UINT32 Reserved : 6; } Offset;
    UINT32 Length;
    UINT32 Reserved;
} CPD_ENTRY;
```

Inside the CPD partitions lie manifests (`CPD_MANIFEST_HEADER`) and extensions
(`CPD_EXTENTION_HEADER {UINT32 Type; UINT32 Length;}`) — around 40 types, of
which the practically important ones are `15 SIGNED_PACKAGE_INFO`,
`10 MODULE_ATTRIBUTES` (which carries `CompressionType`: 0 — none, 1 — Huffman,
2 — LZMA), `19 BOOT_POLICY`, `14 KEY_MANIFEST`, `22 IFWI_PARTITION_MANIFEST`.

---

## 9. NVRAM

Variable stores are found by searching heuristically for signatures inside raw
areas and volumes with an NVRAM GUID. The formats supported (the details are in
`common/nvram.h` and the kaitai descriptions in `common/ksy/`):

| Format | Signature / marker |
|---|---|
| EDK2 VSS / VSS2 | `$VSS` / a GUID header |
| EDK2 FTW | `EFI_FAULT_TOLERANT_WORKING_BLOCK_HEADER` |
| AMI NVAR | `NVAR` |
| Apple SYSF/Fsys | `Fsys` / `Gaid` |
| Phoenix EVSA | `EVSA` |
| Phoenix FlashMap | `_FLASH_MAP` |
| Insyde FDC / FDM | `$FDC` / `HFDM` (0x4D444648) |
| Dell DVAR | `DVAR` (0x52415644) |
| MS SLIC | a marker / a public key |

For a general-purpose parser it is sensible to pick NVRAM stores out as opaque
elements first and parse them on demand.

The Insyde Flash Device Map deserves a mention of its own, since it lays out the
whole image:

```c
typedef struct {
    UINT32 Signature;          // 'HFDM' = 0x4D444648
    UINT32 Size;
    UINT32 DataOffset;
    UINT32 EntrySize;
    UINT8  EntryFormat;
    UINT8  Revision;
    UINT8  ExtensionCount;
    UINT8  Checksum;
    UINT64 FdBaseAddress;
} INSYDE_FLASH_DEVICE_MAP_HEADER;

typedef struct {
    EFI_GUID RegionTypeGuid;
    UINT8    RegionId[16];
    UINT64   RegionOffset;
    UINT64   RegionSize;
    UINT32   Attributes;       // 0x01 modifiable, 0x02 ignored
    // UINT8 Hash[]; the size depends on EntryFormat/EntrySize
} INSYDE_FLASH_DEVICE_MAP_ENTRY;
```

---

## 10. The second pass

Runs after the tree has been built, and needs a VTF that was found and is not
compressed.

1. **Working out `addressDiff`** — see §5.7.
2. **The reset vector** — parsing `X86_RESET_VECTOR_DATA` in the VTF's body.
3. **The FIT** — see the separate document `FIT_TABLE_FORMAT.md`.
4. **The Boot Guard protected ranges.** The vendor hash files:

```c
typedef struct { UINT8 Hash[32]; UINT32 Base; UINT32 Size; }
        PROTECTED_RANGE_VENDOR_HASH_FILE_ENTRY;

typedef struct { UINT64 Signature; UINT32 NumEntries; }   // '$HASHTBL'
        PROTECTED_RANGE_VENDOR_HASH_FILE_HEADER_PHOENIX;

typedef struct { UINT8 Hash[32]; UINT32 Size; }           // AMI v1, base from the flash map
        PROTECTED_RANGE_VENDOR_HASH_FILE_HEADER_AMI_V1;

typedef struct { PROTECTED_RANGE_VENDOR_HASH_FILE_ENTRY Hash0, Hash1; }
        PROTECTED_RANGE_VENDOR_HASH_FILE_HEADER_AMI_V2;

typedef struct {
    UINT8  Hash[32];
    UINT32 FvMainSegmentBase[3];
    UINT32 FvMainSegmentSize[3];
    UINT32 NestedFvBase, NestedFvSize;
    UINT8  Reserved[48];
} PROTECTED_RANGE_VENDOR_HASH_FILE_HEADER_AMI_V3;
```

The ranges listed in these files, together with the IBB described in the Boot
Policy, make up the list of areas that Boot Guard will break if they are
changed.

5. **Checking the bases of TE images** — the `StrippedSize` field of a TE section
   sometimes holds an adjusted base; comparing it with the actual address reveals
   images that a vendor's tool has relocated.

---

## 11. Practical notes

**Limit the recursion depth.** Volume → file → section → volume → … Real images
nest 8 to 10 deep, but a corrupt one can recurse for ever. Set a hard limit.

**Bounds-check at every step.** Every size field is read from untrusted data.
Before any `mid(offset, size)`, check `offset + size <= buffer.size()` allowing
for overflow (add in a 64-bit type, or compare by subtracting).

**Zero sizes.** `FvLength == 0`, `fileSize == 0`, `sectionSize == 0`,
`fitHeader->Size == 0` — all of these mean a broken structure and must stop the
parse of that level, or the result is an infinite loop.

**Broken images are the norm.** Firmware from a flash dump almost always
contains at least one structure that does not match the specification. A parser
has to collect diagnostic messages and carry on rather than fall over the first
problem. The reference implementation uses a "flag plus message" pair
everywhere, never an immediate exit.

**Padding is an element too.** Everything that was not parsed has to end up in
the tree as padding, with its bytes kept. Otherwise rebuilding the image becomes
impossible.

**What must not be moved when rebuilding.** These have to be marked "fixed":

- elements with `FFS_ATTRIB_FIXED`;
- the element containing the FIT, and every element the FIT refers to;
- the VTF;
- areas covered by Boot Guard protected ranges;
- the regions listed in the flash descriptor and in the Insyde Flash Device Map.

**Compressed elements.** Absolute addresses are meaningless for elements inside
compressed containers: the decompressor will place them wherever it likes.
Alignment checks and the FIT's address checks are therefore not performed for
them.
