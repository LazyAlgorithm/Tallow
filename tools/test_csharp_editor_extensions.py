#!/usr/bin/env python3
"""C# editor scripts in the editor: a scratch copy of Tests/CSharpInGame with Tests/CSharpEditorExtensions/Editor as
src/Editor, opened with --editor-extensions-test (Editor/src/Tools/EditorExtensionsTest.bf): a custom Inspector,
editor windows (one failing on purpose), a Tools menu command, Preferences tabs, EditorPrefs/ProjectPrefs, a reload
after a new editor script, and that a game build leaves the editor scripts out. Needs a display (not for CI).

  python3 tools/test_csharp_editor_extensions.py [--keep] [--screenshot PNG]
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))  # noqa: E402
import dotnet_sdk  # noqa: E402,F401  (the released .NET SDK Tallow pins, when installed)

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("--screenshot", help="a picture of the editor near the end")
    options = parser.parse_args()
    launcher = ROOT / "build/Debug_Linux64/TallowLauncher/TallowLauncher"
    work = Path(tempfile.mkdtemp(prefix="tallow-editor-ext-"))
    failures = []
    try:
        project = work / "InGame"
        shutil.copytree(ROOT / "Tests/CSharpInGame", project, ignore=shutil.ignore_patterns(".tallow-*", "build"))
        shutil.copytree(ROOT / "Tests/CSharpEditorExtensions/Editor", project / "src/Editor")
        template = (ROOT / "Editor/templates/empty/Scripts/FirstPersonCharacter.cs.txt").read_text(encoding="utf-8")
        (project / "src/Scripts/FirstPersonCharacter.cs").write_text(template.replace("{NAMESPACE}", "InGame"), encoding="utf-8")
        (project / "project.tallow").write_text(f"name = InGame\nstartScene = Scenes/Main.tscene\nengine = {ROOT.as_posix()}\n", encoding="utf-8")
        # The editor's own settings (layout, EditorPrefs) in the scratch folder, not this user's.
        env = dict(os.environ, XDG_DATA_HOME=str(work / "data"))
        command = [str(launcher), "--editor", "--project", str(project), "--editor-extensions-test"]
        if options.screenshot:
            command += ["--test-screenshot", str(Path(options.screenshot).resolve())]
        run = subprocess.run(command, capture_output=True, text=True, timeout=300, env=env)
        output = run.stdout + run.stderr
        result = [line for line in output.splitlines() if "EDITOR EXTENSIONS TEST" in line]
        if result and "EDITOR EXTENSIONS TEST PASS" in result[0]:
            for part in result[0].split(": ", 1)[1].split("; "):
                print("PASS " + part)
        else:
            failures.append(result[0] if result else "no result: " + output[-3000:])
        # A failing editor script is reported (once), and the editor carries on.
        broken = output.count("The broken window fails on purpose.")
        if broken < 1:
            failures.append("the broken window's exception was not reported")
        elif broken > 2:
            failures.append(f"the broken window's exception was reported {broken} times, not once")
        else:
            print("PASS the broken window's failure is reported once and the editor carries on")
        # A game build has no editor scripts.
        out = work / "game"
        built = subprocess.run([sys.executable, str(ROOT / "tools/build_player.py"), str(project), "--output", str(out),
                                "--csharp-runtime", "jit", "--no-bundle-dotnet"], capture_output=True, text=True, timeout=900)
        editor_files = [path for path in out.rglob("*") if "Tallow.Game.Editor" in path.name or path.name == "Tallow.Editor.dll"]
        if built.returncode != 0:
            failures.append("the game did not build: " + (built.stdout + built.stderr)[-2000:])
        elif editor_files:
            failures.append(f"the game build has editor scripts: {editor_files}")
        else:
            print("PASS a game build leaves the editor scripts and Tallow.Editor out")
        for failure in failures:
            print("FAIL " + failure)
        print("PASS: C# editor scripts work in the editor" if not failures else f"FAIL: {len(failures)} failed")
        return 1 if failures else 0
    finally:
        if options.keep:
            print(f"Kept: {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
