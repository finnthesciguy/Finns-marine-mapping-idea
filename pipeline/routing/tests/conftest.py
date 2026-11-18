import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
TESTDATA = ROOT.parents[1] / "testdata" / "routing"


@pytest.fixture(scope="session")
def synth_pack(tmp_path_factory):
    from enc_routing import packfmt, synth

    p = tmp_path_factory.mktemp("synth") / "synthetic.pack"
    packfmt.write_pack(synth.build_synthetic(), p, with_adjacency=True)
    return p
