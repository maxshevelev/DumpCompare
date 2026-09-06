# Intel Firmware Interface Table (FIT) — structure and rules for modifying it

This document describes the format of the FIT table and the step-by-step rules
for adding and removing entries. The structures and algorithms were checked
against the UEFITool NE implementation (`common/intel_fit.h`,
`common/fitparser.cpp`, branch `new_engine`, version A76) and against Intel's
"Firmware Interface Table BIOS Specification" r1.4 (Intel document 599500).

---

## 1. What it is for

The FIT is a table of pointers to the components of an image that the processor
and its microcode have to find and process **before** the first instruction of
the reset vector runs. Microcode updates, the Startup ACM, the Boot Guard
manifests, the TXT/TPM policies and more are all loaded through it.

What follows for any tool that edits an image: the addresses in a FIT are
absolute physical addresses, not offsets. Moving a component the FIT points at
means editing the table.

---

## 2. Where the table is

The pointer to the FIT sits at the fixed physical address `0xFFFFFFC0`
(`INTEL_FIT_POINTER_OFFSET = 0x40` from the top of the address space).

Converting it to an offset in the image file:

```
addressDiff  = 0x100000000 - image_size          // for a full flash dump
file_offset  = physical_address - addressDiff
```

More precisely, in the general case — where the image does not occupy the whole
top of the address space — `addressDiff` is worked out from the Volume Top
File:

```
addressDiff = 0xFFFFFFFF - base(lastVtf) - fullSize(lastVtf) + 1
```

For a 16 MiB image mapped entirely below `0xFFFFFFFF` this gives
`addressDiff = 0xFF000000`, and the FIT pointer is read at offset
`image_size - 0x40`.

```
FIT_pointer = read_le32(image, image_size - 0x40)
FIT_offset  = FIT_pointer - addressDiff
```

### 2.1. How to find it (for verification)

The reliable way to find the FIT is not to trust the pointer blindly but to
check both ends of the link:

1. Read `FIT_pointer` at `image_size - 0x40`.
2. Find every occurrence in the image of the signature `_FIT_   ` — the eight
   bytes `5F 46 49 54 5F 20 20 20`
   (`INTEL_FIT_SIGNATURE = 0x2020205F5449465F`).
3. For each candidate, work out its physical address and compare it with
   `FIT_pointer`. A match is the real table.
4. Check as well that the image has room for at least two entries (the header
   plus at least one microcode entry).

Candidates that do not match the pointer are somebody else's data that happened
to match the signature — they turn up inside compressed blocks often enough.

---

## 3. The structure of an entry

Every entry, the header included, is the same size: **16 bytes**.

```c
typedef struct {
    UINT64 Address;            // +0x00  component base address, 16-byte aligned
    UINT32 Size : 24;          // +0x08  component size in 16-byte units
    UINT32 Reserved : 8;       // +0x0B  must be 0
    UINT16 Version;            // +0x0C  BCD: low byte minor, high byte major
    UINT8  Type : 7;           // +0x0E  bits [6:0]
    UINT8  ChecksumValid : 1;  // +0x0E  bit [7]
    UINT8  Checksum;           // +0x0F
} INTEL_FIT_ENTRY;
```

Byte for byte:

```
offset    size    field
  0x00      8     Address              (LE)
  0x08      3     Size                 (LE, UINT24)
  0x0B      1     Reserved             (0x00)
  0x0C      2     Version              (LE, BCD)
  0x0E      1     Type[6:0] | CV[7]
  0x0F      1     Checksum
```

**Entries must be ordered by ascending `Type`.** That is a requirement of the
specification rather than a recommendation: the FIT handler in the microcode is
entitled to stop looking at the first type greater than the one it wants.

---

## 4. The header (Type = 0x00)

The header is exactly one entry, always the first.

```
Address        = 0x2020205F5449465F     // ASCII "_FIT_   ", read as a signature
Size           = the number of entries in the table, INCLUDING the header
Reserved       = 0
Version        = 0x0100
Type           = 0x00
ChecksumValid  = 0 or 1
Checksum       = see §5
```

The detail people get wrong most often: in the header the `Size` field holds
**the number of entries**, not a size in bytes and not a component size in
16-byte units. The full size of the table is:

```
fit_size_bytes = header.Size * 16
```

Both readings — "the number of entries" and "the size in 16-byte units" — give
the same number here, since an entry is 16 bytes.

---

## 5. The checksum

Checked only when the `ChecksumValid` bit is set in the header.

The algorithm is a checksum8 over **the whole table**:

```
sum = 0
for every byte b of the whole table (header.Size * 16 bytes),
    counting the header.Checksum field as zero:
        sum = (sum + b) & 0xFF
correct_checksum = (0x100 - sum) & 0xFF
```

Put another way: the sum of every byte of the table, the `Checksum` field
included, must come out at zero modulo 256.

The `Checksum` fields of the other entries have nothing to do with this sum —
they belong to the components themselves (see §7) and are unused in the vast
majority of entries.

A reference implementation in Python:

```python
def fit_checksum(table: bytes) -> int:
    t = bytearray(table)
    t[15] = 0                      # zero the header's Checksum
    return (-sum(t)) & 0xFF
```

---

## 6. Entry types

| Type | Name | Required? |
|---|---|---|
| `0x00` | FIT Header | exactly one, first |
| `0x01` | Microcode | at least one |
| `0x02` | Startup ACM | optional; required for AC boot and Boot Guard |
| `0x03` | Diagnostic ACM | optional |
| `0x04` | Platform Boot Policy | optional |
| `0x06` | FIT Reset State | optional |
| `0x07` | BIOS Startup Module | optional |
| `0x08` | TPM Policy | optional, no more than one |
| `0x09` | BIOS Policy | optional |
| `0x0A` | TXT Policy | optional, no more than one |
| `0x0B` | Boot Guard Key Manifest | optional |
| `0x0C` | Boot Guard Boot Policy | optional |
| `0x10` | CSE SecureBoot Settings | optional, there may be several |
| `0x1A` | VAB Provisioning Table | optional |
| `0x1B` | VAB Key Manifest | optional |
| `0x1C` | VAB Image Manifest | optional |
| `0x1D` | VAB Image Hash Descriptors | optional |
| `0x2C` | SACM Debug Record | optional |
| `0x2D` | ACM Feature Policy | optional |
| `0x2E` | SCRTM Error Record | optional |
| `0x2F` | JMP Debug Policy | optional |
| `0x30`–`0x70` | reserved for OEMs | — |
| `0x7F` | **Empty** | an empty slot, see §9.4 |

The ranges `0x05`, `0x0D`–`0x0F`, `0x11`–`0x19`, `0x1E`–`0x2B` and `0x71`–`0x7E`
are reserved by Intel.

---

## 7. Rules for particular types

### 7.1. Microcode (0x01)

- At least one entry is required.
- `Address` points at the first byte of the microcode header, aligned to 16.
- The component at that address **must not** be compressed, encoded or
  encrypted.
- `ChecksumValid` = 0.
- `Size` is **unused** and must be 0. The real size comes from the `TotalSize`
  field of the microcode header.
- `Version` = `0x0100`.
- The slot may be empty — the first 4 bytes at `Address` are `FF FF FF FF`.
  That is a legal state, provided for by the specification for slots reserved
  for future updates.

### 7.2. Startup ACM (0x02)

- `Address` points at the first byte of the ACM header.
- `ChecksumValid` = 0, `Size` = 0, `Version` = `0x0100`.
- A hardware constraint of its own: the Startup ACM is mapped by a single MTRR
  base/limit pair, so

```
MTRR_Size = 2 ^ ceil(log2(Startup_ACM_Size))
MTRR_Base must be a multiple of MTRR_Size
```

  The whole area `[MTRR_Base, MTRR_Base + MTRR_Size)` — the Authenticated Code
  Execution Area (ACEA) — must contain nothing but the ACM itself. This is the
  strictest placement constraint in the whole table.

### 7.3. TPM Policy (0x08) and TXT Policy (0x0A)

The format of the `Address` field depends on `Version`:

```c
#define INTEL_FIT_POLICY_VERSION_INDEX_IO            0
#define INTEL_FIT_POLICY_VERSION_FLAT_MEMORY_ADDRESS 1

typedef struct {
    UINT16 IndexRegisterAddress;
    UINT16 DataRegisterAddress;
    UINT8  AccessWidthInBytes;   // 1 or 2
    UINT8  BitPosition;
    UINT16 Index;
} INTEL_FIT_INDEX_IO_ADDRESS;

typedef union {
    UINT64 FlatMemoryAddress;
    INTEL_FIT_INDEX_IO_ADDRESS IndexIo;
} INTEL_FIT_POLICY_PTR;
```

With `Version == 0` the first eight bytes of the entry are not an address but a
descriptor of Index/IO registers, and must not be treated as a pointer.
With `Version == 1` they are an ordinary flat address.

Bit 0 at the given address holds the policy itself. `ChecksumValid` = 0,
`Size` = 0.

### 7.4. Boot Guard Key Manifest (0x0B) and Boot Policy (0x0C)

If a Startup ACM is present, both of these entries usually have to be as well.
A cross-check: the hash of the Boot Policy's public key, written down in the Key
Manifest, must match the SHA-256 or SHA-384 of the actual public key in the Boot
Policy. A mismatch means one of the two manifests has been replaced.

### 7.5. CSE SecureBoot (0x10)

There may be several entries, and their order among themselves does not matter.
The subtype is given by the `Reserved` field:

```
0  Reserved                 7  IBBL Hash
1  Key Hash                 8  IBB Hash
2  CSE Measurement Hash     9  OEM ID
3  Boot Policy             10  OEM SKU ID
4  Other Boot Policy       11  Boot Device Indicator (1=SPI, 2=eMMC, 3=UFS)
5  OEM SMIP                12  FIT Patch Manifest
6  MRC Training Data       13  AC Module Manifest
```

`ChecksumValid` = 0, `Version` = `0x0100`.

---

## 8. The invariants a validator must check

1. The pointer at `image_size - 0x40` leads to the signature `_FIT_   `.
2. The first entry has `Type == 0x00`.
3. `header.Size != 0`, and `header.Size * 16` fits inside the image without
   crossing its end.
4. There is no second header (`Type == 0x00`) in the table.
5. Entry types do not decrease as the table is walked.
6. If `header.ChecksumValid == 1`, the table's checksum8 comes out at zero.
7. There is at least one entry of type `0x01`.
8. For every entry with a real address: `addressDiff < Address < 0xFFFFFFFF`,
   that is, the address falls inside the image.
9. Every `Address` is aligned to 16 bytes.
10. For microcode entries: at the address there is either a valid microcode
    header or `FF FF FF FF` (an empty slot). Anything else is an error.
11. The FIT table itself and every component it refers to are in a part of the
    image that must not be relocated.

---

## 9. Adding an entry

### 9.1. Preconditions

The table can be extended in two ways:

- **by filling an empty slot** of type `0x7F` — preferable, since neither the
  size of the table nor its position changes;
- **by increasing `header.Size`** — possible only if there is free space
  (`0xFF` fill) directly behind the table that nothing else has taken.

Moving the table as a whole is highly undesirable: the pointer at `0xFFFFFFC0`
would have to be edited, and it sits inside the VTF, which may be covered by a
Boot Guard protected range.

### 9.2. The procedure for adding a microcode entry

Step by step, for the most common case:

**Step 1. Place the component in the image.**

Find an area free for the microcode. The requirements:
- the address is aligned to 16 bytes;
- the area is no smaller than `TotalSize` from the microcode header;
- the area does not overlap any element of the image's tree;
- the area is not inside a Boot Guard protected range;
- the area does not cross a flash descriptor region boundary.

Microcode usually lies in one contiguous block, and a new one is appended right
after the last: `new_offset = last_ucode_offset + last_ucode_TotalSize`.

**Step 2. Write the microcode body** at the chosen offset.

**Step 3. Work out the physical address.**

```
Address = new_offset + addressDiff
```

This is the only step where a mistake is not diagnosed automatically — see §11.

**Step 4. Find the position for the entry in the table.**

Entries are ordered by ascending `Type`. For microcode (`0x01`) that means
directly after the last entry of type `0x01`. If the addition is going into an
empty `0x7F` slot and there are no free slots among the microcode entries, the
tail of the table will have to be shifted.

**Step 5. Fill in the entry.**

```
Address       = the one worked out in step 3
Size          = 0                    // unused for microcode
Reserved      = 0
Version       = 0x0100
Type          = 0x01
ChecksumValid = 0
Checksum      = 0
```

The entry's bytes, for the example `Address = 0xFFB8FC60`:

```
60 FC B8 FF 00 00 00 00 | 00 00 00 00 | 00 01 | 01 | 00
└──── Address (LE) ────┘  └─Size─┘ Rsv  └─Ver─┘  Type CV|Cks
```

**Step 6. Update `header.Size`** — increase it by 1 unless the entry went into
an empty slot.

**Step 7. Recompute the header's checksum** per §5, if `ChecksumValid == 1`.
Write it to byte `+0x0F` of the header.

**Step 8. Check that the size of the image has not changed.** The size of a
flash dump is fixed by the capacity of the chip; any change to the overall size
makes the image unflashable.

**Step 9. Run the validator from §8.**

### 9.3. What else an addition breaks

- **Boot Guard.** If the area the new component was written to is covered by a
  protected range (the IBB described in the Boot Policy, or a vendor hash file),
  the hash will stop matching and the platform will not start. Check before
  writing, not after.
- **The checksums of the containers above it.** If the microcode lies inside an
  FFS file or a volume rather than in a raw area of the BIOS region, the FFS
  file's checksum — and possibly the volume's `UsedSpace` — will have to be
  recomputed.
- **Signed capsules.** An image extracted from a signed capsule no longer
  matches the signature once edited. Such an image can only be flashed directly,
  with a programmer.

### 9.4. Empty slots (Type = 0x7F)

Vendors often reserve room in the table with entries of type `0x7F`. Such a slot
looks like this:

```
Address       = arbitrary, usually 0
Size          = 0
Version       = 0x0100 or 0x0000
Type          = 0x7F
ChecksumValid = 0
Checksum      = 0
```

Filling an empty slot is the safest way to add an entry: `header.Size` does not
change, the position of the table does not change, and only the checksum has to
be recomputed. But watch the ordering of types: a `0x7F` slot is at the end of
the table, while an entry of type `0x01` has to stand among the other microcode
entries. In practice that means a shift: insert the new entry in the right
place, moving everything after it 16 bytes down, and "eat" one `0x7F` slot at
the tail.

---

## 10. Removing an entry

**Step 1.** Work out what exactly is being removed. Entries of type `0x00` (the
header) cannot be removed. Removing the last entry of type `0x01` makes the
table invalid — there has to be at least one microcode.

**Step 2. Choose how.**

- **Replace it with an empty slot.** Change `Type` to `0x7F` and zero `Address`
  and `Size`. The ordering of types is broken by this (`0x7F` ends up in the
  middle), which formally contradicts the specification. Acceptable only as a
  temporary measure.
- **Collapse the table** (the proper way). Move every entry after it 16 bytes
  up, and either write an empty `0x7F` slot into the tail this frees or
  decrease `header.Size` by 1 and wipe the trailing 16 bytes with `0xFF`.

**Step 3.** If `header.Size` was decreased, wipe the 16 bytes it freed with the
region's filler byte (`0xFF`), so that no rubbish is left to confuse another
parser.

**Step 4.** Recompute the header's checksum.

**Step 5.** Decide what becomes of the component itself. Leaving it in the image
is safer than wiping it: it may be covered by a Boot Guard protected range, or
other structures may refer to it. If it is wiped after all, the area is filled
with `0xFF`, and this must not change the size of the image.

**Step 6.** Run the validator from §8.

---

## 11. A real case, worked through: an entry with a size of zero

The symptom: the last microcode entry in the table is displayed by a parser with
a size of `00000000h` and an empty information field, while the two identical
entries before it are read correctly.

The mechanics. The parser first takes the size straight from the FIT entry:

```c
UINT32 currentEntrySize = currentEntry->Size;      // 0 for microcode, per the spec
```

and substitutes the real size only after the component has been validated:

```c
realSize = ucodeHeader->TotalSize;                 // the handler's last line
```

If there turns out to be no valid microcode header at the address from the
entry, the handler exits early and the original zero stays in the table.

A diagnostic reading of one particular image (16 MiB, `addressDiff = 0xFF000000`,
FIT at `0xFFE00100`, 4 entries):

| # | Address in the FIT | Offset | What is actually there |
|---|---|---|---|
| 1 | `FFB60060` | `B60060` | ucode `000806EA`, TotalSize `018000` |
| 2 | `FFB78060` | `B78060` | ucode `000906EA`, TotalSize `017C00` |
| 3 | `FFBBFC60` | `BBFC60` | `FF FF FF FF …` — empty |

Scanning the whole image for microcode headers found the third component at
offset `B8FC60`, that is at address `FFB8FC60`. The table says `FFBBFC60` — an
error of one hexadecimal digit (`8` → `B`, a miss of `0x30000`). The address
aimed at landed in the free `0xFF` area that begins directly behind the
microcode.

A second defect of the same edit: the FIT header's checksum was left over from
the old table — `CC` was stored, the current contents need `B3`, and after the
address is corrected, `B6`.

**The conclusion for anyone implementing a tool:** after writing an address,
always verify that the expected structure is there. The check costs one read of
48 bytes and catches the whole class of "missed the address" mistakes. It is
also worth reporting explicitly rather than leaving a silent zero in the size
field — a zero size is visually indistinguishable from a legitimate "Size is
unused".

---

## 12. Reference parsing code

```python
import struct

FIT_SIGNATURE = b"_FIT_   "

def parse_fit(image: bytes):
    size = len(image)
    address_diff = 0x100000000 - size

    ptr = struct.unpack_from("<I", image, size - 0x40)[0]
    off = ptr - address_diff
    if not (0 <= off < size - 16):
        raise ValueError("FIT pointer out of image")
    if image[off:off + 8] != FIT_SIGNATURE:
        raise ValueError("no FIT signature at pointed address")

    count = struct.unpack_from("<I", image, off + 8)[0] & 0xFFFFFF
    if count == 0 or off + count * 16 > size:
        raise ValueError("bad FIT size")

    header_flags = image[off + 14]
    if header_flags & 0x80:                       # ChecksumValid
        t = bytearray(image[off:off + count * 16])
        stored, t[15] = t[15], 0
        if (stored + sum(t)) & 0xFF:
            raise ValueError("bad FIT checksum")

    entries = []
    prev_type = -1
    for i in range(count):
        e = image[off + 16 * i: off + 16 * (i + 1)]
        addr = struct.unpack_from("<Q", e, 0)[0]
        esize = struct.unpack_from("<I", e, 8)[0] & 0xFFFFFF
        ver = struct.unpack_from("<H", e, 12)[0]
        etype = e[14] & 0x7F
        cv = e[14] >> 7
        cks = e[15]

        if i == 0 and etype != 0x00:
            raise ValueError("first entry is not a FIT header")
        if i > 0 and etype == 0x00:
            raise ValueError("second FIT header found")
        if etype < prev_type:
            raise ValueError("FIT entries are not sorted by type")
        prev_type = etype

        entries.append(dict(index=i, address=addr, size=esize, version=ver,
                            type=etype, checksum_valid=cv, checksum=cks,
                            offset=(addr - address_diff)
                                   if address_diff < addr < 0xFFFFFFFF else None))
    return entries
```

Checking the component a microcode entry refers to:

```python
def microcode_at(image: bytes, off: int):
    if off is None or off + 0x30 > len(image):
        return None
    (ht, rev, yr, dd, mm, ps, cks, lr, pid, ds, ts) = struct.unpack_from(
        "<IIHBBIIIIII", image, off)
    if ht != 1 or lr != 1:
        return None                       # an empty FF FF FF FF slot included
    if ds % 4 or ds > 0xFFFFFF or ts < ds or ts > 0xFFFFFF or ts == 0:
        return None
    if not (0x1990 <= yr <= 0x2049):
        return None
    return dict(cpu_signature=ps, platform_ids=pid, revision=rev,
                date=(dd, mm, yr), total_size=ts)
```

---

## 13. Constants, collected

```c
#define INTEL_FIT_POINTER_OFFSET 0x40
#define INTEL_FIT_SIGNATURE      0x2020205F5449465FULL   // "_FIT_   "

#define INTEL_FIT_TYPE_HEADER                     0x00
#define INTEL_FIT_TYPE_MICROCODE                  0x01
#define INTEL_FIT_TYPE_STARTUP_AC_MODULE          0x02
#define INTEL_FIT_TYPE_DIAG_AC_MODULE             0x03
#define INTEL_FIT_TYPE_PLATFORM_BOOT_POLICY       0x04
#define INTEL_FIT_TYPE_FIT_RESET_STATE            0x06
#define INTEL_FIT_TYPE_BIOS_STARTUP_MODULE        0x07
#define INTEL_FIT_TYPE_TPM_POLICY                 0x08
#define INTEL_FIT_TYPE_BIOS_POLICY                0x09
#define INTEL_FIT_TYPE_TXT_POLICY                 0x0A
#define INTEL_FIT_TYPE_BOOT_GUARD_KEY_MANIFEST    0x0B
#define INTEL_FIT_TYPE_BOOT_GUARD_BOOT_POLICY     0x0C
#define INTEL_FIT_TYPE_CSE_SECURE_BOOT            0x10
#define INTEL_FIT_TYPE_VAB_PROVISIONING_TABLE     0x1A
#define INTEL_FIT_TYPE_VAB_KEY_MANIFEST           0x1B
#define INTEL_FIT_TYPE_VAB_IMAGE_MANIFEST         0x1C
#define INTEL_FIT_TYPE_VAB_IMAGE_HASH_DESCRIPTORS 0x1D
#define INTEL_FIT_TYPE_SACM_DEBUG_RECORD          0x2C
#define INTEL_FIT_TYPE_ACM_FEATURE_POLICY         0x2D
#define INTEL_FIT_TYPE_SCRTM_ERROR_RECORD         0x2E
#define INTEL_FIT_TYPE_JMP_DEBUG_POLICY           0x2F
#define INTEL_FIT_TYPE_OEM_RESERVED_30            0x30   // .. 0x70
#define INTEL_FIT_TYPE_EMPTY                      0x7F

#define INTEL_ACM_HARDCODED_RSA_EXPONENT 0x10001
```

---

## 14. Sources

- Intel, "Firmware Interface Table BIOS Specification", revision 1.4 —
  <https://cdrdv2-public.intel.com/599500/Firmware-Interface-Table-BIOS-Specification-r1p4.pdf>
- UEFITool NE, `common/intel_fit.h` — the structure definitions and the
  comments carrying the rules for each entry type.
- UEFITool NE, `common/fitparser.cpp` — the reference implementation of
  finding, parsing and validating the table, Boot Guard cross-checks included.
