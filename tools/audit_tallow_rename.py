#!/usr/bin/env python3
"""Audit an entire checkout for legacy Tessera naming after the Tallow rename.

Run: python3 tools/audit_tallow_rename.py
Use --strict to fail CI on every unclassified reference.
Historical GitHub URLs, binary compatibility, serialized formats and native ABI
are reported separately, not silently renamed.
"""
from __future__ import annotations
import argparse
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
TOKEN = re.compile(r"tessera", re.IGNORECASE)
SKIP = {".git", ".venv", "node_modules", "build", "dist", "__pycache__", ".cache"}
HISTORICAL = re.compile(r"github.com/LazyAlgorithm/Tessera|api.github.com/repos/LazyAlgorithm/Tessera|raw.githubusercontent.com/LazyAlgorithm/Tessera", re.I)
FORMATS = re.compile(r"project\.tessera|game\.tessera|\.tessera\b", re.I)
NATIVE = re.compile(r"tessera_native|tessera_model|tessera_web|tessera-net|tn_", re.I)
ENV = re.compile(r"TESSERA_ROOT|TESSERA_WIN|TesseraBuildTools|tessera-win", re.I)

def tracked_files():
    try:
        files = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).split(b"\0")
        return [ROOT / x.decode("utf-8", "surrogateescape") for x in files if x]
    except (OSError, subprocess.CalledProcessError):
        return [p for p in ROOT.rglob("*") if p.is_file() and not (set(p.relative_to(ROOT).parts) & SKIP)]

def classify(line):
    if HISTORICAL.search(line): return "repository URL (until repo rename)"
    if FORMATS.search(line): return "serialized format (compatibility)"
    if NATIVE.search(line): return "native ABI/tool name (migration required)"
    if ENV.search(line): return "environment/toolchain compatibility"
    return "unclassified branding/code"

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--strict", action="store_true", help="Fail if any unclassified reference remains")
    args = parser.parse_args()
    count = 0
    unclassified = 0
    legacy_paths = []
    for file in sorted(tracked_files()):
        if not file.is_file() or set(file.relative_to(ROOT).parts) & SKIP:
            continue
        if TOKEN.search(str(file.relative_to(ROOT))):
            legacy_paths.append(str(file.relative_to(ROOT)))
        try: content = file.read_text("utf-8")
        except (UnicodeError, OSError): continue
        for number, line in enumerate(content.splitlines(), 1):
            if not TOKEN.search(line): continue
            # Avoid treating audit rules themselves as product references.
            if file.name == "audit_tallow_rename.py": continue
            category = classify(line)
            count += 1
            unclassified += category == "unclassified branding/code"
            print(f"{file.relative_to(ROOT)}:{number}: [{category}] {line.strip()[:180]}")
    for path in legacy_paths:
        print(f"{path}: [legacy filename/path] rename or explicitly preserve this path")
    print(f"Legacy-name lines: {count}; unclassified: {unclassified}; legacy paths: {len(legacy_paths)}")
    if args.strict and (unclassified or legacy_paths): return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
