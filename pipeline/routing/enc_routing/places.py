"""Hand-placed reference geometry for the pilot area (lon, lat, WGS84).

These are spike-only conveniences: test-route endpoints, connectivity probe
points, and the inputs of the "open Gulf" mask (safewater.gulf_mask) used to
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

# Reference test routes (start, end). Points are placed in open water just
# off the named place, because a marina basin may be too shallow at chart
# scale.
ROUTES = {
    "a_stpete_to_sarasota": {
        "desc": "Downtown St. Petersburg (municipal marina) to Sarasota (Marina Jack)",
        "start": (-82.6225, 27.7680),
        "end": (-82.5465, 27.3330),
        "inside": False,
    },
    "b_venice_inlet_to_punta_gorda": {
        "desc": "Venice Inlet to Punta Gorda (Fishermen's Village)",
        "start": (-82.4630, 27.1130),
        "end": (-82.0690, 26.9300),
        "inside": False,
    },
    "c_anna_maria_to_boca_grande_inside": {
        "desc": "Bradenton Beach (Bridge Street pier) to Boca Grande, inside route",
        "start": (-82.6930, 27.4690),
        "end": (-82.2480, 26.7530),  # ICW channel abreast of Boca Grande village
        "inside": True,
    },
}
