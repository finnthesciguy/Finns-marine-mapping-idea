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
    assert (major, minor, hsize) == (1, 0, 256)
    assert struct.unpack_from("<I", buf, 16)[0] == len(buf)
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
