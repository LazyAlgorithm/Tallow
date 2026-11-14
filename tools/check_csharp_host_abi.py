#!/usr/bin/env python3
"""Verify the native-host test resolver uses only generated CSharpExpose IDs.

The test host intentionally substitutes C++ implementations for generated
Beef exports. Its symbol IDs must match the real manifest signature hashes,
or a physics/GUI/ECS regression fails only at runtime on some platforms.
"""
from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "Tests/CSharpExpose/fixture.tsv"
HOST = ROOT / "Tests/NativeCSharpHost/main.cpp"


def symbol_hash(signature: str) -> str:
    return hashlib.sha256(signature.encode("utf-8")).hexdigest()[:16]


def approved_symbols(manifest: str) -> set[str]:
    records = manifest.splitlines()
    if not records or records[0] != "TALLOW_CSHARP_API_V1":
        raise ValueError("Unexpected CSharpExpose manifest header")
    symbols: set[str] = set()
    for line_number, line in enumerate(records[1:], 2):
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) < 4 or fields[0] not in ("method", "field"):
            raise ValueError(f"Malformed manifest line {line_number}")
        kind, owner, name, result = fields[:4]
        if kind == "method":
            types = []
            for arg in fields[4:]:
                if ":" not in arg:
                    raise ValueError(f"Malformed parameter at line {line_number}")
                types.append(arg.split(":", 1)[1])
            signature = "|".join([owner, name, result, *types])
        else:
            if len(fields) != 5 or fields[4] not in ("get", "getset"):
                raise ValueError(f"Malformed field at line {line_number}")
            signature = "field|" + "|".join([owner, name, result])
        identifier = symbol_hash(signature)
        if identifier in symbols:
            raise ValueError(f"Duplicate exposed symbol on line {line_number}")
        symbols.add(identifier)
        if kind == "field" and fields[4] == "getset":
            symbols.add(symbol_hash("set|" + identifier))
    return symbols


def main() -> int:
    approved = approved_symbols(MANIFEST.read_text(encoding="utf-8"))
    host = HOST.read_text(encoding="utf-8")
    resolved = re.findall(r'if\s*\(name\s*==\s*"CSharpApi_([0-9a-f]{16})"\)', host)
    if len(resolved) != len(set(resolved)):
        print("Duplicate generated C# symbol in native-host resolver", file=sys.stderr)
        return 1
    unknown = sorted(set(resolved) - approved)
    if unknown:
        print("Native-host resolver contains unapproved/outdated generated ABI IDs:", file=sys.stderr)
        for identifier in unknown:
            print(f"  CSharpApi_{identifier}", file=sys.stderr)
        return 1
    # These are known canonical fixture signatures; protect the hash format,
    # including parameter types, from accidental changes in this checker.
    if symbol_hash("Tallow.CSharpBindingFixture|Average|float|float|float") != "17858942906a9c6f":
        raise AssertionError("CSharpExpose fixture hash algorithm diverged")
    if symbol_hash("Tallow.Physics|SleepRigidbody|bool|ulong|ulong") != "b08ed96d885c92a3":
        raise AssertionError("Rigidbody sleep signature hash diverged")
    required = [
        "Tallow.Physics|SleepRigidbody|bool|ulong|ulong",
        "Tallow.Ecs|CopyRigidbodyMasses|int|ulong|int|System.Span<ulong>|System.Span<float>",
    ]
    for signature in required:
        if symbol_hash(signature) not in resolved:
            print(f"Missing mandatory native-host ABI symbol: {signature}", file=sys.stderr)
            return 1
    print(f"PASS: {len(resolved)} native-host C# ABI symbols match the compiler manifest.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
