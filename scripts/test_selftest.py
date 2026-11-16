#!/usr/bin/env python3
"""Regression checks for scripts/test.py native safety contracts."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import types

ROOT = Path(__file__).resolve().parent.parent
TEST_PY = ROOT / "scripts" / "test.py"


def fail(message: str) -> None:
    print(f"SELFTEST FAILED: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_entry() -> types.ModuleType:
    spec = importlib.util.spec_from_file_location("honkmqtt_test_entry", TEST_PY)
    if spec is None or spec.loader is None:
        fail(f"could not load {TEST_PY}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_fake_goose(directory: Path, mode: str) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    script = directory / "fake_goose.py"
    script.write_text(
        textwrap.dedent(
            f"""\
            #!/usr/bin/env python3
            import sys
            MODE = {mode!r}
            def main() -> int:
                args = sys.argv[1:]
                if args and args[0] == "toolchain":
                    if MODE == "no-cc":
                        print("C compiler: not found on PATH")
                        print("cmake:       not found on PATH")
                        return 0
                    if MODE == "toolchain-fail":
                        print("toolchain broken", file=sys.stderr)
                        return 3
                    if MODE == "unrecognized":
                        print("cmake: not found on PATH")
                        return 0
                    if MODE == "available":
                        print("C compiler:   clang 1.0, found on PATH")
                        return 0
                    print(f"unknown mode {{MODE}}", file=sys.stderr)
                    return 1
                print(f"fake run {{args}}")
                return 0
            if __name__ == "__main__":
                raise SystemExit(main())
            """
        ),
        encoding="utf-8",
    )
    if os.name == "nt":
        launcher = directory / "goose.cmd"
        launcher.write_text(f'@echo off\r\npython "{script}" %*\r\n', encoding="ascii")
        return launcher
    launcher = directory / "goose"
    launcher.write_text(f'#!/bin/sh\nexec python3 "{script}" "$@"\n', encoding="utf-8")
    launcher.chmod(0o755)
    return launcher


def run_entry(goose: Path, *args: str) -> tuple[int, str]:
    env = os.environ.copy()
    env["GOOSE"] = str(goose)
    result = subprocess.run(
        [sys.executable, str(TEST_PY), *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=env,
    )
    output = (result.stdout or "") + (result.stderr or "")
    return result.returncode, output


def expect_contains(output: str, needle: str, label: str) -> None:
    if needle not in output:
        fail(f"{label}: missing {needle!r} in output:\n{output}")


def test_toolchain_classification(entry: types.ModuleType) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)

        kind, detail = entry.probe_c_compiler(str(write_fake_goose(base / "missing", "no-cc")))
        if kind != "missing":
            fail(f"explicit no-compiler should be missing, got {kind}: {detail}")

        kind, detail = entry.probe_c_compiler(str(write_fake_goose(base / "fail", "toolchain-fail")))
        if kind != "error" or "exited 3" not in detail:
            fail(f"nonzero toolchain should be error, got {kind}: {detail}")

        kind, detail = entry.probe_c_compiler(str(write_fake_goose(base / "bad", "unrecognized")))
        if kind != "error" or "unrecognized" not in detail.lower():
            fail(f"unrecognized output should be error, got {kind}: {detail}")

        kind, detail = entry.probe_c_compiler(str(write_fake_goose(base / "ok", "available")))
        if kind != "available" or "clang" not in detail.lower():
            fail(f"available compiler expected, got {kind}: {detail}")

        kind, detail = entry.probe_c_compiler(str(base / "does-not-exist-goose"))
        if kind != "error":
            fail(f"launch failure should be error, got {kind}: {detail}")


def test_entry_fail_vs_skip() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)

        code, out = run_entry(write_fake_goose(base / "fail", "toolchain-fail"), "--native")
        if code == 0:
            fail("toolchain failure must not succeed as a native skip")
        expect_contains(out, "exited 3", "toolchain-fail")

        code, out = run_entry(write_fake_goose(base / "bad", "unrecognized"), "--native")
        if code == 0:
            fail("unrecognized toolchain output must not succeed as a native skip")
        expect_contains(out, "unrecognized", "unrecognized")

        goose = write_fake_goose(base / "missing", "no-cc")
        code, out = run_entry(goose, "--native")
        if code != 0:
            fail(f"explicit no-compiler without --require-native should skip OK, got {code}\n{out}")
        expect_contains(out, "skipping native", "no-cc skip")

        code, out = run_entry(goose, "--native", "--require-native")
        if code == 0:
            fail("--require-native must fail when compiler is missing")
        expect_contains(out, "skipping native", "no-cc require")


def test_clear_build_product_aborts_on_unlink_failure(entry: types.ModuleType) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        exe = Path(tmp) / ("locked.exe" if os.name == "nt" else "locked")
        exe.write_text("stale", encoding="utf-8")
        original_unlink = Path.unlink

        def boom(self: Path, *args, **kwargs):
            if self.resolve() == exe.resolve():
                raise OSError("simulated lock")
            return original_unlink(self, *args, **kwargs)

        Path.unlink = boom  # type: ignore[method-assign]
        try:
            if not entry.clear_build_product(exe):
                fail("clear_build_product must report failure when unlink raises")
            if not exe.is_file():
                fail("simulated unlink failure should leave the executable in place")
        finally:
            Path.unlink = original_unlink  # type: ignore[method-assign]

        if entry.clear_build_product(exe):
            fail("clear_build_product should succeed for a removable file")
        if exe.is_file():
            fail("executable should be removed after successful clear")


def main() -> int:
    entry = load_entry()
    test_toolchain_classification(entry)
    test_entry_fail_vs_skip()
    test_clear_build_product_aborts_on_unlink_failure(entry)
    print("scripts/test.py self-tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
