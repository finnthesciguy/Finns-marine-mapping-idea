"""Polite HTTP for NOAA's export service: rate limit, in-flight cap, per-run
request budget, exponential backoff and a stop on repeated failure.

Every attempt (including retries) counts against the budget and is appended to
a JSON-lines request log, so the number of requests a run made is auditable.
"""
from __future__ import annotations

import json
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import requests

from .config import RunPolicy

RETRY_STATUS = {429, 500, 502, 503, 504}
PNG_SIG = b"\x89PNG\r\n\x1a\n"


class BudgetExceeded(RuntimeError):
    pass


class ServiceFailing(RuntimeError):
    """Too many consecutive failed requests: stop the run (it can be resumed)."""


class BadResponse(RuntimeError):
    pass


class RateLimiter:
    """Request starts are spaced at least 1/rate seconds apart."""

    def __init__(self, rate: float, clock=time.monotonic, sleep=time.sleep):
        self.interval = 1.0 / rate
        self._next = 0.0
        self._lock = threading.Lock()
        self.clock, self.sleep = clock, sleep

    def acquire(self) -> None:
        with self._lock:
            now = self.clock()
            start = max(now, self._next)
            self._next = start + self.interval
        wait = start - self.clock()
        if wait > 0:
            self.sleep(wait)


class PoliteClient:
    def __init__(self, policy: RunPolicy, log_path: str | Path | None = None, session: requests.Session | None = None,
                 sleep=time.sleep, clock=time.monotonic):
        self.policy = policy
        self.session = session or requests.Session()
        self.session.headers["User-Agent"] = policy.user_agent
        self.limiter = RateLimiter(policy.rate, clock=clock, sleep=sleep)
        self._sem = threading.Semaphore(policy.max_inflight)
        self._lock = threading.Lock()
        self.sleep = sleep
        self.used = 0
        self.failures_in_a_row = 0
        self.log_path = Path(log_path) if log_path else None

    @property
    def remaining(self) -> int:
        return self.policy.budget - self.used

    def _reserve(self) -> None:
        with self._lock:
            if self.used >= self.policy.budget:
                raise BudgetExceeded(f"request budget of {self.policy.budget} used up")
            self.used += 1

    def _log(self, rec: dict) -> None:
        if not self.log_path:
            return
        with self._lock:
            with open(self.log_path, "a") as f:
                f.write(json.dumps(rec, separators=(",", ":")) + "\n")

    def get_image(self, url: str, params: dict, tag: str = "") -> bytes:
        """GET an image. Retries 429/5xx/connection errors/non-image replies with
        exponential backoff (honouring Retry-After); raises ServiceFailing after
        `max_consecutive_failures` requests that failed even after retries."""
        delay = self.policy.backoff
        last = "?"
        for attempt in range(self.policy.retries + 1):
            self._reserve()
            self.limiter.acquire()
            t0 = time.monotonic()
            status, nbytes, err, retry_after = None, 0, None, None
            try:
                with self._sem:
                    r = self.session.get(url, params=params, timeout=self.policy.timeout)
                status, body = r.status_code, r.content
                nbytes = len(body)
                retry_after = r.headers.get("Retry-After")
                if status == 200 and body.startswith(PNG_SIG):
                    self._log({"t": _now(), "tag": tag, "status": status, "s": round(time.monotonic() - t0, 3),
                               "bytes": nbytes, "attempt": attempt})
                    with self._lock:
                        self.failures_in_a_row = 0
                    return body
                if status == 200:
                    err = "not a PNG: " + body[:200].decode("utf-8", "replace")
                elif status not in RETRY_STATUS:
                    err = f"HTTP {status}"
                    self._log({"t": _now(), "tag": tag, "status": status, "s": round(time.monotonic() - t0, 3),
                               "bytes": nbytes, "attempt": attempt, "error": err})
                    self._fail()
                    raise BadResponse(f"{tag}: {err}")
                else:
                    err = f"HTTP {status}"
            except (requests.ConnectionError, requests.Timeout) as e:
                err = type(e).__name__
            last = err
            self._log({"t": _now(), "tag": tag, "status": status, "s": round(time.monotonic() - t0, 3),
                       "bytes": nbytes, "attempt": attempt, "error": err})
            if attempt == self.policy.retries:
                break
            wait = float(retry_after) if retry_after and retry_after.isdigit() else delay
            self.sleep(min(wait, 600))
            delay *= 2
        self._fail()
        raise BadResponse(f"{tag}: failed after {self.policy.retries + 1} attempts ({last})")

    def _fail(self) -> None:
        with self._lock:
            self.failures_in_a_row += 1
            n = self.failures_in_a_row
        if n >= self.policy.max_consecutive_failures:
            raise ServiceFailing(f"{n} requests in a row failed; stopping (the run can be resumed later)")


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def friday_reload_window(now: datetime | None = None) -> bool:
    """True from Friday 12:00 to Saturday 06:00 US Central time, when NOAA
    reloads the ENC data behind the chart services and warns of downtime."""
    now = (now or datetime.now(timezone.utc)).astimezone(ZoneInfo("America/Chicago"))
    wd, h = now.weekday(), now.hour
    return (wd == 4 and h >= 12) or (wd == 5 and h < 6)
