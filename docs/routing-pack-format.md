# Routing pack format and routing algorithm, version 1.1

Status: Wave 2, 2026-11-12. Format 1.1 adds a checksum over the section table and makes every reader check explicit; the routing algorithm was corrected where the independent Swift port showed the 1.0 text to be wrong or incomplete (see "Changes from 1.0" at the end). Reference implementation: [`pipeline/routing`](../pipeline/routing) (`enc_routing.packfmt` writes and reads the file, `enc_routing.router` implements part B and reads only the pack). Test vectors: [`testdata/routing`](../testdata/routing).

This document has four parts:

- **A. File format.** Enough to write a reader without seeing the Python code.
- **B. Routing algorithm.** The passability rules, cost function, A*, snapping, funnel straightening, leg validation, grading and summary. An implementation that follows B exactly reproduces the test vectors.
- **C. How the builder produces the values.** This is not needed to read a pack, but it is what the app tells the skipper (for example, what "maintained depth" or "depth from soundings" means).
- **D. Test vector files.**

Keywords: "must" is normative. Anything marked *informative* is not.

---

## Part A. File format

### A.1 Conventions

- **Byte order.** Little-endian throughout. `u8/u16/u32/u64` are unsigned, `i16/i32` are two's complement.
- **Coordinates.** WGS 84 longitude and latitude stored as `i32` in units of 1e-7 degree ("units"). Longitude is always `x` and latitude is always `y`. Degrees are `units / 1e7`, computed in IEEE double as `Double(v) / 1e7`.
- **Depths and heights.** Stored in decimetres (dm), exactly as NOAA charts them. Depths are below MLLW. Clearances are above MHW. See A.6 and B.2.
- **Dates.** `u32` `yyyymmdd`, with 0 = unknown. Times are `u32` `hhmmss` UTC.
- **Strings.** Stored as indices (`u32`) into the string table `STRS`. Index 0 is the empty string.
- **Unsigned varint (uvarint).** LEB128: 7 bits per byte, least significant group first, and the high bit (0x80) is set on every byte except the last. At most 10 bytes. Examples: 0 → `00`, 127 → `7F`, 128 → `80 01`, 300 → `AC 02`, 16384 → `80 80 01`.
- **Zigzag.** Maps a signed integer to an unsigned one: `zz(n) = (n << 1) ^ (n >> 63)` for a 64-bit `n`, so 0→0, -1→1, 1→2, -2→3. To decode, `n = (u >> 1) ^ -(u & 1)`.
- **Compression.** A section is either stored raw (encoding 0) or as a complete **zlib stream** (RFC 1950: a 2-byte header, raw DEFLATE data per RFC 1951, and a 4-byte big-endian Adler-32 trailer), written with zlib level 9 (encoding 1).
  - **iOS.** With libz, call `uncompress(dest, &destLen, src, srcLen)` with `destLen = raw_length`. With Apple's Compression framework (`COMPRESSION_ZLIB`, which expects raw DEFLATE), skip the first 2 bytes and ignore the last 4.
  - **Swift on Linux.** Link the system zlib and use `uncompress`.
  - No other codec is used.
- **Checksums.** CRC-32 as in zlib's `crc32()` (IEEE 802.3, reflected polynomial 0xEDB88320, initial value 0xFFFFFFFF, final XOR 0xFFFFFFFF). `crc32("123456789") = 0xCBF43926`. In format 1.1 every byte of a file is covered: the header CRC covers bytes 0..251 (which hold the section-table CRC), the section-table CRC covers the table, each section CRC covers its stored bytes, and every padding byte must be zero (A.2).
- **Division.** Every integer division in this document is **floor division** (rounding toward −∞). Longitudes here are negative, so truncating division (Swift's `/` on Int) gives wrong answers. Use a floor-division helper.

### A.2 File layout

```
offset 0      header (256 bytes)
offset 256    section table (section_count entries of 32 bytes)
              zero padding to a multiple of 8
              section 0 stored bytes, zero padding to a multiple of 8
              section 1 ...
```

The layout is exact, and readers check it (A.4 check 7): section 0 starts at the first multiple of 8 at or after the end of the table (`256 + 32·section_count`); section i+1 starts at the first multiple of 8 at or after the end of section i's stored bytes; `file_size` is the first multiple of 8 at or after the end of the last section; and every byte in between (all padding) is zero.

Writers store sections in this order. They are identified by their four-character tag, never by position:

`INFO STRS SRCS VERT TRIS [ADJC] ATTR GRID OVHD HAZD CHAN AREA GEOM`

`ADJC` is optional. All the others are required. A reader must ignore sections with unknown tags. A file is memory-mappable: section offsets are 8-byte aligned. A raw (encoding 0) section can be used in place. A compressed section must be inflated into a buffer of `raw_length` bytes. Fixed-width arrays (`ATTR`, the record tables and `GEOM`) can then be used without parsing. Varint sections (`VERT`, `TRIS`, `ADJC`, `GRID`) must be decoded once into arrays.

### A.3 Header (256 bytes)

| off | type | field | meaning |
|---|---|---|---|
| 0 | u8[8] | magic | ASCII `GCRTPACK` |
| 8 | u16 | format_major | 1. A reader must reject any other major version. |
| 10 | u16 | format_minor | 1. A newer minor version only adds sections or fields that are zero in older files; a reader accepts any minor version (A.4). |
| 12 | u32 | header_size | 256. Any other value is rejected. |
| 16 | u32 | file_size | total file size in bytes. Must equal the actual size. |
| 20 | u32 | section_count | number of section table entries, 1..4096 |
| 24 | u32 | section_table_offset | 256. Any other value is rejected. |
| 28 | u32 | flags | bit 0: an `ADJC` section is present (must agree with the table). Bits 1..31 are written as 0 and readers ignore them (reserved for later minor versions). |
| 32 | u8[32] | region_id | ASCII, NUL-padded, e.g. `pilot` |
| 64 | i32 | min_lon | bounding box in units. Every vertex **and every GEOM point** lies inside it, inclusive. `−1.8e9 ≤ min_lon ≤ max_lon ≤ 1.8e9`, `−0.9e9 ≤ min_lat ≤ max_lat ≤ 0.9e9`, and each span (`max − min`) is at most 2^30 units (about 107°), which keeps A.8 exact. |
| 68 | i32 | min_lat | |
| 72 | i32 | max_lon | |
| 76 | i32 | max_lat | |
| 80 | u32 | data_date | the newest ENC issue date among the cells that contributed data (`yyyymmdd`). This is the "chart data date" shown to the user. |
| 84 | u32 | build_date | `yyyymmdd` UTC |
| 88 | u32 | build_time | `hhmmss` UTC |
| 92 | u32 | vertex_count | V, with 3 ≤ V ≤ 2^31 − 1 |
| 96 | u32 | triangle_count | T, with 1 ≤ T and 3·T ≤ 2^31 − 1 |
| 100 | u16 | clearance_dm | safety clearance by which navigable water was shrunk from land, structures and blocking hazards (dm). 120 = 12 m. |
| 102 | u16 | check_dm | hazard radius used by leg validation (B.10), in dm. 110 = 11 m. |
| 104 | u16 | shore_ring0_m | distance band 0 limit (metres) of the shore class (A.7). 50. |
| 106 | u16 | shore_ring1_m | distance band 1 limit. 150. |
| 108 | u32 | table_crc32 | CRC-32 of the section table, bytes `256 .. 256 + 32·section_count − 1` (format 1.1; reserved 0 in 1.0) |
| 112 | u8[140] | reserved | 0 (readers ignore them) |
| 252 | u32 | header_crc32 | CRC-32 of bytes 0..251 |

### A.4 Section table entry (32 bytes)

| off | type | field |
|---|---|---|
| 0 | u8[4] | tag (ASCII, e.g. `VERT`) |
| 4 | u32 | encoding: 0 = raw, 1 = zlib stream |
| 8 | u64 | offset of the stored bytes from the start of the file |
| 16 | u32 | stored_length (bytes in the file) |
| 20 | u32 | raw_length (bytes after inflating; equals stored_length when raw) |
| 24 | u32 | crc32 of the **stored** bytes |
| 28 | u32 | count: number of items (see each section; INFO: 0) |

A writer sets `encoding = 0` and stores the section raw when zlib does not make it smaller.

**Reader checks.** A reader performs all of these, in this order. Any failure means the file is corrupt and must not be used. Both reference readers (`enc_routing.packfmt.decode_pack`, RoutingKit `PackParser`) implement exactly this list.

1. The file is at least 256 bytes and starts with the magic.
2. `format_major == 1`.
3. Header CRC.
4. `file_size` equals the actual size.
5. Header fields: `header_size == 256`; `section_table_offset == 256`; `1 ≤ section_count ≤ 4096` and the table fits in the file; the bounding box and the counts are within the limits of A.3.
6. If `format_minor ≥ 1`: `table_crc32` equals the CRC-32 of the section table. (A 1.0 file has no table CRC, and this check is skipped; every other check applies to it.)
7. Layout (A.2): every section starts exactly where A.2 says, lies inside the file, every padding byte is zero, and the file ends at the padded end of the last section.
8. Every section's stored bytes match its `crc32` (sections with unknown tags included).
9. Tags: no tag occurs twice; every required section is present; flag bit 0 is set if and only if `ADJC` is present. Sections with unknown tags are ignored from here on (their encoding is not checked).
10. Encoding is 0 or 1. Raw: `raw_length == stored_length`. zlib: the stored bytes are exactly one complete zlib stream (nothing after its Adler-32 trailer) that inflates to exactly `raw_length` bytes.
11. Section contents (A.5), in any order:
    - **counts**: `count` equals the stated item count for every section (`STRS`: N, the first u32; `VERT`: V; `TRIS`, `ADJC`, `ATTR`: T; `GRID`: nx·ny; record sections and `GEOM`: raw length / record size, with no remainder);
    - **varint sections**: exactly the stated number of uvarints with nothing left over, none longer than 10 bytes, no 64-bit overflow (the 10th byte is 0 or 1); over-long encodings of small values need not be rejected;
    - **STRS**: N ≥ 1, the offsets are non-decreasing, `offsets[0] == offsets[1] == 0` (string 0 is empty), `offsets[N]` equals the blob length, and every string is valid UTF-8;
    - **VERT**: every vertex lies inside the bounding box;
    - **TRIS**: `b − a > 0`, `c − a > 0`, `b ≠ c`, every index < V, and `orient(a, b, c) > 0` (A.9.1);
    - **ADJC** (when present): every neighbour n of (t, k) is in `[0, T)`, is not t, and owns the reversed edge (`v_t[k+1] → v_t[k]`) at some edge k' with `nbr[n][k'] == t`. When ADJC is absent, the derived adjacency must find no directed edge twice;
    - **ATTR**: raw length `17·T`; `channel`, `overhead` and `area` are `0xFFFF` or a valid record index;
    - **GRID**: `origin == (min_lon, min_lat)`, `cell > 0`, `nx == max(1, ceil((max_lon − min_lon) / cell))`, `ny` likewise with latitudes; per cell the count is ≤ T, ids are strictly ascending and < T; nothing after the last cell;
    - **GEOM**: every point lies inside the bounding box;
    - **OVHD, HAZD**: `geom_type` is 1, 2 or 3; `geom_first + geom_count ≤` the number of GEOM points; a point has exactly 1 point, a polyline at least 2, a ring at least 3;
    - **string ids** in SRCS, OVHD, HAZD, CHAN and AREA are < N.

INFO is never a reason to reject a file: readers decode it as UTF-8 replacing invalid sequences, and ignore lines without `=`. Readers ignore reserved bytes, reserved flag bits (header and ATTR flags bits 13..15) and record padding. The full A.9 guarantees (canonical order, GRID contents, ADJC equal to the derived adjacency) are checked by `enc_routing validate`; a reader need not check them.

**Compatibility.** Readers accept every minor version of major 1. A 1.0 file reads exactly like the same file in 1.1, except that it has no section-table checksum. Packs written before 1.1 need not be rebuilt, but every pack the builder writes now is 1.1.

### A.5 Sections

All descriptions below are of the **raw** (inflated) bytes.

#### INFO: build information

UTF-8 text, one `key=value` line per entry, each terminated by `\n`. Keys seen in v1.0 and v1.1:

- `builder`;
- `params` (JSON of the build parameters, part C);
- `params_key`;
- `crs`;
- `cells`;
- `topology` (JSON);
- `ncf`;
- `attribution`.

INFO is informative only. Routing must not depend on it.

#### STRS: string table (count = N strings)

```
u32 N
u32 offsets[N+1]      byte offsets into blob; string i = blob[offsets[i] .. offsets[i+1])
u8  blob[...]         UTF-8, not NUL-terminated
```

String 0 is `""`. The offsets partition the blob exactly (`offsets[N]` is the blob length), and every string is valid UTF-8.

#### SRCS: source cells (count = records, 24 bytes each)

| off | type | field |
|---|---|---|
| 0 | u32 | name (string id), e.g. `US5FL13M` |
| 4 | u16 | edition |
| 6 | u16 | update number applied |
| 8 | u32 | issue date of the applied update (`yyyymmdd`) |
| 12 | u32 | compilation scale (e.g. 12000) |
| 16 | u8 | usage band 1..6 (overview .. berthing) |
| 17 | u8 | used: 1 if the cell contributed data after the best-scale merge, else 0 |
| 18 | u8[6] | 0 |

#### VERT: vertices (count = V)

A sequence of 2·V uvarints. For i = 0..V−1 they are `zz(dx_i), zz(dy_i)`, where

```
dx_0 = lon_0 − min_lon,  dy_0 = lat_0 − min_lat     (header bbox)
dx_i = lon_i − lon_{i−1}, dy_i = lat_i − lat_{i−1}
```

The reader decodes them into `lon[V], lat[V]` (`i32`) by prefix sums. Every vertex lies inside the header bounding box. Vertices are ordered along a Hilbert curve, which is what makes the deltas small; readers need not know that.

#### TRIS: triangles (count = T)

A sequence of 3·T uvarints. For each triangle t = 0..T−1 they are `(a_t − a_{t−1}), (b_t − a_t), (c_t − a_t)`, with `a_{−1} = 0`. Here `(a, b, c)` are its vertex indices. Guarantees:

- `a < b` and `a < c`: the smallest index comes first, so all three values are ≥ 0.
- `(a, b, c)` is counter-clockwise in (x = lon, y = lat): `orient(a, b, c) > 0` (A.8).
- Triangles are sorted by `(a, b, c)` ascending, so `a_t − a_{t−1} ≥ 0`.

**Edge k** of triangle t is the directed edge from `v[k]` to `v[(k+1) mod 3]`, where `v = (a, b, c)`. Edge 0 is a→b, edge 1 is b→c and edge 2 is c→a.

#### ADJC: adjacency (optional, count = T)

A sequence of 3·T uvarints, `zz(n_{t,k} − t)` for t = 0..T−1 and k = 0..2. Here `n_{t,k}` is the triangle across edge k, and the value **0 means "no neighbour"** (boundary). A triangle is never its own neighbour.

**If ADJC is absent, the reader must derive the adjacency**, and the result is identical. The neighbour across edge k of t, which runs from p to q, is the unique triangle that has the directed edge q→p, or −1 (boundary) if no triangle has it. Build a hash map from the directed edge (p, q) to (t, k) over all 3T edges, then look up each reversed edge. The pack guarantees that no directed edge occurs twice (A.9). The pilot pack omits ADJC: deriving adjacency costs about 0.1 s and saves 1.7 MB of download.

#### ATTR: per-triangle attributes (count = T)

These are columns, each T elements long, stored one after another in this order. Column j therefore starts at byte offset `sum(size of columns before j) · T`.

| # | column | type | unit | sentinel / meaning |
|---|---|---|---|---|
| 0 | depth_dm | i16 | dm below MLLW | **charted least depth** after sounding refinement and lowering (part C). `-32768` = no depth information, so the triangle is impassable. Negative values are drying heights (not produced in v1.0). |
| 1 | band_depth_dm | i16 | dm | the same, but **without** the sounding raise: the depth-area least depth lowered by soundings and hazards. Equal to depth_dm unless flag SOUNDING_REFINED is set. `-32768` = none. |
| 2 | maint_dm | i16 | dm | **USACE maintained depth** of the National Channel Framework reach covering the triangle, converted from feet with the NOAA rule (`floor(ft·3.048)`). `-32768` = not in a maintained reach. |
| 3 | clearance_dm | u16 | dm above MHW | **least known vertical clearance** of any overhead object over the triangle. For an opening span this is the closed clearance. A bridge part with no charted clearance counts as 0 (solid). `0xFFFF` = no overhead object. `0xFFFE` = only objects of unknown clearance. |
| 4 | flags | u16 | bits | see below |
| 5 | channel | u16 | | index into CHAN, `0xFFFF` = none |
| 6 | overhead | u16 | | index into OVHD of the representative overhead object (the lowest known clearance, else an unknown one), `0xFFFF` = none |
| 7 | area | u16 | | index into AREA of the most restrictive regulated area (prohibited > restricted > caution, then the lowest index), `0xFFFF` = none |
| 8 | quality | u8 | | bits 0–2: CATZOC code (0 unknown, 1 A1, 2 A2, 3 B, 4 C, 5 D, 6 U), the worst over the triangle. Bits 3–7: survey decade code d = 0 unknown, else the decade starts at `1850 + 10·d` (d is clamped to 1..31), the oldest over the triangle. |

Flags:

| bit | name | meaning |
|---|---|---|
| 0 | CHANNEL | in a marked channel: ENC fairway, dredged area, recommended track or navigation line (±15 m), or NCF reach |
| 1 | HIGHWAY | within 30 m of a USACE NCF centreline or the ENC Intracoastal Waterway recommended track. Always set together with CHANNEL. |
| 2 | OPENING_BRIDGE | every overhead object over the triangle is an opening span (bascule, swing, lifting, draw, transporter, or generic opening) |
| 3 | UNKNOWN_CLEARANCE | at least one overhead object over the triangle has no charted clearance (a cable or pipe without VERCLR, or an opening span without closed clearance) |
| 4 | RESTRICTED | in a restricted area (entry restricted, area to be avoided, safety zone, military area, minefield) |
| 5 | CAUTION | in a caution area (CTNARE, such as "shoal reported"), a nature reserve or a no-wake/speed area |
| 6 | NEAR_HAZARD | within 30 m of any charted obstruction, wreck or rock |
| 7 | HAZARD_DEPTH | within the clearance zone (12 m) of a hazard with **known** depth; depth_dm is then ≤ that hazard's VALSOU |
| 8 | PROHIBITED | in an entry-prohibited area: never passable |
| 9 | OUTSIDE | open Gulf (outside the barrier islands and bay mouths) |
| 10 | SOUNDING_REFINED | depth_dm was raised above the depth-area least depth by the sounding rule (C.4) |
| 11–12 | shore class | 0: within shore_ring0_m (50 m) of land, a structure or a blocking hazard; 1: within shore_ring1_m (150 m); 3: farther; 2: unused |
| 13–15 | reserved | 0 |

#### GRID: point-location index (count = nx·ny)

```
i32 origin_lon, i32 origin_lat     (units; equal to header min_lon, min_lat)
i32 cell                           cell size in units (pilot: 100000 = 0.01 degree), > 0
u32 nx, u32 ny                     nx = max(1, ceil((max_lon − min_lon) / cell)), ny likewise
then for each cell c = i·nx + j (i = row from the south, j = column from the west), in order:
   uvarint n                        number of triangles listed in the cell
   if n > 0: uvarint id_0, then n−1 uvarints (id_k − id_{k−1})   (ids strictly ascending)
```

Cell (i, j) is the **closed** rectangle `[origin_lon + j·cell, origin_lon + (j+1)·cell] × [origin_lat + i·cell, origin_lat + (i+1)·cell]`. Triangle t is listed in every cell that intersects its integer bounding box (closed intervals; so a triangle whose edge lies on a cell line is listed on both sides). For each triangle, the cell range is

```
ja = clamp(floor((xmin − ox) / cell) − (1 if (xmin − ox) mod cell == 0 else 0), 0, nx−1)
jb = clamp(floor((xmax − ox) / cell), 0, nx−1)
```

and the same for rows with y. **Lookup** of a point (x, y): `j = clamp(floor((x − ox)/cell), 0, nx−1)`, `i = clamp(floor((y − oy)/cell), 0, ny−1)`. Every triangle containing the point is listed in that cell.

#### OVHD: overhead objects (bridges, cables, pipes; count = records, 40 bytes each)

| off | type | field |
|---|---|---|
| 0 | u8 | kind: 1 bridge part, 2 overhead cable, 3 overhead pipe |
| 1 | u8 | flags: bit 0 opening span; bit 1 clearance not charted, so this non-opening bridge part is treated as solid (clearance 0) |
| 2 | u16 | CATBRG bitmask: bit (c−1) set for each S-57 CATBRG value c (1 fixed, 2 opening, 3 swing, 4 lifting, 5 bascule, 6 pontoon, 7 drawbridge, 8 transporter, 9 footbridge, 10 viaduct, 11 aqueduct, 12 suspension) |
| 4 | u16 | clearance_dm: VERCCL for an opening span, else VERCLR (VERCSA for a cable if present); `0xFFFE` unknown |
| 6 | u16 | open_clearance_dm (VERCOP), `0xFFFE` unknown |
| 8 | u16 | horizontal clearance (HORCLR) in dm, `0xFFFE` unknown |
| 10 | u16 | 0 |
| 12 | u32 | name (string id; 0 = unnamed) |
| 16 | i32 | lon, representative point (units) |
| 20 | i32 | lat |
| 24 | u32 | geom_first: index of the first point in GEOM |
| 28 | u32 | geom_count |
| 32 | u8 | geom_type: 1 point (exactly 1 point), 2 polyline (at least 2), 3 polygon ring (at least 3; outer ring, not closed: the last point is not repeated) |
| 33 | u8[7] | 0 |

A multi-part source object is stored as one record per part.

#### HAZD: hazards (count = records, 32 bytes each)

Every charted obstruction, wreck and underwater rock in the region, except foul ground (OBSTRN CATOBS 7).

| off | type | field |
|---|---|---|
| 0 | u8 | class: 1 OBSTRN, 2 WRECKS, 3 UWTROC |
| 1 | u8 | WATLEV (0 unknown, 1 partly submerged at high water, 2 always dry, 3 always under water, 4 covers and uncovers, 5 awash, 6 subject to inundation, 7 floating) |
| 2 | u8 | category: the smallest CATOBS (OBSTRN) or CATWRK (WRECKS) value, 0 if none |
| 3 | u8 | geom_type (as OVHD) |
| 4 | i16 | valsou_dm: least depth (dm), `-32768` unknown, ≤ 0 dry or awash |
| 6 | u16 | 0 |
| 8 | i32 | lon (representative point) |
| 12 | i32 | lat |
| 16 | u32 | geom_first |
| 20 | u32 | geom_count |
| 24 | u32 | name (string id) |
| 28 | u32 | 0 |

#### CHAN: named channels (count = records, 32 bytes each)

| off | type | field |
|---|---|---|
| 0 | u8 | source: 1 USACE NCF channel reach, 2 ENC FAIRWY, 3 ENC DRGARE, 4 ENC RECTRC/NAVLNE (buffered ±15 m) |
| 1 | u8 | flags: bit 0 Intracoastal Waterway |
| 2 | i16 | maint_dm: maintained depth (NCF `depthmaintained`, converted), `-32768` none |
| 4 | i16 | auth_dm: authorised depth (NCF `depthauthorized`) or DRGARE DRVAL1, `-32768` none |
| 6 | u16 | 0 |
| 8 | u32 | name (string id), e.g. `Giww Cal To Anc (Sarasota County)` |
| 12 | u32 | ident (string id): NCF reach id, or ENC LNAM |
| 16 | u32 | desc (string id): NCF cut, e.g. `Cut S-28` |
| 20 | u32 | date: NCF upload date or ENC SORDAT (`yyyymmdd`) |
| 24 | i32 | lon (representative point) |
| 28 | i32 | lat |

#### AREA: regulated areas (count = records, 32 bytes each)

| off | type | field |
|---|---|---|
| 0 | u8 | kind: 1 prohibited, 2 restricted, 3 caution |
| 1 | u8 | source: 1 RESARE, 2 CTNARE |
| 2 | u16 | 0 |
| 4 | u32 | name (string id; a generic name if the chart has none) |
| 8 | u32 | text (string id): the chart's INFORM text, e.g. `Shoal reported` |
| 12 | i32 | lon (representative point) |
| 16 | i32 | lat |
| 20 | u8[12] | 0 |

#### GEOM: coordinate pool (count = points)

`count` pairs of `i32 lon, i32 lat` (units), referenced by OVHD and HAZD. Every point lies inside the header bounding box (the builder grows the box to include them).

### A.6 Units and the NOAA truncation rule

NOAA compiles US charts in feet and writes S-57 metric values **truncated** to 0.1 m. For example, 6 ft = 1.8288 m is stored as 1.8, 12 ft as 3.6, 36 ft as 10.9 and 65 ft as 19.8. The pack stores these values unchanged as integer dm (18, 36, 109, 198). USACE depths, which are published in feet, are converted the same way: `floor(ft · 3.048)` dm. Comparisons against a boat requirement given in feet must use B.2. Comparing with exact metres drops every whole-foot contour (6 ft > 1.8 m).

### A.7 Shore class

The shore class is a 2-bit field in `flags`. It is used only by the cost function (B.5). The ring polygons are simplified by 5 m, so the class is approximate to about 5 m.

### A.8 Geometry predicates (exact)

```
orient(p, q, r) = (q.x − p.x)·(r.y − p.y) − (q.y − p.y)·(r.x − p.x)        in Int64
```

**Exactness bound.** Every input to `orient` in this document is a vertex, a GEOM point, or a query or snapped point that lies inside the header bounding box (B.6 rejects others). Every coordinate difference is therefore at most 2^30 in absolute value (A.3), each product at most 2^60 and the result at most 2^61 in absolute value, so the computation is exact in Int64. (Arbitrary i32 inputs are **not** safe: differences reach 2^32 and products overflow.) The dot products of B.10, `(P − A)·(B − A)`, obey the same bound. Triangle t **contains** point P if `orient(a,b,P) ≥ 0 && orient(b,c,P) ≥ 0 && orient(c,a,P) ≥ 0`. Points on edges and vertices count as inside.

### A.9 Topology guarantees

The builder fails rather than write a pack that violates any of these. `enc_routing validate` re-checks them.

1. Every triangle has `orient(a,b,c) > 0`: no flat or clockwise triangles.
2. No directed edge occurs in two triangles. So every undirected edge is shared by at most two triangles, with opposite directions: the mesh is manifold and consistently oriented.
3. No vertex lies strictly inside any boundary edge: no T-junctions. Interior edges cannot have one either, given 2 and the exact area check the builder runs (the triangles' total area equals the area of the polygons they triangulate).
4. No duplicate vertices and no unused vertices.
5. Triangles are canonical (A.5 TRIS) and the GRID matches the construction in A.5 exactly.

Bow-tie vertices (two water parts touching at a single point) are allowed. A route never passes through a bare vertex, because A* moves across edges.

### A.10 Worked examples (synthetic.pack)

The bytes below are from `testdata/routing/synthetic.pack`. All values are little-endian.

**Header** (all 256 bytes; bytes 112..251 are zero and elided):

```
0000  47 43 52 54 50 41 43 4B 01 00 01 00 00 01 00 00
0010  20 07 00 00 0D 00 00 00 00 01 00 00 01 00 00 00
0020  73 79 6E 74 68 65 74 69 63 00 00 00 00 00 00 00
0030  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
0040  00 CB 1F CF 80 DF 17 10 80 03 21 CF C0 7B 18 10
0050  ED 28 35 01 F8 28 35 01 C0 D4 01 00 2D 00 00 00
0060  3E 00 00 00 78 00 6E 00 32 00 96 00 0D 02 87 03
...
00F0  00 00 00 00 00 00 00 00 00 00 00 00 1D 17 A0 34
```

Decoded: magic `GCRTPACK`; version 1.1; header_size 256; file_size 1824 (`20 07 00 00`); section_count 13; table at 256; flags 1 (ADJC present); region `synthetic`; bbox lon -820000000 .. -819920000, lat 270000000 .. 270040000 (for example `00 CB 1F CF` = -820000000 = -82.0000000°); data_date 20261101 (`ED 28 35 01`); build 20261112 120000; V = 45, T = 62; clearance_dm 120 (`78 00`); check_dm 110 (`6E 00`); shore rings 50 / 150 m; table_crc32 0x0387020D (`0D 02 87 03`, the CRC-32 of the 416-byte table at 0x100); header_crc32 0x34A0171D.

**Section table** (the first five entries):

```
0100  49 4E 46 4F 00 00 00 00 A0 02 00 00 00 00 00 00
0110  33 00 00 00 33 00 00 00 3F F7 E7 FE 00 00 00 00
0120  53 54 52 53 01 00 00 00 D8 02 00 00 00 00 00 00
0130  A8 00 00 00 E8 00 00 00 51 C3 B5 52 0E 00 00 00
0140  53 52 43 53 00 00 00 00 80 03 00 00 00 00 00 00
0150  18 00 00 00 18 00 00 00 6C 12 80 F3 01 00 00 00
0160  56 45 52 54 01 00 00 00 98 03 00 00 00 00 00 00
0170  3F 00 00 00 B6 00 00 00 FE 8D 2E 60 2D 00 00 00
0180  54 52 49 53 01 00 00 00 D8 03 00 00 00 00 00 00
0190  74 00 00 00 BA 00 00 00 4A 76 62 B3 3E 00 00 00
```

Entry 0: tag `INFO`, encoding 0, offset 672 (the first multiple of 8 after the 256 + 13·32 = 672-byte header and table), stored 51, raw 51, crc32 0xFEE7F73F, count 0. Its stored bytes end at 723, so bytes 723..727 are zero padding and entry 1 (`STRS`) starts at 728. Entry 3: tag `VERT`, encoding 1 (zlib), offset 920, stored 63, raw 182, count 45.

**INFO** raw starts `62 75 69 6C 64 65 72 3D 65 6E 63 5F 72 6F 75 74 69 6E 67 20 73 79 6E 74` = `builder=enc_routing synt`...

**STRS** raw starts

```
0000  0E 00 00 00 00 00 00 00 00 00 00 00 13 00 00 00
0010  24 00 00 00 2E 00 00 00 38 00 00 00 44 00 00 00
0020  49 00 00 00 55 00 00 00 64 00 00 00 73 00 00 00
```

N = 14; offsets[0..2] = 0, 0, 19, so string 0 = `""` and string 1 = bytes 0..19 of the blob = `Test Opening Bridge`. The blob starts at byte 4 + 4·(N+1) = 64.

**SRCS** record 0 (24 bytes): `0C 00 00 00 03 00 01 00 ED 28 35 01 E0 2E 00 00 05 01 00 00 00 00 00 00`. name = string 12 (`US5TEST1`), edition 3, update 1, issue date 20261101 (`ED 28 35 01`), cscale 12000 (`E0 2E 00 00`), band 5, used 1.

**VERT** raw starts `00 00 A0 9C 01 00 00 A0 9C 01 9F 9C`. The first uvarints are [0, 0, 20000, 0, 0, 20000]: zigzag-decoded they are dx0 = 0, dy0 = 0 (vertex 0 = (-820000000, 270000000) = (min_lon + dx0, min_lat + dy0)), then vertex 1 = (-819990000, 270000000), and vertex 2 = (-819990000, 270010000). For example, `A0 9C 01` = 20000 → zigzag → +10000.

**TRIS** raw starts `00 01 02 00 02 03 01 0C`. Triangle 0: uvarints [0, 1, 2] → a = 0, b = 1, c = 2. Triangle 1: [0, 2, 3] → [0, 2, 3].

**ADJC** raw starts `00 04 02 01 06 00`. Triangle 0: uvarints [0, 4, 2] → zigzag [0, 2, 1] → neighbours [-1, 2, 1] (0 → none, −1).

**ATTR** triangle 0 (T = 62, so column j starts at 2·j·T for the 16-bit columns and the quality byte column at 16·T):

- depth_dm @ 0: `06 00` = 6
- band_depth_dm @ 124: `06 00` = 6
- maint_dm @ 248: `00 80` = -32768
- clearance_dm @ 372: `FF FF` = 65535
- flags @ 496: `00 00` = 0
- channel @ 620: `FF FF` = 65535
- overhead @ 744: `FF FF` = 65535
- area @ 868: `FF FF` = 65535
- quality @ 992: `55` = 85

flags 0x0000 = shore class 0. Quality 0x55 = CATZOC 5 (D), decade code 10 (1950s).

**GRID** raw starts `00 CB 1F CF 80 DF 17 10 20 4E 00 00 04 00 00 00 02 00 00 00 10 00 01 01 01 01 01 01`: origin (-820000000, 270000000), cell 20000, nx 4, ny 2. Then cell 0: count 16, ids [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 15, 16, 17, 18, 25] (encoded as the first id, then deltas).

**OVHD** record 0 (40 bytes):

```
0000  01 01 10 00 12 00 FE FF 12 01 00 00 01 00 00 00
0010  D8 A1 20 CF 18 1A 18 10 00 00 00 00 02 00 00 00
0020  02 00 00 00 00 00 00 00
```

kind=1, flags=1, catbrg=16, clearance_dm=18, open_clearance_dm=65534, hor_clearance_dm=274, name=1, lon=-819945000, lat=270015000, geom_first=0, geom_count=2, geom_type=2.

**HAZD** record 0 (32 bytes):

```
0000  02 03 00 01 0F 00 00 00 C8 7A 20 CF 28 41 18 10
0010  07 00 00 00 01 00 00 00 04 00 00 00 00 00 00 00
```

cls=2, watlev=3, category=0, geom_type=1, valsou_dm=15, lon=-819955000, lat=270025000, geom_first=7, geom_count=1, name=4. (GEOM point 6 is the overhead point object, OVHD 3.)

**CHAN** record 0 (32 bytes):

```
0000  01 01 1B 00 1B 00 00 00 05 00 00 00 06 00 00 00
0010  07 00 00 00 05 25 35 01 40 67 20 CF 18 1A 18 10
```

source=1, flags=1, maint_dm=27, auth_dm=27, name=5, ident=6, desc=7, date=20260101, lon=-819960000, lat=270015000.

**AREA** record 0 (32 bytes):

```
0000  01 01 00 00 08 00 00 00 00 00 00 00 E8 C8 20 CF
0010  38 68 18 10 00 00 00 00 00 00 00 00 00 00 00 00
```

kind=1, source=1, name=8, text=0, lon=-819935000, lat=270035000.

**GEOM** point 0: `D8 A1 20 CF 90 06 18 10` = (-819945000, 270010000).

---

## Part B. Routing algorithm

The router reads only the pack. Every constant below is exact. Floating point is IEEE double. Operations must be done in the order written, so that results match the vectors bit for bit (for distances, within 1e-6 m).

### B.1 Constants and the local metric

```
R      = 6371008.8                     metres (mean Earth radius)
DEG    = 0.017453292519943295          π/180 as a double
K      = R · DEG                       metres per degree of latitude
UNITS  = 1e7

dist(lon1, lat1, lon2, lat2):          // degrees in, metres out
    phi = (lat1 + lat2) · 0.5 · DEG
    dx  = (lon2 − lon1) · DEG · cos(phi)
    dy  = (lat2 − lat1) · DEG
    return R · sqrt(dx·dx + dy·dy)
```

This is equirectangular about the mean latitude. Every distance in the router uses it. `cos` is the platform libm cos; differences between libm implementations are below 1 ulp and do not change any vector.

**Local frame at a point (lon0, lat0)** (degrees): `kx = K·cos(lat0·DEG)`, `ky = K`. A point maps to `X = (lon − lon0)·kx` and `Y = (lat − lat0)·ky`, where `lon = x/1e7` and `lat = y/1e7`.

### B.2 Boat profile and thresholds

| field | type | default | meaning |
|---|---|---|---|
| draft_ft | double | – | draft in feet |
| margin_ft | double | – | safety margin under the keel, in feet |
| air_draft_ft | double | – | height above the waterline, in feet |
| use_maintained | bool | false | allow USACE maintained depth where the chart is shallower ("use maintained channels") |
| accept_unknown_clearance | bool | false | allow passing under overhead objects of unknown clearance |
| avoid_open_gulf | bool | false | inside route only: OUTSIDE triangles are impassable |

```
req_dm(f) = floor( ceil(f − 1e-9) · 3048 / 1000 )      // ceil and floor on integers; result in dm
req = req_dm(draft_ft + margin_ft)      e.g. 4.5 + 1.5 = 6.0 ft → 18 dm;  5.5 ft → 6 ft → 18;  6.1 ft → 7 ft → 21
air = req_dm(air_draft_ft)              e.g. 20 ft → 60 dm; 65 ft → 198 dm
```

**Valid profiles.** `draft_ft`, `margin_ft` and `air_draft_ft` must each be finite, ≥ 0 and < 1000, and `draft_ft + margin_ft < 1000`; `max_snap_m` (B.6) must be finite with `0 ≤ max_snap_m ≤ 100000`. Otherwise the result is `INVALID_REQUEST` (B.13), checked before anything else. (`req_dm(0) = 0`: a zero requirement is valid.)

The requirement is rounded **up** to whole feet first, because charts are compiled in whole feet: a 5.5 ft requirement can only be met by a charted 6 ft. It is then converted exactly as NOAA does. A charted value v satisfies the requirement if and only if `v ≥ req` (or `v ≥ air`).

### B.3 Triangle passability

For triangle t, with `depth, band, maint, clr, flags` from ATTR:

```
has_depth  = depth ≠ −32768
depth_ok   = has_depth && depth ≥ req
maint_ok   = use_maintained && has_depth && maint ≠ −32768 && maint ≥ req && !(flags & HAZARD_DEPTH)
opening    = flags & OPENING_BRIDGE
unknown    = flags & UNKNOWN_CLEARANCE
has_ovh    = clr ≠ 0xFFFF
known_ok   = clr == 0xFFFE || clr ≥ air
```

The triangle is **blocked**, with the first reason that applies in this order (reason codes 0..4):

| code | reason | condition |
|---|---|---|
| 0 | PROHIBITED | `flags & PROHIBITED` |
| 1 | OPEN_GULF | `avoid_open_gulf && (flags & OUTSIDE)` |
| 2 | DEPTH | `!(depth_ok || maint_ok)` |
| 3 | CLEARANCE | `has_ovh && !opening && !known_ok` |
| 4 | UNKNOWN_CLEARANCE | `has_ovh && !opening && known_ok && unknown && !accept_unknown_clearance` |

Otherwise it is **passable**. Opening bridges are always passable. Maintained depth never overrides a charted hazard (HAZARD_DEPTH).

Derived per-triangle booleans (for passable triangles):

```
via_maint     = !depth_ok && maint_ok                       // passable only thanks to maintained depth
via_sound     = depth_ok && (band == −32768 || band < req)  // passable only thanks to the sounding raise
needs_opening = opening && has_ovh && (clr == 0xFFFE || clr < air)
unknown_used  = unknown && !opening && has_ovh
restricted    = flags & RESTRICTED
```

### B.4 Shore class

`shore = (flags >> 11) & 3`.

### B.5 Cost factor and penalties

For each triangle compute `f` as a double, in this order:

```
f = 1.0
if flags & HIGHWAY:      f = f · 0.80
else if flags & CHANNEL: f = f · 0.90
if shore == 0:           f = f · 1.5
else if shore == 1:      f = f · 1.15
if flags & NEAR_HAZARD:  f = f · 1.2
spare = depth − req                                   (Int)
if via_maint:            f = f · 3.0
else if spare < 3:       f = f · 1.3
else if spare < 10:      f = f · 1.1
if via_sound:            f = f · 1.5
if restricted:           f = f · 2.0
if flags & CAUTION:      f = f · 1.25
FMIN = 0.8                                           (heuristic multiplier)
```

Entry penalties are added, in metres, when the search steps from triangle t into triangle u:

| condition | penalty |
|---|---|
| `needs_opening[u] && !needs_opening[t]` | +1500 |
| `unknown_used[u] && !unknown_used[t]` | +3000 |
| `restricted[u] && !restricted[t]` | +1000 |
| `blocked[u] && !blocked[t]` (only in the no-route search, B.11) | +100000 |

### B.6 Snapping the start and goal

Input is lon/lat in degrees and `max_snap_m`, default 750. The start is snapped first, then the goal, each with this procedure.

1. If `lon·1e7 + 0.5` or `lat·1e7 + 0.5` is not finite (NaN, ±∞, or an overflow), the result is error `OUTSIDE_PACK`. Otherwise `x = floor(lon·1e7 + 0.5)`, `y = floor(lat·1e7 + 0.5)`, as exact integers (not clamped to i32).
2. If (x, y) is outside the header bbox (inclusive), the result is error `OUTSIDE_PACK`. This also covers |lon| > 180 and |lat| > 90.
3. **Locate.** Look up the GRID cell (A.5). Among its triangle ids, in ascending order, the first one that contains (x, y) (A.8) is the located triangle. If none contains it, the point is not in the mesh ("in_mesh" = false). That happens on land, within the clearance zone of land or structures, or in water too small for the mesh.
4. If the located triangle exists and is passable for the profile, use it with `snap_m = 0` and the point (x, y) unchanged.
5. Otherwise, search:
   - `lat0 = y/1e7`, `lon0 = x/1e7`, `kx = K·cos(lat0·DEG)`, `ky = K`. The local frame of B.1 at (lon0, lat0) maps a point (px, py) in units to `X = (px/1e7 − lon0)·kx`, `Y = (py/1e7 − lat0)·ky`, and its **distance** is `hypot(X, Y)`.
   - `rx = ceil(max_snap_m / kx · 1e7)`, `ry = ceil(max_snap_m / ky · 1e7)` (integers).
   - Take all GRID cells from `cell(x − rx, y − ry)` to `cell(x + rx, y + ry)` inclusive (the lookup of A.5 clamps both corners into the grid). The candidates are the union of their ids, keeping only passable triangles, **sorted ascending**.
   - For each candidate, map its three vertices into the local frame, then compute the closest point Q of the triangle to the origin. The origin is inside if, for every edge k with endpoints A = vertex k and B = vertex k+1, `(B.X − A.X)·(0 − A.Y) − (B.Y − A.Y)·(0 − A.X) ≥ 0`; then Q is the origin and the distance is 0. Otherwise, for k = 0, 1, 2, take the closest point on segment AB: with `d = B − A`, `s = ((0−A.X)·d.X + (0−A.Y)·d.Y) / (d.X² + d.Y²)` (if `d.X² + d.Y² == 0`, Q = A), clamped to [0, 1], `Q = A + s·d`, with distance `hypot(Q.X, Q.Y)`. Keep the edge with the strictly smallest distance.
   - Pick the candidate with the strictly smallest distance d, so the lowest id wins a tie. The snapped triangle is that candidate (not re-located).
   - If there is no candidate, the result is error `NO_WATER_NEARBY` with `located` (the located triangle, or null). If d > `max_snap_m`, the result is error `NO_WATER_NEARBY` with `located` and `nearest_m = d`.
   - **Rounding into the triangle.** `sx = floor((lon0 + Q.X/kx)·1e7 + 0.5)`, `sy = floor((lat0 + Q.Y/ky)·1e7 + 0.5)`. If the snapped triangle contains (sx, sy) (A.8, exact), that is the snapped point. Otherwise (rounding moved it up to a unit outside the triangle, possibly into an impassable neighbour), consider in this order the eight points `(sx + i, sy + j)` for j = −1, 0, 1 and, within each j, i = −1, 0, 1 (skipping (0, 0)), then the triangle's vertices a, b, c; among those the snapped triangle contains, the snapped point is the one with the strictly smallest distance in the local frame (the first in that order wins a tie). A vertex always qualifies, so a point is always found. The snapped point therefore always lies inside or on the boundary of the snapped passable triangle.
   - `snap_m` is the distance of the snapped point (sx, sy) in the local frame. It can exceed d, and `max_snap_m`, by about a centimetre (more only in the vertex fallback); the `max_snap_m` test uses d.
6. Errors are reported as `START_<error>` or `GOAL_<error>`. If the start fails, the goal is not snapped.

The app must show `snap_m` when it is above a few metres. A start at a dock is usually snapped 10–40 m, because water within 12 m of structures is not in the mesh.

`hypot` is the platform's; like `cos` (B.1), implementations differ by at most 1 ulp, which changes no vector.

### B.7 A* over triangles

The inputs are the start triangle s, the goal triangle g, `S = (sx/1e7, sy/1e7)`, `G = (gx/1e7, gy/1e7)` (degrees), the per-triangle `ok` (passable) and `f`, and the penalties.

```
gcost[s] = 0; pos[s] = S; came[s] = −1; closed = ∅; seq = 0
push (FMIN · dist(S, G), 0, s)
while heap not empty:
    pop the entry with the smallest (priority, seq)
    if t ∈ closed: continue
    closed ∪= {t}
    if t == g: stop (found)
    (px, py) = pos[t]
    for k in 0, 1, 2:
        u = nbr[t][k]
        if u < 0 or u ∈ closed or !ok[u]: continue
        (mx, my) = midpoint of edge k of t:  ((x_a + x_b) / 2e7, (y_a + y_b) / 2e7)   // integer sum, then one double division
        step = dist(px, py, mx, my) · ((f[t] + f[u]) · 0.5)
        step += penalties for entering u from t (B.5, in the order listed)
        ng = gcost[t] + step
        if ng < gcost[u] (default +∞):
            gcost[u] = ng; pos[u] = (mx, my); came[u] = t
            seq = seq + 1
            push (ng + FMIN · dist(mx, my, G), seq, u)
```

If g is never closed, there is no route. The **corridor** is g, came[g], came[came[g]], … reversed, so it runs from s to g. If s == g, the corridor is [s].

### B.8 Funnel (string pulling)

Portals: for consecutive corridor triangles (t, u), let k be the edge of t with `nbr[t][k] == u`. Then `left = v[(k+1) mod 3]`, `right = v[k]`, as integer vertex coordinates. With n = corridor length, `P[0] = (S, S)`, `P[1..n−1]` are the portals and `P[n] = (G, G)`, all as integer units (S and G are the snapped (x, y)). `tri2 = orient` (A.8, exact Int64).

```
path = [(S, 0)]; apex = S; left = P[0].left; right = P[0].right; ai = li = ri = 0; i = 1
while i ≤ n:
    (pl, pr) = P[i]
    if tri2(apex, right, pr) ≥ 0:
        if apex == right or tri2(apex, left, pr) < 0:  right = pr; ri = i
        else:  path.append((left, li)); apex = left; ai = li; left = right = apex; li = ri = ai; i = ai + 1; continue
    if tri2(apex, left, pl) ≤ 0:
        if apex == left or tri2(apex, right, pl) > 0:  left = pl; li = i
        else:  path.append((right, ri)); apex = right; ai = ri; left = right = apex; li = ri = ai; i = ai + 1; continue
    i = i + 1
if path.last.point ≠ G: path.append((G, n))
remove each entry whose point equals the previous kept entry's point (keep the first)
if path.last.index ≠ n: path.last.index = n
```

The result is a list of waypoints `(point, portal index)`. The first has index 0 and the last has index n; when S == G the list has a single waypoint (with index n) and the route has no legs. **Leg j** runs from waypoint j (index pa) to waypoint j+1 (index pb). It covers corridor positions `lo = pa` to `hi = min(max(pa, pb − 1), n − 1)` inclusive. Every leg lies inside the union of its triangles: water is pre-shrunk by the safety clearance (part C), so the straightened path keeps the clearance without any further offset.

### B.9 Leg grading

For leg j, with TT = corridor[lo..hi], the **yellow reasons** are tested in this order and listed in this order:

| reason | condition (any triangle in TT) |
|---|---|
| MAINTAINED_DEPTH | via_maint |
| SOUNDING_DEPTH | via_sound |
| BRIDGE_OPENING | needs_opening |
| UNKNOWN_CLEARANCE | unknown_used |
| RESTRICTED_AREA | flags & RESTRICTED |
| CAUTION_AREA | flags & CAUTION |
| HAZARD_PROXIMITY | flags & HAZARD_DEPTH |
| LOW_DATA_QUALITY | CATZOC ∈ {0 unknown, 5 D, 6 U} |
| THIN_MARGIN | !via_maint && depth − req < 3 && CATZOC ∈ {0, 4 C, 5 D, 6 U} |

`grade = "yellow"` if there is any reason, else `"green"` (charted depth satisfies draft + margin and nothing else applies). **There are no red legs in a returned route.** Anything that would be red makes the whole query fail: no route (B.11) or leg validation failure (B.10).

Per leg, also report:

- `length_m = dist(A, B)`;
- `min_depth_dm = min depth over TT`;
- `min_spare_dm = min(depth − req)` over the triangles of TT that are not via_maint (null if there are none);
- `crossings` from B.10.

### B.10 Leg validation against the side tables

This is an independent check of each leg against HAZD and OVHD. The mesh already guarantees it (hazards blocking the boat are 12 m away, overhead footprints contain their geometry with a margin, C.6), so a violation indicates a builder or reader bug. It is never shown as a red leg: the whole result becomes error `LEG_VALIDATION` with the list of violations.

1. **Frame.** For leg A→B (integer units, A ≠ B): `lonm = (xA + xB)/2e7`, `latm = (yA + yB)/2e7` (integer sum, then one double division), `kx = K·cos(latm·DEG)`, `ky = K`. A point (px, py) maps to `X = (px/1e7 − lonm)·kx`, `Y = (py/1e7 − latm)·ky`. `check_m = check_dm / 10`. The leg bbox is `[min(xA,xB), max(xA,xB)] × [min(yA,yB), max(yA,yB)]` in units; each record's geometry bbox is the bbox of its GEOM points.
2. **Hazards.** Candidates: every HAZD record whose geometry bbox intersects the leg bbox grown by `mx = ceil((check_m + 1)/kx·1e7)` units in x and `my = ceil((check_m + 1)/ky·1e7)` in y. A hazard **blocks** this boat if `valsou == −32768 || valsou < req`. A blocking candidate with `distance(leg, geometry) < check_m` (strict, item 5) is a violation `{kind: "HAZARD", record, distance_m, valsou_dm}`.
3. **Overhead candidates.** Every OVHD record whose geometry bbox intersects the leg bbox grown by `ox = ceil(2/kx·1e7)` and `oy = ceil(2/ky·1e7)` units: the 1 m point radius plus 1 m. (A point object within 1 m of the leg can lie outside the leg's own bbox, for example beside a leg that runs exactly east–west.) A larger candidate set gives the same result.
4. **Does the leg pass under a candidate?**
   - **Point** (geom_type 1, and a polyline whose points are all equal): the distance from the point to segment AB in the local frame (item 5) is ≤ 1.0 m.
   - **Polyline** (geom_type 2). Exact, on integer units, with `orient` of A.8 and integer dot products (exact by the bound of A.8). Remove consecutive duplicate points first. The leg passes under the polyline record if any of these holds:
     1. *proper crossing*: for some segment CD, `o1 = orient(A,B,C)`, `o2 = orient(A,B,D)`, `o3 = orient(C,D,A)`, `o4 = orient(C,D,B)` are all non-zero, o1 and o2 have opposite signs and o3 and o4 have opposite signs;
     2. *collinear overlap*: for some segment CD with `o1 = o2 = 0`, let `tC = (C−A)·(B−A)`, `tD = (D−A)·(B−A)`, `L2 = (B−A)·(B−A)`; the overlap has positive length: `max(min(tC,tD), 0) < min(max(tC,tD), L2)`;
     3. *leg endpoint on the line*: A or B lies on some closed segment CD (`orient(C,D,P) = 0` and P inside the bbox of CD). This catches a crossing that happens exactly at a waypoint, which neither adjacent leg crosses properly;
     4. *crossing through a vertex*: some point V lies strictly inside the leg (`orient(A,B,V) = 0` and `0 < (V−A)·(B−A) < L2`) and is a vertex of one or more candidate polylines. Its **arms** are the neighbouring vertices of V in every candidate polyline that has a vertex at V (one arm for an end vertex, two for an interior vertex). If some arm W has `orient(A,B,W) > 0` and some arm has `orient(A,B,W) < 0`, the leg crosses the joined line at V, and **every** polyline with an arm at V is passed under. (This covers a line that zigzags through the leg, and a leg that crosses exactly at the joint between two parts of one bridge stored as separate records: neither part alone is crossed, but the bridge is.)

     Otherwise the leg does not pass under it. In particular, a leg that only **touches** a polyline, at a vertex whose arms all lie on one side, does not: for example a leg that runs along the edge of a footprint and touches the end of its line, or a cable that sags onto the leg and turns back. Arms collinear with AB are covered by rule 2. Every rule is symmetric in A and B, so it does not depend on the direction of travel.
   - **Ring** (geom_type 3), in the local frame: some part of the leg lies strictly inside the ring. Touching the boundary does not count, because a leg along the edge of an adjacent bridge part is not under it. With `D = B − A`, ring points R_0..R_{n−1} and edges (R_i, R_{(i+1) mod n}):
     - for each edge (C, E), with `F = E − C` and `den = D.X·F.Y − D.Y·F.X`: if `den ≠ 0`, `s = ((C.X − A.X)·F.Y − (C.Y − A.Y)·F.X) / den` and `u = ((C.X − A.X)·D.Y − (C.Y − A.Y)·D.X) / den`; if `0 ≤ s ≤ 1` and `0 ≤ u ≤ 1`, s is a parameter;
     - and, if `L2 = D.X² + D.Y² > 0`, for each of C and E (call it P): `s = ((P.X − A.X)·D.X + (P.Y − A.Y)·D.Y) / L2`; if `0 ≤ s ≤ 1` and `hypot(P.X − (A.X + s·D.X), P.Y − (A.Y + s·D.Y)) ≤ 1e-6`, s is a parameter;
     - add 0 and 1, sort ascending and remove exact duplicates. For each consecutive pair (s0, s1) with `s1 − s0 > 1e-12`, take `sm = 0.5·(s0 + s1)` and `M = (A.X + sm·D.X, A.Y + sm·D.Y)`. The leg passes under the ring if for some pair M is inside the ring by the even–odd test (item 5) **and** its distance to the ring boundary (minimum over all edges, closing edge included, of the distance to the closest point on the edge) is `> 1e-6` m.
5. **Distances and tests** (local frame, doubles):
   - closest point on segment PQ to point R: `d = Q − P`; if `d.X² + d.Y² == 0` it is P; else `s = ((R.X−P.X)·d.X + (R.Y−P.Y)·d.Y)/(d.X² + d.Y²)` clamped to [0, 1], point `P + s·d`; the distance is `hypot` of the difference;
   - **point**: distance to the closest point on AB;
   - **segment–segment** AB, CD: 0 if they properly intersect (the four orientations, computed in doubles as in item 4.1, are non-zero with opposite pairs); otherwise the minimum of the four endpoint-to-segment distances (C and D to AB, then A and B to CD);
   - **polyline**: the minimum over its segments; **ring**: the minimum over its edges, closing edge included, and 0 if A is inside the ring;
   - **even–odd test** of point (px, py): `inside = false; j = n−1; for i in 0..n−1: if (R_i.Y > py) != (R_j.Y > py) and px < R_i.X + (py − R_i.Y)·(R_j.X − R_i.X)/(R_j.Y − R_i.Y): inside = !inside; j = i`.
6. **Crossings and violations.** For each candidate passed under, in ascending record order:
   - an opening span (OVHD flags bit 0) is recorded as `{record, clearance_dm, opening: true, needs_opening: clr == 0xFFFE || clr < air}`;
   - otherwise `{record, clearance_dm, opening: false}` (no `needs_opening` key); and if `clr == 0xFFFE` it is a violation `{kind: "UNKNOWN_CLEARANCE", record}` unless accept_unknown_clearance is set; else if `clr < air` it is a violation `{kind: "CLEARANCE", record, clearance_dm}`.

   Every candidate passed under is listed in the leg's `crossings`. Each violation also carries `leg` (the leg index). The violations of a route are listed leg by leg; within a leg, the hazard violations in ascending record order, then the overhead ones in ascending record order.

### B.11 No route

If A* finds no corridor, run A* again from the same s, g, S and G with these changes:

- every triangle is allowed;
- blocked triangles get `f = 50.0`, and passable ones keep their B.5 factor;
- the extra entry penalty of +100000 m applies when entering a blocked triangle from a passable one.

The result is `{ok: false, error: "NO_ROUTE", reason, blocked, hints}`:

- **blocked.** Each maximal run of consecutive blocked triangles along the relaxed corridor, in order. Each entry is: `corridor_index`, `triangle` (the run's first triangle), `reason` (its B.3 reason name), `lon/lat` (its centroid: `floor((x_a+x_b+x_c)/3)`, same for y, then /1e7), `depth_dm`, `maint_dm`, `clearance_dm`, the overhead name and the area name. The **best blocked location** shown to the user is `blocked[0]`: the first place along the cheapest almost-route where the boat cannot go.
- **reason.** `blocked[0].reason`, or `NOT_CONNECTED` if even the relaxed search fails, meaning the start and goal are in disconnected water. `blocked` is then empty.
- **hints.** An object with one key for each option among `use_maintained` and `accept_unknown_clearance` that is currently false (an option already on has no key). The value is true if the B.7 search, from the same s, g, S and G, finds a corridor with that option alone switched on. This uses the B.3 rules for the changed profile, and is false if s or g is not passable under it. For `NOT_CONNECTED` every present key is false, without searching (no option can connect disconnected water). For example, "this route exists if you trust maintained channels". The app should offer the option rather than silently applying it.
- Each `blocked` entry has exactly the keys `corridor_index`, `triangle`, `reason`, `lon`, `lat`, `depth_dm` (ATTR), `maint_dm` (ATTR), `clearance_dm` (ATTR), `overhead` (the **name** string of OVHD[ATTR.overhead], `""` if 0xFFFF or unnamed) and `area` (the name of AREA[ATTR.area], `""` if 0xFFFF).

### B.12 Route summary

From the corridor (all positions) and the legs. Every field comes from the source named here.

- `distance_m`: the sum of `length_m` over the legs, added in leg order starting from 0.0 (0.0 when there are no legs). `distance_nm = distance_m / 1852`.
- `legs`, `green_legs`, `yellow_legs`: counts of legs.
- `shallowest`: the first corridor triangle with the minimum ATTR `depth_dm`: `{depth_dm, triangle, lon, lat, maintained}`, where lon/lat is its centroid (B.11) in degrees and `maintained` is via_maint. This is the **charted** depth even where maintained depth was used.
- `lowest_clearance`: among corridor triangles with ATTR `clearance_dm < 0xFFFE`, the first with the minimum value: `{clearance_dm, overhead, name, opening}`, where `overhead` is the triangle's ATTR overhead index (0xFFFF possible), `name` the name of that OVHD record (`""` if 0xFFFF) and `opening` the triangle's ATTR flag OPENING_BRIDGE (not the record's flag). null if there is none.
- `openings`: bridges that must open. Each maximal run of consecutive needs_opening corridor triangles gives one entry, from the run's first triangle: `{corridor_index, overhead, clearance_dm, name, lon, lat}` with `overhead` and `clearance_dm` from its ATTR, `name` as above and lon/lat its centroid.
- `unknown_clearances`: the same for runs of unknown_used.
- `maintained_triangles`: the number of corridor triangles with via_maint.
- `data_date`: from the header.

### B.13 Result object

Every result has `ok` and `data_date` (header). The reference implementation also echoes the `profile`; it is informative.

**Success:** `{ok: true, req_dm, air_dm, start, goal, corridor, waypoints_units, waypoints, legs, summary, data_date}`.

- `start`, `goal`: `{x, y, lon, lat, triangle, snap_m, in_mesh}`. x, y is the snapped point in units and lon, lat the same in degrees (`units/1e7`). `snap_m` is reported rounded to 0.001 m (`round(d, 3)`, half-even; compare within 1e-3). `in_mesh` is false when step 3 of B.6 located no triangle.
- `corridor`: triangle ids from s to g. `waypoints_units`: the B.8 points; `waypoints` the same in degrees.
- `legs[j]`: `{from, to, triangles: [lo, hi], length_m, grade, reasons, min_depth_dm, min_spare_dm, crossings}` (B.8–B.10).
- **Start equal to goal.** If the snapped start and goal are the same point, the funnel returns one waypoint, so `legs` is empty, `distance_m` is 0, and `corridor` is whatever B.7 returns (`[s]` when s == g).

**Failure:** `{ok: false, error, ...}`. The error, in the order the checks happen, and its other keys:

| error | when | other keys |
|---|---|---|
| `INVALID_REQUEST` | B.2 valid-profile rule fails | none (no req_dm or air_dm) |
| `START_OUTSIDE_PACK`, `START_NO_WATER_NEARBY` | B.6 on the start | `req_dm`, `air_dm`, `start: {error: "OUTSIDE_PACK"}` or `start: {error: "NO_WATER_NEARBY", located, nearest_m?}` (`located`: the impassable located triangle or null; `nearest_m`: only when a passable candidate existed but was farther than max_snap_m) |
| `GOAL_OUTSIDE_PACK`, `GOAL_NO_WATER_NEARBY` | B.6 on the goal | `req_dm`, `air_dm`, `start` (the snapped start object), `goal` as above |
| `NO_ROUTE` | B.7 finds no corridor | `req_dm`, `air_dm`, `start`, `goal`, `reason`, `blocked`, `hints` (B.11) |
| `LEG_VALIDATION` | B.10 finds a violation | `req_dm`, `air_dm`, `start`, `goal`, `corridor`, `violations` (B.10 item 6) |

An implementation may add its own failures outside this list (RoutingKit: cancelled, timed out); they are not part of the vectors.

---

## Part C. How the builder produces the values

Builder: `python -m enc_routing build --region pilot`, with defaults from `enc_routing.config.BuildParams`.

**C.1 Cells and merge.** The NOAA ENC catalog selects the active cells covering the region. Each cell is downloaded and read with GDAL (updates applied), and the result is cached per edition and update. Every location is served by exactly one cell: the best band, then the largest scale, then the newest issue date. Hairline slivers between harbour cells are closed (see the Wave 1 report).

**C.2 Navigable water and the safety clearance.**

- **Water** is the union of DEPARE and DRGARE with DRVAL1 ≥ 0, closed by 5 m.
- **Obstacles** are LNDARE, SLCONS (except fenders), PONTON, HULKES, FLODOC, DRYDOC, DAMCON, GATCON, DYKCON, PILPNT, UNSARE, causeways minus bridge footprints, and every hazard that blocks every boat: VALSOU unknown or ≤ 0.
- **Clearances.**
  - Obstacles are buffered by `clearance + 2·s`, with clearance = 12 m and s = 1 m.
  - **Near bridges** (within 60 m of any BRIDGE object touching water), obstacles are buffered by `4 m + 2·s` instead. Bascule and swing openings are 25–40 m wide between land, piers and fenders, so 12 m on each side would close them. In the pilot that closed Cortez, Blackburn Point and Manatee River.
  - Bridge fenders (SLCONS CATSLC 14) are buffered by `3 m + 2·s` everywhere.
  - The union is simplified with Douglas–Peucker tolerance s. That moves its boundary by at most s, so every point of the domain is at least the applicable clearance from the raw obstacle: 12 m, or 4 m near bridges, or 3 m from fenders. The 2·s allowance absorbs the simplification, and the remaining 1 m covers rounding.
- **Water parts under 200 m²** are dropped.
- **Exactness.** Depth-area boundaries are never simplified. All constraint lines are snap-rounded to the 1e-7° grid (≈1 cm).

**C.3 Depth (depth_dm).**

1. The **depth-area least depth** is the minimum DRVAL1 over all depth areas within 3 cm of the triangle's face sample point. If none is found (a healed sliver), it is the minimum over depth areas within 50 m.
2. The **sounding raise** (C.4) may then replace it.
3. The **lowering** gives the minimum of:
   - that value;
   - the DEPTH of any sounding within 12 m of the triangle;
   - the VALSOU of any known-depth hazard within 12.1 m.

Soundings are applied through octagons that circumscribe the 12 m disk, and hazards through 12.1 m buffers (polygon chords lie inside the circle, so +0.1 m). `band_depth_dm` is the same computation without step 2.

**C.4 Sounding refinement rule (exact).** Raising requires clear supporting evidence; lowering requires only proximity.

- Build a Delaunay triangulation (TIN) of all soundings (SOUNDG, split points, metric, truncated to dm). A TIN triangle τ **supports** depth area A if **all** of these hold:
  1. A is a DEPARE (not DRGARE) with a finite band, `0 ≤ DRVAL1 < DRVAL2`;
  2. all three soundings of τ lie inside A;
  3. τ lies entirely inside A;
  4. its longest edge is at most `min(0.02 · compilation scale of A, 400 m)`, which is 240 m at 1:12,000 and 400 m at 1:20,000 and smaller scales.
- The supported depth of τ is `min(DRVAL2, min of its three sounding depths)`. τ is kept if that exceeds DRVAL1.
- A mesh face whose sample point is inside a kept τ, and which touches only depth area A, gets `depth = supported depth` and flag SOUNDING_REFINED.
- Because τ is a Delaunay triangle, no other sounding lies inside it.
- The value is capped at DRVAL2. A sounding deeper than its own contour band is treated as inconsistent with the contour, and the contour wins.
- Lowering (C.3 step 3) then applies on top. Any shallower sounding within 12 m pulls the value back down.

The router grades a leg that relies on a raised depth yellow (SOUNDING_DEPTH, B.9). The depth is real charted evidence, but between soundings it is inferred.

**C.5 Maintained depth.** The USACE National Channel Framework ChannelReach layer gives `depthmaintained` in feet, converted with `floor(ft·3.048)`. Reach polygons sit 1–30 m off the ENC channel, so they are grown by 15 m. Where reaches overlap, the minimum applies. Only reaches with a maintained depth > 0 count.

**C.6 Overhead.** BRIDGE, CBLOHD and PIPOHD objects that touch water are included.

- **Footprint.**
  - Polygons are used as charted, with no buffer, so adjacent bridge parts do not overlap.
  - Lines are buffered by 5 m, so a footprint contains its line with a 5 m margin, including around the line's ends and around the joint between two parts of one bridge. B.10 relies on this: a leg in passable water never touches the line of an object too low for the boat.
- **Clearance.**
  - An opening span (CATBRG 2, 3, 4, 5, 7 or 8) uses VERCCL, or VERCLR if VERCCL is missing.
  - Other objects use VERCLR, or VERCSA for cables.
  - A bridge part with neither clearance counts as solid (0). In practice this is a fixed approach span next to the charted navigation span.
- **Duplicates.** Duplicate cable geometries are dropped.
- **Bounding box.** The header bbox is the region box grown to include every vertex and every GEOM point (A.3).

**C.7 Regulated areas.** RESARE and CTNARE map to kinds as follows:

| kind | flag | source |
|---|---|---|
| prohibited | PROHIBITED | RESTRN contains 7 (entry prohibited) |
| restricted | RESTRICTED | RESTRN contains 8 (entry restricted) or 14 (area to be avoided); or CATREA 1 (safety zone), 9 (military area) or 14 (minefield) |
| caution | CAUTION | every CTNARE; RESARE with CATREA 4, 5, 22, 23, 24, 27 or 28 (reserves, no-wake, sensitive sea areas); RESTRN 13 (no wake) or 27 (speed restricted) |

Other RESAREs (for example anchoring prohibited) are ignored for routing. Membership uses any overlap with the 3 cm sample disk, so it is conservative.

**C.8 Channels and highway.**

- **CHANNEL** means inside any of: an NCF reach (grown by 15 m), an ENC FAIRWY, an ENC DRGARE, or RECTRC/NAVLNE buffered by 15 m.
- **HIGHWAY** means within 30 m of an NCF centreline or of an ENC RECTRC named Intracoastal Waterway.
- The **channel id** is the containing channel with the best source: NCF first, then DRGARE, FAIRWY, track; the lowest index wins ties.

**C.9 Quality.** Each triangle takes the worst CATZOC and the oldest SUREND year of the M_QUAL polygons containing its sample point. The M_QUAL polygons are simplified by 5 m.

**C.10 Mesh.**

- All constraint lines are transformed to 1e-7° units and snap-rounded together (GEOS OverlayNG, grid 1). The constraint lines are the boundaries of all of the above, the shore rings (50 m and 150 m, simplified by 5 m), the 30 m hazard proximity ring, the open-Gulf mask, and a 0.02° grid that bounds triangle size.
- The lines are polygonized. Faces inside the domain are triangulated with GEOS's constrained Delaunay triangulation, which adds no Steiner points.
- A face's attributes are sampled at the incentre of its fattest triangle.
- Repairs run in exact integer arithmetic: flat triangles are removed by splitting the triangle across them, and T-junctions are split. The A.9 checks plus the exact area equality must pass, or the build fails.

**C.11 Open Gulf.** The pilot sets OUTSIDE from a mask. The mask is the region box minus land closed by 1.5 km (which seals the passes) and a line across the Tampa Bay mouth, keeping the part connected to an offshore seed point. Other regions need their own seed and barrier lines (`places.GULF_MASK`).

---

## Part D. Test vector files (`testdata/routing/`)

| file | content |
|---|---|
| `synthetic.pack` | hand-checkable 62-triangle pack with ADJC (layout in `enc_routing/synth.py` and below) |
| `synthetic.records.json` | decoded header, section table and sample records of every section |
| `synthetic.vectors.json` | queries and exact expected results |
| `sarasota.pack` | real cut of the pilot pack (Sarasota Bay to Roberts Bay), **without** ADJC, so it exercises derived adjacency |
| `sarasota.records.json`, `sarasota.vectors.json` | as above |
| `sarasota.obstacles.wkb.gz` | raw land, structures and blocking hazards (WKB, EPSG:4326 degrees) clipped to the cut, for the "no route touches land" regression test |
| `sarasota.bridge_zone.wkb.gz` | the 60 m bridge zones (C.2) where the reduced 4 m clearance applies, for the same test |

The regression test (`pipeline/routing/tests/test_regression.py`, ported to RoutingKit as `ObstacleRegressionTests`) routes every successful Sarasota query forwards and reversed, maps the waypoints to an equirectangular frame about 27.35° N, and requires that the route does not touch any obstacle, stays ≥ 3.5 m from them everywhere and ≥ 11.5 m outside the bridge zones (the 4 m and 12 m clearances less 0.5 m for rounding and the metric).

**Synthetic layout.** The pack is an 8 × 4 grid of 0.001° squares with the SW corner at (−82.000, 27.000). Each square is split along its SW–NE diagonal. Columns run west to east (0..7) and rows run south to north (0..3).

| row | contents |
|---|---|
| 0 | 6 dm, CATZOC D 1950, shore class 0. Column 1 is a caution area (AREA 2). Column 2 is missing (an island). |
| 1 | the channel: 36 dm, maintained 27, CHANNEL+HIGHWAY, channel 0. Column 3 is shoaled to 9 dm. Column 5 is an opening bridge with closed clearance 18 dm (OVHD 0). |
| 2 | 21 dm. Column 2 has a cable of unknown clearance (OVHD 2). Column 4 is a known-depth wreck zone at 15 dm (HAZD 0, HAZARD_DEPTH), with an overhead point object of 50 m clearance (OVHD 3, referenced by no triangle) 4 units north of the row 1/row 2 boundary at column 4.5. Column 5 is a fixed bridge at 30 dm (OVHD 1). Column 6 is restricted (AREA 1). Column 7 has band 9 dm refined to 21 dm (SOUNDING_REFINED). |
| 3 | 60 dm, with the cable at column 2, the fixed bridge at column 5, and a prohibited area at column 6 (AREA 0). |

Everything else is CATZOC A2, 2010, shore class 3.

Overhead lines (all N–S): OVHD 0 (opening span) from row 1's southern edge to row 2's southern edge at column 5.5; OVHD 1 (fixed bridge) from 0.0001° (11 m) north of row 2's southern edge to the top of the pack at column 5.5; OVHD 2 (cable) from row 2's southern edge to the top at column 2.5. The fixed bridge line starts inside its own footprint, as C.6 guarantees for real packs; a leg along the row 1/row 2 boundary therefore touches the ends of the opening-span and cable lines without passing under them (B.10 item 4).

**`*.records.json`**

```
{ file, sha256,
  header:   every header field by name (A.3), plus header_crc32,
  sections: [{name, encoding, offset, stored_length, raw_length, crc32, count}],
  info:     {key: value},
  strings:  {count, first: {id: string}},
  vertices: [{index, lon, lat}],                          // units
  triangles:[{index, v:[a,b,c], nbr:[n0,n1,n2], depth_dm, band_depth_dm, maint_dm,
              clearance_dm, flags, channel, overhead, area, quality}],
  grid:     {origin_lon, origin_lat, cell, nx, ny, total_ids, cells:[{cell, ids:[...]}]},
  sources|overhead|hazards|channels|areas: [{index, <every non-padding field by its A.5 name>, geom?:[[lon,lat],...]}] }
```

**`*.vectors.json`**

```
{ schema: "routing-vectors/1", pack, pack_sha256,
  tolerances: {waypoints_units: 0, distance_m: 1e-6, snap_m: 1e-3},
  queries: [ { id, note?, start:[lon,lat], goal:[lon,lat],
               profile:{draft_ft, margin_ft, air_draft_ft, use_maintained?, accept_unknown_clearance?, avoid_open_gulf?},
               max_snap_m,
               expected: <the B.13 result object without profile, plus distance_m for a success> } ] }
```

All integers (triangle ids, corridor, waypoints_units, dm values, reasons, grades) must match exactly. Floating-point fields must match within the stated tolerances. `legs[].from/to` and `waypoints` are `units/1e7` and are informative; compare `waypoints_units`.

`expected` holds exactly the B.13 keys of that result: for example `violations` only for `LEG_VALIDATION`, `hints` for every `NO_ROUTE`, and no `req_dm` for `INVALID_REQUEST`. The queries cover every result kind except `LEG_VALIDATION` (a consistent pack produces none; the B.10 rules are covered by unit tests in both implementations) and every input rule of B.2 and B.6 that can be written in JSON (non-finite inputs are covered by unit tests).

**Properties checked by both implementations** (`tests/test_rules.py`, RoutingKit `PropertyTests`): over every ordered pair of the 32 square centres of the synthetic pack and six profiles, the outcome class (route / no route / leg-validation failure) is the same in both directions and no leg fails validation; every snapped point lies in its triangle; and no leg of any route enters the interior of an impassable triangle (RoutingKit, exact).

*Informative: the Python reference reproduces every vector from the pack file alone (`pytest pipeline/routing -k vectors`).*

---

## Changes from 1.0

Found by the independent Swift port (RoutingKit), which reproduced the 1.0 reference exactly, defects included. Each is fixed in this document, the Python reference and RoutingKit together.

| # | 1.0 | 1.1 |
|---|---|---|
| 1 | B.6: the snapped point was rounded to whole units and could lie a unit outside its triangle, inside an impassable neighbour (Sarasota q3). | The rounded point is kept only if the triangle contains it; otherwise the nearest contained point among its 8 neighbours and the triangle's vertices. `snap_m` is the distance of the final point. |
| 2 | B.10: touching an overhead polyline counted as passing under it, so a leg along a footprint edge failed validation, in one direction only (588 of 11,904 synthetic queries). | Exact integer rule: proper crossing, collinear overlap, a leg endpoint on the line, or a crossing through a vertex where the arms of all lines meeting there lie on both sides. Touches do not count. The synthetic fixed-bridge line was moved inside its footprint (C.6). |
| 3 | B.10: overhead candidates used the unexpanded leg bbox, missing a point object within 1 m. | The overhead prefilter is grown by 2 m. |
| 4 | B.10 ring test: parameters and `<`/`≤` unstated. | Written out (item 4, ring). |
| 5–7 | NOT_CONNECTED hints, error shapes and summary sources were only in the reference code. | B.11, B.12, B.13. NOT_CONNECTED now always has `hints` (all false). |
| 8 | A.8 claimed exactness for any i32 input. | Bbox span ≤ 2^30 and every GEOM point inside the bbox; the bound is stated. |
| 9 | A.4 listed six checks; the section table had no checksum and padding was unchecked. | `table_crc32` at header offset 108, exact layout with zero padding, and the full check list. Every single-bit corruption is now detected. 1.0 files are still accepted. |
| 10 | Non-finite or out-of-range coordinates, invalid boat dimensions and start = goal were unspecified (the reference crashed on NaN). | B.2 `INVALID_REQUEST`, B.6 step 1, B.13. |
