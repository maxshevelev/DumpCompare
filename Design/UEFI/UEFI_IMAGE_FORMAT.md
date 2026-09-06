# Формат образа UEFI-прошивки — описание для реализации парсера

Документ описывает структуру образа прошивки, совместимого с UEFI PI, в объёме,
достаточном для написания парсера с нуля. Все структуры и алгоритмы выверены по
эталонной реализации UEFITool NE (`common/ffsparser.cpp`, `common/ffs.h`,
`common/descriptor.h`, ветка `new_engine`, версия A76).

---

## 0. Общие соглашения

| Свойство | Значение |
|---|---|
| Порядок байт | little-endian везде, без исключений |
| Упаковка структур | плотная, `#pragma pack(1)`, выравнивающих дыр нет |
| Незанятое пространство | заполнено байтом `emptyByte`: `0xFF` при erase polarity = 1, `0x00` при 0 |
| Базовый тип GUID | `EFI_GUID` = `{UINT32 Data1; UINT16 Data2; UINT16 Data3; UINT8 Data4[8];}`, 16 байт |

Вспомогательные операции, которые понадобятся повсеместно:

```
ALIGN4(x)  = (x + 3)  & ~3
ALIGN8(x)  = (x + 7)  & ~7
ALIGN16(x) = (x + 15) & ~15

uint24ToUint32(p) = p[0] | (p[1] << 8) | (p[2] << 16)

calculateSum8(buf, len)       = сумма байт по модулю 256
calculateChecksum8(buf, len)  = (0x100 - calculateSum8(buf, len)) & 0xFF
calculateChecksum16(buf, len) = аналогично для UINT16, len должен быть чётным
```

Контрольная сумма «checksum8» построена так, что сумма всех байт вместе с полем
контрольной суммы даёт 0. Это же правило действует для FIT, FFS-файлов и микрокода.

### Рекомендуемая модель данных

Эталонный парсер строит дерево, где каждый узел хранит:

- `type` / `subtype` — что это за элемент,
- `offset` — смещение относительно родителя,
- `base` — абсолютное смещение от начала образа (вычисляемое),
- `header`, `body`, `tail` — три непересекающихся среза байт,
- `fixed` — флаг «нельзя двигать при пересборке»,
- `compressed` — лежит ли элемент внутри сжатого контейнера,
- `parsingData` — служебные данные, унаследованные детьми (erase polarity,
  версия FFS, выравнивание тома, GUID файла).

Разделение на `header`/`body`/`tail` принципиально: почти каждый уровень
вложенности — это «заголовок + тело», и тело следующего уровня разбирается
рекурсивно. `tail` используется только для FFSv1-файлов с `FFS_ATTRIB_TAIL_PRESENT`.

Разбор идёт в два прохода:

1. **Первый проход** — построение дерева от корня вниз, чисто по смещениям.
2. **Второй проход** — всё, что требует знания абсолютных адресов: вычисление
   `addressDiff`, разбор reset vector, поиск и разбор FIT, проверка защищённых
   диапазонов Boot Guard, проверка баз TE-образов. Второй проход возможен только
   если найден Volume Top File и он не лежит внутри сжатого элемента.

---

## 1. Верхний уровень: определение типа образа

Алгоритм на входном буфере целиком:

```
1. Если начало буфера — известная сигнатура капсулы → снять заголовок капсулы,
   продолжить с тела.
2. Если по смещению 0x00 или 0x10 лежит FLASH_DESCRIPTOR_SIGNATURE (0x0FF0A55A)
   → это Intel-образ с флеш-дескриптором.
3. Иначе → «generic image»: весь буфер считается одной raw-областью
   (BIOS region), сканируется эвристически (см. §4).
```

Смещение 0x10 проверяется потому, что первые 16 байт дескриптора —
`ReservedVector`, на x86 забитый `0xFF`, а на некоторых ARM-образах там лежит
реальный ARM reset vector.

### 1.1. Капсулы

```c
typedef struct {
    EFI_GUID CapsuleGuid;
    UINT32   HeaderSize;      // тело начинается с этого смещения
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
    UINT16 RomImageOffset;       // от начала заголовка капсулы до тела
    UINT16 RomLayoutOffset;
} APTIO_CAPSULE_HEADER;
```

Флаги: `SETUP = 0x00000001`, `PERSIST_ACROSS_RESET = 0x00010000`,
`POPULATE_SYSTEM_TABLE = 0x00020000`.

Распознаваемые GUID капсул:

| GUID | Тип |
|---|---|
| `3B6686BD-0D76-4030-B70E-B5519E2FC5A0` | стандартная EFI-капсула |
| `6DCBD5ED-E82D-4C44-BDA1-7194199AD92A` | стандартная FMP-капсула |
| `539182B9-ABB5-4391-B69A-E3A943F72FCC` | Intel |
| `E20BAFD3-9914-4F4F-9537-3129E090EB3C` | Lenovo |
| `25B5FE76-8243-4A5C-A9BD-7EE3246198B5` | Lenovo (второй) |
| `3BE07062-1D51-45D2-832B-F093257ED461` | Toshiba |
| `4A3CA68B-7723-48FB-803D-578CC1FEC44D` | AMI Aptio signed |
| `14EEBB90-890A-43DB-AED1-5D3C4588A418` | AMI Aptio unsigned |

Для Aptio signed размер тела берётся по `RomImageOffset`; между заголовком и телом
лежит `FW_CERTIFICATE` + `ROM_AREA[]`, которые для целей парсинга образа можно
пропустить. Если `CapsuleImageSize` меньше фактического размера буфера, хвост —
мусор после капсулы, его стоит выделить в отдельный узел, а не молча отбрасывать.

---

## 2. Intel Flash Descriptor

Дескриптор занимает первые `0x1000` байт образа.

```c
typedef struct {
    UINT8  ReservedVector[16];
    UINT32 Signature;            // 0x0FF0A55A
} FLASH_DESCRIPTOR_HEADER;
```

### 2.1. Карта дескриптора (FLMAP)

Сразу за заголовком, по смещению `0x14`:

```c
typedef struct {
    // FLMAP0
    UINT32 ComponentBase      : 8;   // биты [11:4] адреса
    UINT32 NumberOfFlashChips : 2;   // zero-based
    UINT32                    : 6;
    UINT32 RegionBase         : 8;
    UINT32 NumberOfRegions    : 3;   // зарезервировано в дескрипторе v2
    UINT32                    : 5;
    // FLMAP1
    UINT32 MasterBase         : 8;
    UINT32 NumberOfMasters    : 2;
    UINT32                    : 6;
    UINT32 PchStrapsBase      : 8;
    UINT32 NumberOfPchStraps  : 8;   // one-based, в UINT32
    // FLMAP2
    UINT32 ProcStrapsBase     : 8;
    UINT32 NumberOfProcStraps : 8;
    UINT32                    : 16;
    // FLMAP3
    UINT32 DescriptorVersion;        // зарезервировано до Coffee Lake
} FLASH_DESCRIPTOR_MAP;
```

**Важно:** все поля `*Base` хранят биты `[11:4]` реального смещения. Реальное
смещение = `Base << 4`. Максимальное значение базы — `0xE0`; больше означает
битый дескриптор.

`DescriptorVersion` (начиная с Coffee Lake) разбирается как:

```c
typedef struct {
    UINT32 Reserved : 14;
    UINT32 Minor    : 7;
    UINT32 Major    : 11;
} FLASH_DESCRIPTOR_VERSION;
```

Единственная известная валидная версия — Major=1, Minor=0. Значение
`0xFFFFFFFF` означает «поле зарезервировано», то есть дескриптор v1.

### 2.2. Секция регионов

Расположена по `RegionBase << 4`. Каждый регион — пара `UINT16` Base/Limit,
хранящих **старшие 16 бит** реальных 32-битных адресов:

```
offset = Base  << 12
limit  = (Limit << 12) | 0xFFF
size   = limit - offset + 1
```

Регион отсутствует, если `Limit == 0` (либо `Base > Limit`).

```c
typedef struct {
    UINT16 DescriptorBase, DescriptorLimit;   // сам дескриптор
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

Количество валидных пар зависит от версии дескриптора: в v1 читаются первые 5
(Descriptor, BIOS, ME, GbE, PDR), в более новых — все.

Правильный алгоритм разбора образа Intel:

1. Собрать список присутствующих регионов в виде `{offset, length, type}`.
2. Отсортировать по `offset`.
3. Проверить на пересечения — пересекающиеся регионы означают битый дескриптор.
4. Промежутки между регионами добавить как элементы «padding».
5. Разобрать каждый регион своим парсером; BIOS-регион и Device Expansion 1
   разбираются как raw-области (§4), ME/GbE/PDR — как непрозрачные блобы с
   извлечением версии.

### 2.3. Секция мастеров

По `MasterBase << 4`. Два формата — до Skylake и начиная с него:

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

Биты доступа в v1: `DESC=0x01, BIOS=0x02, ME=0x04, GBE=0x08, PDR=0x10, EC=0x20`.

### 2.4. Прочее в дескрипторе

- `FLASH_DESCRIPTOR_UPPER_MAP` по фиксированному смещению `0x0EFC`:
  `{UINT8 VsccTableBase; UINT8 VsccTableSize; UINT16 ReservedZero;}`.
  База — снова биты `[11:4]`, размер — в `UINT32`.
- Таблица VSCC: массив `{UINT8 VendorId; UINT8 DeviceId0; UINT8 DeviceId1;
  UINT8 ReservedZero; UINT32 VsccRegisterValue;}`.
- OEM-секция: фиксированно `0x0F00`, размер `0x100`.

---

## 3. Firmware Volume (FV)

### 3.1. Заголовок тома

```c
typedef struct {
    UINT8    ZeroVector[16];
    EFI_GUID FileSystemGuid;
    UINT64   FvLength;
    UINT32   Signature;        // '_FVH' = 0x4856465F, по смещению 0x28
    UINT32   Attributes;
    UINT16   HeaderLength;
    UINT16   Checksum;
    UINT16   ExtHeaderOffset;  // зарезервировано в Revision 1
    UINT8    Reserved;
    UINT8    Revision;         // 1 или 2
    // EFI_FV_BLOCK_MAP_ENTRY FvBlockMap[];
} EFI_FIRMWARE_VOLUME_HEADER;   // 0x38 байт до блок-мапы

typedef struct {
    UINT32 NumBlocks;
    UINT32 Length;
} EFI_FV_BLOCK_MAP_ENTRY;       // терминируется парой {0, 0}
```

Ключевая деталь для поиска томов: сигнатура `_FVH` находится по фиксированному
смещению `EFI_FV_SIGNATURE_OFFSET = 0x28` от начала заголовка. Поиск ведётся по
сигнатуре, затем откатом назад на `0x28` получается кандидат заголовка.

**Проверки кандидата** (все обязательны, иначе ложные срабатывания):

- `FvLength >= sizeof(header) + 2 * sizeof(EFI_FV_BLOCK_MAP_ENTRY)` и `< 0xFFFFFFFF`;
- `Revision` равна 1 или 2;
- `HeaderLength >= sizeof(EFI_FIRMWARE_VOLUME_HEADER)` и `ALIGN8(HeaderLength)`
  не выходит за границу данных;
- альтернативный размер, посчитанный по блок-мапе (`Σ NumBlocks * Length`),
  сравнивается с `FvLength`; расхождение — признак повреждения, но не повод
  отбрасывать том: эталонный парсер в этом случае пробует оба размера.

### 3.2. Расширенный заголовок

Если `Revision > 1` и `ExtHeaderOffset != 0`:

```c
typedef struct {
    EFI_GUID FvName;
    UINT32   ExtHeaderSize;
} EFI_FIRMWARE_VOLUME_EXT_HEADER;

typedef struct {                       // цепочка записей внутри ext header
    UINT16 ExtEntrySize;
    UINT16 ExtEntryType;               // 0x0000 = END
} EFI_FIRMWARE_VOLUME_EXT_ENTRY;
```

Типы записей: `END = 0x0000`, `OEM_TYPE = 0x0001` (`UINT32 TypeMask` +
`EFI_GUID Types[]`), `GUID_TYPE = 0x0002` (`EFI_GUID FormatType` + данные).

Итоговый размер заголовка тома:

```
if (Revision > 1 && ExtHeaderOffset)
    headerSize = ExtHeaderOffset + extHeader->ExtHeaderSize;
else
    headerSize = HeaderLength;
headerSize = ALIGN8(headerSize);       // конец ext header может быть невыровнен
```

### 3.3. Контрольная сумма заголовка

`checksum16` по первым `HeaderLength` байтам с обнулённым полем `Checksum`;
результат должен совпасть с сохранённым значением. Обратите внимание: сумма
считается по `HeaderLength`, а не по `headerSize` — расширенный заголовок в неё
не входит.

### 3.4. Определение файловой системы тома

По `FileSystemGuid`:

| GUID | Смысл |
|---|---|
| `7A9354D9-0468-444A-81CE-0BF617D890DF` | FFSv1 (`EFI_FIRMWARE_FILE_SYSTEM_GUID`) |
| `8C8CE578-8A3D-4F1C-9935-896185C32DD3` | FFSv2 |
| `5473C07A-3DCB-4DCA-BD6F-1E9689E7349A` | FFSv3 |
| `04ADEEAD-61FF-4D31-B6BA-64F8BF901F5A` | Apple immutable FV (FFSv2) |
| `BD001B8C-6A71-487B-A14F-0C2A2DCF7A5D` | Apple authentication FV (FFSv2) |
| `153D2197-29BD-44DC-AC59-887F70E41A6B` | Apple microcode volume, заголовок фикс. `0x100` |
| `AD3FFFFF-D28B-44C4-9F13-9EA98A97F9F0` | Intel FS (FFSv2) |
| `D6A1CD70-4B33-4994-A6EA-375F2CCC5437` | Intel FS 2 (FFSv2) |
| `4F494156-AED6-4D64-A537-B8A5557BCEEC` | Sony FS (FFSv2) |
| `372B56DF-CC9F-4817-AB97-0A10A92CEAA5` | HP FS (FFSv2) |
| `FFF12B8D-7696-4C8B-A985-2747075B4F50` | NVRAM main store (VSS) |
| `00504624-8A59-4EEB-BD0F-6B36E96128E0` | NVRAM additional store |

Списки `FFSv2Volumes` / `FFSv3Volumes` в реализации содержат все GUID,
трактуемые как соответствующая версия FFS. Том с неизвестным GUID не разбирается
как FFS — его тело сохраняется как непрозрачные данные.

### 3.5. Атрибуты и выравнивание

`EFI_FVB_ERASE_POLARITY = 0x00000800` определяет `emptyByte`:
установлен → `0xFF`, сброшен → `0x00`. Это значение наследуется всеми детьми.

Выравнивание тома:

- **Revision 1**: биты выравнивания `EFI_FVB_ALIGNMENT_2 … _64K` в
  `Attributes[31:16]` действительны только при взведённом
  `EFI_FVB_ALIGNMENT_CAP = 0x00008000`. На практике корректность там не соблюдают,
  проверять смысла нет.
- **Revision 2**: `alignment = 1 << ((Attributes & EFI_FVB2_ALIGNMENT) >> 16)`,
  где `EFI_FVB2_ALIGNMENT = 0x001F0000`. Диапазон — от `ALIGNMENT_1` (0) до
  `ALIGNMENT_2G` (0x1F). Дополнительно `EFI_FVB2_WEAK_ALIGNMENT = 0x80000000`
  ослабляет требование выравнивания для файлов внутри.
  По умолчанию, если атрибуты не заданы, — `0x10000` (64 КиБ).

Проверка выравнивания тома имеет смысл только для несжатых томов: сжатый том
всё равно распаковывается в память по адресу, который выбирает распаковщик.

### 3.6. Apple CRC32 и UsedSpace в ZeroVector

Некоторые вендоры используют зарезервированный `ZeroVector`:

- байты `[8..12)` — CRC32 тела тома (от `HeaderLength` до конца). Если значение
  ненулевое и CRC совпадает — это Apple CRC32;
- байты `[12..16)` — `UsedSpace`, смещение конца занятой области от начала тома.
  Считается валидным, если совпадает с найденной границей свободного места.

---

## 4. Raw-области и эвристический поиск

BIOS-регион, Device Expansion, тело padding-элементов и «generic image»
разбираются одинаково: линейным сканированием в поисках известных сигнатур.

Алгоритм `findNextRawAreaItem` — побайтовый (не по 4 байта!) проход с проверкой
`UINT32` по текущему смещению:

```
для offset от start до size-4:
    dword = read_le32(data + offset)

    если dword == 0x00000001:                    // кандидат в микрокод Intel
        требуется restSize >= sizeof(INTEL_MICROCODE_HEADER) (0x30)
        требуется intelMicrocodeHeaderValid(header)
        требуется TotalSize != 0
        → найден микрокод, size = TotalSize

    если dword == 0x4856465F ('_FVH'):           // кандидат в том
        требуется offset >= 0x28
        проверить заголовок тома по §3.1
        посчитать альтернативный размер по блок-мапе
        → найден том, size = FvLength, altSize = сумма по блок-мапе

    если dword == 0x5F494F5F ('_IO_'), 0x24504324 и т.п. → прочие сторы
```

Всё, что находится между найденными элементами, оформляется как padding.
Padding, целиком состоящий из `emptyByte`, помечается как «пустой» — это важно
при последующей пересборке.

Дополнительно в raw-областях ищутся хранилища NVRAM, AMD-микрокод, BPDT/CPD
(см. §7, §8).

---

## 5. FFS-файлы

### 5.1. Заголовки

```c
typedef union {
    struct { UINT8 Header; UINT8 File; } Checksum;
    UINT16 TailReference;   // Revision 1
    UINT16 Checksum16;      // Revision 2
} EFI_FFS_INTEGRITY_CHECK;

typedef struct {                       // базовый, 0x18 байт
    EFI_GUID                Name;
    EFI_FFS_INTEGRITY_CHECK IntegrityCheck;
    UINT8                   Type;
    UINT8                   Attributes;
    UINT8                   Size[3];   // UINT24, полный размер файла с заголовком
    UINT8                   State;
} EFI_FFS_FILE_HEADER;

typedef struct {                       // FFSv3 large file, 0x20 байт
    EFI_GUID                Name;
    EFI_FFS_INTEGRITY_CHECK IntegrityCheck;
    UINT8                   Type;
    UINT8                   Attributes;
    UINT8                   Size[3];   // 0xFFFFFF или 0x000000
    UINT8                   State;
    UINT64                  ExtendedSize;
} EFI_FFS_FILE_HEADER2;

typedef struct {                       // Lenovo large file в FFSv2, 0x1C байт
    EFI_GUID                Name;
    EFI_FFS_INTEGRITY_CHECK IntegrityCheck;
    UINT8                   Type;
    UINT8                   Attributes;
    UINT8                   Size[3];   // 0x000000
    UINT8                   State;
    UINT32                  ExtendedSize;
} EFI_FFS_FILE_HEADER2_LENOVO;
```

### 5.2. Определение размера файла

```
если ffsVersion == 2:
    size = uint24(Size)
    если volumeRevision == 2 и (Attributes & FFS_ATTRIB_LARGE_FILE):
        size = header2Lenovo->ExtendedSize      // нестандартное расширение Lenovo
если ffsVersion == 3:
    если (Attributes & FFS_ATTRIB_LARGE_FILE):
        size = header2->ExtendedSize
    иначе:
        size = uint24(Size)
```

`Size` — **полный** размер файла, включая заголовок. Размер `0` означает
невозможность продолжать разбор тома.

### 5.3. Атрибуты

```
FFS_ATTRIB_TAIL_PRESENT    0x01   // только Revision 1
FFS_ATTRIB_RECOVERY        0x02   // только Revision 1
FFS_ATTRIB_LARGE_FILE      0x01   // только FFSv3 (и Lenovo в FFSv2 Rev2)
FFS_ATTRIB_DATA_ALIGNMENT2 0x02   // Revision 2, UEFI PI 1.6+
FFS_ATTRIB_FIXED           0x04
FFS_ATTRIB_DATA_ALIGNMENT  0x38   // 3 бита индекса в таблице выравнивания
FFS_ATTRIB_CHECKSUM        0x40
```

Обратите внимание на коллизию: бит `0x01` означает `TAIL_PRESENT` в томах
Revision 1 и `LARGE_FILE` в FFSv3, бит `0x02` — `RECOVERY` или
`DATA_ALIGNMENT2`. Интерпретация зависит от версии тома, а не от файла.

Выравнивание тела файла:

```
idx = (Attributes & FFS_ATTRIB_DATA_ALIGNMENT) >> 3;
если (Attributes & FFS_ATTRIB_DATA_ALIGNMENT2) и volumeRevision == 2:
    alignment = 1 << ffsAlignment2Table[idx];   // {17,18,19,20,21,22,23,24}
иначе:
    alignment = 1 << ffsAlignmentTable[idx];    // {0,4,7,9,10,12,15,16}
```

То есть базовая таблица даёт 1, 16, 128, 512, 1K, 4K, 32K, 64K байт, а
расширенная — от 128K до 16M.

### 5.4. Контрольные суммы

```
// заголовок: сумма всех байт заголовка, кроме двух полей IntegrityCheck и State
calculatedHeader = 0x100 - (sum8(header) - IC.Checksum.Header
                                          - IC.Checksum.File
                                          - State);

// тело
если (Attributes & FFS_ATTRIB_CHECKSUM):
    calculatedData = checksum8(body)          // при пустом теле это ошибка формата
иначе если volumeRevision == 1:
    calculatedData = FFS_FIXED_CHECKSUM  = 0x5A
иначе:
    calculatedData = FFS_FIXED_CHECKSUM2 = 0xAA
```

Проверка тела выполняется только для файлов с непустым телом.

### 5.5. Состояние файла

```
EFI_FILE_HEADER_CONSTRUCTION 0x01
EFI_FILE_HEADER_VALID        0x02
EFI_FILE_DATA_VALID          0x04
EFI_FILE_MARKED_FOR_UPDATE   0x08
EFI_FILE_DELETED             0x10
EFI_FILE_HEADER_INVALID      0x20
EFI_FILE_ERASE_POLARITY      0x80
```

Биты состояния записываются в порядке возрастания и **инвертируются**, если
erase polarity тома равна 0. Для файла `emptyByte` берётся из его собственного
`State & EFI_FILE_ERASE_POLARITY`, а не из тома — это позволяет корректно
обрабатывать смешанные случаи.

### 5.6. Типы файлов

```
0x00 ALL (недопустим в образе)   0x0B FIRMWARE_VOLUME_IMAGE
0x01 RAW                          0x0C COMBINED_MM_DXE
0x02 FREEFORM                     0x0D MM_CORE
0x03 SECURITY_CORE                0x0E MM_STANDALONE
0x04 PEI_CORE                     0x0F MM_CORE_STANDALONE
0x05 DXE_CORE                     0xC0..0xDF OEM
0x06 PEIM                         0xE0..0xEF DEBUG
0x07 DRIVER                       0xF0 PAD
0x08 COMBINED_PEIM_DRIVER         0xF0..0xFF FFS-специфичные
0x09 APPLICATION
0x0A MM (ранее SMM)
```

Тип больше `0x0F` и не равный `0xF0` следует считать неизвестным.

### 5.7. Особые файлы

| GUID | Смысл |
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
| `DE3E049C-A218-4891-8658-5FC0FA84C788` | AMD microcode в TE/PE |
| `05CA01FC-…` … `05CA020B-…` | AMI ROM Hole 0..15 |

**Volume Top File — критически важен.** Последний байт последнего VTF в образе
отображается на физический адрес `0xFFFFFFFF`. Отсюда:

```
addressDiff = 0xFFFFFFFF - base(lastVtf) - fullSize(lastVtf) + 1
физический_адрес = смещение_в_файле + addressDiff
```

Без найденного VTF абсолютные адреса вычислить нельзя, и весь второй проход
(FIT, reset vector, защищённые диапазоны) пропускается. Значение по умолчанию
`addressDiff = 0x100000000` означает «адреса неизвестны».

Внутри VTF по фиксированным адресам лежит reset vector:

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

Значение `0x12345678` в полях означает «не заполнено» (EDK2 оставляет плейсхолдер).

### 5.8. Обход тела тома

```
fileOffset = 0
пока fileOffset < размер_тела_тома:
    fileSize = getFileSize(...)
    если fileSize == 0 → прервать разбор

    если первые sizeof(EFI_FFS_FILE_HEADER) байт == emptyByte:
        // достигли свободного пространства
        если остаток не весь состоит из emptyByte:
            найти первый непустой байт i
            выровнять i вниз до 8 байт: если i != ALIGN8(i) → i = ALIGN8(i) - 8
            [0, i)  → свободное место
            [i, …)  → «non-UEFI data», разобрать эвристически
        иначе:
            весь остаток → свободное место
        прервать

    если остатка не хватает на заголовок или на fileSize:
        остаток → non-UEFI data, прервать

    разобрать файл
    fileOffset = ALIGN8(fileOffset + fileSize)
```

Выравнивание следующего файла — всегда на 8 байт, независимо от версии FFS.

---

## 6. Секции

Тело файла типов, отличных от `RAW` и `PAD`, состоит из последовательности секций.

```c
typedef struct {
    UINT8 Size[3];             // UINT24, полный размер секции с заголовком
    UINT8 Type;
} EFI_COMMON_SECTION_HEADER;   // 4 байта

typedef struct {
    UINT8  Size[3];            // == 0xFFFFFF, признак использования расширенного
    UINT8  Type;
    UINT32 ExtendedSize;
} EFI_COMMON_SECTION_HEADER2;  // 8 байт
```

Расширенный заголовок применим только в FFSv3-томах: `Size == EFI_SECTION2_IS_USED
(0xFFFFFF)` → читать `ExtendedSize`.

Секции внутри файла выравниваются на 4 байта (`ALIGN4`).

### 6.1. Типы секций

**Инкапсулирующие** (содержат другие секции):

| Тип | Имя |
|---|---|
| `0x01` | `COMPRESSION` |
| `0x02` | `GUID_DEFINED` |
| `0x03` | `DISPOSABLE` |

**Листовые**:

| Тип | Имя | Тип | Имя |
|---|---|---|---|
| `0x10` | `PE32` | `0x17` | `FIRMWARE_VOLUME_IMAGE` |
| `0x11` | `PIC` | `0x18` | `FREEFORM_SUBTYPE_GUID` |
| `0x12` | `TE` | `0x19` | `RAW` |
| `0x13` | `DXE_DEPEX` | `0x1B` | `PEI_DEPEX` |
| `0x14` | `VERSION` | `0x1C` | `MM_DEPEX` |
| `0x15` | `USER_INTERFACE` | `0x20` | Insyde postcode (вендорный) |
| `0x16` | `COMPATIBILITY16` | `0xF0` | Phoenix SCT postcode (вендорный) |

### 6.2. Секция сжатия (0x01)

```c
typedef struct {
    UINT32 UncompressedLength;
    UINT8  CompressionType;
} EFI_COMPRESSION_SECTION;
```

`CompressionType`: `0x00` — не сжато, `0x01` — Tiano/EFI 1.1 (алгоритм
EfiTianoDecompress), `0x02` — customized, `0x86` — LZMA с фильтром x86.

Для типа `0x01` требуется пробовать оба варианта — EFI 1.1 и Tiano: они
различаются только шириной поля и распознаются по успешности распаковки.

### 6.3. GUID-defined секция (0x02)

```c
typedef struct {
    EFI_GUID SectionDefinitionGuid;
    UINT16   DataOffset;       // от начала секции до данных
    UINT16   Attributes;
} EFI_GUID_DEFINED_SECTION;
```

Атрибуты: `PROCESSING_REQUIRED = 0x01`, `AUTH_STATUS_VALID = 0x02`.

Известные GUID:

| GUID | Обработка |
|---|---|
| `FC1BCDB0-7D31-49AA-936A-A4600D9DD083` | CRC32 (данные не сжаты, только проверка) |
| `A31280AD-481E-41B6-95E8-127F4C984779` | Tiano |
| `EE4E5898-3914-4259-9D6E-DC7BD79403CF` | LZMA |
| `0ED85E23-F253-413F-A03C-901987B04397` | LZMA (HP) |
| `BD9921EA-ED91-404A-8B2F-B4D724747C8C` | LZMA (Microsoft) |
| `D42AE6BD-1352-4BFB-909A-CA72A6EAE889` | LZMA + x86 filter |
| `1D301FE9-BE79-4353-91C2-D23BC959AE0C` | GZip |
| `CE3233F5-2CD6-4D87-9152-4A238BB6D1C4` | Zlib (AMD) |
| `991EFAC0-E260-416B-A4B8-3B153072B804` | Zlib (AMD, второй) |
| `3D532050-5CDA-4FD0-879E-0F7F630D5AFB` | Brotli |
| `0F9D89E8-9259-4F76-A5AF-0C89E34023DF` | Firmware contents signed |

Заголовки специфичных упаковщиков:

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

Для подписанных секций (`FIRMWARE_CONTENTS_SIGNED`) данные предваряются
`WIN_CERTIFICATE_UEFI_GUID`:

```c
typedef struct { UINT32 Length; UINT16 Revision; UINT16 CertificateType; } WIN_CERTIFICATE;
typedef struct { WIN_CERTIFICATE Header; EFI_GUID CertType; } WIN_CERTIFICATE_UEFI_GUID;
typedef struct { EFI_GUID HashType; UINT8 PublicKey[256]; UINT8 Signature[256]; }
        EFI_CERT_BLOCK_RSA2048_SHA256;
```

`WIN_CERT_TYPE_EFI_GUID = 0x0EF1`, `CertType` для RSA2048/SHA256 —
`A7717414-C616-4977-9420-844712A735BF`.

### 6.4. Прочие секции

```c
typedef struct { UINT16 BuildNumber; } EFI_VERSION_SECTION;        // далее UCS-2 строка
typedef struct { EFI_GUID SubTypeGuid; } EFI_FREEFORM_SUBTYPE_GUID_SECTION;
typedef struct { UINT32 Postcode; } POSTCODE_SECTION;
```

`USER_INTERFACE` (0x15) — тело целиком UCS-2 строка с завершающим нулём.

Секция `FIRMWARE_VOLUME_IMAGE` (0x17) содержит вложенный том — рекурсия обратно
к §3.

### 6.5. Depex-секции

Тело — байткод из однобайтных опкодов:

```
0x00 BEFORE (только DXE, первый и единственный)
0x01 AFTER  (только DXE, первый и единственный)
0x02 PUSH   + EFI_GUID (16 байт операнда)
0x03 AND    0x04 OR     0x05 NOT
0x06 TRUE   0x07 FALSE  0x08 END
0x09 SOR    (только DXE, первый опкод)
```

---

## 7. Микрокод

### 7.1. Intel

```c
typedef struct {
    UINT32 HeaderType;         // 1
    UINT32 UpdateRevision;
    UINT16 DateYear;           // BCD
    UINT8  DateDay;            // BCD
    UINT8  DateMonth;          // BCD
    UINT32 ProcessorSignature;
    UINT32 Checksum;           // сумма всех DWORD образа == 0
    UINT32 LoaderRevision;     // 1
    UINT32 PlatformIds;
    UINT32 DataSize;           // 0 означает 2000 байт
    UINT32 TotalSize;
    UINT32 MetadataSize;       // зарезервировано
    UINT32 UpdateRevisionMin;
    UINT32 Reserved;
} INTEL_MICROCODE_HEADER;      // 0x30 байт
```

Критерии валидности (`intelMicrocodeHeaderValid`) — все обязательны:

- `DataSize % 4 == 0` и `DataSize <= 0xFFFFFF`;
- `TotalSize >= DataSize` и `TotalSize <= 0xFFFFFF`;
- `DateDay` — валидный BCD в диапазонах `01–09, 10–19, 20–29, 30–31`;
- `DateMonth` — валидный BCD `01–09, 10–12`;
- `DateYear` — BCD в `1990–1999, 2000–2009, 2010–2019, 2020–2029, 2030–2039, 2040–2049`;
- `HeaderType == 1`;
- `LoaderRevision == 1`.

При сканировании дополнительно требуется `TotalSize != 0`.

Расширенная таблица сигнатур, если `TotalSize > 0x30 + DataSize`:

```c
typedef struct { UINT32 EntryCount; UINT32 Checksum; UINT8 Reserved[12]; }
        INTEL_MICROCODE_EXTENDED_HEADER;
typedef struct { UINT32 ProcessorSignature; UINT32 PlatformIds; UINT32 Checksum; }
        INTEL_MICROCODE_EXTENDED_HEADER_ENTRY;
```

Пустой слот микрокода — первые 4 байта равны `FF FF FF FF`. Это легальное
состояние: спецификация FIT явно разрешает записи, указывающие на пустые слоты.

### 7.2. AMD

Разбирается отдельно (`amd_microcode.h`), поиск ведётся как по raw-областям, так
и внутри TE/PE-файлов с GUID `DE3E049C-A218-4891-8658-5FC0FA84C788`.

---

## 8. IFWI: BPDT и CPD

Применимо к образам с Converged Security Engine (Apollo Lake и новее).

```c
#define BPDT_GREEN_SIGNATURE  0x000055AA
#define BPDT_YELLOW_SIGNATURE 0x00AA55AA

typedef struct {
    UINT32 Signature;
    UINT16 NumEntries;
    UINT8  HeaderVersion;      // 1 или 2
    UINT8  RedundancyFlag;     // зарезервировано в версии 1
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

Типы партиций: `0 SMIP, 1 RBEP, 2 FTPR, 3 UCOD, 4 IBBP, 5 S_BPDT, 6 OBBP,
7 NFTP, 8 ISHC, 9 DLMP, 10 UEBP, 11 UTOK, 14 PMCP, 17 UEP, 18 WCOD, 19 LOCL,
20 OEMP, 21 FITC, 32 PCHC` и далее (полный список — в `ffs.h`).

Тип `5 (S_BPDT)` — вложенная BPDT, разбирается рекурсивно.

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

Внутри CPD-партиций лежат манифесты (`CPD_MANIFEST_HEADER`) и расширения
(`CPD_EXTENTION_HEADER {UINT32 Type; UINT32 Length;}`) — типов около 40,
из практически важных: `15 SIGNED_PACKAGE_INFO`, `10 MODULE_ATTRIBUTES`
(содержит `CompressionType`: 0 — нет, 1 — Huffman, 2 — LZMA), `19 BOOT_POLICY`,
`14 KEY_MANIFEST`, `22 IFWI_PARTITION_MANIFEST`.

---

## 9. NVRAM

Хранилища переменных находятся эвристическим поиском сигнатур внутри raw-областей
и томов с NVRAM-GUID. Поддерживаемые форматы (детали — в `common/nvram.h` и
kaitai-описаниях `common/ksy/`):

| Формат | Сигнатура / признак |
|---|---|
| EDK2 VSS / VSS2 | `$VSS` / GUID-заголовок |
| EDK2 FTW | `EFI_FAULT_TOLERANT_WORKING_BLOCK_HEADER` |
| AMI NVAR | `NVAR` |
| Apple SYSF/Fsys | `Fsys` / `Gaid` |
| Phoenix EVSA | `EVSA` |
| Phoenix FlashMap | `_FLASH_MAP` |
| Insyde FDC / FDM | `$FDC` / `HFDM` (0x4D444648) |
| Dell DVAR | `DVAR` (0x52415644) |
| MS SLIC | marker / pubkey |

Для парсера общего назначения NVRAM-сторы разумно сначала выделять как
непрозрачные элементы и разбирать по требованию.

Insyde Flash Device Map заслуживает отдельного упоминания, так как задаёт
разметку всего образа:

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
    // UINT8 Hash[]; размер зависит от EntryFormat/EntrySize
} INSYDE_FLASH_DEVICE_MAP_ENTRY;
```

---

## 10. Второй проход

Выполняется после построения дерева, требует найденного и несжатого VTF.

1. **Вычисление `addressDiff`** — см. §5.7.
2. **Reset vector** — разбор `X86_RESET_VECTOR_DATA` в теле VTF.
3. **FIT** — см. отдельный документ `FIT_TABLE_FORMAT.md`.
4. **Защищённые диапазоны Boot Guard**. Vendor hash files:

```c
typedef struct { UINT8 Hash[32]; UINT32 Base; UINT32 Size; }
        PROTECTED_RANGE_VENDOR_HASH_FILE_ENTRY;

typedef struct { UINT64 Signature; UINT32 NumEntries; }   // '$HASHTBL'
        PROTECTED_RANGE_VENDOR_HASH_FILE_HEADER_PHOENIX;

typedef struct { UINT8 Hash[32]; UINT32 Size; }           // AMI v1, база из flash map
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

Диапазоны, перечисленные в этих файлах, вместе с IBB, описанным в Boot Policy,
образуют список областей, изменение которых сломает Boot Guard.

5. **Проверка баз TE-образов** — у TE-секций поле `StrippedSize` иногда содержит
   скорректированную базу; сравнение с фактическим адресом позволяет выявить
   образы, перемещённые вендорским инструментом.

---

## 11. Практические замечания

**Ограничение глубины рекурсии.** Том → файл → секция → том → … Вложенность в
реальных образах доходит до 8–10 уровней, но битый образ может дать бесконечную
рекурсию. Ставьте жёсткий лимит.

**Проверка границ на каждом шаге.** Каждое поле размера читается из недоверенных
данных. Перед любым `mid(offset, size)` проверяйте `offset + size <= buffer.size()`
с учётом переполнения (складывайте в 64-битном типе или сравнивайте вычитанием).

**Нулевые размеры.** `FvLength == 0`, `fileSize == 0`, `sectionSize == 0`,
`fitHeader->Size == 0` — все означают битую структуру и должны прерывать разбор
соответствующего уровня, иначе получится бесконечный цикл.

**Битые образы — норма.** Прошивка из дампа флеша почти всегда содержит хотя бы
одну структуру, не соответствующую спецификации. Парсер должен собирать
диагностические сообщения и продолжать, а не падать на первой же проблеме.
Эталонная реализация везде использует пару «флаг + сообщение», а не немедленный
выход.

**Padding — тоже элемент.** Всё, что не разобрано, должно попасть в дерево как
padding с сохранением байт. Иначе пересборка образа станет невозможной.

**Что нельзя двигать при пересборке.** Помеченными «fixed» должны быть:

- элементы с `FFS_ATTRIB_FIXED`;
- элемент, содержащий FIT, и все элементы, на которые FIT ссылается;
- VTF;
- области, покрытые защищёнными диапазонами Boot Guard;
- регионы, перечисленные во флеш-дескрипторе и Insyde Flash Device Map.

**Сжатые элементы.** Для элементов внутри сжатых контейнеров абсолютные адреса
не имеют смысла: распаковщик разместит их где угодно. Соответственно, проверки
выравнивания и адресные проверки FIT для них не выполняются.
