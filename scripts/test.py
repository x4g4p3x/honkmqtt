#!/usr/bin/env python3
"""Run HonkMQTT's deterministic Goose tests from one entry point.

By default this runs tests/test.goose, tests/publish.goose, and
tests/coverage.goose in the in-process Goose runner, once normally and once
with --debug. Pass --native to also goose build and execute each program when
a C compiler is available; pass --require-native to fail if native work is
skipped or unavailable. Set GOOSE to override the Goose executable.
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


def run(command: list[str], *, label: str) -> int:
    print(f"+ {' '.join(command)}", flush=True)
    result = subprocess.run(command, cwd=ROOT)
    if result.returncode != 0:
        print(f"FAILED: {label} (exit {result.returncode})", file=sys.stderr)
    return result.returncode


def executable_for(source: Path) -> Path:
    built = source.parent / source.stem
    if os.name == "nt":
        return built.with_suffix(".exe")
    return built


def toolchain_has_c_compiler(goose: str) -> bool:
    result = subprocess.run(
        [goose, "toolchain"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    text = (result.stdout or "") + (result.stderr or "")
    if result.returncode != 0:
        return False
    for line in text.splitlines():
        lowered = line.lower()
        if "c compiler:" in lowered and "not found" in lowered:
            return False
        if "c compiler:" in lowered:
            return True
    return False


def run_interpreter(goose: str) -> int:
    failed = 0
    for source in TESTS:
        path = str(source.as_posix())
        failed |= run([goose, path], label=f"run {path}")
        failed |= run([goose, path, "--debug"], label=f"run {path} --debug")
    return failed


def run_native(goose: str, *, require: bool) -> int:
    if not toolchain_has_c_compiler(goose):
        message = "No C compiler reported by `goose toolchain`; skipping native builds."
        if require:
            print(message, file=sys.stderr)
            return 1
        print(message)
        return 0

    failed = 0
    built: list[Path] = []
    try:
        for source in TESTS:
            path = str(source.as_posix())
            code = run([goose, "build", path], label=f"build {path}")
            if code != 0:
                failed |= code
                continue
            exe = executable_for(ROOT / source)
            if not exe.is_file():
                print(f"FAILED: expected native executable at {exe.relative_to(ROOT)}", file=sys.stderr)
                failed = 1
                continue
            built.append(exe)
            failed |= run([str(exe)], label=f"native {exe.relative_to(ROOT).as_posix()}")
    finally:
        for exe in built:
            try:
                exe.unlink()
            except OSError as error:
                print(f"warning: could not remove {exe}: {error}", file=sys.stderr)
            for suffix in (".obj", ".o", ".pdb", ".ilk"):
                side = exe.with_suffix(suffix)
                if side.is_file():
                    try:
                        side.unlink()
                    except OSError:
                        pass
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
        failed |= run_native(goose, require=args.require_native)

    if failed:
        print("HonkMQTT test entry point failed.", file=sys.stderr)
        return 1
    print("HonkMQTT test entry point passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
