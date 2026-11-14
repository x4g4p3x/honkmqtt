#!/usr/bin/env python3
"""Check formatting and Goose diagnostics without modifying source files."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SKIP_DIRS = {"build", "__pycache__"}


def main():
    goose = shutil.which(os.environ.get("GOOSE", "goose"))
    if not goose:
        print("Goose executable not found; set GOOSE or add goose to PATH.", file=sys.stderr)
        return 2
    files = sorted(
        p for p in ROOT.rglob("*.goose")
        if not any(part.startswith(".") or part in SKIP_DIRS for part in p.relative_to(ROOT).parts)
    )
    if not files:
        print("No Goose files found.", file=sys.stderr)
        return 2

    failed = False
    print(f"Checking formatting and diagnostics for {len(files)} Goose files", flush=True)
    formatted = subprocess.run([goose, "format", "--check", *map(str, files)], cwd=ROOT)
    if formatted.returncode != 0:
        print("Goose formatting check failed; run 'goose format .' to fix it.", file=sys.stderr)
        failed = True

    for path in files:
        result = subprocess.run(
            [goose, "check", str(path), "--diagnostics", "json", "--offline"],
            cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace",
        )
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr)
        try:
            diagnostics = json.loads(result.stdout)
            if not isinstance(diagnostics, list):
                raise ValueError("expected a diagnostics array")
        except (ValueError, json.JSONDecodeError):
            print(f"Could not parse Goose diagnostics for {path.relative_to(ROOT)}:\n{result.stdout}", file=sys.stderr)
            failed = True
            continue
        if result.returncode != 0 or diagnostics:
            failed = True
            for diagnostic in diagnostics:
                print(diagnostic.get("text", str(diagnostic)), file=sys.stderr)
            if result.returncode != 0 and not diagnostics:
                print(f"Goose check failed for {path.relative_to(ROOT)} (exit {result.returncode})", file=sys.stderr)
    if not failed:
        print("Goose formatting and diagnostics checks passed.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
