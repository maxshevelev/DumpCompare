# Intel Firmware Interface Table (FIT) — структура и правила модификации

Документ описывает формат таблицы FIT и пошаговые правила добавления и удаления
записей. Структуры и алгоритмы выверены по реализации UEFITool NE
(`common/intel_fit.h`, `common/fitparser.cpp`, ветка `new_engine`, версия A76)
и спецификации Intel «Firmware Interface Table BIOS Specification» r1.4
(документ Intel 599500).

---

## 1. Назначение

FIT — таблица указателей на компоненты образа, которые процессор и его
микрокод должны найти и обработать **до** выполнения первой инструкции из
reset vector. Через FIT загружаются обновления микрокода, Startup ACM,
манифесты Boot Guard, политики TXT/TPM и прочее.

Следствие для любого инструмента, редактирующего образ: адреса в FIT —
абсолютные физические адреса, а не смещения. Любое перемещение компонента,
на который указывает FIT, требует правки таблицы.

---

## 2. Расположение таблицы

Указатель на FIT лежит по фиксированному физическому адресу `0xFFFFFFC0`
(`INTEL_FIT_POINTER_OFFSET = 0x40` от конца адресного пространства).

Пересчёт в смещение в файле образа:

```
addressDiff  = 0x100000000 - размер_образа          // для полного дампа флеша
file_offset  = physical_address - addressDiff
```

Точнее, в общем случае (когда образ не занимает весь верх адресного
пространства) `addressDiff` вычисляется по Volume Top File:

```
addressDiff = 0xFFFFFFFF - base(lastVtf) - fullSize(lastVtf) + 1
```

Для образа 16 МиБ, целиком отображённого под `0xFFFFFFFF`, это даёт
`addressDiff = 0xFF000000`, а указатель на FIT читается по смещению
`размер_образа - 0x40`.

```
FIT_pointer = read_le32(image, image_size - 0x40)
FIT_offset  = FIT_pointer - addressDiff
```

### 2.1. Алгоритм поиска (для верификации)

Надёжный способ найти FIT — не доверять указателю вслепую, а проверить обе
стороны связи:

1. Прочитать `FIT_pointer` по `image_size - 0x40`.
2. Найти в образе все вхождения сигнатуры `_FIT_   ` — 8 байт
   `5F 46 49 54 5F 20 20 20` (`INTEL_FIT_SIGNATURE = 0x2020205F5449465F`).
3. Для каждого кандидата вычислить его физический адрес и сравнить с
   `FIT_pointer`. Совпадение — настоящая таблица.
4. Дополнительно проверить, что в образе хватает места хотя бы на две записи
   (заголовок + минимум одна запись микрокода).

Кандидаты, не совпавшие с указателем, — это чужие данные, совпавшие по
сигнатуре (нередко попадаются внутри сжатых блоков).

---

## 3. Структура записи

Все записи, включая заголовок, имеют одинаковый размер — **16 байт**.

```c
typedef struct {
    UINT64 Address;            // +0x00  базовый адрес компонента, выровнен на 16
    UINT32 Size : 24;          // +0x08  размер компонента в единицах по 16 байт
    UINT32 Reserved : 8;       // +0x0B  должно быть 0
    UINT16 Version;            // +0x0C  BCD: младший байт minor, старший major
    UINT8  Type : 7;           // +0x0E  биты [6:0]
    UINT8  ChecksumValid : 1;  // +0x0E  бит [7]
    UINT8  Checksum;           // +0x0F
} INTEL_FIT_ENTRY;
```

Побайтовая раскладка:

```
смещение  размер  поле
  0x00      8     Address              (LE)
  0x08      3     Size                 (LE, UINT24)
  0x0B      1     Reserved             (0x00)
  0x0C      2     Version              (LE, BCD)
  0x0E      1     Type[6:0] | CV[7]
  0x0F      1     Checksum
```

**Записи обязаны быть упорядочены по возрастанию `Type`.** Это требование
спецификации, а не рекомендация: обработчик FIT в микрокоде вправе
останавливать просмотр на первом типе, который больше искомого.

---

## 4. Заголовок (Type = 0x00)

Заголовок — ровно одна запись, всегда первая.

```
Address        = 0x2020205F5449465F     // ASCII "_FIT_   ", читается как сигнатура
Size           = число записей в таблице, ВКЛЮЧАЯ заголовок
Reserved       = 0
Version        = 0x0100
Type           = 0x00
ChecksumValid  = 0 или 1
Checksum       = см. §5
```

Ключевая деталь, на которой чаще всего ошибаются: в заголовке поле `Size`
хранит **количество записей**, а не размер в байтах и не размер в 16-байтных
блоках компонента. Полный размер таблицы:

```
fit_size_bytes = header.Size * 16
```

Обе трактовки — «число записей» и «размер в единицах по 16 байт» — здесь дают
одно и то же число, поскольку запись равна 16 байтам.

---

## 5. Контрольная сумма

Проверяется только если в заголовке взведён бит `ChecksumValid`.

Алгоритм — checksum8 по **всей таблице целиком**:

```
sum = 0
для каждого байта b всей таблицы (header.Size * 16 байт),
    считая поле header.Checksum равным нулю:
        sum = (sum + b) & 0xFF
correct_checksum = (0x100 - sum) & 0xFF
```

Эквивалентная формулировка: сумма всех байт таблицы, включая само поле
`Checksum`, должна быть равна нулю по модулю 256.

Поля `Checksum` в остальных записях к этой сумме отношения не имеют — они
относятся к самим компонентам (см. §7) и в подавляющем большинстве записей
не используются.

Референсная реализация на Python:

```python
def fit_checksum(table: bytes) -> int:
    t = bytearray(table)
    t[15] = 0                      # обнулить Checksum заголовка
    return (-sum(t)) & 0xFF
```

---

## 6. Типы записей

| Тип | Имя | Обязательность |
|---|---|---|
| `0x00` | FIT Header | ровно одна, первая |
| `0x01` | Microcode | минимум одна |
| `0x02` | Startup ACM | опционально; обязательна для AC boot и Boot Guard |
| `0x03` | Diagnostic ACM | опционально |
| `0x04` | Platform Boot Policy | опционально |
| `0x06` | FIT Reset State | опционально |
| `0x07` | BIOS Startup Module | опционально |
| `0x08` | TPM Policy | опционально, не более одной |
| `0x09` | BIOS Policy | опционально |
| `0x0A` | TXT Policy | опционально, не более одной |
| `0x0B` | Boot Guard Key Manifest | опционально |
| `0x0C` | Boot Guard Boot Policy | опционально |
| `0x10` | CSE SecureBoot Settings | опционально, может быть несколько |
| `0x1A` | VAB Provisioning Table | опционально |
| `0x1B` | VAB Key Manifest | опционально |
| `0x1C` | VAB Image Manifest | опционально |
| `0x1D` | VAB Image Hash Descriptors | опционально |
| `0x2C` | SACM Debug Record | опционально |
| `0x2D` | ACM Feature Policy | опционально |
| `0x2E` | SCRTM Error Record | опционально |
| `0x2F` | JMP Debug Policy | опционально |
| `0x30`–`0x70` | зарезервировано за OEM | — |
| `0x7F` | **Empty** | пустой слот, см. §9.4 |

Диапазоны `0x05`, `0x0D`–`0x0F`, `0x11`–`0x19`, `0x1E`–`0x2B`, `0x71`–`0x7E`
зарезервированы Intel.

---

## 7. Правила для конкретных типов

### 7.1. Microcode (0x01)

- Требуется минимум одна запись.
- `Address` указывает на первый байт заголовка микрокода, выровнен на 16 байт.
- Компонент по этому адресу **не должен** быть сжат, закодирован или зашифрован.
- `ChecksumValid` = 0.
- `Size` **не используется**, должен быть 0. Реальный размер берётся из поля
  `TotalSize` заголовка микрокода.
- `Version` = `0x0100`.
- Слот может быть пустым — первые 4 байта по `Address` равны `FF FF FF FF`.
  Это легальное состояние, предусмотренное спецификацией для зарезервированных
  под будущие обновления слотов.

### 7.2. Startup ACM (0x02)

- `Address` указывает на первый байт заголовка ACM.
- `ChecksumValid` = 0, `Size` = 0, `Version` = `0x0100`.
- Отдельное аппаратное ограничение: Startup ACM отображается одной парой
  MTRR base/limit, поэтому

```
MTRR_Size = 2 ^ ceil(log2(Startup_ACM_Size))
MTRR_Base должен быть кратен MTRR_Size
```

  Вся область `[MTRR_Base, MTRR_Base + MTRR_Size)` — Authenticated Code
  Execution Area (ACEA) — не должна содержать ничего, кроме самого ACM.
  Это самое жёсткое размещенческое ограничение во всей таблице.

### 7.3. TPM Policy (0x08) и TXT Policy (0x0A)

Формат поля `Address` зависит от `Version`:

```c
#define INTEL_FIT_POLICY_VERSION_INDEX_IO            0
#define INTEL_FIT_POLICY_VERSION_FLAT_MEMORY_ADDRESS 1

typedef struct {
    UINT16 IndexRegisterAddress;
    UINT16 DataRegisterAddress;
    UINT8  AccessWidthInBytes;   // 1 или 2
    UINT8  BitPosition;
    UINT16 Index;
} INTEL_FIT_INDEX_IO_ADDRESS;

typedef union {
    UINT64 FlatMemoryAddress;
    INTEL_FIT_INDEX_IO_ADDRESS IndexIo;
} INTEL_FIT_POLICY_PTR;
```

При `Version == 0` первые 8 байт записи — это не адрес, а дескриптор
Index/IO-регистров, и трактовать их как указатель нельзя.
При `Version == 1` — обычный плоский адрес.

Бит 0 по указанному адресу хранит саму политику. `ChecksumValid` = 0, `Size` = 0.

### 7.4. Boot Guard Key Manifest (0x0B) и Boot Policy (0x0C)

Если присутствует Startup ACM, обе эти записи обычно должны быть тоже.
Взаимная проверка: хеш публичного ключа Boot Policy, записанный в Key Manifest,
должен совпадать с SHA-256 или SHA-384 фактического публичного ключа из
Boot Policy. Расхождение означает, что один из манифестов подменён.

### 7.5. CSE SecureBoot (0x10)

Может быть несколько записей, порядок между собой не важен. Подтип задаётся
полем `Reserved`:

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

## 8. Инварианты, которые обязан проверять валидатор

1. Указатель по `image_size - 0x40` ведёт на сигнатуру `_FIT_   `.
2. Первая запись имеет `Type == 0x00`.
3. `header.Size != 0`, и `header.Size * 16` помещается в образ, не пересекая
   его конец.
4. Второго заголовка (`Type == 0x00`) в таблице нет.
5. Типы записей не убывают при движении по таблице.
6. Если `header.ChecksumValid == 1` — checksum8 таблицы равен нулю.
7. Присутствует хотя бы одна запись типа `0x01`.
8. Для каждой записи с реальным адресом: `addressDiff < Address < 0xFFFFFFFF`,
   то есть адрес попадает внутрь образа.
9. Каждый `Address` выровнен на 16 байт.
10. Для записей микрокода: по адресу лежит либо валидный заголовок микрокода,
    либо `FF FF FF FF` (пустой слот). Всё остальное — ошибка.
11. Сама таблица FIT и все компоненты, на которые она ссылается, находятся в
    области образа, не подлежащей перемещению.

---

## 9. Добавление записи

### 9.1. Предусловия

Таблицу можно расширять двумя способами:

- **заполнением пустого слота** типа `0x7F` — предпочтительно, размер таблицы
  и её положение не меняются;
- **увеличением `header.Size`** — возможно только если сразу за таблицей есть
  свободное место (`0xFF`-заполнение), не занятое ничем другим.

Перемещать таблицу целиком крайне нежелательно: придётся править указатель по
`0xFFFFFFC0`, а он лежит внутри VTF, который может входить в защищённый
диапазон Boot Guard.

### 9.2. Процедура добавления записи микрокода

Пошагово, на примере самого частого случая:

**Шаг 1. Разместить компонент в образе.**

Найти область, свободную под микрокод. Требования:
- адрес выровнен на 16 байт;
- размер области не меньше `TotalSize` из заголовка микрокода;
- область не пересекается ни с одним элементом дерева образа;
- область не входит в защищённые диапазоны Boot Guard;
- область не пересекает границу региона флеш-дескриптора.

Обычно микрокоды лежат подряд одним блоком, и новый дописывается сразу за
последним: `new_offset = last_ucode_offset + last_ucode_TotalSize`.

**Шаг 2. Записать тело микрокода** по выбранному смещению.

**Шаг 3. Вычислить физический адрес.**

```
Address = new_offset + addressDiff
```

Это единственный шаг, где ошибка не диагностируется автоматически — см. §11.

**Шаг 4. Найти позицию для записи в таблице.**

Записи упорядочены по возрастанию `Type`. Для микрокода (`0x01`) — сразу после
последней записи типа `0x01`. Если добавление идёт в пустой слот `0x7F`, а
свободных слотов между записями микрокода нет, придётся сдвигать хвост таблицы.

**Шаг 5. Заполнить запись.**

```
Address       = вычисленный на шаге 3
Size          = 0                    // не используется для микрокода
Reserved      = 0
Version       = 0x0100
Type          = 0x01
ChecksumValid = 0
Checksum      = 0
```

Байты записи для примера с `Address = 0xFFB8FC60`:

```
60 FC B8 FF 00 00 00 00 | 00 00 00 00 | 00 01 | 01 | 00
└──── Address (LE) ────┘  └─Size─┘ Rsv  └─Ver─┘  Type CV|Cks
```

**Шаг 6. Обновить `header.Size`** — увеличить на 1, если запись добавлена не в
пустой слот.

**Шаг 7. Пересчитать контрольную сумму заголовка** по §5, если
`ChecksumValid == 1`. Записать в байт `+0x0F` заголовка.

**Шаг 8. Проверить, что размер образа не изменился.** Размер дампа флеша
фиксирован ёмкостью микросхемы; любое изменение общего размера делает образ
непрошиваемым.

**Шаг 9. Прогнать валидатор из §8.**

### 9.3. Что дополнительно ломается при добавлении

- **Boot Guard.** Если область, куда записан новый компонент, покрыта
  защищённым диапазоном (IBB в Boot Policy или vendor hash file), хеш перестанет
  сходиться и платформа не стартует. Проверять до записи, а не после.
- **Контрольные суммы вышестоящих контейнеров.** Если микрокоды лежат внутри
  FFS-файла или тома, а не в raw-области BIOS-региона, потребуется пересчитать
  контрольную сумму FFS-файла и, возможно, `UsedSpace` тома.
- **Подписанные капсулы.** Образ, извлечённый из подписанной капсулы, после
  правки перестаёт соответствовать подписи. Прошивать такой образ можно только
  напрямую программатором.

### 9.4. Пустые слоты (Type = 0x7F)

Вендоры часто резервируют место в таблице записями типа `0x7F`. Такой слот
выглядит как:

```
Address       = произвольный, обычно 0
Size          = 0
Version       = 0x0100 или 0x0000
Type          = 0x7F
ChecksumValid = 0
Checksum      = 0
```

Заполнение пустого слота — самый безопасный способ добавления: `header.Size`
не меняется, положение таблицы не меняется, требуется пересчитать только
контрольную сумму. Но следите за порядком типов: слот `0x7F` находится в конце
таблицы, а запись типа `0x01` должна стоять среди других записей микрокода.
Практически это означает сдвиг: вставить новую запись на нужное место, сдвинув
все последующие на 16 байт вниз, и «съесть» один слот `0x7F` в хвосте.

---

## 10. Удаление записи

**Шаг 1.** Определить, что именно удаляется. Удалять записи типа `0x00`
(заголовок) нельзя. Удаление последней записи типа `0x01` сделает таблицу
невалидной — микрокод должен быть хотя бы один.

**Шаг 2. Выбрать способ.**

- **Замена на пустой слот.** Заменить `Type` на `0x7F`, обнулить `Address` и
  `Size`. Порядок типов при этом нарушается (`0x7F` окажется в середине), что
  формально противоречит спецификации. Допустимо только как временная мера.
- **Схлопывание таблицы** (правильный способ). Сдвинуть все последующие записи
  на 16 байт вверх, в освободившийся хвост записать пустой слот `0x7F` либо
  уменьшить `header.Size` на 1 и затереть хвостовые 16 байт значением `0xFF`.

**Шаг 3.** Если `header.Size` уменьшен — затереть освободившиеся 16 байт
байтом-заполнителем региона (`0xFF`), чтобы не оставлять мусор, который
собьёт другой парсер.

**Шаг 4.** Пересчитать контрольную сумму заголовка.

**Шаг 5.** Решить судьбу самого компонента. Оставить его в образе безопаснее,
чем затирать: он может быть покрыт защищённым диапазоном Boot Guard или на него
могут ссылаться другие структуры. Если компонент всё же затирается, область
заполняется `0xFF`, и это не должно менять размер образа.

**Шаг 6.** Прогнать валидатор из §8.

---

## 11. Разбор реального случая: запись нулевого размера

Симптом: последняя запись микрокода в таблице отображается парсером с размером
`00000000h` и пустым полем информации, тогда как две предыдущие такие же записи
разбираются корректно.

Механика. Парсер сначала берёт размер прямо из записи FIT:

```c
UINT32 currentEntrySize = currentEntry->Size;      // для микрокода это 0 по спеке
```

и подменяет его настоящим размером только после успешной валидации компонента:

```c
realSize = ucodeHeader->TotalSize;                 // последняя строка обработчика
```

Если по адресу из записи не оказывается валидного заголовка микрокода,
обработчик выходит досрочно, и в таблице остаётся исходный ноль.

Диагностический разбор конкретного образа (16 МиБ, `addressDiff = 0xFF000000`,
FIT по `0xFFE00100`, 4 записи):

| # | Адрес в FIT | Смещение | Фактическое содержимое |
|---|---|---|---|
| 1 | `FFB60060` | `B60060` | ucode `000806EA`, TotalSize `018000` |
| 2 | `FFB78060` | `B78060` | ucode `000906EA`, TotalSize `017C00` |
| 3 | `FFBBFC60` | `BBFC60` | `FF FF FF FF …` — пусто |

Сканирование всего образа на заголовки микрокода нашло третий компонент по
смещению `B8FC60`, то есть по адресу `FFB8FC60`. В таблице записано `FFBBFC60` —
ошибка в одном шестнадцатеричном разряде (`8` → `B`, промах на `0x30000`).
Целевой адрес попал в свободную `0xFF`-область, начинающуюся сразу за
микрокодами.

Второй дефект того же редактирования: контрольная сумма заголовка FIT осталась
от старой таблицы — сохранено `CC`, при текущем содержимом требуется `B3`,
а после исправления адреса — `B6`.

**Вывод для реализации инструмента:** после записи адреса обязательно
верифицировать, что по нему лежит ожидаемая структура. Проверка стоит одно
чтение 48 байт и ловит весь класс ошибок «промахнулись адресом». Полезно также
выдавать явное сообщение вместо молчаливого нуля в поле размера — нулевой
размер визуально неотличим от легального «Size не используется».

---

## 12. Референсный код разбора

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

Проверка компонента, на который ссылается запись микрокода:

```python
def microcode_at(image: bytes, off: int):
    if off is None or off + 0x30 > len(image):
        return None
    (ht, rev, yr, dd, mm, ps, cks, lr, pid, ds, ts) = struct.unpack_from(
        "<IIHBBIIIIII", image, off)
    if ht != 1 or lr != 1:
        return None                       # включая пустой слот FF FF FF FF
    if ds % 4 or ds > 0xFFFFFF or ts < ds or ts > 0xFFFFFF or ts == 0:
        return None
    if not (0x1990 <= yr <= 0x2049):
        return None
    return dict(cpu_signature=ps, platform_ids=pid, revision=rev,
                date=(dd, mm, yr), total_size=ts)
```

---

## 13. Сводка констант

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

## 14. Источники

- Intel, «Firmware Interface Table BIOS Specification», ревизия 1.4 —
  <https://cdrdv2-public.intel.com/599500/Firmware-Interface-Table-BIOS-Specification-r1p4.pdf>
- UEFITool NE, `common/intel_fit.h` — определения структур и комментарии
  с правилами по каждому типу записи.
- UEFITool NE, `common/fitparser.cpp` — эталонная реализация поиска, разбора и
  валидации таблицы, включая кросс-проверки Boot Guard.
