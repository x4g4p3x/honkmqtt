#!/usr/bin/env python3
"""Run HonkMQTT's deterministic Goose tests from one entry point.

By default this runs tests/test.goose, tests/publish.goose, and
tests/coverage.goose in the in-process Goose runner, once normally and once
with --debug. Pass --native to also goose build and execute each program when
a C compiler is available; pass --require-native to fail if native work is
skipped or unavailable. Set GOOSE to override the Goose executable.

Native mode removes any pre-existing build product for a target before
building, so a successful no-op or failed build cannot re-run a stale binary.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
TESTS = (
    Path("tests/test.goose"),
    Path("tests/publish.goose"),
    Path("tests/coverage.goose"),
)
SIDE_SUFFIXES = (".obj", ".o", ".pdb", ".ilk")


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


def remove_artifacts(executable: Path) -> None:
    for path in artifact_paths(executable):
        try:
            if path.is_file():
                path.unlink()
        except OSError as error:
            print(f"warning: could not remove {path}: {error}", file=sys.stderr)


def toolchain_c_compiler(goose: str) -> str | None:
    """Return the C compiler summary line, or None if Goose reports none."""
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
        print(f"FAILED: goose toolchain ({error})", file=sys.stderr)
        return None
    text = (result.stdout or "") + (result.stderr or "")
    if result.returncode != 0:
        print(text, end="", file=sys.stderr)
        return None
    for line in text.splitlines():
        stripped = line.strip()
        lowered = stripped.lower()
        if not lowered.startswith("c compiler:"):
            continue
        detail = stripped.split(":", 1)[1].strip().lower()
        if not detail or detail.startswith("not found"):
            return None
        return stripped
    return None


def run_interpreter(goose: str) -> bool:
    failed = False
    for source in TESTS:
        path = str(source.as_posix())
        failed = run([goose, path], label=f"run {path}") or failed
        failed = run([goose, path, "--debug"], label=f"run {path} --debug") or failed
    return failed


def run_native(goose: str, *, require: bool) -> bool:
    compiler = toolchain_c_compiler(goose)
    if compiler is None:
        message = "No C compiler reported by `goose toolchain`; skipping native builds."
        if require:
            print(message, file=sys.stderr)
            return True
        print(message)
        return False

    print(f"Native builds using {compiler}", flush=True)
    failed = False
    for source in TESTS:
        path = str(source.as_posix())
        exe = executable_for(ROOT / source)
        relative_exe = exe.relative_to(ROOT).as_posix()
        remove_artifacts(exe)
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
            remove_artifacts(exe)
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
