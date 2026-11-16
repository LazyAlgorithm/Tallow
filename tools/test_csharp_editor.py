#!/usr/bin/env python3
"""Editor checks for C# projects (roadmap P0, benchmarks B01/B04/B06). Needs a display: never in CI.

Opens the precompiled editor (TallowLauncher --editor) on copies of projects with --play-cycle-test
(Editor/src/Tools/PlayCycleTest.bf) and checks:
  1. a C# project (Samples/Sandbox): opens without BeefBuild, its first C# build finishes, Play/Stop N times
     detaches every script each Stop and no unloaded game assembly stays in memory; time to usable is reported;
  2. a new project (--create) whose scripts were deleted: opens and plays with no C# build error;
  3. the C# project with a syntax error: opens, the error is logged with its file and line, Play stays off;
  4. the same project after the error is fixed: plays again;
  5. Play always runs the C# on disk (--stale-build-test): a file saved elsewhere just before Play, an edit while a
     build runs, a moved file and a deleted file;
  6. hot reload through the editor (--hot-reload-test): Tests/CSharpReload plays, v2/Scripts is typed into the code
     editor and saved during Play; the save compiles and reloads, version 2's RELOAD checks pass, the old code unloads;
  7. C# completion through the editor (--completion-test): an unimported type with its using, described members, and a
     long list marked as cut short;
  8. Find All References through the editor (--references-test): a field's uses in an open and an unopened file,
     and opening one puts the caret on it.
Run: python3 tools/test_csharp_editor.py [--cycles 20]
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
LAUNCHER = ROOT / "build/Debug_Linux64/TallowLauncher/TallowLauncher"


def open_editor(project: Path, *switches: str, timeout: int = 600, env: dict | None = None):
    """Runs the editor on project; returns (output, seconds until PLAY CYCLE READY, total seconds)."""
    started = time.perf_counter()
    process = subprocess.Popen([str(LAUNCHER), "--editor", "--project", str(project), *switches],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace",
                               env={**os.environ, **(env or {})})
    lines, ready = [], None
    try:
        for line in process.stdout:
            lines.append(line)
            if ready is None and "PLAY CYCLE READY" in line:
                ready = time.perf_counter() - started
            if time.perf_counter() - started > timeout:
                process.kill()
                lines.append("TIMED OUT\n")
                break
        process.wait(timeout=60)
    finally:
        if process.poll() is None:
            process.kill()
    return "".join(lines), ready, time.perf_counter() - started


def project_copy(work: Path, name: str, source: Path) -> Path:
    project = work / name
    shutil.copytree(source, project, ignore=shutil.ignore_patterns(".tallow-*", "build", "bin", "obj"))
    text = (project / "project.tallow").read_text(encoding="utf-8")
    (project / "project.tallow").write_text(re.sub(r"(?m)^engine = .*$", f"engine = {ROOT.as_posix()}", text),
                                            encoding="utf-8")
    return project


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cycles", type=int, default=20)
    args = parser.parse_args()
    if not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
        print("test_csharp_editor.py needs a display.", file=sys.stderr)
        return 2
    if not LAUNCHER.is_file():
        print(f"Build the engine first: {LAUNCHER} is missing.", file=sys.stderr)
        return 2
    subprocess.run(["dotnet", "build", str(ROOT / "Managed/Tallow.ManagedRuntime/Tallow.ManagedRuntime.csproj"),
                    "--configuration", "Debug", "--nologo", "--verbosity", "quiet"], check=True)
    failed: list[str] = []

    def check(label: str, condition: bool, detail: str = ""):
        print(("EDITOR PASS " if condition else "EDITOR FAIL ") + label)
        if not condition:
            failed.append(label)
            if detail:
                print(detail[-2500:])

    def result(output: str) -> str:
        found = [line for line in output.splitlines() if "PLAY CYCLE TEST" in line]
        return found[-1] if found else ""

    work = Path(tempfile.mkdtemp(prefix="tallow-csharp-editor-"))
    try:
        # 1. A C# project: cold open (no .tallow-csharp yet), then Play/Stop cycles.
        game = project_copy(work, "Sandbox", ROOT / "Samples/Sandbox")
        output, ready, total = open_editor(game, "--play-cycle-test", str(args.cycles))
        line = result(output)
        check(f"C# project opens and its build finishes (usable after {ready or 0:.1f} s, cold)", ready is not None, output)
        check(f"Play/Stop x{args.cycles}: {line}", "PLAY CYCLE TEST PASS" in line, output)
        check("opening the project never runs BeefBuild", "BeefBuild" not in output, output)
        check("no unloaded game assembly stays in memory", "unloaded game assemblies are still in memory" not in output,
              output)
        output, ready_warm, _ = open_editor(game, "--play-cycle-test", "1")
        check(f"C# project reopens (usable after {ready_warm or 0:.1f} s, warm)", "PLAY CYCLE TEST PASS" in result(output),
              output)

        # 2. A new project without scripts.
        empty = work / "Empty"
        created = subprocess.run([str(LAUNCHER), "--create", str(empty)], capture_output=True, text=True)
        check("--create makes a new project", created.returncode == 0 and (empty / "project.tallow").is_file(),
              created.stdout + created.stderr)
        for script in (empty / "src").rglob("*.cs"):
            script.unlink()
        output, ready, _ = open_editor(empty, "--play-cycle-test", "3")
        check(f"a project with no C# plays: {result(output)}", "PLAY CYCLE TEST PASS" in result(output), output)
        check("a project with no C# has no build error", not re.search(r"(?i)missing compiled game|C# compilation failed",
                                                                         output), output)

        # 3. Broken C#: an error in a script.
        broken = project_copy(work, "Broken", ROOT / "Samples/Sandbox")
        scripts = sorted((broken / "src").rglob("*.cs"))
        target = scripts[0]
        original = target.read_text(encoding="utf-8")
        target.write_text(original.rstrip() + "\nclass Broken { int x = ; }\n", encoding="utf-8")
        output, ready, _ = open_editor(broken, "--play-cycle-test", "1", "--expect-play-blocked")
        check(f"a broken project opens and Play stays off: {result(output)}", "PLAY CYCLE TEST PASS" in result(output),
              output)
        check(f"the error names its file ({target.name})", re.search(re.escape(target.name) + r".*error CS", output)
              is not None, output)

        # 4. Fixed: plays again.
        target.write_text(original, encoding="utf-8")
        output, ready, _ = open_editor(broken, "--play-cycle-test", "2")
        check(f"after the fix it plays: {result(output)}", "PLAY CYCLE TEST PASS" in result(output), output)

        # 5. No stale builds.
        output, _, _ = open_editor(broken, "--stale-build-test")
        found = [line for line in output.splitlines() if "STALE BUILD TEST" in line]
        check(f"Play runs the C# on disk: {found[-1] if found else 'no result'}",
              bool(found) and "STALE BUILD TEST PASS" in found[-1], output)

        # 6. Hot reload through the editor: save during Play.
        reload = work / "Reload"
        shutil.copytree(ROOT / "Tests/CSharpReload", reload, ignore=shutil.ignore_patterns(".tallow-*", "v2", "bin", "obj"))
        (reload / "project.tallow").write_text(
            f"name = Reload\nstartScene = Scenes/Main.tscene\nengine = {ROOT.as_posix()}\n", encoding="utf-8")
        output, _, _ = open_editor(reload, "--hot-reload-test", str(ROOT / "Tests/CSharpReload/v2/Scripts"),
                                   env={"TALLOW_RELOAD_UNLOAD_CHECK": "1"})
        found = [line for line in output.splitlines() if "HOT RELOAD TEST" in line]
        passes = sum("RELOAD PASS" in line for line in output.splitlines())
        reload_failures = [line for line in output.splitlines() if "RELOAD FAIL" in line or "[Tallow C#]" in line]
        took = next((line for line in found if "reloaded" in line), "")
        check(f"saving C# during Play reloads it ({took.split('TEST ')[-1] if took else 'no reload'}): "
              f"{found[-1] if found else 'no result'}", bool(found) and "HOT RELOAD TEST PASS" in found[-1], output)
        check(f"the reloaded game keeps its state ({passes} RELOAD checks)", passes == 25 and not reload_failures,
              "\n".join(reload_failures) or output)

        # 7. Completion through the editor and the language service.
        output, _, _ = open_editor(game, "--completion-test")
        found = [line for line in output.splitlines() if "COMPLETION TEST" in line]
        check(f"C# completion in the editor: {found[-1] if found else 'no result'}",
              bool(found) and "COMPLETION TEST PASS" in found[-1], output)

        # 8. Find All References through the editor and the language service.
        output, _, _ = open_editor(game, "--references-test")
        found = [line for line in output.splitlines() if "REFERENCES TEST" in line]
        check(f"C# Find All References in the editor: {found[-1] if found else 'no result'}",
              bool(found) and "REFERENCES TEST PASS" in found[-1], output)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if failed:
        print(f"C# editor checks FAILED: {len(failed)}")
        return 1
    print("C# editor checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
