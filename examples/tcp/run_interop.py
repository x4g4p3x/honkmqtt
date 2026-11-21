#!/usr/bin/env python3
"""Run HonkMQTT M3 TCP interop against Mosquitto and Aedes on loopback.

Starts ephemeral brokers, drives examples/tcp/session.goose through bridge.py,
records versions/config hashes and the case matrix. Does not claim protocol
conformance or production security.
"""

from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
import select
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
    # Prefer Linux Node on WSL loopback. Do not fall back to Windows node.exe —
    # it binds on the Windows network namespace and is unreachable from WSL.
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


def aedes_install_dir(workdir: Path) -> Path:
    """Return a native-FS directory with ``npm ci`` tree for Aedes.

    Installing ``node_modules`` on /mnt/c (9p/drvfs) can leave truncated
    package.json files. Prefer a Linux temp dir under ``workdir``.
    """
    dest = workdir / "aedes_npm"
    marker = dest / "node_modules" / "aedes" / "package.json"
    if marker.is_file():
        try:
            json.loads(marker.read_text(encoding="utf-8"))
            return dest
        except (OSError, json.JSONDecodeError):
            pass
    lock = BROKERS / "package-lock.json"
    if not lock.is_file():
        raise RuntimeError(
            f"missing {lock}; run 'npm ci' with the brokers lockfile first"
        )
    npm = which("npm") or which("npm.cmd")
    if not npm:
        raise RuntimeError("npm not found; cannot install pinned aedes (npm ci)")
    dest.mkdir(parents=True, exist_ok=True)
    for name in ("package.json", "package-lock.json", "aedes_server.js"):
        src = BROKERS / name
        (dest / name).write_bytes(src.read_bytes())
    subprocess.check_call(
        [npm, "ci", "--no-fund", "--no-audit"],
        cwd=str(dest),
    )
    if not marker.is_file():
        raise RuntimeError("npm ci did not install aedes")
    json.loads(marker.read_text(encoding="utf-8"))  # validate readable JSON
    return dest


def start_aedes(workdir: Path) -> BrokerProc:
    node = which("node") or which("node.exe")
    if not node:
        raise RuntimeError("node not found on PATH")
    install = aedes_install_dir(workdir)
    aedes_pkg = install / "node_modules" / "aedes" / "package.json"
    try:
        version = json.loads(aedes_pkg.read_text(encoding="utf-8"))["version"]
    except (OSError, json.JSONDecodeError, KeyError):
        version = json.loads((BROKERS / "package.json").read_text(encoding="utf-8"))[
            "dependencies"
        ]["aedes"]
    port = free_port()
    conf_hash = sha256_file(BROKERS / "aedes_server.js")
    log_path = workdir / "aedes.log"
    logf = open(log_path, "wb")
    proc = subprocess.Popen(
        [node, str(install / "aedes_server.js"), str(port)],
        stdout=subprocess.PIPE,
        stderr=logf,
        cwd=str(install),
        bufsize=0,
    )
    assert proc.stdout is not None
    deadline = time.monotonic() + 5.0
    ready = False
    buf = bytearray()
    fd = proc.stdout.fileno()
    try:
        while time.monotonic() < deadline and not ready:
            left = deadline - time.monotonic()
            if left <= 0:
                break
            readable, _, _ = select.select([fd], [], [], left)
            if not readable:
                break
            try:
                chunk = os.read(fd, 256)
            except OSError as exc:
                if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    continue
                break
            if not chunk:
                break
            buf.extend(chunk)
            while b"\n" in buf:
                line, _, rest = buf.partition(b"\n")
                buf[:] = rest
                text = line.decode("utf-8", errors="replace").strip()
                if text.startswith("AEDES_READY"):
                    ready = True
                    break
            if len(buf) > 4096:
                break
    finally:
        if not ready:
            try:
                proc.kill()
            except OSError:
                pass
            try:
                proc.wait(timeout=2)
            except Exception:
                pass
            logf.close()
            err = ""
            try:
                err = Path(log_path).read_text(encoding="utf-8", errors="replace")[:500]
            except OSError:
                pass
            raise RuntimeError(f"aedes failed to become ready: {err}")
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
    # Bridge-observed close only (PEER_CLOSE line from bridge.py). Do not
    # promote Goose EVENT strings — those can be emitted without a RECV.
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
        # Require socket-observed close from the bridge, not event fallback.
        ok = ok and peer_close in ("EOF", "RESET")
        close_idxs = [
            i for i, e in enumerate(events) if e.startswith("PEER_CLOSE reason=")
        ]
        ok = ok and len(close_idxs) >= 1
        if close_idxs and peer_close:
            ok = ok and events[close_idxs[0]].endswith(peer_close)
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

    def cmd_version(argv: List[str]) -> str:
        try:
            out = subprocess.run(
                argv,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            line = (out.stdout or "").strip().splitlines()
            return line[0] if line else "unknown"
        except OSError:
            return "unknown"

    goose_ver = cmd_version([goose, "version"])
    meta = {
        "repo_paths": {
            "session": "examples/tcp/session.goose",
            "bridge": "examples/tcp/bridge.py",
            "stream": "examples/stream/stream.goose",
            "brokers": "examples/tcp/brokers",
        },
        "session_sha256": sha256_file(SESSION),
        "bridge_sha256": sha256_file(BRIDGE),
        "stream_sha256": sha256_file(ROOT / "examples" / "stream" / "stream.goose"),
        "toolchain": {
            "python": sys.version.split()[0],
            "python_implementation": sys.version.split("\n")[0],
            "node": cmd_version(["node", "--version"]),
            "npm": cmd_version(["npm", "--version"]),
            "goose": goose_ver,
            "os_uname": " ".join(os.uname()) if hasattr(os, "uname") else sys.platform,
            "platform": sys.platform,
        },
        "bounds": {
            "rx_cap": 256,
            "tx_cap": 256,
            "max_body": 251,
            "recv_max": 64,
            "recv_cap_rule": "min(64, rx_tail_free); compact when tail full",
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
        "broker_listeners": (
            "Harness starts only ephemeral 127.0.0.1 Mosquitto/Aedes children "
            "in a TemporaryDirectory (cleaned up on exit). It does not stop, "
            "disable, or manage any system mosquitto.service unit."
        ),
        "aedes_install": (
            "npm ci --no-fund --no-audit from brokers/package-lock.json into a "
            "native temp directory (avoids corrupted node_modules on /mnt/c)"
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
