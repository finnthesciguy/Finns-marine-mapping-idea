from datetime import datetime, timezone

import pytest
import requests

from chart_build.config import RunPolicy
from chart_build.http import (BadResponse, BudgetExceeded, PoliteClient, RateLimiter, ServiceFailing,
                              friday_reload_window)

PNG = b"\x89PNG\r\n\x1a\n" + b"x" * 20


class Resp:
    def __init__(self, status, body=PNG, headers=None):
        self.status_code, self.content, self.headers = status, body, headers or {}


class Session:
    def __init__(self, script):
        self.script = list(script)
        self.headers = {}
        self.calls = 0

    def get(self, url, params=None, timeout=None):
        self.calls += 1
        r = self.script.pop(0)
        if isinstance(r, Exception):
            raise r
        return r


class Clock:
    def __init__(self):
        self.t = 0.0
        self.sleeps = []

    def __call__(self):
        return self.t

    def sleep(self, s):
        self.sleeps.append(s)
        self.t += s


def client(script, **kw):
    clock = Clock()
    pol = RunPolicy(**{"budget": 100, "backoff": 2.0, "retries": 3, **kw})
    c = PoliteClient(pol, session=Session(script), sleep=clock.sleep, clock=clock)
    return c, clock


def test_rate_limiter_spaces_request_starts():
    clock = Clock()
    rl = RateLimiter(1.0, clock=clock, sleep=clock.sleep)
    for _ in range(5):
        rl.acquire()
    assert clock.t == pytest.approx(4.0)


def test_success_and_user_agent():
    c, _ = client([Resp(200)])
    assert c.get_image("u", {}) == PNG
    assert c.used == 1
    assert "chart-tile-client" in c.session.headers["User-Agent"]


def test_backoff_on_503_then_success_honours_retry_after():
    c, clock = client([Resp(503), Resp(429, headers={"Retry-After": "30"}), Resp(200)])
    assert c.get_image("u", {}) == PNG
    assert c.used == 3
    backoffs = [s for s in clock.sleeps if s > 1.5]
    assert backoffs[:2] == [2.0, 30]


def test_non_png_200_is_retried_then_fails():
    c, _ = client([Resp(200, b'{"error":{"code":500}}')] * 4, max_consecutive_failures=5)
    with pytest.raises(BadResponse, match="not a PNG"):
        c.get_image("u", {})
    assert c.used == 4


def test_connection_errors_and_consecutive_failure_stop():
    script = [requests.ConnectionError("x")] * 4 + [Resp(500)] * 4
    c, _ = client(script, max_consecutive_failures=2)
    with pytest.raises(BadResponse):
        c.get_image("u", {})
    with pytest.raises(ServiceFailing):
        c.get_image("u", {})


def test_budget_is_hard():
    c, _ = client([Resp(200)] * 5, budget=2)
    c.get_image("u", {})
    c.get_image("u", {})
    with pytest.raises(BudgetExceeded):
        c.get_image("u", {})
    assert c.session.calls == 2


def test_policy_limits():
    with pytest.raises(ValueError):
        RunPolicy(rate=5)
    with pytest.raises(ValueError):
        RunPolicy(max_inflight=4)


def test_friday_window():
    assert friday_reload_window(datetime(2026, 11, 13, 20, 0, tzinfo=timezone.utc))  # Fri 14:00 CT
    assert not friday_reload_window(datetime(2026, 11, 13, 15, 0, tzinfo=timezone.utc))  # Fri 09:00 CT
    assert friday_reload_window(datetime(2026, 11, 14, 10, 0, tzinfo=timezone.utc))  # Sat 04:00 CT
    assert not friday_reload_window(datetime(2026, 11, 14, 14, 0, tzinfo=timezone.utc))


def test_mcs_renderer_retries_suspect_blank_metatiles():
    import numpy as np
    from chart_build.config import RenderConfig
    from chart_build.grid import Metatile
    from chart_build.renderer import MCSRenderer, SuspectBlank
    from chart_build.tiles import encode_png
    cfg = RenderConfig.load().with_overrides(tile_px=16, metatile=2, gutter_px=4)
    size = 2 * 16 + 8
    blank = encode_png(np.zeros((size, size, 4), np.uint8), "rgba")
    chart = np.zeros((size, size, 4), np.uint8)
    chart[..., 3] = 255
    chart = encode_png(chart, "rgba")

    class C:
        def __init__(self, replies):
            self.replies = list(replies)

        def get_image(self, url, params, tag=""):
            return self.replies.pop(0)

    mt = Metatile(12, 1000, 1700, 2)
    r = MCSRenderer(cfg, C([blank, chart]), sleep=lambda s: None)
    assert r.render(mt)[..., 3].all()
    with pytest.raises(SuspectBlank):
        MCSRenderer(cfg, C([blank] * 3), sleep=lambda s: None).render(mt)
    low = Metatile(3, 0, 0, 2)  # small areas really are blank at low zoom
    r = MCSRenderer(cfg, C([encode_png(np.zeros((40, 40, 4), np.uint8), "rgba")]), sleep=lambda s: None)
    assert not r.render(low)[..., 3].any()
