import copy
import hashlib
import json
from pathlib import Path

import pytest

from chart_build import manifest as mf
from chart_build.build import execute
from chart_build.publish import LocalTarget, publish
from chart_build.renderer import FakeRenderer

SAMPLE = Path(__file__).resolve().parents[3] / "Packages" / "ChartKit" / "Samples" / "gulf-manifest.sample.json"


def test_chartkit_sample_manifest_validates():
    mf.validate(json.loads(SAMPLE.read_text()))


@pytest.mark.parametrize("mutate,msg", [
    (lambda m: m.update(schemaVersion=2), "newer"),
    (lambda m: m["regions"][0].update(id="bad/id"), "invalid region id"),
    (lambda m: m["regions"].append(copy.deepcopy(m["regions"][0])), "duplicate"),
    (lambda m: m["regions"][0]["package"].update(sha256="xyz"), "sha256"),
    (lambda m: m["regions"][0]["package"].update(byteSize=0), "byteSize"),
    (lambda m: m["regions"][0]["package"].update(url="file:///x"), "http"),
    (lambda m: m["regions"][0].update(minZoom=17), "zoom range"),
    (lambda m: m["regions"][0]["bounds"].update(west=200), "bounds"),
    (lambda m: m["regions"][0]["package"].update(dataDate="May 2024"), "dataDate"),
    (lambda m: m["regions"][0].pop("source"), "source"),
])
def test_invalid_manifests_rejected(mutate, msg):
    m = json.loads(SAMPLE.read_text())
    mutate(m)
    with pytest.raises(mf.ManifestInvalid, match=msg):
        mf.validate(m)


def test_publish_local_writes_real_sizes_and_hashes(tmp_path, root, region, cfg, policy, snapshot):
    rec = execute(root, region, cfg, policy, FakeRenderer(cfg, [region.bbox]), "baseline", snapshot,
                  log=lambda m: None)
    target = LocalTarget(tmp_path / "pub", "https://charts.example.invalid/gulf")
    base = json.loads(SAMPLE.read_text())
    m = publish(target, [(region, rec, root.package_path("t", rec))], base_manifest=base)
    on_disk = json.loads((tmp_path / "pub" / "manifest.json").read_text())
    assert on_disk == m
    mf.validate(on_disk)
    ids = [r["id"] for r in m["regions"]]
    assert ids == sorted(ids) and "t" in ids and "ncds_13" in ids  # merged with the previous manifest
    entry = next(r for r in m["regions"] if r["id"] == "t")
    f = tmp_path / "pub" / rec["file"]
    assert entry["package"]["byteSize"] == f.stat().st_size
    assert entry["package"]["sha256"] == hashlib.sha256(f.read_bytes()).hexdigest()
    assert entry["package"]["url"] == "https://charts.example.invalid/gulf/" + rec["file"]
    assert entry["package"]["dataDate"] == "2026-11-02" and entry["package"]["version"] == "2026-11-11"
    assert entry["minZoom"] == rec["minzoom"] and entry["maxZoom"] == 16 and entry["tileFormat"] == "png"
    assert "2026-11-11" in entry["source"]


def test_publish_refuses_a_file_that_changed(tmp_path, root, region, cfg, policy, snapshot):
    rec = execute(root, region, cfg, policy, FakeRenderer(cfg, [region.bbox]), "baseline", snapshot,
                  log=lambda m: None)
    p = root.package_path("t", rec)
    with open(p, "ab") as f:
        f.write(b"\0")
    with pytest.raises(RuntimeError, match="do not match"):
        publish(LocalTarget(tmp_path / "pub", "https://x.invalid"), [(region, rec, p)], base_manifest={})
