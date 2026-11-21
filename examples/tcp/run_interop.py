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
    # Prefer Linux Node on WSL loopback. Do not fall back to Windows node.exe —
    # it binds on the Windows network namespace and is unreachable from WSL.
    return None


def wait_port(
    host: str,
    port: int,
    timeout_s: float = 5.0,
    child: Optional[subprocess.Popen] = None,
) -> None:
    """Bounded loopback accept probe; fail early if ``child`` has exited."""
    deadline = time.monotonic() + timeout_s
    last = None
    while time.monotonic() < deadline:
        if child is not None and child.poll() is not None:
            raise RuntimeError(f"child exited before listen rc={child.returncode}")
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


MOSQUITTO_DEB_PIN = "2.0.18-1build3"


def aedes_parent_dir() -> Optional[Path]:
    """Optional parent for an owned Aedes TemporaryDirectory (native FS)."""
    raw = os.environ.get("HONKMQTT_AEDES_NPM", "").strip()
    if not raw:
        return None
    parent = Path(raw)
    parent.mkdir(parents=True, exist_ok=True)
    return parent


def prepare_aedes_install(
    parent: Optional[Path] = None,
) -> Tuple[tempfile.TemporaryDirectory, Path, Dict]:
    """Always ``npm ci`` into a fresh owned TemporaryDirectory.

    ``parent`` (or ``HONKMQTT_AEDES_NPM``) is only a native-FS parent for the
    temp dir — never deleted, never reused as a stale install root. Caller must
    keep the TemporaryDirectory alive for the matrix, then clean it up.
    """
    if parent is None:
        parent = aedes_parent_dir()
    lock = BROKERS / "package-lock.json"
    if not lock.is_file():
        raise RuntimeError(
            f"missing {lock}; run 'npm ci' with the brokers lockfile first"
        )
    npm = which("npm") or which("npm.cmd")
    if not npm:
        raise RuntimeError("npm not found; cannot install pinned aedes (npm ci)")
    td = tempfile.TemporaryDirectory(
        prefix="honkmqtt-aedes-",
        dir=str(parent) if parent is not None else None,
    )
    dest = Path(td.name)
    for name in ("package.json", "package-lock.json", "aedes_server.js"):
        (dest / name).write_bytes((BROKERS / name).read_bytes())
    cmd = [npm, "ci", "--no-fund", "--no-audit"]
    subprocess.check_call(cmd, cwd=str(dest))
    marker = dest / "node_modules" / "aedes" / "package.json"
    if not marker.is_file():
        td.cleanup()
        raise RuntimeError("npm ci did not install aedes")
    version = json.loads(marker.read_text(encoding="utf-8"))["version"]
    provenance = {
        "method": "npm ci into owned TemporaryDirectory",
        "parent": str(parent) if parent is not None else None,
        "install_dir": str(dest),
        "package_json": "examples/tcp/brokers/package.json",
        "package_lock": "examples/tcp/brokers/package-lock.json",
        "aedes_server": "examples/tcp/brokers/aedes_server.js",
        "command": " ".join(cmd),
        "aedes_version": version,
        "lock_sha256": sha256_file(lock),
        "server_sha256": sha256_file(BROKERS / "aedes_server.js"),
    }
    return td, dest, provenance


def extract_mosquitto_deb(
    workdir: Path,
    pin: str = MOSQUITTO_DEB_PIN,
) -> Tuple[Path, Dict]:
    """``apt-get download`` + ``dpkg-deb -x`` into ``workdir``; return binary + provenance.

    Does not install via dpkg/apt, and never touches systemd units.
    """
    workdir.mkdir(parents=True, exist_ok=True)
    dl = workdir / "deb"
    root = workdir / "root"
    dl.mkdir(exist_ok=True)
    root.mkdir(exist_ok=True)
    pkg = f"mosquitto={pin}"
    download_cmd = ["apt-get", "download", pkg]
    try:
        subprocess.check_call(download_cmd, cwd=str(dl))
    except (OSError, subprocess.CalledProcessError) as exc:
        # Fall back to whatever version apt can fetch, recording the failure.
        fallback = ["apt-get", "download", "mosquitto"]
        try:
            subprocess.check_call(fallback, cwd=str(dl))
            download_cmd = fallback
            pin_note = f"pin {pin} failed ({exc}); downloaded unpinned mosquitto"
        except (OSError, subprocess.CalledProcessError) as exc2:
            raise RuntimeError(
                f"apt-get download failed for {pkg} and unpinned mosquitto: {exc2}"
            ) from exc2
    else:
        pin_note = f"downloaded {pkg}"
    debs = sorted(dl.glob("mosquitto_*.deb"))
    if not debs:
        raise RuntimeError(f"no mosquitto_*.deb after apt-get download in {dl}")
    deb = debs[-1]
    extract_cmd = ["dpkg-deb", "-x", str(deb), str(root)]
    subprocess.check_call(extract_cmd)
    candidates = [
        root / "usr" / "sbin" / "mosquitto",
        root / "usr" / "bin" / "mosquitto",
    ]
    binary = next((c for c in candidates if c.is_file()), None)
    if binary is None:
        raise RuntimeError(f"mosquitto binary missing under {root}")
    # Prepend the directory that actually contains the binary.
    bin_dir = str(binary.parent)
    os.environ["PATH"] = bin_dir + os.pathsep + os.environ.get("PATH", "")
    provenance = {
        "method": "apt-get download + dpkg-deb -x (no dpkg -i; system unit untouched)",
        "requested_pin": pin,
        "note": pin_note,
        "deb_file": deb.name,
        "deb_sha256": sha256_file(deb),
        "extract_root": str(root),
        "binary": str(binary),
        "path_prepend": bin_dir,
        "download_command": " ".join(download_cmd),
        "extract_command": " ".join(extract_cmd),
    }
    return binary, provenance


def start_aedes(workdir: Path, install: Path) -> BrokerProc:
    """Start Aedes; readiness is port listen + live child (no stdout banner)."""
    node = which("node") or which("node.exe")
    if not node:
        raise RuntimeError("node not found on PATH")
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
    # Discard stdout; readiness is wait_port + poll (silent children time out).
    proc = subprocess.Popen(
        [node, str(install / "aedes_server.js"), str(port)],
        stdout=subprocess.DEVNULL,
        stderr=logf,
        cwd=str(install),
    )
    try:
        wait_port("127.0.0.1", port, timeout_s=5.0, child=proc)
        if proc.poll() is not None:
            raise RuntimeError(f"aedes exited during startup rc={proc.returncode}")
    except Exception as exc:
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
        raise RuntimeError(f"aedes failed to become ready: {exc}; log={err}") from exc
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
    ap.add_argument(
        "--extract-mosquitto",
        action="store_true",
        help=(
            f"apt-get download mosquitto={MOSQUITTO_DEB_PIN} + dpkg-deb -x into "
            "a fresh work dir; prepend that binary's dir to PATH (no dpkg -i)"
        ),
    )
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
    meta: Dict = {
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
            "recv_cap_rule": (
                "min(64, rx_tail_free); compact when tail full; "
                "reset empty window at capacity"
            ),
            "connect_deadline": "fail if remaining<=0; else min(2.0, remaining)",
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
            "npm ci --no-fund --no-audit from brokers/package-lock.json into an "
            "owned TemporaryDirectory (optional HONKMQTT_AEDES_NPM parent only); "
            "readiness via wait_port + child.poll (no stdout banner)"
        ),
    }

    aedes_td: Optional[tempfile.TemporaryDirectory] = None
    with tempfile.TemporaryDirectory(prefix="honkmqtt-m3-") as td:
        work = Path(td)
        brokers: List[BrokerProc] = []
        try:
            if "mosquitto" in wanted:
                if args.extract_mosquitto:
                    _, mosq_prov = extract_mosquitto_deb(work / "mosquitto_pkg")
                    meta["mosquitto_provenance"] = mosq_prov
                else:
                    mosq_bin = which("mosquitto")
                    meta["mosquitto_provenance"] = {
                        "method": "PATH binary (no --extract-mosquitto)",
                        "binary": mosq_bin,
                        "note": "reused host PATH mosquitto; system unit untouched",
                    }
                brokers.append(start_mosquitto(work / "mosquitto"))
            if "aedes" in wanted:
                aedes_td, aedes_install, aedes_prov = prepare_aedes_install()
                meta["aedes_provenance"] = aedes_prov
                (work / "aedes").mkdir(exist_ok=True)
                brokers.append(start_aedes(work / "aedes", aedes_install))

            for broker in brokers:
                for scenario in SCENARIOS:
                    cid = f"honk-m3-{broker.name}-{scenario}"
                    print(f"== {broker.name}@{broker.version} {scenario} :{broker.port}", flush=True)
                    results.append(run_case(goose, broker, scenario, cid))
        finally:
            for b in brokers:
                b.stop()
            if aedes_td is not None:
                aedes_td.cleanup()

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
