#!/usr/bin/env python3
"""Run HonkMQTT's deterministic Goose tests from one entry point.

By default this runs tests/test.goose, tests/publish.goose,
tests/publish_encode.goose, tests/pubresp.goose, tests/connack.goose,
tests/coverage.goose, tests/api.goose, and tests/fuzz.goose in the in-process
Goose runner, once normally and once with --debug. Pass --native to also goose
build and execute each program when a C compiler is available; pass
--require-native to fail if native work is skipped or unavailable. Set GOOSE
to override the Goose executable.

Native mode removes each target's pre-existing build product before building.
If that executable cannot be removed, native work aborts for the target so a
stale binary cannot be executed. Toolchain launch failures, nonzero toolchain
exits, empty C compiler detail, and unrecognized toolchain output are errors;
only an explicit "C compiler: not found" response may skip native builds.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Literal

ROOT = Path(__file__).resolve().parent.parent
TESTS = (
    Path("tests/test.goose"),
    Path("tests/publish.goose"),
    Path("tests/publish_encode.goose"),
    Path("tests/pubresp.goose"),
    Path("tests/connack.goose"),
    Path("tests/coverage.goose"),
    Path("tests/api.goose"),
    Path("tests/fuzz.goose"),
)
SIDE_SUFFIXES = (".obj", ".o", ".pdb", ".ilk")

ToolchainKind = Literal["available", "missing", "error"]


def run(command: list[str], *, label: str) -> bool:
    """Run a command. Return True when it fails."""
    print(f"+ {' '.join(command)}", flush=True)
    try:
        result = subprocess.run(command, cwd=ROOT)
    except OSError as error:
        print(f"FAILED: {label} ({error})", file=sys.stderr)
        return True
    if result.returncode != 0:
        print(f"FAILED: {label} (exit {result.returncode})", file=sys.stderr)
        return True
    return False


def executable_for(source: Path) -> Path:
    built = source.parent / source.stem
    if os.name == "nt":
        return built.with_suffix(".exe")
    return built


def artifact_paths(executable: Path) -> list[Path]:
    paths = [executable]
    for suffix in SIDE_SUFFIXES:
        paths.append(executable.with_suffix(suffix))
    return paths


def clear_build_product(executable: Path) -> bool:
    """Remove build products for executable.

    Return True when the executable itself could not be cleared while present,
    or when an unlink failed for a related artifact before a native build.
    Missing paths are fine.
    """
    failed = False
    for path in artifact_paths(executable):
        if not path.is_file():
            continue
        try:
            path.unlink()
        except OSError as error:
            print(f"FAILED: could not remove {path}: {error}", file=sys.stderr)
            failed = True
    if executable.is_file():
        print(
            f"FAILED: executable still present after removal attempt: {executable}",
            file=sys.stderr,
        )
        failed = True
    return failed


def probe_c_compiler(goose: str) -> tuple[ToolchainKind, str]:
    """Classify `goose toolchain` C compiler status.

    Returns (kind, detail):
    - available: detail is the C compiler summary line
    - missing: Goose explicitly reported no C compiler
    - error: launch failure, nonzero exit, empty C compiler detail, or
      unrecognized output
    """
    try:
        result = subprocess.run(
            [goose, "toolchain"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except OSError as error:
        return "error", f"FAILED: could not launch `goose toolchain` ({error})"

    text = (result.stdout or "") + (result.stderr or "")
    if result.returncode != 0:
        detail = text.strip() or f"exit {result.returncode}"
        return "error", f"FAILED: `goose toolchain` exited {result.returncode}: {detail}"

    for line in text.splitlines():
        stripped = line.strip()
        lowered = stripped.lower()
        if not lowered.startswith("c compiler:"):
            continue
        detail = stripped.split(":", 1)[1].strip()
        detail_lower = detail.lower()
        if not detail:
            return "error", f"FAILED: unrecognized `goose toolchain` output: {stripped}"
        if detail_lower.startswith("not found"):
            return "missing", stripped
        return "available", stripped

    snippet = text.strip() or "(empty toolchain output)"
    return "error", f"FAILED: unrecognized `goose toolchain` output: {snippet}"


def run_interpreter(goose: str) -> bool:
    failed = False
    for source in TESTS:
        path = str(source.as_posix())
        failed = run([goose, path], label=f"run {path}") or failed
        failed = run([goose, path, "--debug"], label=f"run {path} --debug") or failed
    return failed


def run_native(goose: str, *, require: bool) -> bool:
    kind, detail = probe_c_compiler(goose)
    if kind == "error":
        print(detail, file=sys.stderr)
        return True
    if kind == "missing":
        message = f"No C compiler reported by `goose toolchain` ({detail}); skipping native builds."
        if require:
            print(message, file=sys.stderr)
            return True
        print(message)
        return False

    print(f"Native builds using {detail}", flush=True)
    failed = False
    for source in TESTS:
        path = str(source.as_posix())
        exe = executable_for(ROOT / source)
        relative_exe = exe.relative_to(ROOT).as_posix()
        if clear_build_product(exe):
            print(
                f"FAILED: aborting native build for {path}; stale {relative_exe} may remain",
                file=sys.stderr,
            )
            failed = True
            continue
        try:
            if run([goose, "build", path], label=f"build {path}"):
                failed = True
                continue
            if not exe.is_file():
                print(
                    f"FAILED: native build for {path} did not create {relative_exe}",
                    file=sys.stderr,
                )
                failed = True
                continue
            if run([str(exe)], label=f"native {relative_exe}"):
                failed = True
        finally:
            # Best-effort cleanup after the run; a failure here cannot revive a
            # pre-build stale binary we already refused to execute.
            if clear_build_product(exe):
                print(
                    f"warning: could not clean native artifacts for {relative_exe}",
                    file=sys.stderr,
                )
    return failed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--native",
        action="store_true",
        help="also goose build and run each test when a C compiler is available",
    )
    parser.add_argument(
        "--require-native",
        action="store_true",
        help="with --native, fail if the C compiler or native builds are unavailable",
    )
    args = parser.parse_args()
    if args.require_native and not args.native:
        parser.error("--require-native requires --native")

    goose = shutil.which(os.environ.get("GOOSE", "goose"))
    if not goose:
        print("Goose executable not found; set GOOSE or add goose to PATH.", file=sys.stderr)
        return 2

    print(f"Using Goose at {goose}", flush=True)
    failed = run_interpreter(goose)
    if args.native:
        failed = run_native(goose, require=args.require_native) or failed

    if failed:
        print("HonkMQTT test entry point failed.", file=sys.stderr)
        return 1
    print("HonkMQTT test entry point passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
