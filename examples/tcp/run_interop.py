#!/usr/bin/env python3
"""Run HonkMQTT M3 TCP interop against Mosquitto and Aedes on loopback.

Starts ephemeral brokers, drives examples/tcp/session.goose through bridge.py,
records versions/config hashes and the case matrix. Does not claim protocol
conformance or production security.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

ROOT = Path(__file__).resolve().parents[2]
TCP_DIR = Path(__file__).resolve().parent
BROKERS = TCP_DIR / "brokers"
SESSION = TCP_DIR / "session.goose"
BRIDGE = TCP_DIR / "bridge.py"

SCENARIOS = ("positive", "malformed", "reconnect")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def which(name: str) -> Optional[str]:
    found = shutil.which(name)
    if found:
        return found
    # WSL often sees Windows Node only as node.exe under Program Files.
    for candidate in (
        "/mnt/c/Program Files/nodejs/node.exe",
        "/mnt/c/Program Files/nodejs/npm.cmd",
        r"C:\Program Files\nodejs\node.exe",
        r"C:\Program Files\nodejs\npm.cmd",
    ):
        if name in ("node", "node.exe") and candidate.endswith("node.exe") and Path(candidate).is_file():
            return candidate
        if name in ("npm", "npm.cmd") and candidate.endswith("npm.cmd") and Path(candidate).is_file():
            return candidate
    return None


def wait_port(host: str, port: int, timeout_s: float = 5.0) -> None:
    deadline = time.monotonic() + timeout_s
    last = None
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.2):
                return
        except OSError as exc:
            last = exc
            time.sleep(0.05)
    raise RuntimeError(f"port {host}:{port} not ready: {last}")


class BrokerProc:
    def __init__(self, name: str, version: str, port: int, proc: subprocess.Popen, conf_hash: str):
        self.name = name
        self.version = version
        self.port = port
        self.proc = proc
        self.conf_hash = conf_hash

    def stop(self) -> None:
        if self.proc.poll() is not None:
            return
        try:
            self.proc.send_signal(signal.SIGTERM)
            self.proc.wait(timeout=3)
        except Exception:
            self.proc.kill()
            self.proc.wait(timeout=2)


def start_mosquitto(workdir: Path) -> BrokerProc:
    mosq = which("mosquitto")
    if not mosq:
        raise RuntimeError("mosquitto not found on PATH")
    ver_proc = subprocess.run(
        [mosq, "-h"], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    version = "unknown"
    for line in ver_proc.stdout.splitlines():
        if line.lower().startswith("mosquitto version"):
            version = line.split()[-1]
            break
    port = free_port()
    workdir.mkdir(parents=True, exist_ok=True)
    template = (BROKERS / "mosquitto.conf.in").read_text(encoding="utf-8")
    conf_text = template.replace("@PORT@", str(port))
    conf_path = workdir / "mosquitto.conf"
    conf_path.write_text(conf_text, encoding="utf-8")
    conf_hash = hashlib.sha256(conf_text.encode("utf-8")).hexdigest()
    log_path = workdir / "mosquitto.log"
    logf = open(log_path, "wb")
    proc = subprocess.Popen(
        [mosq, "-c", str(conf_path)],
        stdout=logf,
        stderr=subprocess.STDOUT,
        cwd=str(workdir),
    )
    try:
        wait_port("127.0.0.1", port)
    except Exception:
        proc.kill()
        logf.close()
        raise
    return BrokerProc("mosquitto", version, port, proc, conf_hash)


def ensure_aedes_installed() -> None:
    pkg = BROKERS / "node_modules" / "aedes" / "package.json"
    if pkg.is_file():
        return
    npm = which("npm") or which("npm.cmd")
    if not npm:
        raise RuntimeError("npm not found; cannot install pinned aedes")
    subprocess.check_call(
        [npm, "install", "--no-fund", "--no-audit"],
        cwd=str(BROKERS),
    )


def start_aedes(workdir: Path) -> BrokerProc:
    ensure_aedes_installed()
    node = which("node") or which("node.exe")
    if not node:
        raise RuntimeError("node not found on PATH")
    version = json.loads((BROKERS / "node_modules" / "aedes" / "package.json").read_text())[
        "version"
    ]
    port = free_port()
    conf_hash = sha256_file(BROKERS / "aedes_server.js")
    log_path = workdir / "aedes.log"
    logf = open(log_path, "wb")
    proc = subprocess.Popen(
        [node, str(BROKERS / "aedes_server.js"), str(port)],
        stdout=subprocess.PIPE,
        stderr=logf,
        cwd=str(BROKERS),
    )
    assert proc.stdout is not None
    deadline = time.monotonic() + 5.0
    ready = False
    while time.monotonic() < deadline:
        line = proc.stdout.readline()
        if not line:
            break
        text = line.decode("utf-8", errors="replace").strip()
        if text.startswith("AEDES_READY"):
            ready = True
            break
    if not ready:
        proc.kill()
        logf.close()
        raise RuntimeError("aedes failed to become ready")
    wait_port("127.0.0.1", port)
    return BrokerProc("aedes", version, port, proc, conf_hash)


def run_case(
    goose: str,
    broker: BrokerProc,
    scenario: str,
    client_id: str,
) -> Dict:
    cmd = [
        sys.executable,
        str(BRIDGE),
        "--host",
        "127.0.0.1",
        "--port",
        str(broker.port),
        "--goose",
        goose,
        "--session",
        str(SESSION),
        "--scenario",
        scenario,
        "--client-id",
        client_id,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    events = []
    peer_close = None
    exit_code = None
    for line in proc.stdout.splitlines():
        if line.startswith("EVENT "):
            events.append(line[6:])
        elif line.startswith("PEER_CLOSE "):
            peer_close = line[11:]
        elif line.startswith("EXIT "):
            exit_code = int(line[5:])
    ok = proc.returncode == 0 and exit_code == 0
    if peer_close is None:
        for e in events:
            if e.startswith("PEER_CLOSE reason="):
                peer_close = e.split("=", 1)[1]
                break
    if scenario == "positive":
        needed = [
            "CONNACK session=0 code=0",
            "SUBACK id=7 code=0",
            "PUBLISH qos0 sent",
            "PUBLISH verified topic=m3/t payload=hi!",
            "PINGRESP ok",
            "DISCONNECT sent",
        ]
        ok = ok and all(any(e == n for e in events) for n in needed)
    elif scenario == "malformed":
        ok = ok and any(e.startswith("MALFORMED sent") for e in events)
        # Confirmed peer closure must be EOF or RESET — never TIMEOUT/other.
        ok = ok and peer_close in ("EOF", "RESET")
        close_idxs = [
            i for i, e in enumerate(events) if e.startswith("PEER_CLOSE reason=")
        ]
        ok = ok and len(close_idxs) >= 1
        if close_idxs:
            reason = events[close_idxs[0]].split("=", 1)[-1]
            ok = ok and reason in ("EOF", "RESET")
            # No PINGRESP before the confirmed close (post-reconnect ping is OK).
            ok = ok and not any(
                events[i].startswith("PINGRESP") for i in range(close_idxs[0])
            )
        ok = ok and any(e == "RECONNECTED after malformed" for e in events)
        ok = ok and sum(1 for e in events if e.startswith("CONNACK")) >= 2
    elif scenario == "reconnect":
        ok = ok and any(e == "RECONNECTED" for e in events)
        connacks = [e for e in events if e.startswith("CONNACK")]
        ok = ok and len(connacks) >= 2
        pings = [e for e in events if e.startswith("PINGRESP")]
        ok = ok and len(pings) >= 2

    return {
        "broker": broker.name,
        "broker_version": broker.version,
        "broker_conf_sha256": broker.conf_hash,
        "scenario": scenario,
        "client_id": client_id,
        "ok": ok,
        "bridge_returncode": proc.returncode,
        "goose_exit": exit_code,
        "events": events,
        "peer_close": peer_close,
        "stderr": proc.stderr.strip(),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--goose", default=os.environ.get("GOOSE", "goose"))
    ap.add_argument(
        "--brokers",
        default="mosquitto,aedes",
        help="comma list: mosquitto,aedes",
    )
    ap.add_argument("--json-out", type=Path, default=None)
    args = ap.parse_args()

    goose = args.goose
    if not which(goose) and not Path(goose).exists():
        print(f"goose not found: {goose}", file=sys.stderr)
        return 2

    wanted = [b.strip() for b in args.brokers.split(",") if b.strip()]
    results: List[Dict] = []
    meta = {
        "honkmqtt_root": str(ROOT),
        "session_sha256": sha256_file(SESSION),
        "bridge_sha256": sha256_file(BRIDGE),
        "stream_sha256": sha256_file(ROOT / "examples" / "stream" / "stream.goose"),
        "bounds": {
            "rx_cap": 256,
            "tx_cap": 256,
            "max_body": 251,
            "recv_max": 64,
            "recv_cap_rule": "min(64, rx_free)",
            "ipc_max": 512,
            "connect_timeout_s": 2.0,
            "io_timeout_s": 2.0,
            "case_timeout_s": 15.0,
            "send_ack": "socket.send byte count; Goose commit_tx(exact)",
        },
        "architecture": (
            "Python TCP bridge moves bounded socket chunks and returns actual "
            "send() counts; Goose applies stream::feed/frame/commit_rx and "
            "stream::enqueue/drain/commit_tx plus typed codecs. Python does not "
            "frame MQTT. Core honkmqtt.goose unchanged."
        ),
        "broker_service_note": (
            "apt mosquitto postinst may enable systemd mosquitto.service; this "
            "harness stops/disables that unit and uses only ephemeral 127.0.0.1 "
            "listeners with TemporaryDirectory cleanup."
        ),
    }

    with tempfile.TemporaryDirectory(prefix="honkmqtt-m3-") as td:
        work = Path(td)
        brokers: List[BrokerProc] = []
        try:
            if "mosquitto" in wanted:
                brokers.append(start_mosquitto(work / "mosquitto"))
            if "aedes" in wanted:
                (work / "aedes").mkdir(exist_ok=True)
                brokers.append(start_aedes(work / "aedes"))

            for broker in brokers:
                for scenario in SCENARIOS:
                    cid = f"honk-m3-{broker.name}-{scenario}"
                    print(f"== {broker.name}@{broker.version} {scenario} :{broker.port}", flush=True)
                    results.append(run_case(goose, broker, scenario, cid))
        finally:
            for b in brokers:
                b.stop()

    failed = [r for r in results if not r["ok"]]
    report = {"meta": meta, "results": results, "failed": len(failed)}
    text = json.dumps(report, indent=2)
    print(text)
    if args.json_out:
        args.json_out.write_text(text + "\n", encoding="utf-8")

    # Human summary matrix
    print("\nMATRIX")
    for r in results:
        pc = r.get("peer_close") or "-"
        print(
            f"  {r['broker']:10} {r['scenario']:10} "
            f"{'PASS' if r['ok'] else 'FAIL'} peer_close={pc}"
        )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
