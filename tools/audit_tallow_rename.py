#!/usr/bin/env python3
"""Audit an entire checkout for legacy Tessera naming after the Tallow rename.

Run: python3 tools/audit_tallow_rename.py
Use --strict to fail CI on every unclassified reference.
Existing GitHub URLs and the original copyright notice are reported separately;
old native names, formats and project identifiers are considered rename work.
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

def tracked_files():
    try:
        files = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).split(b"\0")
        return [ROOT / x.decode("utf-8", "surrogateescape") for x in files if x]
    except (OSError, subprocess.CalledProcessError):
        return [p for p in ROOT.rglob("*") if p.is_file() and not (set(p.relative_to(ROOT).parts) & SKIP)]

def classify(line, match, path=""):
    """Classify a single occurrence, never the entire line."""
    if path == "LICENSE" and line == "Copyright (c) 2026 Tessera contributors":
        return "historical copyright attribution"
    start, end = match.span()
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
            if file.name == "audit_tallow_rename.py": continue
            for match in TOKEN.finditer(line):
                category = classify(line, match, str(file.relative_to(ROOT)))
                count += 1
                unclassified += category == "unclassified branding/code"
                print(f"{file.relative_to(ROOT)}:{number}:{match.start() + 1}: [{category}] {line.strip()[:180]}")
    for path in legacy_paths:
        print(f"{path}: [legacy filename/path] rename or explicitly preserve this path")
    print(f"Legacy-name lines: {count}; unclassified: {unclassified}; legacy paths: {len(legacy_paths)}")
    if args.strict and (unclassified or legacy_paths): return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
