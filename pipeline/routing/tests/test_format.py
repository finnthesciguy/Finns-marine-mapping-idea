"""Pack format: encodings, round trip, checksums, canonical order, index."""
from __future__ import annotations

import struct
import zlib

import numpy as np
import pytest

from enc_routing import packfmt as P
from enc_routing import synth


def test_uvarint_known_bytes():
    assert P.uvarint_encode([0, 1, 127, 128, 300, 16384]) == bytes(
        [0x00, 0x01, 0x7F, 0x80, 0x01, 0xAC, 0x02, 0x80, 0x80, 0x01])
    v, end = P.uvarint_decode(bytes([0xAC, 0x02, 0x05]))
    assert v.tolist() == [300, 5] and end == 3


def test_zigzag_roundtrip():
    a = np.array([0, -1, 1, -2, 2, -(2 ** 31), 2 ** 31 - 1])
    assert P.zigzag(a).tolist() == [0, 1, 2, 3, 4, 2 ** 32 - 1, 2 ** 32 - 2]
    assert P.unzigzag(P.zigzag(a)).tolist() == a.tolist()
    rng = np.random.default_rng(1)
    b = rng.integers(-(2 ** 40), 2 ** 40, 1000)
    v, _ = P.uvarint_decode(P.uvarint_encode(P.zigzag(b)))
    assert P.unzigzag(v).tolist() == b.tolist()


def test_roundtrip_synthetic(synth_pack):
    src = synth.build_synthetic()
    q = P.read_pack(synth_pack)
    assert q.region_id == "synthetic" and q.data_date == 20261101
    assert np.array_equal(q.vertices, src.vertices) and np.array_equal(q.tris, src.tris)
    assert np.array_equal(q.nbr, src.nbr)
    for k, _ in P.ATTR_COLUMNS:
        assert np.array_equal(q.attrs[k], src.attrs[k]), k
    assert q.strings == src.strings
    assert np.array_equal(q.overhead, src.overhead) and np.array_equal(q.hazards, src.hazards)
    assert np.array_equal(q.grid["ids"], src.grid["ids"])


def test_pack_without_adjacency_derives_the_same(tmp_path):
    src = synth.build_synthetic()
    p = tmp_path / "noadj.pack"
    P.write_pack(src, p, with_adjacency=False)
    q = P.read_pack(p)
    assert "ADJC" not in [s["name"] for s in q.sections]
    assert np.array_equal(q.nbr, src.nbr)


def test_header_layout_and_crc(synth_pack):
    buf = synth_pack.read_bytes()
    assert buf[:8] == b"GCRTPACK"
    major, minor, hsize = struct.unpack_from("<HHI", buf, 8)
    assert (major, minor, hsize) == (1, 1, 256)
    assert struct.unpack_from("<I", buf, 16)[0] == len(buf)
    n = struct.unpack_from("<I", buf, 20)[0]
    assert struct.unpack_from("<I", buf, 108)[0] == zlib.crc32(buf[256:256 + 32 * n])
    assert struct.unpack_from("<I", buf, 252)[0] == zlib.crc32(buf[:252])
    bad = bytearray(buf)
    bad[40] ^= 1
    with pytest.raises(P.PackError):
        P.read_header(bytes(bad))


def test_section_crc_detects_corruption(synth_pack, tmp_path):
    buf = bytearray(synth_pack.read_bytes())
    h = P.read_header(bytes(buf))
    name, enc, off, slen = struct.unpack_from("<4sIQI", buf, 256 + 32 * 4)  # 5th section
    buf[off + slen // 2] ^= 0xFF
    p = tmp_path / "bad.pack"
    p.write_bytes(bytes(buf))
    with pytest.raises(P.PackError):
        P.read_pack(p)
    assert h["section_count"] >= 12


def test_sections_are_8_byte_aligned_and_ordered(synth_pack):
    q = P.read_pack(synth_pack)
    names = [s["name"] for s in q.sections]
    assert names == [n for n in P.SECTION_ORDER if n in names]
    assert all(s["offset"] % 8 == 0 for s in q.sections)


def test_canonical_order():
    v = np.array([[0, 0], [10, 0], [10, 10], [0, 10]], np.int64)
    t = np.array([[2, 3, 0], [1, 2, 0]], np.int64)
    V, T, perm = P.canonicalize(v, t)
    assert (T[:, 0] < T[:, 1]).all() and (T[:, 0] < T[:, 2]).all()
    # orientation preserved (CCW)
    o = (V[T[:, 1], 0] - V[T[:, 0], 0]) * (V[T[:, 2], 1] - V[T[:, 0], 1]) - \
        (V[T[:, 1], 1] - V[T[:, 0], 1]) * (V[T[:, 2], 0] - V[T[:, 0], 0])
    assert (o > 0).all()
    assert [tuple(x) for x in T] == sorted(tuple(x) for x in T)


def test_adjacency_and_nonmanifold_detection():
    t = np.array([[0, 1, 2], [0, 2, 3]], np.int64)
    nbr, dup = P.adjacency(t)
    assert dup == 0 and nbr.tolist() == [[-1, -1, 1], [0, -1, -1]]
    _, dup = P.adjacency(np.array([[0, 1, 2], [0, 1, 3]]))
    assert dup == 1  # same directed edge twice: inconsistent / non-manifold


def test_grid_cells_are_closed():
    v = np.array([[0, 0], [10, 0], [10, 10], [20, 10]], np.int64)
    t = np.array([[0, 1, 2], [1, 3, 2]], np.int64)
    g = P.build_grid(v, t, (0, 0, 20, 20), 10)
    cells = {c: g["ids"][g["offsets"][c]:g["offsets"][c + 1]].tolist() for c in range(g["nx"] * g["ny"])}
    # triangle 0 spans x 0..10, y 0..10: touches cells (0,0),(0,1),(1,0),(1,1) because cells are closed
    assert cells == {0: [0, 1], 1: [0, 1], 2: [0, 1], 3: [0, 1]}


# ------------------------------------------------------------------ reader checks (spec A.4)

def _fix_crcs(buf: bytearray, table_crc: bool = True) -> bytes:
    """Recompute the section-table CRC (format 1.1) and the header CRC after a mutation."""
    n = struct.unpack_from("<I", buf, 20)[0]
    if table_crc:
        struct.pack_into("<I", buf, 108, zlib.crc32(bytes(buf[256:256 + 32 * n])))
    struct.pack_into("<I", buf, 252, zlib.crc32(bytes(buf[:252])))
    return bytes(buf)


def _entry(buf, tag):
    n = struct.unpack_from("<I", buf, 20)[0]
    for i in range(n):
        if buf[256 + 32 * i: 260 + 32 * i] == tag:
            return 256 + 32 * i
    raise KeyError(tag)


def test_reader_accepts_format_1_0(synth_pack):
    buf = bytearray(synth_pack.read_bytes())
    struct.pack_into("<H", buf, 10, 0)       # minor 0
    struct.pack_into("<I", buf, 108, 0)      # reserved in 1.0: no section-table CRC
    old = P.decode_pack(_fix_crcs(buf, table_crc=False))
    new = P.read_pack(synth_pack)
    assert old.header["minor"] == 0 and new.header["minor"] == 1
    assert np.array_equal(old.tris, new.tris) and np.array_equal(old.nbr, new.nbr)
    # a 1.0 file has no table CRC, so a table change is not detected by a checksum ...
    struct.pack_into("<I", buf, _entry(buf, b"INFO") + 28, 5)  # INFO count is informative
    P.decode_pack(_fix_crcs(buf, table_crc=False))
    # ... but in 1.1 it is
    buf = bytearray(synth_pack.read_bytes())
    struct.pack_into("<I", buf, _entry(buf, b"INFO") + 28, 5)
    with pytest.raises(P.PackError, match="section table CRC"):
        P.decode_pack(bytes(buf))


def _mutations(buf):
    """(name, mutated bytes) with every CRC fixed, so the semantic checks are reached."""
    out = []
    b = bytearray(buf)
    struct.pack_into("<I", b, 12, 255)
    out.append(("header_size", _fix_crcs(b)))
    b = bytearray(buf)
    struct.pack_into("<I", b, 24, 264)
    out.append(("section_table_offset", _fix_crcs(b)))
    b = bytearray(buf)
    b[_entry(b, b"CHAN"): _entry(b, b"CHAN") + 4] = b"AREA"
    out.append(("duplicate tag", _fix_crcs(b)))
    b = bytearray(buf)
    struct.pack_into("<I", b, 28, 0)
    out.append(("flag bit 0 without ADJC", _fix_crcs(b)))
    b = bytearray(buf)
    struct.pack_into("<I", b, _entry(b, b"STRS") + 28, 12)
    out.append(("STRS count", _fix_crcs(b)))
    b = bytearray(buf)
    struct.pack_into("<I", b, _entry(b, b"GRID") + 28, 9)
    out.append(("GRID count", _fix_crcs(b)))
    b = bytearray(buf)
    struct.pack_into("<I", b, 16, len(b) + 8)
    out.append(("file_size", _fix_crcs(b + bytearray(8))[:len(b)]))
    b = bytearray(buf) + bytearray(8)
    struct.pack_into("<I", b, 16, len(b))
    out.append(("trailing padding block", _fix_crcs(b)))
    b = bytearray(buf)
    e = _entry(b, b"INFO")
    off, slen = struct.unpack_from("<QI", b, e + 8)
    if (off + slen) % 8:
        b[off + slen] = 1
        out.append(("non-zero padding", bytes(b)))
    b = bytearray(buf)
    struct.pack_into("<i", b, 72, struct.unpack_from("<i", b, 64)[0] + (1 << 30) + 1)
    out.append(("bbox span", _fix_crcs(b)))
    return out


@pytest.mark.parametrize("i", range(10))
def test_reader_rejects_checksum_valid_mutations(synth_pack, i):
    muts = _mutations(synth_pack.read_bytes())
    if i < len(muts):
        name, b = muts[i]
        with pytest.raises(P.PackError):
            P.decode_pack(b)


def test_every_bit_flip_is_rejected(synth_pack):
    """Format 1.1 covers every byte: header CRC, table CRC, section CRCs, zero padding."""
    buf = synth_pack.read_bytes()
    accepted = []
    for pos in range(len(buf)):
        for bit in range(8):
            b = bytearray(buf)
            b[pos] ^= 1 << bit
            try:
                P.decode_pack(bytes(b))
                accepted.append((pos, bit))
            except P.PackError:
                pass
    assert not accepted, accepted[:10]


def test_reader_rejects_geometry_outside_bbox(tmp_path):
    src = synth.build_synthetic()
    src.geom = src.geom.copy()
    src.geom[0, 0] = src.bbox[0] - 1
    p = tmp_path / "geom.pack"
    P.write_pack(src, p, with_adjacency=True)
    with pytest.raises(P.PackError, match="GEOM"):
        P.read_pack(p)


def test_reader_rejects_inconsistent_adjacency(tmp_path):
    src = synth.build_synthetic()
    src.nbr = src.nbr.copy()
    t = int(np.flatnonzero((src.nbr >= 0).all(axis=1))[0])
    src.nbr[t, 0], src.nbr[t, 1] = src.nbr[t, 1], src.nbr[t, 0]
    p = tmp_path / "adj.pack"
    P.write_pack(src, p, with_adjacency=True)
    with pytest.raises(P.PackError, match="ADJC"):
        P.read_pack(p)
