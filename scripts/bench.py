#!/usr/bin/env python3
"""Run HonkMQTT optimized-build baseline workloads with serialized samples.

Builds native -O2 executables, discards warmup runs, then records at least
seven steady-state samples per workload. Timing boundary: the workload's own
steady_seconds (loop only; excludes process startup). Checksums must match
expected values. This script does not assert wall-clock budgets.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent

WORKLOADS = (
    {
        "name": "encode_frame_match",
        "source": Path("tests/benchmark.goose"),
        "args": [
            "sensor reading",
            "sensors/+/temperature",
            "sensors/kitchen/temperature",
            "sensors/kitchen/humidity",
        ],
        "expected_checksum": 16500000,
    },
    {
        "name": "publish_parse",
        "source": Path("tests/bench_publish.goose"),
        "args": [],
        "expected_checksum": 4679000000,
    },
)


def run(command: list[str], *, label: str) -> subprocess.CompletedProcess[str]:
    print(f"+ {' '.join(command)}", flush=True)
    result = subprocess.run(
        command,
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise SystemExit(f"FAILED: {label} (exit {result.returncode})")
    return result


def executable_for(source: Path) -> Path:
    built = source.parent / source.stem
    if os.name == "nt":
        return built.with_suffix(".exe")
    return built


def parse_metrics(output: str) -> dict[str, str]:
    metrics: dict[str, str] = {}
    for line in output.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        metrics[key.strip()] = value.strip()
    for required in ("workload", "iterations", "checksum", "steady_seconds"):
        if required not in metrics:
            raise SystemExit(f"missing {required} in workload output:\n{output}")
    return metrics


def goose_bin() -> str:
    goose = shutil.which(os.environ.get("GOOSE", "goose"))
    if not goose:
        raise SystemExit("Goose executable not found; set GOOSE or add goose to PATH.")
    return goose


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--warmup", type=int, default=1, help="discarded runs per workload (default 1)")
    parser.add_argument("--samples", type=int, default=7, help="recorded samples per workload (default 7)")
    args = parser.parse_args()
    if args.warmup < 0 or args.samples < 7:
        raise SystemExit("--samples must be >= 7; --warmup must be >= 0")

    goose = goose_bin()
    toolchain = run([goose, "toolchain"], label="goose toolchain")
    version = run([goose, "version"], label="goose version")

    print("=== environment ===")
    print(f"machine={platform.node()}")
    print(f"platform={platform.platform()}")
    print(f"python={sys.version.split()[0]}")
    print("goose_version:")
    print(version.stdout.strip() or version.stderr.strip())
    print("goose_toolchain:")
    print((toolchain.stdout or toolchain.stderr).strip())
    print(f"build=goose build -O2 (default optimized inlining)")
    print(f"timing_boundary=steady_seconds from workload clock() around timed loop only")
    print(f"warmup={args.warmup} samples={args.samples} serialized=yes")
    print()

    for workload in WORKLOADS:
        source = workload["source"]
        exe = executable_for(ROOT / source)
        if exe.is_file():
            exe.unlink()
        run([goose, "build", "-O2", str(source.as_posix())], label=f"build {source}")
        if not exe.is_file():
            raise SystemExit(f"missing native executable {exe}")

        command = [str(exe), *workload["args"]]
        for _ in range(args.warmup):
            warm = run(command, label=f"warmup {workload['name']}")
            metrics = parse_metrics(warm.stdout)
            if int(metrics["checksum"]) != workload["expected_checksum"]:
                raise SystemExit(
                    f"checksum mismatch during warmup for {workload['name']}: "
                    f"{metrics['checksum']} != {workload['expected_checksum']}"
                )

        samples: list[float] = []
        print(f"=== workload {workload['name']} ===")
        print(f"source={source.as_posix()}")
        print(f"command={' '.join(command)}")
        print(f"expected_checksum={workload['expected_checksum']}")
        for index in range(args.samples):
            result = run(command, label=f"sample {workload['name']}#{index + 1}")
            metrics = parse_metrics(result.stdout)
            if metrics["workload"] != workload["name"]:
                raise SystemExit(f"unexpected workload label {metrics['workload']}")
            checksum = int(metrics["checksum"])
            if checksum != workload["expected_checksum"]:
                raise SystemExit(
                    f"checksum mismatch for {workload['name']} sample {index + 1}: "
                    f"{checksum} != {workload['expected_checksum']}"
                )
            seconds = float(metrics["steady_seconds"])
            samples.append(seconds)
            print(
                f"sample={index + 1} iterations={metrics['iterations']} "
                f"checksum={checksum} steady_seconds={seconds:.9f}"
            )

        ordered = sorted(samples)
        mean = sum(samples) / len(samples)
        print(
            f"summary n={len(samples)} min={ordered[0]:.9f} "
            f"median={ordered[len(ordered) // 2]:.9f} max={ordered[-1]:.9f} "
            f"mean={mean:.9f}"
        )
        print()

        for path in (exe, exe.with_suffix(".obj"), exe.with_suffix(".o"), exe.with_suffix(".pdb")):
            if path.is_file():
                try:
                    path.unlink()
                except OSError as error:
                    print(f"warning: could not remove {path}: {error}", file=sys.stderr)

    print("HonkMQTT baseline run complete.")
    print(
        "Limitations: single-machine local samples; not CI SLA; not a throughput "
        "guarantee; process startup excluded from steady_seconds; no network I/O."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
