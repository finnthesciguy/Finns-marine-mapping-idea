import json
import random

from conftest import make_zip

from enc_catalog.download import CellCache, CellRequest, Http, fetch_catalog


def req(server, name="US5TEST1", body=None, **kw):
    body = body if body is not None else make_zip(name)
    server.files[f"/ENCs/{name}.zip"] = body
    args = dict(name=name, url=f"{server.url}/ENCs/{name}.zip", size=len(body), edtn=1, updn=0,
                isdt="2026-11-01", uadt="2026-11-01")
    args.update(kw)
    return CellRequest(**args), body


def http():
    return Http(max_concurrency=2, retries=3, backoff=0.01, timeout=10)


def test_download_then_skip(tmp_path, server):
    r, body = req(server)
    cache = CellCache(tmp_path)
    res = cache.fetch(r, http())
    assert res.status == "downloaded" and res.bytes == len(body)
    assert cache.path(r.name).read_bytes() == body
    idx = json.loads((tmp_path / "cache.json").read_text())
    assert idx[r.name]["version"]["edtn"] == 1 and len(idx[r.name]["sha256"]) == 64
    n = len(server.log)
    assert cache.fetch(r, http()).status == "skipped"
    assert CellCache(tmp_path).fetch(r, http(), verify=True).status == "skipped"
    assert len(server.log) == n  # no request made


def test_new_version_redownloads(tmp_path, server):
    r, _ = req(server)
    cache = CellCache(tmp_path)
    cache.fetch(r, http())
    r2, body2 = req(server, body=make_zip("US5TEST1", b"y" * 7000), updn=1)
    res = cache.fetch(r2, http())
    assert res.status == "downloaded"
    assert cache.path(r2.name).read_bytes() == body2


def test_resume_after_interrupted_transfer(tmp_path, server):
    r, body = req(server, body=make_zip("US5TEST1", random.Random(1).randbytes(20_000)))
    cache = CellCache(tmp_path)
    server.truncate_next = 1000  # connection "drops" after 1000 bytes
    first = cache.fetch(r, http())
    assert first.status == "failed" and "size" in first.error
    part = cache.path(r.name).with_suffix(".zip.part")
    assert part.stat().st_size == 1000
    second = cache.fetch(r, http())
    assert second.status == "resumed", second
    assert server.log[-1][1] == "bytes=1000-" and server.log[-1][2] == "206"
    assert cache.path(r.name).read_bytes() == body
    assert not part.exists()


def test_stale_part_from_other_version_is_discarded(tmp_path, server):
    r, body = req(server)
    cache = CellCache(tmp_path)
    server.truncate_next = 100
    cache.fetch(r, http())
    r2, body2 = req(server, body=make_zip("US5TEST1", b"z" * 9000), edtn=2)
    assert cache.fetch(r2, http()).status == "downloaded"
    assert server.log[-1][1] == ""  # fresh GET, no Range
    assert cache.path(r.name).read_bytes() == body2


def test_size_mismatch_and_corrupt_zip_fail(tmp_path, server):
    r, body = req(server)
    bad_size = CellRequest(r.name, r.url, r.size + 10, 1, 0, r.isdt, r.uadt)
    assert CellCache(tmp_path / "a").fetch(bad_size, http()).status == "failed"
    corrupt = bytearray(body)
    corrupt[60] ^= 0xFF  # inside the deflated member data -> CRC error
    r2, _ = req(server, name="US5TEST2", body=bytes(corrupt))
    res = CellCache(tmp_path / "b").fetch(r2, http())
    assert res.status == "failed"
    assert not CellCache(tmp_path / "b").path("US5TEST2").exists()


def test_retry_on_503(tmp_path, server):
    r, body = req(server)
    server.fail_next = 2
    res = CellCache(tmp_path).fetch(r, http())
    assert res.status == "downloaded"
    assert [s for _, _, s in server.log] == ["503", "503", "200"]


def test_404_reported(tmp_path, server):
    r = CellRequest("US5NONE", f"{server.url}/ENCs/US5NONE.zip", 10, 1, 0, "", "")
    res = CellCache(tmp_path).fetch(r, http())
    assert res.status == "failed" and "404" in res.error


def test_fetch_all(tmp_path, server):
    reqs = [req(server, name=f"US5T{i:04d}")[0] for i in range(5)]
    res = CellCache(tmp_path).fetch_all(reqs, http(), workers=2)
    assert [r.status for r in res] == ["downloaded"] * 5


def test_fetch_catalog_conditional(tmp_path, server, fixture_path):
    data = open(fixture_path, "rb").read()
    server.files["/ENCs/ENCProdCat.xml"] = data
    server.etags["/ENCs/ENCProdCat.xml"] = '"abc"'
    dest = tmp_path / "cat.xml"
    url = f"{server.url}/ENCs/ENCProdCat.xml"
    assert fetch_catalog(dest, http(), url) is True
    assert dest.read_bytes() == data
    assert fetch_catalog(dest, http(), url) is False
    assert server.log[-1][2] == "304"
