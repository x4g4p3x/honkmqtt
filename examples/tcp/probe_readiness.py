#!/usr/bin/env python3
"""Focused probes for connect deadline + silent-child Aedes readiness."""

from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from bridge import BridgeError, connect_tcp  # noqa: E402
from run_interop import kill_reap, read_aedes_ready_port  # noqa: E402


def probe_expired_connect() -> None:
    deadline = time.monotonic() - 0.01
    try:
        connect_tcp("127.0.0.1", 1, deadline)
    except BridgeError as exc:
        if str(exc) != "CASE_TIMEOUT":
            raise AssertionError(f"expected CASE_TIMEOUT, got {exc}") from exc
        print("ok: expired connect_tcp rejects without fresh 2s fallback")
        return
    raise AssertionError("expired connect_tcp should fail")


def probe_silent_aedes_banner() -> None:
    # Child keeps stdout open but never emits AEDES_READY — must time out + reap.
    child = subprocess.Popen(
        [sys.executable, "-c", "import time, sys; time.sleep(30)"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        bufsize=0,
    )
    t0 = time.monotonic()
    try:
        read_aedes_ready_port(child, timeout_s=0.4)
        raise AssertionError("silent child should not report AEDES_READY")
    except RuntimeError as exc:
        elapsed = time.monotonic() - t0
        if elapsed > 1.5:
            raise AssertionError(f"banner wait not deadline-aware: {elapsed:.2f}s") from exc
        if "timeout" not in str(exc):
            raise AssertionError(f"unexpected ready error: {exc}") from exc
    finally:
        if child.poll() is None:
            kill_reap(child)
        else:
            raise AssertionError("silent child exited unexpectedly during probe")
    print("ok: silent-child AEDES_READY banner times out and child is reaped")


def main() -> int:
    probe_expired_connect()
    probe_silent_aedes_banner()
    print("probe_readiness: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
