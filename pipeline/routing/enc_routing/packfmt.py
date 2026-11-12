"""Routing pack binary format, version 1.1: writer and reader.

The authoritative description is docs/routing-pack-format.md (part A). This
module depends only on numpy, zlib and struct, and the reader touches nothing
but the pack file. The reader performs every check of spec A.4, in order, and
raises PackError for any failure. It also accepts version 1.0 files (no
section-table checksum).
"""
from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass, field

import numpy as np

MAGIC = b"GCRTPACK"
FORMAT_MAJOR = 1
FORMAT_MINOR = 1
HEADER_SIZE = 256
ENTRY_SIZE = 32
TABLE_CRC_OFFSET = 108       # u32 CRC-32 of the section table (format 1.1; reserved 0 in 1.0)
MAX_SECTIONS = 4096
MAX_SPAN_UNITS = 1 << 30     # bbox span limit that keeps every A.8 orientation exact in Int64
GEOM_TYPES = (1, 2, 3)       # point, polyline, polygon ring

# sentinels
DEPTH_NONE = -32768          # i16: no value
CLR_NONE = 0xFFFF            # u16: no overhead object
CLR_UNKNOWN = 0xFFFE         # u16: overhead object(s) of unknown clearance only
ID_NONE = 0xFFFF             # u16 side-table reference: none

# triangle flags (u16)
F_CHANNEL = 1 << 0
F_HIGHWAY = 1 << 1
F_OPENING = 1 << 2
F_UNKNOWN_CLR = 1 << 3
F_RESTRICTED = 1 << 4
F_CAUTION = 1 << 5
F_NEAR_HAZARD = 1 << 6
F_HAZARD_DEPTH = 1 << 7
F_PROHIBITED = 1 << 8
F_OUTSIDE = 1 << 9
F_REFINED = 1 << 10
SHORE_SHIFT = 11              # bits 11-12: shore class 0..3
SHORE_MASK = 3 << SHORE_SHIFT

FLAG_NAMES = {F_CHANNEL: "CHANNEL", F_HIGHWAY: "HIGHWAY", F_OPENING: "OPENING_BRIDGE",
              F_UNKNOWN_CLR: "UNKNOWN_CLEARANCE", F_RESTRICTED: "RESTRICTED", F_CAUTION: "CAUTION",
              F_NEAR_HAZARD: "NEAR_HAZARD", F_HAZARD_DEPTH: "HAZARD_DEPTH",
              F_PROHIBITED: "PROHIBITED", F_OUTSIDE: "OUTSIDE", F_REFINED: "SOUNDING_REFINED"}

SECTION_ORDER = ["INFO", "STRS", "SRCS", "VERT", "TRIS", "ADJC", "ATTR", "GRID",
                 "OVHD", "HAZD", "CHAN", "AREA", "GEOM"]

ATTR_COLUMNS = [  # (name, numpy dtype) in storage order
    ("depth_dm", "<i2"), ("band_depth_dm", "<i2"), ("maint_dm", "<i2"), ("clearance_dm", "<u2"),
    ("flags", "<u2"), ("channel", "<u2"), ("overhead", "<u2"), ("area", "<u2"), ("quality", "u1"),
]

OVHD_DT = np.dtype([("kind", "u1"), ("flags", "u1"), ("catbrg", "<u2"), ("clearance_dm", "<u2"),
                    ("open_clearance_dm", "<u2"), ("hor_clearance_dm", "<u2"), ("reserved", "<u2"),
                    ("name", "<u4"), ("lon", "<i4"), ("lat", "<i4"), ("geom_first", "<u4"),
                    ("geom_count", "<u4"), ("geom_type", "u1"), ("pad", "u1", (7,))])
HAZD_DT = np.dtype([("cls", "u1"), ("watlev", "u1"), ("category", "u1"), ("geom_type", "u1"),
                    ("valsou_dm", "<i2"), ("reserved", "<u2"), ("lon", "<i4"), ("lat", "<i4"),
                    ("geom_first", "<u4"), ("geom_count", "<u4"), ("name", "<u4"), ("reserved2", "<u4")])
CHAN_DT = np.dtype([("source", "u1"), ("flags", "u1"), ("maint_dm", "<i2"), ("auth_dm", "<i2"),
                    ("reserved", "<u2"), ("name", "<u4"), ("ident", "<u4"), ("desc", "<u4"),
                    ("date", "<u4"), ("lon", "<i4"), ("lat", "<i4")])
AREA_DT = np.dtype([("kind", "u1"), ("source", "u1"), ("reserved", "<u2"), ("name", "<u4"),
                    ("text", "<u4"), ("lon", "<i4"), ("lat", "<i4"), ("reserved2", "<u4", (3,))])
SRCS_DT = np.dtype([("name", "<u4"), ("edition", "<u2"), ("update", "<u2"), ("issue_date", "<u4"),
                    ("cscale", "<u4"), ("band", "u1"), ("used", "u1"), ("pad", "u1", (6,))])
assert OVHD_DT.itemsize == 40 and HAZD_DT.itemsize == 32 and CHAN_DT.itemsize == 32
assert AREA_DT.itemsize == 32 and SRCS_DT.itemsize == 24

HEADER_FMT = "<8sHHIIIII32s4iIIIIIHHHH"  # see write_header; padded to 252 + crc


# --------------------------------------------------------------------------- varints

def zigzag(a: np.ndarray) -> np.ndarray:
    a = np.asarray(a, dtype=np.int64)
    return ((a << 1) ^ (a >> 63)).astype(np.uint64)


def unzigzag(u: np.ndarray) -> np.ndarray:
    u = np.asarray(u, dtype=np.uint64)
    return ((u >> np.uint64(1)).astype(np.int64)) ^ (-(u & np.uint64(1)).astype(np.int64))


def uvarint_encode(vals) -> bytes:
    """Unsigned LEB128, vectorised: 7 bits per byte, low group first,
    high bit set on every byte except the last."""
    v = np.asarray(vals, dtype=np.uint64).ravel()
    if len(v) == 0:
        return b""
    nbytes = np.ones(len(v), dtype=np.int64)
    for k in range(1, 10):
        nbytes += (v >= (np.uint64(1) << np.uint64(7 * k))).astype(np.int64)
    out = np.zeros(int(nbytes.sum()), dtype=np.uint8)
    start = np.concatenate([[0], np.cumsum(nbytes)[:-1]])
    for k in range(10):
        m = nbytes > k
        if not m.any():
            break
        byte = ((v[m] >> np.uint64(7 * k)) & np.uint64(0x7F)).astype(np.uint8)
        cont = (nbytes[m] > k + 1).astype(np.uint8) << 7
        out[start[m] + k] = byte | cont
    return out.tobytes()


def uvarint_decode(buf: bytes, count: int | None = None, offset: int = 0):
    """Decode unsigned LEB128 values. Returns (np.uint64 array, end offset).
    With count=None decodes to the end of buf."""
    b = np.frombuffer(buf, dtype=np.uint8, offset=offset)
    ends = np.flatnonzero(b < 0x80)
    if count is not None:
        if len(ends) < count:
            raise ValueError("truncated varint stream")
        ends = ends[:count]
    n = len(ends)
    if n == 0:
        return np.zeros(0, np.uint64), offset
    starts = np.concatenate([[0], ends[:-1] + 1])
    lens = ends - starts + 1
    if lens.max() > 10:
        raise ValueError("varint longer than 10 bytes")
    vals = np.zeros(n, dtype=np.uint64)
    for k in range(int(lens.max())):
        m = lens > k
        vals[m] |= (b[starts[m] + k].astype(np.uint64) & np.uint64(0x7F)) << np.uint64(7 * k)
    return vals, offset + int(ends[-1]) + 1


# --------------------------------------------------------------------------- data model

@dataclass
class Pack:
    region_id: str
    bbox: tuple                     # i32 units (min_lon, min_lat, max_lon, max_lat)
    data_date: int
    build_date: int
    build_time: int
    clearance_dm: int
    check_dm: int                   # leg-validation hazard radius
    shore_rings_m: tuple            # (ring0, ring1) metres, 0 = unused
    vertices: np.ndarray            # (V,2) int32 lon, lat in 1e-7 deg
    tris: np.ndarray                # (T,3) int32, CCW
    attrs: dict                     # column name -> array (T,)
    strings: list                   # string table; [0] == ""
    overhead: np.ndarray            # OVHD_DT records
    hazards: np.ndarray             # HAZD_DT
    channels: np.ndarray            # CHAN_DT
    areas: np.ndarray               # AREA_DT
    sources: np.ndarray             # SRCS_DT
    geom: np.ndarray                # (G,2) int32 coordinate pool
    info: dict = field(default_factory=dict)
    nbr: np.ndarray | None = None   # (T,3) int32, -1 = boundary
    grid: dict | None = None        # origin_lon, origin_lat, cell, nx, ny, offsets, ids
    sections: list | None = None    # filled by the reader: section table entries

    def string(self, sid: int) -> str:
        return self.strings[sid] if 0 <= sid < len(self.strings) else ""


# --------------------------------------------------------------------------- canonical order

def hilbert_index(x: np.ndarray, y: np.ndarray, order: int = 16) -> np.ndarray:
    """Hilbert curve index of integer coordinates in [0, 2**order)."""
    x = x.astype(np.int64).copy()
    y = y.astype(np.int64).copy()
    d = np.zeros(len(x), dtype=np.int64)
    s = 1 << (order - 1)
    while s > 0:
        rx = ((x & s) > 0).astype(np.int64)
        ry = ((y & s) > 0).astype(np.int64)
        d += s * s * ((3 * rx) ^ ry)
        # rotate
        m = ry == 0
        flip = m & (rx == 1)
        x[flip] = s - 1 - x[flip]
        y[flip] = s - 1 - y[flip]
        xt = x[m].copy()
        x[m] = y[m]
        y[m] = xt
        s >>= 1
    return d


def canonicalize(vertices, tris, attrs_tri_order=None):
    """Reorder vertices along a Hilbert curve; rotate each triangle so its
    smallest vertex index comes first (keeping CCW order); sort triangles by
    (v0, v1, v2). Returns (vertices, tris, triangle permutation old->new order
    as an index array `perm` such that new_tris = old_tris[perm])."""
    v = np.asarray(vertices, dtype=np.int64)
    lo = v.min(axis=0)
    span = max(int((v.max(axis=0) - lo).max()), 1)
    shift = max(0, span.bit_length() - 16)
    q = (v - lo) >> shift
    h = hilbert_index(q[:, 0], q[:, 1])
    vorder = np.lexsort((v[:, 1], v[:, 0], h))
    inv = np.empty(len(v), dtype=np.int64)
    inv[vorder] = np.arange(len(v))
    t = inv[np.asarray(tris, dtype=np.int64)]
    r = np.argmin(t, axis=1)
    idx = (r[:, None] + np.arange(3)[None, :]) % 3
    t = np.take_along_axis(t, idx, axis=1)
    perm = np.lexsort((t[:, 2], t[:, 1], t[:, 0]))
    return v[vorder].astype(np.int32), t[perm].astype(np.int32), perm


def adjacency(tris: np.ndarray):
    """nbr[t,k] = triangle sharing the edge (v[k], v[(k+1)%3]) traversed in
    the opposite direction, -1 if none. Returns (nbr, problems) where
    problems counts directed edges that occur more than once."""
    T = len(tris)
    a = tris.astype(np.int64)
    src = a.reshape(-1)
    dst = a[:, [1, 2, 0]].reshape(-1)
    nv = int(a.max()) + 1 if T else 1
    key = src * nv + dst
    rkey = dst * nv + src
    order = np.argsort(key, kind="stable")
    sk = key[order]
    dup = int((sk[1:] == sk[:-1]).sum())
    pos = np.searchsorted(sk, rkey)
    pos = np.clip(pos, 0, len(sk) - 1)
    found = sk[pos] == rkey
    nbr = np.where(found, order[pos] // 3, -1).astype(np.int32)
    return nbr.reshape(T, 3), dup


def build_grid(vertices, tris, bbox, cell: int):
    """Point-location grid: every triangle is listed in every cell its
    integer bounding box intersects (cells are closed rectangles)."""
    ox, oy = int(bbox[0]), int(bbox[1])
    nx = max(1, -(-(int(bbox[2]) - ox) // cell))
    ny = max(1, -(-(int(bbox[3]) - oy) // cell))
    p = vertices[tris].astype(np.int64)  # (T,3,2)
    x0, x1 = p[:, :, 0].min(1), p[:, :, 0].max(1)
    y0, y1 = p[:, :, 1].min(1), p[:, :, 1].max(1)

    def rng(lo, hi, o, n):
        a = np.clip((lo - o) // cell, 0, n - 1)
        # a closed cell [o+j*c, o+(j+1)*c] also contains its upper edge
        b = np.clip((hi - o) // cell, 0, n - 1)
        a = np.where((lo - o) % cell == 0, np.clip((lo - o) // cell - 1, 0, n - 1), a)
        return a, b
    ja, jb = rng(x0, x1, ox, nx)
    ia, ib = rng(y0, y1, oy, ny)
    cells, ids = [], []
    T = len(tris)
    cnt = (jb - ja + 1) * (ib - ia + 1)
    tid = np.repeat(np.arange(T), cnt)
    # enumerate cells per triangle
    off = np.concatenate([[0], np.cumsum(cnt)[:-1]])
    k = np.arange(int(cnt.sum())) - np.repeat(off, cnt)
    w = np.repeat(jb - ja + 1, cnt)
    jj = np.repeat(ja, cnt) + k % w
    ii = np.repeat(ia, cnt) + k // w
    c = ii * nx + jj
    order = np.lexsort((tid, c))
    c, tid = c[order], tid[order]
    counts = np.bincount(c, minlength=nx * ny)
    offsets = np.concatenate([[0], np.cumsum(counts)]).astype(np.int64)
    return {"origin_lon": ox, "origin_lat": oy, "cell": cell, "nx": int(nx), "ny": int(ny),
            "offsets": offsets, "ids": tid.astype(np.int32)}


# --------------------------------------------------------------------------- encode

def _enc_vertices(v, bbox) -> bytes:
    d = np.diff(np.vstack([[bbox[0], bbox[1]], v]).astype(np.int64), axis=0)
    return uvarint_encode(zigzag(d.reshape(-1)))


def _enc_tris(t) -> bytes:
    t = t.astype(np.int64)
    d0 = np.diff(np.concatenate([[0], t[:, 0]]))
    vals = np.stack([d0, t[:, 1] - t[:, 0], t[:, 2] - t[:, 0]], 1)
    return uvarint_encode(vals.reshape(-1))


def _enc_adj(nbr) -> bytes:
    T = len(nbr)
    d = np.where(nbr < 0, 0, nbr.astype(np.int64) - np.arange(T)[:, None])
    return uvarint_encode(zigzag(d.reshape(-1)))


def _enc_grid(g) -> bytes:
    head = struct.pack("<iiiII", g["origin_lon"], g["origin_lat"], g["cell"], g["nx"], g["ny"])
    offs, ids = g["offsets"], g["ids"].astype(np.int64)
    counts = np.diff(offs)
    # per cell: count, then first id, then deltas
    vals = []
    deltas = np.diff(np.concatenate([[0], ids]))
    first = np.zeros(len(ids), bool)
    first[offs[:-1][counts > 0]] = True
    deltas = np.where(first, ids, deltas)
    # interleave counts before each cell's ids
    n_cells = len(counts)
    pos_count = offs[:-1] + np.arange(n_cells)
    total = len(ids) + n_cells
    seq = np.zeros(total, dtype=np.uint64)
    seq[pos_count] = counts
    mask = np.ones(total, bool)
    mask[pos_count] = False
    seq[mask] = deltas
    del vals
    return head + uvarint_encode(seq)


def _enc_strings(strings) -> bytes:
    blobs = [s.encode("utf-8") for s in strings]
    offs = np.concatenate([[0], np.cumsum([len(b) for b in blobs])]).astype("<u4")
    return struct.pack("<I", len(blobs)) + offs.tobytes() + b"".join(blobs)


def _enc_info(info: dict) -> bytes:
    lines = []
    for k, v in info.items():
        v = str(v).replace("\n", " ")
        lines.append(f"{k}={v}\n")
    return "".join(lines).encode("utf-8")


def _enc_attrs(attrs, T) -> bytes:
    out = []
    for name, dt in ATTR_COLUMNS:
        a = np.asarray(attrs[name])
        assert len(a) == T, name
        out.append(a.astype(dt).tobytes())
    return b"".join(out)


def write_pack(pack: Pack, path, with_adjacency: bool = True, level: int = 9) -> dict:
    """Write `pack` (vertices/tris must already be canonical) to path.
    Returns {section: (stored_bytes, raw_bytes)}."""
    T, V = len(pack.tris), len(pack.vertices)
    if pack.nbr is None:
        pack.nbr, dup = adjacency(pack.tris)
        assert dup == 0
    sec = {
        "INFO": (_enc_info(pack.info), 0),
        "STRS": (_enc_strings(pack.strings), len(pack.strings)),
        "SRCS": (pack.sources.tobytes(), len(pack.sources)),
        "VERT": (_enc_vertices(pack.vertices, pack.bbox), V),
        "TRIS": (_enc_tris(pack.tris), T),
        "ADJC": (_enc_adj(pack.nbr), T) if with_adjacency else None,
        "ATTR": (_enc_attrs(pack.attrs, T), T),
        "GRID": (_enc_grid(pack.grid), pack.grid["nx"] * pack.grid["ny"]),
        "OVHD": (pack.overhead.tobytes(), len(pack.overhead)),
        "HAZD": (pack.hazards.tobytes(), len(pack.hazards)),
        "CHAN": (pack.channels.tobytes(), len(pack.channels)),
        "AREA": (pack.areas.tobytes(), len(pack.areas)),
        "GEOM": (pack.geom.astype("<i4").tobytes(), len(pack.geom)),
    }
    names = [n for n in SECTION_ORDER if sec.get(n) is not None]
    table_end = HEADER_SIZE + ENTRY_SIZE * len(names)
    offset = (table_end + 7) // 8 * 8
    body, entries, sizes = [], [], {}
    for n in names:
        raw, count = sec[n]
        stored = zlib.compress(raw, level)
        enc = 1
        if len(stored) >= len(raw):
            stored, enc = raw, 0
        crc = zlib.crc32(stored) & 0xFFFFFFFF
        entries.append(struct.pack("<4sIQIIII", n.encode(), enc, offset, len(stored), len(raw), crc, count))
        pad = (-len(stored)) % 8
        body.append(stored + b"\0" * pad)
        sizes[n] = (len(stored), len(raw))
        offset += len(stored) + pad
    file_size = offset
    table = b"".join(entries)
    header = struct.pack(
        "<8sHHIIIII32s4iIIIIIHHHHI",
        MAGIC, FORMAT_MAJOR, FORMAT_MINOR, HEADER_SIZE, file_size, len(names), HEADER_SIZE,
        1 if with_adjacency else 0, pack.region_id.encode("ascii")[:32].ljust(32, b"\0"),
        *[int(b) for b in pack.bbox], pack.data_date, pack.build_date, pack.build_time, V, T,
        pack.clearance_dm, pack.check_dm, int(pack.shore_rings_m[0]), int(pack.shore_rings_m[1]),
        zlib.crc32(table) & 0xFFFFFFFF)
    header = header.ljust(252, b"\0")
    header += struct.pack("<I", zlib.crc32(header) & 0xFFFFFFFF)
    gap = b"\0" * ((table_end + 7) // 8 * 8 - table_end)
    with open(path, "wb") as f:
        f.write(header + table + gap + b"".join(body))
    return sizes


# --------------------------------------------------------------------------- decode

class PackError(ValueError):
    pass


HEADER_FIELDS = ["magic", "major", "minor", "header_size", "file_size", "section_count",
                 "section_table_offset", "flags", "region_id", "min_lon", "min_lat", "max_lon",
                 "max_lat", "data_date", "build_date", "build_time", "vertex_count",
                 "triangle_count", "clearance_dm", "check_dm", "shore_ring0_m", "shore_ring1_m",
                 "table_crc32"]
REQUIRED_SECTIONS = [n for n in SECTION_ORDER if n != "ADJC"]
RECORD_SIZES = {"SRCS": SRCS_DT.itemsize, "OVHD": OVHD_DT.itemsize, "HAZD": HAZD_DT.itemsize,
                "CHAN": CHAN_DT.itemsize, "AREA": AREA_DT.itemsize}


def _align8(n: int) -> int:
    return (n + 7) // 8 * 8


def read_header(buf: bytes) -> dict:
    """Spec A.4 checks 1-5 (magic, major version, header CRC, file size, header fields)."""
    if len(buf) < HEADER_SIZE:
        raise PackError("file shorter than the 256-byte header")
    if buf[:8] != MAGIC:
        raise PackError("not a routing pack (bad magic)")
    major, minor = struct.unpack_from("<HH", buf, 8)
    if major != FORMAT_MAJOR:
        raise PackError(f"unsupported format major version {major}")
    crc = struct.unpack_from("<I", buf, 252)[0]
    if zlib.crc32(buf[:252]) & 0xFFFFFFFF != crc:
        raise PackError("header CRC mismatch")
    f = struct.unpack_from("<8sHHIIIII32s4iIIIIIHHHHI", buf, 0)
    h = dict(zip(HEADER_FIELDS, f))
    h["region_id"] = h["region_id"].split(b"\0", 1)[0].decode("ascii", errors="replace")
    h["header_crc32"] = crc
    if h["file_size"] != len(buf):
        raise PackError("file size mismatch")
    if h["header_size"] != HEADER_SIZE:
        raise PackError(f"header_size {h['header_size']}")
    if h["section_table_offset"] != HEADER_SIZE:
        raise PackError(f"section_table_offset {h['section_table_offset']}")
    n = h["section_count"]
    if not 1 <= n <= MAX_SECTIONS or HEADER_SIZE + ENTRY_SIZE * n > len(buf):
        raise PackError(f"section_count {n}")
    x0, y0, x1, y1 = h["min_lon"], h["min_lat"], h["max_lon"], h["max_lat"]
    if not (-1_800_000_000 <= x0 <= x1 <= 1_800_000_000 and -900_000_000 <= y0 <= y1 <= 900_000_000
            and x1 - x0 <= MAX_SPAN_UNITS and y1 - y0 <= MAX_SPAN_UNITS):
        raise PackError("invalid bounding box")
    V, T = h["vertex_count"], h["triangle_count"]
    if not (3 <= V <= 0x7FFFFFFF and 1 <= T and 3 * T <= 0x7FFFFFFF):
        raise PackError("invalid vertex or triangle count")
    if minor == 0:
        h["table_crc32"] = 0  # reserved in format 1.0
    return h


def read_sections(buf: bytes, h: dict) -> dict:
    """Spec A.4 checks 6-10: table CRC, layout and padding, section CRCs, tags, encodings."""
    n = h["section_count"]
    table_end = HEADER_SIZE + ENTRY_SIZE * n
    table = buf[HEADER_SIZE:table_end]
    if h["minor"] >= 1 and zlib.crc32(table) & 0xFFFFFFFF != h["table_crc32"]:
        raise PackError("section table CRC mismatch")
    entries = [struct.unpack_from("<4sIQIIII", buf, HEADER_SIZE + i * ENTRY_SIZE) for i in range(n)]
    # layout: sections back to back in table order, each at the next multiple of 8; zero padding
    expected, prev_end = _align8(table_end), table_end
    for name, enc, off, slen, rlen, crc, count in entries:
        if off != expected or off + slen > len(buf):
            raise PackError(f"section {name!r}: offset {off} breaks the layout")
        if any(buf[prev_end:off]):
            raise PackError("non-zero padding")
        prev_end = off + slen
        expected = _align8(prev_end)
    if len(buf) != expected or any(buf[prev_end:]):
        raise PackError("file does not end at the padded end of the last section")
    out = {}
    for name, enc, off, slen, rlen, crc, count in entries:
        tag = name.decode("latin-1")
        stored = buf[off:off + slen]
        if zlib.crc32(stored) & 0xFFFFFFFF != crc:
            raise PackError(f"section {tag}: CRC mismatch")
        if tag in out:
            raise PackError(f"duplicate section {tag}")
        out[tag] = {"stored": stored, "count": count, "encoding": enc, "offset": off,
                    "stored_length": slen, "raw_length": rlen, "crc32": crc}
    for tag in REQUIRED_SECTIONS:
        if tag not in out:
            raise PackError(f"missing section {tag}")
    if ("ADJC" in out) != bool(h["flags"] & 1):
        raise PackError("flag bit 0 (ADJC present) disagrees with the section table")
    for tag, e in out.items():
        if tag not in SECTION_ORDER:
            continue  # unknown tags are ignored (layout and CRC are checked above)
        stored = e.pop("stored")
        if e["encoding"] == 0:
            raw = bytes(stored)
        elif e["encoding"] == 1:
            d = zlib.decompressobj()
            try:
                raw = d.decompress(stored)
            except zlib.error as err:
                raise PackError(f"section {tag}: inflate failed ({err})") from None
            if not d.eof or d.unused_data:
                raise PackError(f"section {tag}: not exactly one complete zlib stream")
        else:
            raise PackError(f"section {tag}: unknown encoding {e['encoding']}")
        if len(raw) != e["raw_length"]:
            raise PackError(f"section {tag}: raw length mismatch")
        e["raw"] = raw
    for tag in [t for t in out if t not in SECTION_ORDER]:
        out[tag].pop("stored")
    return out


def _uvarints(raw: bytes, count: int | None, tag: str, offset: int = 0) -> np.ndarray:
    """Every uvarint from `offset` to the end of `raw`: no partial varint at the end, at most
    10 bytes each, no 64-bit overflow, and exactly `count` values unless count is None."""
    b = np.frombuffer(raw, dtype=np.uint8, offset=offset)
    if len(b) and b[-1] >= 0x80:
        raise PackError(f"section {tag}: varint data ends inside a value")
    ends = np.flatnonzero(b < 0x80)
    if count is not None and len(ends) != count:
        raise PackError(f"section {tag}: {len(ends)} varints, expected {count}")
    if len(ends) == 0:
        return np.zeros(0, np.uint64)
    starts = np.concatenate([[0], ends[:-1] + 1])
    lens = ends - starts + 1
    if lens.max() > 10 or (b[ends[lens == 10]] > 1).any():
        raise PackError(f"section {tag}: varint overflows 64 bits")
    vals = np.zeros(len(ends), dtype=np.uint64)
    for k in range(int(lens.max())):
        m = lens > k
        vals[m] |= (b[starts[m] + k].astype(np.uint64) & np.uint64(0x7F)) << np.uint64(7 * k)
    return vals


def _dec_strings(raw, count) -> list:
    if len(raw) < 4:
        raise PackError("section STRS: too short")
    n = struct.unpack_from("<I", raw, 0)[0]
    base = 4 + 4 * (n + 1)
    if n < 1 or n != count or len(raw) < base:
        raise PackError(f"section STRS: string count {n}")
    offs = np.frombuffer(raw, dtype="<u4", count=n + 1, offset=4).astype(np.int64)
    if offs[0] != 0 or offs[1] != 0 or (np.diff(offs) < 0).any() or offs[n] != len(raw) - base:
        raise PackError("section STRS: offsets do not partition the blob (string 0 must be empty)")
    try:
        return [raw[base + int(offs[i]): base + int(offs[i + 1])].decode("utf-8") for i in range(n)]
    except UnicodeDecodeError:
        raise PackError("section STRS: a string is not valid UTF-8") from None


def _dec_grid(raw, count, h):
    T = h["triangle_count"]
    if len(raw) < 20:
        raise PackError("section GRID: too short")
    ox, oy, cell, nx, ny = struct.unpack_from("<iiiII", raw, 0)
    if ox != h["min_lon"] or oy != h["min_lat"] or cell <= 0:
        raise PackError("section GRID: origin or cell size")
    if nx != max(1, -(-(h["max_lon"] - ox) // cell)) or ny != max(1, -(-(h["max_lat"] - oy) // cell)) \
            or nx * ny != count:
        raise PackError("section GRID: dimensions")
    vals = _uvarints(raw, None, "GRID", 20).astype(np.int64)
    offsets = np.zeros(nx * ny + 1, dtype=np.int64)
    ids = np.zeros(max(len(vals) - nx * ny, 0), dtype=np.int64)
    p, q = 0, 0
    for c in range(nx * ny):
        if p >= len(vals):
            raise PackError("section GRID: data ends early")
        n = int(vals[p])
        p += 1
        offsets[c] = q
        if n:
            if n > T or p + n > len(vals):
                raise PackError(f"section GRID: cell {c} count")
            d = vals[p:p + n]
            if (d[1:] == 0).any() or (d >= T).any():
                raise PackError(f"section GRID: cell {c} ids")
            seg = np.cumsum(d)
            if seg[-1] >= T:
                raise PackError(f"section GRID: cell {c} id out of range")
            ids[q:q + n] = seg
            p += n
            q += n
    if p != len(vals):
        raise PackError("section GRID: trailing data")
    offsets[nx * ny] = q
    return {"origin_lon": ox, "origin_lat": oy, "cell": cell, "nx": nx, "ny": ny,
            "offsets": offsets, "ids": ids[:q].astype(np.int32)}


def _records(s, tag, dtype):
    e = s[tag]
    size = RECORD_SIZES[tag]
    if len(e["raw"]) != size * e["count"]:
        raise PackError(f"section {tag}: length does not hold {e['count']} records")
    return np.frombuffer(e["raw"], dtype=dtype)


def _check_geometry_refs(recs, tag, npoints):
    if not len(recs):
        return
    gt = recs["geom_type"].astype(np.int64)
    cnt = recs["geom_count"].astype(np.int64)
    first = recs["geom_first"].astype(np.int64)
    ok = np.isin(gt, GEOM_TYPES) & (first + cnt <= npoints)
    ok &= np.where(gt == 1, cnt == 1, np.where(gt == 2, cnt >= 2, cnt >= 3))
    if not ok.all():
        raise PackError(f"section {tag}: record {int(np.flatnonzero(~ok)[0])} has an invalid geometry reference")


def check_adjacency(tris, nbr):
    """Spec A.4: every stored neighbour n of (t, k) is another triangle that owns the reversed
    edge and lists t across it."""
    T = len(tris)
    t = np.repeat(np.arange(T), 3)
    k = np.tile(np.arange(3), T)
    n = nbr.reshape(-1).astype(np.int64)
    has = n >= 0
    if ((n >= T) | (n == t)).any():
        raise PackError("section ADJC: neighbour out of range")
    p = tris[t, k].astype(np.int64)
    q = tris[t, (k + 1) % 3].astype(np.int64)
    tn = tris[np.where(has, n, 0)].astype(np.int64)          # (3T, 3) vertices of the neighbour
    nn = nbr[np.where(has, n, 0)].astype(np.int64)            # its neighbours
    match = (tn == q[:, None]) & (np.roll(tn, -1, axis=1) == p[:, None]) & (nn == t[:, None])
    if (has & ~match.any(axis=1)).any():
        raise PackError("section ADJC: adjacency is not consistent")


def read_pack(path) -> Pack:
    buf = open(path, "rb").read()
    return decode_pack(buf)


def decode_pack(buf: bytes) -> Pack:
    """Decode and check a whole pack (spec A.4, all checks in order)."""
    h = read_header(buf)
    s = read_sections(buf, h)
    V, T = h["vertex_count"], h["triangle_count"]
    bbox = (h["min_lon"], h["min_lat"], h["max_lon"], h["max_lat"])
    # STRS, GEOM, side tables
    strings = _dec_strings(s["STRS"]["raw"], s["STRS"]["count"])
    ns = len(strings)
    graw = s["GEOM"]["raw"]
    if len(graw) % 8 or len(graw) // 8 != s["GEOM"]["count"]:
        raise PackError("section GEOM: length does not hold its points")
    geom = np.frombuffer(graw, dtype="<i4").reshape(-1, 2)
    if len(geom) and ((geom[:, 0] < bbox[0]) | (geom[:, 0] > bbox[2]) | (geom[:, 1] < bbox[1])
                      | (geom[:, 1] > bbox[3])).any():
        raise PackError("section GEOM: point outside the header bounding box")
    sources = _records(s, "SRCS", SRCS_DT)
    overhead = _records(s, "OVHD", OVHD_DT)
    hazards = _records(s, "HAZD", HAZD_DT)
    channels = _records(s, "CHAN", CHAN_DT)
    areas = _records(s, "AREA", AREA_DT)
    for tag, recs, cols in (("SRCS", sources, ["name"]), ("OVHD", overhead, ["name"]), ("HAZD", hazards, ["name"]),
                            ("CHAN", channels, ["name", "ident", "desc"]), ("AREA", areas, ["name", "text"])):
        for c in cols:
            if len(recs) and (recs[c] >= ns).any():
                raise PackError(f"section {tag}: {c} string id out of range")
    _check_geometry_refs(overhead, "OVHD", len(geom))
    _check_geometry_refs(hazards, "HAZD", len(geom))
    # VERT
    if s["VERT"]["count"] != V:
        raise PackError("section VERT: count differs from vertex_count")
    d = unzigzag(_uvarints(s["VERT"]["raw"], 2 * V, "VERT")).reshape(V, 2)
    if (np.abs(d) > MAX_SPAN_UNITS).any():
        raise PackError("section VERT: delta out of range")
    d[0] += np.array([bbox[0], bbox[1]])
    verts = np.cumsum(d, axis=0)
    if ((verts[:, 0] < bbox[0]) | (verts[:, 0] > bbox[2]) | (verts[:, 1] < bbox[1]) | (verts[:, 1] > bbox[3])).any():
        raise PackError("section VERT: vertex outside the header bounding box")
    verts = verts.astype(np.int32)
    # TRIS
    if s["TRIS"]["count"] != T:
        raise PackError("section TRIS: count differs from triangle_count")
    tv = _uvarints(s["TRIS"]["raw"], 3 * T, "TRIS").reshape(T, 3)
    if (tv >= np.uint64(V)).any():
        raise PackError("section TRIS: vertex index out of range")
    tv = tv.astype(np.int64)
    a = np.cumsum(tv[:, 0])
    tris = np.stack([a, a + tv[:, 1], a + tv[:, 2]], 1)
    if (tris >= V).any() or (tv[:, 1] == 0).any() or (tv[:, 2] == 0).any() or (tv[:, 1] == tv[:, 2]).any():
        raise PackError("section TRIS: invalid vertex indices")
    pv = verts.astype(np.int64)[tris]
    o = ((pv[:, 1, 0] - pv[:, 0, 0]) * (pv[:, 2, 1] - pv[:, 0, 1])
         - (pv[:, 1, 1] - pv[:, 0, 1]) * (pv[:, 2, 0] - pv[:, 0, 0]))
    if (o <= 0).any():
        raise PackError("section TRIS: triangle not counter-clockwise")
    tris = tris.astype(np.int32)
    # ADJC, or derived adjacency
    if "ADJC" in s:
        if s["ADJC"]["count"] != T:
            raise PackError("section ADJC: count differs from triangle_count")
        dd = unzigzag(_uvarints(s["ADJC"]["raw"], 3 * T, "ADJC")).reshape(T, 3)
        nb = dd + np.arange(T)[:, None]
        if ((dd != 0) & ((nb < 0) | (nb >= T))).any():
            raise PackError("section ADJC: neighbour out of range")
        nbr = np.where(dd == 0, -1, nb).astype(np.int32)
        check_adjacency(tris, nbr)
    else:
        nbr, dup = adjacency(tris)
        if dup:
            raise PackError("section TRIS: a directed edge occurs twice")
    # ATTR
    e = s["ATTR"]
    if e["count"] != T or len(e["raw"]) != 17 * T:
        raise PackError("section ATTR: length differs from 17 * triangle_count")
    attrs, o = {}, 0
    for name, dt in ATTR_COLUMNS:
        col = np.frombuffer(e["raw"], dtype=dt, count=T, offset=o)
        attrs[name] = col
        o += col.nbytes
    for col, table in (("channel", channels), ("overhead", overhead), ("area", areas)):
        x = attrs[col].astype(np.int64)
        if ((x != ID_NONE) & (x >= len(table))).any():
            raise PackError(f"section ATTR: {col} reference out of range")
    grid = _dec_grid(s["GRID"]["raw"], s["GRID"]["count"], h)
    info = {}
    for line in s["INFO"]["raw"].decode("utf-8", errors="replace").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            info[k] = v
    p = Pack(
        region_id=h["region_id"], bbox=bbox, data_date=h["data_date"], build_date=h["build_date"],
        build_time=h["build_time"], clearance_dm=h["clearance_dm"], check_dm=h["check_dm"],
        shore_rings_m=(h["shore_ring0_m"], h["shore_ring1_m"]), vertices=verts, tris=tris,
        attrs=attrs, strings=strings, overhead=overhead, hazards=hazards, channels=channels,
        areas=areas, sources=sources, geom=geom, info=info, nbr=nbr, grid=grid,
    )
    p.sections = [{"name": k, **{kk: vv for kk, vv in v.items() if kk != "raw"}} for k, v in s.items()]
    p.header = h
    return p
