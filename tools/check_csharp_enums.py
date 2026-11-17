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
    ("Engine/src/Audio/Audio.bf", r"enum AudioGroup : int32\s*\{(.*?)\n\}",
     "Managed/Tallow.API/Gameplay.cs", r"public enum AudioGroup\s*\{(.*?)\n\}"),
    ("Engine/src/Core/Gamepad.bf", r"enum GamepadButton : int32\s*\{(.*?)\n\}",
     "Managed/Tallow.API/Platform.cs", r"public enum GamepadButton\s*\{(.*?)\n\}"),
    ("Engine/src/Core/Gamepad.bf", r"enum GamepadAxis : int32\s*\{(.*?)\n\}",
     "Managed/Tallow.API/Platform.cs", r"public enum GamepadAxis\s*\{(.*?)\n\}"),
    ("Engine/src/Core/Gamepad.bf", r"enum GamepadKind : int32\s*\{(.*?)\n\}",
     "Managed/Tallow.API/Platform.cs", r"public enum GamepadKind\s*\{(.*?)\n\}"),
    ("Engine/src/Render/Quality.bf", r"enum QualityLevel\s*\{(.*?)\n\}",
     "Managed/Tallow.API/Platform.cs", r"public enum QualityLevel\s*\{(.*?)\n\}"),
    ("Engine/src/Render/Material.bf", r"enum MaterialBlend : int32\s*\{(.*?)\n\}",
     "Managed/Tallow.API/Materials.cs", r"public enum MaterialBlend\s*\{(.*?)\n\}"),
    ("Engine/src/Core/Profiler.bf", r"enum ProfilerCategory : uint8\s*\{(.*?)\n\}",
     "Managed/Tallow.API/Profiling.cs", r"public enum ProfilerCategory : byte\s*\{(.*?)\n\}"),
    ("Engine/src/Render/Textures.bf", r"enum TextureKind\s*\{(.*?)\n\}",
     "Managed/Tallow.API/Textures.cs", r"public enum TextureKind\s*\{(.*?)\n\}"),
    ("Engine/src/Scene/SceneManager.bf", r"public enum Stage\s*\{(.*?)\n\t\}",
     "Managed/Tallow.API/SceneLoading.cs", r"public enum SceneLoadStage\s*\{(.*?)\n\}"),
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
