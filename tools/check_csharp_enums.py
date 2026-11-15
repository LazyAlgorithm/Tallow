#!/usr/bin/env python3
"""Verify hand-written C# enums that cross the native ABI as integers.

C# gameplay passes KeyCode to the engine as its number, so the C# enum must
list the same names with the same values as the Beef enum.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PAIRS = [
    ("Engine/src/Core/Input.bf", r"enum KeyCode : int32\s*\{(.*?)\n\}",
     "Managed/Tallow.API/Input.cs", r"public enum KeyCode\s*\{(.*?)\n\}"),
]


def members(body: str) -> dict[str, int]:
    body = re.sub(r"//[^\n]*", "", body)
    values: dict[str, int] = {}
    current = -1
    for item in body.split(","):
        item = item.strip()
        if not item:
            continue
        if "=" in item:
            name, value = (part.strip() for part in item.split("=", 1))
            current = int(value, 0)
        else:
            name = item
            current += 1
        values[name] = current
    return values


def main() -> int:
    for native_path, native_pattern, managed_path, managed_pattern in PAIRS:
        native = re.search(native_pattern, (ROOT / native_path).read_text(encoding="utf-8"), re.S)
        managed = re.search(managed_pattern, (ROOT / managed_path).read_text(encoding="utf-8"), re.S)
        if not native or not managed:
            print(f"Could not find the enum in {native_path} or {managed_path}", file=sys.stderr)
            return 1
        expected, actual = members(native.group(1)), members(managed.group(1))
        if expected != actual:
            differing = sorted(set(expected.items()) ^ set(actual.items()))
            print(f"{managed_path} does not match {native_path}: {differing}", file=sys.stderr)
            return 1
    print("C# ABI enums match their native definitions.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
