#!/usr/bin/env python3
"""B29 (docs/csharp-benchmark-plan.md): a NativeAOT export keeps every C# field a JIT export has.

Builds Tests/CSharpInGame twice from the same sources, as JIT and as NativeAOT (tools/build_player.py), runs each
headless with --fixed-step to frame 100 and --csharp-field-dump, which writes every running script of the scene in
object order: its script name, Inspector fields, all fields (public, private and hidden, with types), [Sync] fields
and saved fields. The two files must be the same, line for line: nothing trimmed, no enum written as a number,
no inherited or [Serializable] field lost, references and renamed classes ([FormerlyNamed]) resolved alike.

    python3 tools/test_csharp_aot_fields.py [--keep]
"""
from __future__ import annotations

import argparse
import difflib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import dotnet_sdk  # noqa: E402,F401  (the released .NET SDK Tallow pins, when installed)

# What the dump must show, so that a difference cannot hide behind an empty or partial file.
EXPECTED = [
    ("a renamed class ([FormerlyNamed]) under its new name", "InGame.RenamedProbe"),
    ("a base class's [ShowInInspector] field", "baseSecret\t"),
    ("a private field with its type", "_tick\tint\t"),
    ("enum members by name inside a [Serializable] list", "Kind=Second"),
    ("a list of [Serializable] items", "Waypoints\t"),
]

# Fields whose value is the runtime's own and may differ between JIT and NativeAOT; the name and type must still
# match. AsyncProbe._thread holds Environment.CurrentManagedThreadId, which is 2 under JIT on Windows (the runtime
# starts a managed thread before the game's) and 1 under NativeAOT.
RUNTIME_VALUES = ("_thread\tint\t",)


def comparable(line: str) -> str:
    for prefix in RUNTIME_VALUES:
        if line.startswith(prefix):
            return prefix + "<runtime value>"
    return line


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix="tallow-aot-fields-"))
    try:
        project = work / "InGame"
        shutil.copytree(ROOT / "Tests/CSharpInGame", project, ignore=shutil.ignore_patterns(".tallow-*", "build"))
        template = (ROOT / "Editor/templates/empty/Scripts/FirstPersonCharacter.cs.txt").read_text(encoding="utf-8")
        (project / "src/Scripts/FirstPersonCharacter.cs").write_text(template.replace("{NAMESPACE}", "InGame"), encoding="utf-8")
        (project / "project.tallow").write_text(
            f"name = InGame\nstartScene = Scenes/Main.tscene\nengine = {ROOT.as_posix()}\n", encoding="utf-8")
        dumps: dict[str, list[str]] = {}
        for runtime in ("jit", "native"):
            output = work / f"Built-{runtime}"
            built = subprocess.run([sys.executable, str(ROOT / "tools/build_player.py"), str(project), "--output", str(output),
                                    "--config", "Release", "--csharp-runtime", runtime], capture_output=True, text=True)
            if built.returncode != 0:
                print((built.stdout + built.stderr)[-6000:])
                print(f"FAIL: the {runtime} build failed")
                return 1
            dump = work / f"fields-{runtime}.txt"
            env = {k: v for k, v in os.environ.items() if not k.startswith("DOTNET_")}
            run = subprocess.run([str(output / ("InGame.exe" if os.name == "nt" else "InGame")), "--headless", "--fixed-step", "--frames", "110",
                                  "--csharp-field-dump", str(dump)], cwd=output, env=env, capture_output=True,
                                 text=True, timeout=600)
            report = next((l for l in (run.stdout + run.stderr).splitlines() if "FIELDDUMP" in l), "")
            print(f"{runtime}: {report.strip() or '(no dump: exit ' + str(run.returncode) + ')'}")
            if not dump.is_file():
                print((run.stdout + run.stderr)[-4000:])
                print(f"FAIL: the {runtime} build wrote no field dump")
                return 1
            dumps[runtime] = dump.read_text(encoding="utf-8").splitlines()
        failures = 0
        for what, needle in EXPECTED:
            ok = all(any(needle in line for line in lines) for lines in dumps.values())
            print(f"{'PASS' if ok else 'FAIL'} both dumps have {what}")
            failures += not ok
        jit, native = ([comparable(line) for line in dumps[r]] for r in ("jit", "native"))
        scripts = sum(line.startswith("== ") for line in jit)
        if jit == native:
            print(f"PASS the NativeAOT build's fields equal the JIT build's: {scripts} scripts, {len(jit)} lines")
        else:
            failures += 1
            diff = list(difflib.unified_diff(jit, native, "jit", "native", lineterm="", n=2))
            print(f"FAIL the builds' fields differ ({sum(l.startswith(('+', '-')) for l in diff) - 2} lines):")
            print("\n".join(diff[:120]))
        print("PASS: JIT and NativeAOT keep the same C# fields" if not failures else f"FAIL: {failures} failed")
        return 1 if failures else 0
    finally:
        if args.keep:
            print(f"Kept: {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
