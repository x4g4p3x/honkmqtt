#!/usr/bin/env python3
"""Run repeatable loopback publish/receive batches against local MQTT brokers.

The runner compiles the Goose session once, starts only owned ephemeral broker
children, and keeps compilation, broker/package setup and MQTT connection setup
outside publish/echo timing. Raw per-echo latencies and per-batch throughput are
saved as JSON. This measures this example bridge architecture, not a general
MQTT client or library-only operation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import tempfile
import time
from typing import Any

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import run_interop as interop  # noqa: E402


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def command_version(args: list[str]) -> str:
    try:
        p = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, check=False)
    except OSError as exc:
        return f"unavailable: {exc}"
    lines = (p.stdout or "").strip().splitlines()
    return lines[0] if lines else f"exit={p.returncode}"


def compiler_selection(goose: str) -> str:
    try:
        p = subprocess.run([goose, "toolchain"], text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, check=False)
    except OSError as exc:
        return f"unavailable: {exc}"
    lines = (p.stdout or "").splitlines()
    selected = [line.strip() for line in lines if line.strip().startswith((
        "C compiler:", "style:", "id:",
    ))]
    for index, line in enumerate(lines):
        if line.strip().startswith("C compiler:") and index + 1 < len(lines):
            compiler_path = lines[index + 1].strip()
            if compiler_path.startswith("/"):
                selected.insert(1, f"compiler path: {compiler_path}")
            break
    return "; ".join(selected) if selected else f"unavailable (exit={p.returncode})"


def host_identity() -> dict[str, str]:
    os_release = "unknown"
    try:
        for line in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
            if line.startswith("PRETTY_NAME="):
                os_release = line.split("=", 1)[1].strip().strip('"')
                break
    except OSError:
        pass
    cpu_model = "unknown"
    try:
        for line in Path("/proc/cpuinfo").read_text(encoding="utf-8").splitlines():
            if line.lower().startswith("model name"):
                cpu_model = line.split(":", 1)[1].strip()
                break
    except OSError:
        pass
    return {
        "os": os_release,
        "kernel_release": platform.release(),
        "architecture": platform.machine(),
        "cpu_model": cpu_model,
        "libc": " ".join(platform.libc_ver()),
    }


def run_batch(binary: Path, broker: interop.BrokerProc, payload_size: int,
              warmup: int, iterations: int, label: str) -> dict[str, Any]:
    cmd = [
        sys.executable, str(HERE / "bridge.py"),
        "--host", "127.0.0.1", "--port", str(broker.port),
        "--goose", str(binary), "--session", str(HERE / "session.goose"),
        "--scenario", "benchmark", "--client-id", f"honk-bench-{label}",
        "--native", "--session-arg", str(payload_size), "--session-arg", str(warmup),
        "--session-arg", str(iterations), "--observe", "--rss-extra-pid",
        str(broker.proc.pid), "--case-timeout", "60",
    ]
    started = time.monotonic_ns()
    try:
        p = subprocess.run(cmd, text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, check=False, timeout=90)
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"outer 90-second timeout for {broker.name}/{payload_size}/{label}") from exc
    finished = time.monotonic_ns()
    starts: list[int] = []
    ends: list[int] = []
    measurement_seen = False
    measurement_ended = False
    exit_code = None
    rss: dict[str, Any] = {}
    events: list[str] = []
    for line in p.stdout.splitlines():
        if line.startswith("EVENT "):
            parts = line[6:].split()
            if parts and parts[0] == "BENCH_MEASURE_BEGIN":
                measurement_seen = True
            elif parts and parts[0] == "BENCH_MEASURE_END":
                measurement_ended = True
            elif measurement_seen and parts and parts[0] == "BENCH_SAMPLE":
                if len(parts) != 4 or int(parts[1]) != len(starts):
                    raise RuntimeError(f"malformed Goose timing event: {line}")
                starts.append(int(parts[2]))
                ends.append(int(parts[3]))
            else:
                events.append(" ".join(parts))
        elif line.startswith("EXIT "):
            exit_code = int(line[5:])
        elif line.startswith("RSS "):
            rss = json.loads(line[4:])
    if p.returncode != 0 or exit_code != 0:
        raise RuntimeError(
            f"bridge failed for {broker.name}/{payload_size}/{label}: "
            f"rc={p.returncode} goose={exit_code}\n{p.stderr}\n{p.stdout[-3000:]}"
        )
    if not measurement_seen or not measurement_ended or len(starts) != iterations or len(ends) != iterations:
        raise RuntimeError(
            f"incomplete measured exchanges: starts={len(starts)} ends={len(ends)} "
            f"expected={iterations}; events={events}; stderr={p.stderr}"
        )
    latencies = [end - begin for begin, end in zip(starts, ends)]
    elapsed = ends[-1] - starts[0]
    if elapsed <= 0 or any(ns <= 0 for ns in latencies):
        raise RuntimeError("non-positive measured interval")
    return {
        "label": label,
        "payload_bytes": payload_size,
        "warmup_exchanges": warmup,
        "measured_exchanges": iterations,
        "elapsed_ns_first_start_to_last_done": elapsed,
        "messages_per_second": iterations * 1_000_000_000 / elapsed,
        "payload_bytes_per_second": payload_size * iterations * 1_000_000_000 / elapsed,
        "latency_ns_per_echo": latencies,
        "latency_median_ns": statistics.median(latencies),
        "latency_p95_ns": sorted(latencies)[max(0, (len(latencies) * 95 + 99) // 100 - 1)],
        "rss_kib": rss,
        "runner_wall_ns_including_connect_and_teardown": finished - started,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--goose", default=os.environ.get("GOOSE", "goose"))
    ap.add_argument("--brokers", default="mosquitto,aedes")
    ap.add_argument("--json-out", type=Path, default=None)
    ap.add_argument("--samples", type=int, default=7)
    ap.add_argument("--iterations", type=int, default=1000)
    ap.add_argument("--warmup", type=int, default=30)
    ap.add_argument("--smoke", action="store_true", help="one short functional run per broker and size")
    args = ap.parse_args()
    if args.samples < 7 and not args.smoke or args.samples > 20:
        ap.error("--samples must be 7..20 (smoke mode uses one)")
    if args.iterations < 1 or args.iterations > 1000 or args.warmup < 0 or args.warmup > 50:
        ap.error("iterations must be 1..1000 and warmup 0..50")
    goose = args.goose
    if not interop.which(goose) and not Path(goose).exists():
        ap.error(f"Goose not found: {goose}")

    sizes = [16, 192]
    samples = 1 if args.smoke else args.samples
    iterations = min(args.iterations, 3) if args.smoke else args.iterations
    warmup = min(args.warmup, 1) if args.smoke else args.warmup
    wanted = [v.strip() for v in args.brokers.split(",") if v.strip()]
    if not wanted or len(set(wanted)) != len(wanted) or any(v not in {"mosquitto", "aedes"} for v in wanted):
        ap.error("--brokers accepts a nonempty, duplicate-free list from mosquitto,aedes")
    report: dict[str, Any] = {
        "schema": "honkmqtt-m3-broker-baseline-v1",
        "scope": "loopback QoS0 PUBLISH echo through Goose stream adapter and Python TCP bridge",
        "limitations": [
            "Only MQTT 3.1.1 CONNECT, SUBSCRIBE, QoS0 PUBLISH echo, DISCONNECT path exercised.",
            "Payload sizes are small and bounded by RX=TX=256; no claim for larger frames or other QoS.",
            "Loopback WSL measurements include Python IPC, socket calls, broker work and Goose codec/adapter work.",
            "No comparison or speedup claim; results describe this machine and exact harness only.",
            "RSS uses 1 ms /proc VmRSS polling for bridge, Goose child and broker; combined is sampled concurrent sum, excludes runner and setup/install.",
        ],
        "configuration": {
            "sizes_bytes": sizes,
            "warmup_per_connection": warmup,
            "samples_per_workload": samples,
            "iterations_per_sample": iterations,
            "allowed_limits": "payload sizes fixed at 16 and 192 bytes; --samples 7..20; --iterations 1..1000; --warmup 0..50; each batch has a 60 s bridge watchdog and 90 s outer subprocess timeout",
            "rx_capacity_bytes": 256,
            "tx_capacity_bytes": 256,
            "max_body_bytes": 251,
            "recv_max_bytes": 64,
            "bridge_ipc_max_bytes": 512,
            "timing": "Goose clock_ns() immediately before payload generation/encoding and after complete echoed PUBLISH parse, sequence/topic/payload validation, and stream commit; start/end ticks are buffered then emitted after the measured loop so no event IPC lies inside an echo; throughput is first start to final end",
            "setup_excluded": "native compile, npm install, broker start, TCP connect, MQTT CONNECT/SUBSCRIBE and per-connection warmup",
            "payload": "first four bytes are a big-endian per-exchange sequence; remaining bytes are deterministic from position and sequence; every echoed byte and topic checked in Goose before completion event, preventing an earlier echo from satisfying a later operation",
            "memory": "1ms nominal /proc VmRSS sampling during each batch; bridge, Goose child and broker component maxima are separate; combined_sampled_sum_max_kib is the maximum sum of page counts read sequentially in one nominal sampling round, may include shared pages and miss transients, and is not a strict instantaneous or unique-memory peak; excludes compile/setup/install and runner",
        },
        "identity": {
            "goose": command_version([goose, "version"]),
            "native_build": "goose build examples/tcp/session.goose -O2; C compiler optimization enabled",
            "compiler": command_version(["cc", "--version"]),
            "goose_compiler_selection": compiler_selection(goose),
            "python": platform.python_version() + " " + platform.python_implementation(),
            "node": command_version(["node", "--version"]),
            "npm": command_version(["npm", "--version"]),
            "host": host_identity(),
            "source_sha256": {
                name: sha256(path) for name, path in {
                    "session.goose": HERE / "session.goose",
                    "bridge.py": HERE / "bridge.py",
                    "bench_run.py": HERE / "bench_run.py",
                    "run_interop.py": HERE / "run_interop.py",
                    "stream.goose": ROOT / "examples" / "stream" / "stream.goose",
                    "honkmqtt.goose": ROOT / "honkmqtt.goose",
                    "mosquitto.conf.in": HERE / "brokers" / "mosquitto.conf.in",
                    "aedes_package.json": HERE / "brokers" / "package.json",
                    "aedes_server.js": HERE / "brokers" / "aedes_server.js",
                    "aedes_package_lock.json": HERE / "brokers" / "package-lock.json",
                }.items()
            },
        },
        "brokers": {},
        "mode": "smoke" if args.smoke else "timed",
    }
    aedes_td = None
    with tempfile.TemporaryDirectory(prefix="honkmqtt-m3-bench-") as tmp:
        work = Path(tmp)
        binary = work / "bench_session"
        build = subprocess.run(
            [goose, "build", str(HERE / "session.goose"), "-o", str(binary), "-O2"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
        )
        if build.returncode != 0:
            raise RuntimeError(f"native Goose build failed:\n{build.stdout}")
        report["identity"]["native_binary_sha256"] = sha256(binary)
        brokers: list[interop.BrokerProc] = []
        try:
            if "mosquitto" in wanted:
                brokers.append(interop.start_mosquitto(work / "mosquitto"))
            if "aedes" in wanted:
                aedes_td, install, provenance = interop.prepare_aedes_install()
                (work / "aedes").mkdir(exist_ok=True)
                brokers.append(interop.start_aedes(work / "aedes", install))
                report["identity"]["aedes_provenance"] = {
                    key: provenance[key]
                    for key in ("method", "package_json", "package_lock", "aedes_server",
                                "command", "aedes_version", "lock_sha256", "server_sha256")
                }
            for broker in brokers:
                entry: dict[str, Any] = {
                    "version": broker.version,
                    "listener": "ephemeral 127.0.0.1 child; runner does not manage system services",
                    "config_sha256": broker.conf_hash,
                    "workloads": {},
                }
                report["brokers"][broker.name] = entry
                for size in sizes:
                    # One discarded connection/run warms code and broker state.
                    warm = run_batch(binary, broker, size, warmup, min(iterations, 100),
                                     f"{broker.name}-warm-{size}")
                    batches = []
                    for idx in range(samples):
                        batches.append(run_batch(binary, broker, size, warmup, iterations,
                                                 f"{broker.name}-{size}-{idx + 1}"))
                    entry["workloads"][str(size)] = {
                        "warmup_run_discarded": warm,
                        "raw_samples": batches,
                        "throughput_messages_per_second_median": statistics.median(
                            x["messages_per_second"] for x in batches),
                        "throughput_messages_per_second_min": min(x["messages_per_second"] for x in batches),
                        "throughput_messages_per_second_max": max(x["messages_per_second"] for x in batches),
                        "batch_median_latency_ns_median": statistics.median(
                            x["latency_median_ns"] for x in batches),
                    }
                    print(f"complete {broker.name} payload={size} samples={samples}", flush=True)
        finally:
            for broker in brokers:
                broker.stop()
            if aedes_td is not None:
                aedes_td.cleanup()
    rendered = json.dumps(report, indent=2)
    print(rendered)
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(rendered + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
