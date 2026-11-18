#!/usr/bin/env python3
"""Run the C# gameplay API checks inside the real engine.

Builds Tests/CSharpInGame with the .NET SDK, then starts it in the built
player without a window. The scripts log one "INGAME PASS/FAIL" line per check
and "INGAME DONE" at the end. Unlike the native-host smoke test, nothing is
mocked: the scene, Jolt and Flecs are the engine's own.

    python3 tools/test_csharp_ingame.py [--config Debug]
"""
from __future__ import annotations

import argparse
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))  # noqa: E402
import dotnet_sdk  # noqa: E402,F401  (the released .NET SDK Tallow pins, when installed)

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="Debug")
    parser.add_argument("--keep", action="store_true", help="keep the temporary project")
    parser.add_argument("--editor", action="store_true",
                        help="also open the editor on the project for its C# Inspector checks (needs a display: never in CI)")
    args = parser.parse_args()

    windows = platform.system() == "Windows"
    target = f"{args.config}_{'Win64' if windows else 'Linux64'}"
    launcher = ROOT / "build" / target / "TallowLauncher" / ("TallowLauncher.exe" if windows else "TallowLauncher")
    if not launcher.is_file():
        print(f"Build the engine first: {launcher} is missing.", file=sys.stderr)
        return 2

    work = Path(tempfile.mkdtemp(prefix="tallow-csharp-ingame-"))
    try:
        project = work / "InGame"
        shutil.copytree(ROOT / "Tests/CSharpInGame", project,
                        ignore=shutil.ignore_patterns(".tallow-*", "build"))
        template = (ROOT / "Editor/templates/empty/Scripts/FirstPersonCharacter.cs.txt").read_text(encoding="utf-8")
        (project / "src/Scripts/FirstPersonCharacter.cs").write_text(
            template.replace("{NAMESPACE}", "InGame"), encoding="utf-8")
        (project / "project.tallow").write_text(
            f"name = InGame\nstartScene = Scenes/Main.tscene\nengine = {ROOT.as_posix()}\n", encoding="utf-8")

        # GraphProbe.cs is what the graph compiler makes of GraphProbe.tgraph: compile the graph again with this
        # engine, so the run tests the compiler as it is now, and say so when the checked-in copy is out of date.
        # The graph uses nodes read from C# (.tallow-csharp/graph-nodes.tsv), which a build writes: build first.
        subprocess.run(["dotnet", "run", "--project", str(ROOT / "Managed/Tallow.Build/Tallow.Build.csproj"),
                        "--", "--project", str(project), "--engine-root", str(ROOT)], capture_output=True, text=True)
        graph = project / "src/Scripts/GraphProbe.tgraph"
        committed = (project / "src/Scripts/GraphProbe.cs").read_text(encoding="utf-8")
        compiled = subprocess.run([str(launcher), "--graph-compile", str(graph), "InGame"], capture_output=True, text=True,
                                  timeout=300)
        if compiled.returncode != 0:
            print(compiled.stdout + compiled.stderr)
            print("The graph compiler failed on GraphProbe.tgraph.", file=sys.stderr)
            return 1
        graph_drift = (project / "src/Scripts/GraphProbe.cs").read_text(encoding="utf-8") != committed

        build = subprocess.run(
            ["dotnet", "run", "--project", str(ROOT / "Managed/Tallow.Build/Tallow.Build.csproj"),
             "--", "--project", str(project), "--engine-root", str(ROOT)],
            capture_output=True, text=True)
        if build.returncode != 0:
            print(build.stdout + build.stderr)
            print("C# test project did not compile.", file=sys.stderr)
            return 1
        subprocess.run(["dotnet", "build", str(ROOT / "Managed/Tallow.ManagedRuntime/Tallow.ManagedRuntime.csproj"),
                        "--configuration", "Debug", "--nologo", "--verbosity", "quiet"], check=True)

        run = subprocess.run(
            [str(launcher), "--game", "--project", str(project), "--headless", "--fixed-step", "--csharp-field-test", "--frames", "600",
             "--profile-report", str(work / "profile.txt")],
            capture_output=True, text=True, timeout=180)
        output = run.stdout + run.stderr
        lines = [line for line in output.splitlines() if "INGAME" in line or "[Tallow C#]" in line]
        print("\n".join(lines))
        passed = sum("INGAME PASS" in line for line in lines)
        # Thrower throws on purpose: allowed, but it must be logged once, naming the file and line it threw on.
        expected = "thrown on purpose by Thrower"
        failed = [line for line in lines if "INGAME FAIL" in line or ("[Tallow C#]" in line and "thrown on purpose" not in line
                   # RunFieldTest's refused Inspector edit, logged as the editor would show it.
                   and "'not a number' was not in a correct format" not in line)]
        # A Debug Windows build reports leaks (and other Debug breakpoints) on stderr and goes on (CrashReports.bf).
        for marker in ("[leak check]", "[breakpoint]"):
            at = output.find(marker)
            if at >= 0:
                failed.append(f"INGAME FAIL {marker} " + output[at:at + 3000])
                print(failed[-1])
        thrown = [line for line in output.splitlines() if line.startswith("[error] System.InvalidOperationException: " + expected)]
        source = (project / "src/Scripts/ApiChecks.cs").read_text().splitlines()
        throw_line = next(i + 1 for i, text in enumerate(source) if expected in text and "throw" in text)
        if len(thrown) == 1 and f"InGame.Thrower.Update" in thrown[0] and f"at ApiChecks.cs:{throw_line})" in thrown[0]:
            passed += 1
            print("INGAME PASS a script exception is logged once with the game file and line it was thrown on")
        else:
            failed.append(f"INGAME FAIL script exception report: {thrown or 'not logged'}")
            print(failed[-1])
        report = (work / "profile.txt").read_text() if (work / "profile.txt").exists() else ""
        for label, needle in [("the Profiler times each C# script class by name", "| InGame.ApiChecks.Update() | Scripts |"),
                              ("the Profiler times C# await continuations", "| C# await continuations | Scripts |"),
                              ("the Profiler counts C# allocations and heap size", "- C# allocated this frame in bytes:"),
                              ("the Profiler counts C# garbage collections", "- C# garbage collections this frame:"),
                              ("a C# ProfilerMarker is timed under its category", "| InGame tick work | AI |"),
                              ("a C# ProfilerCounter is shown with its unit", "- InGame ticks in ticks:")]:
            if needle in report:
                passed += 1
                print("INGAME PASS " + label)
            else:
                failed.append("INGAME FAIL " + label)
                print(failed[-1])
        # The Inspector's field catalog: reference fields are kind "object" with what they take in column 8.
        catalog = {tuple(row.split("\t")[:2]): row.split("\t") for row in
                   (project / ".tallow-csharp/fields.tsv").read_text(encoding="utf-8").splitlines() if row}
        for field, wanted in [("Target", "GameObject"), ("Lamp", "native:Tallow.Light"),
                              ("Spot", "Transform"), ("Late", "script:InGame.LateHelper")]:
            row = catalog.get(("InGame.RefProbe", field), [])
            if len(row) >= 8 and row[2] == "object" and row[7] == wanted:
                passed += 1
                print(f"INGAME PASS the field catalog lists RefProbe.{field} as an object field taking {wanted}")
            else:
                failed.append(f"INGAME FAIL catalog row for RefProbe.{field}: {row}")
                print(failed[-1])
        # A [Serializable] struct field's fields are rows of their own, "Outer.Inner", nested types included.
        nested = {name: catalog.get(("InGame.ApiChecks", name), [None, None, None])[2]
                  for name in ("Stats.Health", "Stats.Speed", "Stats.Limits.Max", "Stats.Limits.Tag", "Stats.Ignored", "Stats")}
        if nested == {"Stats.Health": "int", "Stats.Speed": "float", "Stats.Limits.Max": "float",
                      "Stats.Limits.Tag": "string", "Stats.Ignored": None, "Stats": None}:
            passed += 1
            print("INGAME PASS the field catalog lists a nested [Serializable] type's fields as Outer.Inner rows")
        else:
            failed.append(f"INGAME FAIL nested catalog rows: {nested}")
            print(failed[-1])
        # A field's /// comment is its Inspector tooltip (field-docs.tsv: class, field, one line of text).
        docs = {tuple(row.split("\t")[:2]): row.split("\t")[2] for row in
                (project / ".tallow-csharp/field-docs.tsv").read_text(encoding="utf-8").splitlines() if row}
        wanted_docs = {("InGame.ApiChecks", "Speed"): "How fast it moves, in metres a second (see Stats) & more.",
                       ("InGame.ApiChecks", "Stats.Health"): "Hit points."}
        if all(docs.get(key) == text for key, text in wanted_docs.items()) and ("InGame.ApiChecks", "Label") not in docs:
            passed += 1
            print("INGAME PASS a C# field's doc comment is written for the Inspector's tooltip")
        else:
            failed.append(f"INGAME FAIL field docs: {[docs.get(key) for key in wanted_docs]}")
            print(failed[-1])
        # A list of a [Serializable] type is "list:record"; column 8 lists the item's fields (name~kind~default~options).
        waves = catalog.get(("InGame.ApiChecks", "Waves"), [])
        points = catalog.get(("InGame.ApiChecks", "Waypoints"), [])
        if (len(waves) >= 8 and waves[2] == "list:record" and
                waves[7] == "Count~int~3~|Delay~float~0~|Kind~enum~First~First/Second|Name~string~~" and
                len(points) >= 8 and points[2] == "list:record" and points[7] == "At~Vector3~0,0,0~|Wait~bool~false~"):
            passed += 1
            print("INGAME PASS the field catalog lists a list of [Serializable] items with the item's fields")
        else:
            failed.append(f"INGAME FAIL list:record catalog rows: {waves} {points}")
            print(failed[-1])
        # Defaults: an enclosing initializer's `new() { Health = 10 }` wins over the type's own initializers.
        defaults = {name: (catalog.get(("InGame.ApiChecks", name)) or [""] * 4)[3]
                    for name in ("Stats.Health", "NoOverrides.Health", "Stats.Limits.Max")}
        if defaults == {"Stats.Health": "10", "NoOverrides.Health": "0", "Stats.Limits.Max": "5"}:
            passed += 1
            print("INGAME PASS nested field defaults come from the enclosing initializer, then the type's own")
        else:
            failed.append(f"INGAME FAIL nested field defaults: {defaults}")
            print(failed[-1])
        # [Asset(kind)] strings and string lists carry "asset:<kind>" in column 8 (the Inspector's asset picker).
        assets = {name: (catalog.get(("InGame.ApiChecks", name)) or [""] * 8)[2::5] for name in ("EnemyPrefab", "Sounds")}
        if assets == {"EnemyPrefab": ["string", "asset:prefab"], "Sounds": ["list:string", "asset:audioClip"]}:
            passed += 1
            print("INGAME PASS [Asset] string fields and lists are asset paths in the field catalog")
        else:
            failed.append(f"INGAME FAIL [Asset] catalog rows: {assets}")
            print(failed[-1])
        # C# behaviour nodes are offered to the editor before the game runs (.tallow-csharp/behavior-nodes.tsv).
        bt_path = project / ".tallow-csharp/behavior-nodes.tsv"
        bt_rows = {row.split("\t")[0]: row.split("\t") for row in
                   (bt_path.read_text(encoding="utf-8").split("\n") if bt_path.exists() else []) if row}
        ammo, count = bt_rows.get("ingame.ammo"), bt_rows.get("InGame.CountTicks")
        if (ammo and ammo[1:6] == ["Game", "Ammo At Least", "1", "Succeeds while the blackboard's ammo is at least Count.", "InGame.AmmoAtLeast"]
                and ammo[6] == "Count\x1fNumber\x1f1" and count and count[6] == "Ticks\x1fNumber\x1f2\x1eEntry\x1fText\x1fcount"
                and bt_rows.get("InGame.MarkDone", [""] * 2)[1] == "Tests"):
            passed += 1
            print("INGAME PASS the build lists C# behaviour nodes, their keys and settings for the editor")
        else:
            failed.append(f"INGAME FAIL behaviour node catalog rows: {bt_rows}")
            print(failed[-1])
        boom = [line for line in output.splitlines()
                if line.startswith("[error] System.InvalidOperationException: thrown on purpose by async code (in async code")]
        if len(boom) == 1 and "AsyncProbe" in boom[0] and "ApiChecks.cs:" in boom[0]:
            passed += 1
            print("INGAME PASS an exception after an await is logged with its script's line")
        else:
            failed.append(f"INGAME FAIL async exception report: {boom or 'not logged'}")
            print(failed[-1])
        if graph_drift:
            failed.append("INGAME FAIL Tests/CSharpInGame/src/Scripts/GraphProbe.cs is not what the graph compiler makes "
                          "now: run TallowLauncher --graph-compile on GraphProbe.tgraph (namespace InGame) and commit it")
            print(failed[-1])
        else:
            passed += 1
            print("INGAME PASS the checked-in GraphProbe.cs matches what the graph compiler makes of GraphProbe.tgraph")
        if args.editor:
            # Inspector edits of C# fields (plain, nested, [Asset]) go through undo and redo.
            editor = subprocess.run([str(launcher), "--editor", "--project", str(project), "--csharp-inspector-test",
                                     "--frames", "30"], capture_output=True, text=True, timeout=180)
            result = [line for line in (editor.stdout + editor.stderr).splitlines() if "CSHARP INSPECTOR TEST" in line]
            if result and "CSHARP INSPECTOR TEST PASS" in result[0]:
                passed += 1
                print("INGAME PASS (editor) " + result[0])
            else:
                failed.append(f"INGAME FAIL (editor) {result or 'no result: ' + (editor.stdout + editor.stderr)[-1500:]}")
                print(failed[-1])
        if run.returncode != 0 or failed or not any("INGAME DONE" in line for line in lines):
            if not lines or run.returncode != 0:
                print(output[-4000:])
            print(f"In-engine C# checks failed (exit {run.returncode}, {passed} passed, {len(failed)} failed).",
                  file=sys.stderr)
            return 1
        print(f"In-engine C# checks passed: {passed}.")
        return 0
    finally:
        if args.keep:
            print(f"Kept {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
