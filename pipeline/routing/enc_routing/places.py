"""Hand-placed reference geometry for the pilot area (lon, lat, WGS84).

These are spike-only conveniences: test-route endpoints, connectivity probe
points, and the inputs of the "open Gulf" mask (mesh.gulf_mask) used to
answer "can you go *inside*?".
"""
from __future__ import annotations

# Line across the mouth of Tampa Bay (Pass-a-Grille - Egmont Key - Anna
# Maria). Used with the land mass to separate the open Gulf from inside water.
TAMPA_MOUTH = [(-82.736, 27.693), (-82.762, 27.620), (-82.765, 27.585), (-82.742, 27.532)]

# A point well out in the open Gulf.
GULF_SEED = (-83.2, 27.0)

# Probe points for connectivity questions (in navigable water).
PROBES = {
    "tampa_bay_mid": (-82.580, 27.700),
    "st_pete_downtown": (-82.622, 27.770),
    "boca_ciega_bay": (-82.7307, 27.7350),
    "anna_maria_sound": (-82.6945, 27.4974),
    "sarasota_bay": (-82.600, 27.380),
    "roberts_bay": (-82.545, 27.300),
    "little_sarasota_bay": (-82.5032, 27.2115),
    "venice_icw": (-82.4373, 27.0941),
    "lemon_bay": (-82.3489, 26.9290),
    "gasparilla_sound": (-82.2548, 26.8017),
    "charlotte_harbor": (-82.130, 26.850),
    "punta_gorda": (-82.070, 26.940),
    "pine_island_sound": (-82.2139, 26.6387),
}

# Reference routes (spike report sections 7 and 10). Points are lon, lat.
# "profile": draft_ft, margin_ft, air_draft_ft and options; "expect" is the
# property the route is checked against (see enc_routing.assess).
STPETE = (-82.6225, 27.7680)
MARINA_JACK = (-82.5465, 27.3330)
VENICE_INLET = (-82.4630, 27.1130)
PUNTA_GORDA = (-82.0690, 26.9300)
BRADENTON_BEACH = (-82.6930, 27.4690)
BOCA_GRANDE = (-82.2480, 26.7530)
BOAT = dict(draft_ft=4.5, margin_ft=1.5, air_draft_ft=20.0)
RELAXED = dict(use_maintained=True, accept_unknown_clearance=True)

ROUTES = [
    {"id": "a_strict", "desc": "St. Petersburg municipal marina to Marina Jack (spike a / ref 1)",
     "start": STPETE, "end": MARINA_JACK, "profile": BOAT,
     "expect": {"ok": True, "nm": 33.0, "openings": 0}},
    {"id": "a_relaxed", "desc": "same, maintained channels and unknown clearance accepted",
     "start": STPETE, "end": MARINA_JACK, "profile": {**BOAT, **RELAXED}, "expect": {"ok": True, "nm": 33.0}},
    {"id": "b_strict", "desc": "Venice Inlet to Punta Gorda, charted depth only (spike b / ref 2): outside via Boca Grande Pass",
     "start": VENICE_INLET, "end": PUNTA_GORDA, "profile": BOAT, "expect": {"ok": True, "nm": 47.4}},
    {"id": "b_relaxed", "desc": "same, relaxed: inside via the ICW",
     "start": VENICE_INLET, "end": PUNTA_GORDA, "profile": {**BOAT, **RELAXED}, "expect": {"ok": True, "nm": 46.2}},
    {"id": "b_relaxed_inside", "desc": "same, relaxed and inside only (avoid open Gulf): the ICW run",
     "start": VENICE_INLET, "end": PUNTA_GORDA, "profile": {**BOAT, **RELAXED, "avoid_open_gulf": True},
     "expect": {"ok": True, "nm": 46.2}},
    {"id": "c_strict", "desc": "Bradenton Beach to Boca Grande inside, strict (spike c / ref 3): must fail",
     "start": BRADENTON_BEACH, "end": BOCA_GRANDE, "profile": {**BOAT, "avoid_open_gulf": True},
     "expect": {"ok": False}},
    {"id": "c_relaxed", "desc": "same, relaxed: ICW with openings at Stickney Point, Blackburn Point, Albee Road",
     "start": BRADENTON_BEACH, "end": BOCA_GRANDE, "profile": {**BOAT, **RELAXED, "avoid_open_gulf": True},
     "expect": {"ok": True, "nm": 52.1, "openings_min": 3}},
    {"id": "r4_air9", "desc": "ref 4: as c_relaxed with 9 ft air draft",
     "start": BRADENTON_BEACH, "end": BOCA_GRANDE,
     "profile": {**BOAT, **RELAXED, "air_draft_ft": 9.0, "avoid_open_gulf": True}, "expect": {"ok": True}},
    {"id": "r5_clearwater_bocaciega", "desc": "ref 5: Clearwater Pass to Boca Ciega Bay inside (Treasure Island bascule 21 ft, never the 4-5 ft fixed parts)",
     "start": (-82.8170, 27.9660), "end": (-82.7307, 27.7350), "profile": {**BOAT, "avoid_open_gulf": True},
     "expect": {"ok": True}},
    {"id": "r6_bocaciega_70ft", "desc": "ref 6: Boca Ciega Bay to Tampa Bay, 70 ft air draft: not under the 65 ft Pinellas Bayway",
     "start": (-82.7307, 27.7350), "end": (-82.5800, 27.7000), "profile": {**BOAT, "air_draft_ft": 70.0},
     "expect": {"max_clearance_violation": True}},
    {"id": "r7_fmb_captiva", "desc": "ref 7: Fort Myers Beach to Captiva via San Carlos Bay, 30 ft air draft: Sanibel Causeway 70 ft span",
     "start": (-81.9520, 26.4560), "end": (-82.2139, 26.6387), "profile": {**BOAT, "air_draft_ft": 30.0},
     "expect": {"ok": True}},
    {"id": "r8_tampa_egmont_15ft", "desc": "ref 8: Harbour Island to Egmont Key, 15 ft draft: ship channel, under the Skyway",
     "start": (-82.4560, 27.9390), "end": (-82.7900, 27.6000),
     "profile": dict(draft_ft=15.0, margin_ft=2.0, air_draft_ft=60.0), "expect": {"ok": True}},
    {"id": "r8b_tampa_egmont_15ft_maintained", "desc": "ref 8 with maintained channels: the berth at Harbour Island is charted 6 ft",
     "start": (-82.4560, 27.9390), "end": (-82.7900, 27.6000),
     "profile": dict(draft_ft=15.0, margin_ft=2.0, air_draft_ft=60.0, use_maintained=True), "expect": {"ok": True}},
    {"id": "r9_portmanatee_bradenton", "desc": "ref 9: Port Manatee to Bradenton, Manatee River bridges",
     "start": (-82.5620, 27.6370), "end": (-82.5450, 27.5080), "profile": BOAT, "expect": {"ok": True}},
    {"id": "r10a_start_on_land", "desc": "ref 10: start 3 km inland: error",
     "start": (-82.4500, 27.3500), "end": MARINA_JACK, "profile": BOAT, "expect": {"ok": False}},
    {"id": "r10b_marina_basin", "desc": "ref 10: start in a marina basin (Gulfport): snap <= 600 m",
     "start": (-82.7012, 27.7375), "end": (-82.7307, 27.7350), "profile": BOAT, "expect": {"ok": True, "snap_max_m": 600}},
    {"id": "r10c_sarasota_15ft", "desc": "ref 10: Sarasota Bay at 15 ft draft: no path",
     "start": (-82.6000, 27.3800), "end": MARINA_JACK, "profile": dict(draft_ft=15.0, margin_ft=1.5, air_draft_ft=20.0),
     "expect": {"ok": False}},
    {"id": "r10d_ringling_66ft", "desc": "ref 10: Ringling Causeway at 66 ft air draft, inside: no route",
     "start": (-82.6000, 27.3800), "end": (-82.5450, 27.3000),
     "profile": {**BOAT, **RELAXED, "air_draft_ft": 66.0, "avoid_open_gulf": True}, "expect": {"ok": False}},
    {"id": "r11_egmont_bocagrande_offshore", "desc": "ref 11: Egmont Key to Boca Grande Pass offshore: does not hug the beach",
     "start": (-82.8000, 27.5800), "end": (-82.2700, 26.7000), "profile": BOAT, "expect": {"ok": True}},
]

# Open-Gulf mask per region (mesh.gulf_mask): land is closed with close_m
# (sealing the passes), barrier lines are drawn across bay mouths, and the
# water connected to `seed` is "outside".
GULF_MASK = {
    "pilot": {"seed": GULF_SEED, "barriers": [TAMPA_MOUTH], "close_m": 1500.0},
}
