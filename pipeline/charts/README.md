# pipeline/charts — chart build job

`chart-build` renders NOAA chart tiles into MBTiles region packages:

- the renderer is NOAA's MCS `NOAAChartDisplay` export: 2048 px metatiles with a 256 px gutter, and pinned display parameters;
- a package holds only the tiles the ENC coverage and scale policy calls for, with blank tiles dropped, lossless PNGs and identical tiles stored once;
- a weekly incremental update re-renders only what the ENC catalog diff says changed;
- `publish` writes a `manifest.json` that ChartKit decodes.

Operator guide, measurements and estimates: [docs/chart-build.md](../../docs/chart-build.md).

```sh
pip install -e pipeline/catalog -e "pipeline/charts[test]"
pytest pipeline/charts                                  # offline (fake renderer)
CHART_BUILD_LIVE=1 pytest pipeline/charts -k live       # one real export request

chart-build plan    --root R --region ncds_13 --snapshot snap.json
chart-build build   --root R --region ncds_13 --snapshot snap.json [--scale 2] [--budget N] [--allow-over-budget]
chart-build update  --root R --region ncds_13 --snapshot snap-new.json
chart-build verify  --root R --region ncds_13 --deep
chart-build canary  --root R --region ncds_13
chart-build publish --root R ncds_13 [ncds_14@2x] --target local --dir OUT --base-url URL
chart-build publish --root R ncds_13 --target github --repo owner/name --tag charts-YYYYMMDD --include-state
chart-build status  --root R
chart-build calibrate --root R            # determinism and seam measurements (about 45 requests)
```

| Module | Role |
|---|---|
| `grid` | Tile and metatile maths |
| `config` | Pinned render config (`data/render.json`), run policy, regions (`data/regions.json`) |
| `http` | Rate limit, in-flight cap, budget, backoff, request log |
| `renderer` | MCS client and the deterministic fake |
| `tiles` | Slicing, blank detection, PNG encoding |
| `mbtiles` | Writer with dedup and the resume ledger |
| `policy` | Zoom and coverage rules, affected tiles |
| `build` | Plan, build, update, canary and finalize |
| `verify`, `manifest`, `publish`, `calibrate`, `cli` | The remaining commands |
