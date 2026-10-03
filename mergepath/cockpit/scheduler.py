"""One bounded scheduler with single-flight sources and last-good envelopes."""

import copy
import math
import re
import threading
import time
from dataclasses import dataclass, field

from .github import ClientError, copy_json_tree, error_category


@dataclass(frozen=True)
class Sample:
    data: object
    hot: bool = False


@dataclass
class Source:
    name: str
    fetch: object = field(repr=False)
    hot_interval: float = 15
    idle_interval: float = 120
    timeout: float = 30
    max_backoff: float = 900
    due: float = 0
    failures: int = 0
    blocked_until: float = 0
    deadline: float = 0
    in_flight: bool = False
    timed_out: bool = False
    envelope: dict = field(default_factory=lambda: {
        "data": None, "observed_at": None, "attempted_at": None,
        "stale": True, "error": "unavailable", "retry_at": None,
        "in_flight": False,
    })


class Scheduler:
    def __init__(self, *, workers=2, clock=time.time, monotonic=time.monotonic,
                 changed=lambda: None):
        if not 1 <= workers <= 8:
            raise ValueError("invalid_worker_bound")
        self._workers, self._clock, self._monotonic = workers, clock, monotonic
        self._changed = changed
        self._sources, self._active = {}, 0
        self._lock = threading.RLock()
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._thread = None

    def register(self, name, fetch, *, hot_interval=15, idle_interval=120,
                 timeout=30, max_backoff=900):
        values = (hot_interval, idle_interval, timeout, max_backoff)
        if (not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", name)
                or not callable(fetch) or any(not math.isfinite(value) or value <= 0 for value in values)
                or idle_interval < hot_interval or max_backoff < hot_interval):
            raise ValueError("invalid_source")
        with self._lock:
            if name in self._sources:
                raise ValueError("duplicate_source")
            self._sources[name] = Source(name, fetch, *values)
        self._wake.set()

    def snapshot(self):
        with self._lock:
            return {name: copy.deepcopy(source.envelope) for name, source in self._sources.items()}

    def refresh(self, name):
        with self._lock:
            source = self._sources[name]
            source.due = max(self._monotonic(), source.blocked_until)
        self._wake.set()

    def _failure(self, source, category, retry_after=0):
        source.failures += 1
        delay = max(retry_after, min(source.max_backoff,
                    source.hot_interval * 2 ** min(source.failures - 1, 16)))
        source.blocked_until = self._monotonic() + delay
        source.due = source.blocked_until
        source.envelope.update(stale=True, error=category,
                               retry_at=self._clock() + delay)

    def _fetch(self, source):
        sample, error, retry = None, None, 0
        try:
            sample = source.fetch(source.deadline)
            if not isinstance(sample, Sample):
                raise ValueError("invalid_sample")
            data = copy_json_tree(sample.data)
        except ClientError as exc:
            # Validate again at publication even if adapter code mutated an error.
            error, retry = error_category(exc.category), exc.retry_after
        except Exception:
            error = "source_failed"
        with self._lock:
            if self._stop.is_set():
                source.in_flight = False
                self._active -= 1
                return
            late = source.timed_out or self._monotonic() >= source.deadline
            if late:
                if not source.timed_out:
                    self._failure(source, "deadline_exceeded")
            elif error:
                self._failure(source, error, retry)
            else:
                source.failures, source.blocked_until = 0, 0
                source.due = self._monotonic() + (source.hot_interval if sample.hot else source.idle_interval)
                source.envelope.update(data=data, observed_at=self._clock(),
                                       stale=False, error=None, retry_at=self._clock() +
                                       (source.hot_interval if sample.hot else source.idle_interval))
            source.in_flight = False
            source.envelope["in_flight"] = False
            self._active -= 1
        self._changed()
        self._wake.set()

    def tick(self):
        """Dispatch only available slots; tests may drive this without a clock loop."""
        changed = False
        with self._lock:
            if self._stop.is_set():
                return
            now = self._monotonic()
            for source in self._sources.values():
                if source.in_flight and now >= source.deadline and not source.timed_out:
                    source.timed_out = True
                    self._failure(source, "deadline_exceeded")
                    changed = True
                if (source.in_flight or source.due > now or source.blocked_until > now
                        or self._active >= self._workers):
                    continue
                source.in_flight, source.timed_out = True, False
                source.deadline = now + source.timeout
                source.envelope.update(attempted_at=self._clock(), in_flight=True)
                self._active += 1
                threading.Thread(target=self._fetch, args=(source,), daemon=True,
                                 name="cockpit-source").start()
                changed = True
        if changed:
            self._changed()

    def _loop(self):
        while not self._stop.is_set():
            self.tick()
            self._wake.wait(0.25)
            self._wake.clear()

    def start(self):
        with self._lock:
            if self._thread is None:
                self._thread = threading.Thread(target=self._loop, daemon=True, name="cockpit-poller")
                self._thread.start()

    def close(self):
        self._stop.set()
        self._wake.set()
        if self._thread is not None:
            self._thread.join(timeout=1)
