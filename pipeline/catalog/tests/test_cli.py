import copy
import json

from enc_catalog.cli import main


def test_select_json(fixture_path, capsys):
    main(["select", "--catalog", fixture_path, "--format", "json"])
    out = json.loads(capsys.readouterr().out)
    assert out["cells"] == 26
    assert out["by_band"]["harbour"] == 13
    assert out["by_region"]["ncds_13"]["harbour"] == 3


def test_select_text_and_names(fixture_path, capsys):
    main(["select", "--catalog", fixture_path])
    text = capsys.readouterr().out
    assert "26 active cells in AOI" in text and "ncds_14" in text
    main(["select", "--catalog", fixture_path, "--format", "names"])
    assert "US5PLQCI" in capsys.readouterr().out.split()


def test_snapshot_diff_roundtrip(tmp_path, fixture_path, capsys):
    a = tmp_path / "a.json"
    main(["snapshot", "--catalog", fixture_path, "--out", str(a)])
    snap = json.loads(a.read_text())
    new = copy.deepcopy(snap)
    new["cells"]["US5PLQCI"]["updn"] = 1
    b = tmp_path / "b.json"
    b.write_text(json.dumps(new))
    tiles = tmp_path / "tiles.json"
    capsys.readouterr()
    main(["diff", str(a), str(b), "--max-zoom", "14", "--tiles-out", str(tiles), "--json"])
    s = json.loads(capsys.readouterr().out)
    assert s["updated"] == ["US5PLQCI"] and s["tiles_total"] > 0
    t = json.loads(tiles.read_text())
    assert t["scheme"] == "xyz" and sum(len(v) for v in t["tiles"].values()) == s["tiles_total"]
    main(["diff", str(a), str(b), "--max-zoom", "14"])
    assert "1 updated" in capsys.readouterr().out


def test_activity(fixture_path, capsys):
    main(["activity", "--catalog", fixture_path, "--weeks", "3", "--json"])
    rows = json.loads(capsys.readouterr().out)
    assert [r["week_start"] for r in rows] == ["2026-11-09", "2026-11-02", "2026-10-26"]
    assert set(rows[0]["names"]) == {"US3LA1BA", "US2GOACB", "US4LA1FH"}
