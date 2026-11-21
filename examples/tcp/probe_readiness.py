#!/usr/bin/env python3
"""Focused probes for connect deadline + silent-child Aedes readiness."""

from __future__ import annotations

import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from bridge import BridgeError, connect_tcp  # noqa: E402
from run_interop import wait_port  # noqa: E402


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


def probe_silent_child_timeout() -> None:
    # Child that never binds; wait_port must time out and leave it for reap.
    child = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(30)"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = int(sock.getsockname()[1])
    sock.close()  # nothing listening
    t0 = time.monotonic()
    try:
        wait_port("127.0.0.1", port, timeout_s=0.4, child=child)
        raise AssertionError("wait_port should time out for silent non-listener")
    except RuntimeError as exc:
        elapsed = time.monotonic() - t0
        if elapsed > 1.5:
            raise AssertionError(f"wait_port not deadline-aware: {elapsed:.2f}s") from exc
        if "not ready" not in str(exc):
            raise AssertionError(f"unexpected wait_port error: {exc}") from exc
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=2)
        else:
            raise AssertionError("silent child exited unexpectedly during probe")
    print("ok: silent-child wait_port times out and child is reaped")


def main() -> int:
    probe_expired_connect()
    probe_silent_child_timeout()
    print("probe_readiness: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
