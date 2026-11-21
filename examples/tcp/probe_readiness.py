#!/usr/bin/env python3
"""Focused probes: connect deadline, silent Aedes banner, occupied Mosquitto port."""

from __future__ import annotations

import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from bridge import BridgeError, connect_tcp  # noqa: E402
from run_interop import (  # noqa: E402
    BROKERS,
    kill_reap,
    read_aedes_ready_port,
    wait_mosquitto_ready_log,
    which,
)


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
        [sys.executable, "-c", "import time; time.sleep(30)"],
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


def probe_mosquitto_occupied_port() -> None:
    """Hold a real loopback port; Mosquitto must fail ready (no running) and be reaped."""
    mosq = which("mosquitto")
    if not mosq:
        raise AssertionError("mosquitto not on PATH for occupied-port probe")
    holder = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    holder.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    holder.bind(("127.0.0.1", 0))
    holder.listen(1)
    port = int(holder.getsockname()[1])
    work = Path(tempfile.mkdtemp(prefix="honkmqtt-mosq-probe-"))
    template = (BROKERS / "mosquitto.conf.in").read_text(encoding="utf-8")
    conf_path = work / "mosquitto.conf"
    conf_path.write_text(template.replace("@PORT@", str(port)), encoding="utf-8")
    log_path = work / "mosquitto.log"
    logf = open(log_path, "wb", buffering=0)
    cmd = [mosq, "-c", str(conf_path)]
    stdbuf = which("stdbuf")
    if stdbuf:
        cmd = [stdbuf, "-oL", "-eL", *cmd]
    child = subprocess.Popen(
        cmd,
        stdout=logf,
        stderr=subprocess.STDOUT,
        cwd=str(work),
    )
    try:
        wait_mosquitto_ready_log(child, log_path, port, timeout_s=3.0)
        raise AssertionError("occupied port must not become mosquitto-ready")
    except RuntimeError as exc:
        text = str(exc)
        if "before ready" not in text and "ready timeout" not in text:
            raise AssertionError(f"unexpected occupied-port error: {exc}") from exc
        log = log_path.read_text(encoding="utf-8", errors="replace")
        if f"Opening ipv4 listen socket on port {port}." not in log:
            raise AssertionError(f"expected pre-bind listen notice; log={log!r}")
        if "mosquitto version" in log and " running" in log:
            # Full "… running" must not appear on bind failure.
            if any(
                ln.strip().endswith(" running") and "mosquitto version" in ln
                for ln in log.splitlines()
            ):
                raise AssertionError(f"running line must not appear on EADDRINUSE; log={log!r}")
    finally:
        if child.poll() is None:
            kill_reap(child, logf)
        else:
            try:
                logf.close()
            except Exception:
                pass
        holder.close()
        if child.poll() is None:
            raise AssertionError("occupied-port mosquitto was not reaped")
    print("ok: occupied-port Mosquitto fails ready (listen≠running) and is reaped")


def main() -> int:
    probe_expired_connect()
    probe_silent_aedes_banner()
    probe_mosquitto_occupied_port()
    print("probe_readiness: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
