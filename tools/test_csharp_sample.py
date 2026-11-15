#!/usr/bin/env python3
"""The Voxel sandbox template, all C#: creates a project from it, lets the first run build its scene and player
prefab, adds a probe script, and runs it headless. Passes when the probe logs "SAMPLE DONE" with no failures.

    python3 tools/test_csharp_sample.py [--config Debug] [--keep]
"""
from __future__ import annotations

import argparse
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

PROBE = """using System.Numerics;
using Tallow;

namespace SampleGame;

/// Checks the sample's C# scripts work together once the player has spawned and moved a little.
public class SampleProbe : Script
{
    private int _frames;

    private static void Check(string label, bool ok) => Log.Info((ok ? "SAMPLE PASS " : "SAMPLE FAIL ") + label);

    public override void FixedUpdate(float deltaTime)
    {
        if (++_frames != 120)
            return;
        GameObject? player = Scene.Find("Player");
        Check("the Network Session spawns Prefabs/Player.tprefab", player != null);
        if (player is { } p)
        {
            Check("the player has the built-in Character Motor", p.GetComponent<CharacterMotor>().IsValid);
            Check("the player runs FollowCamera and CharacterAnimation", p.GetComponent<FollowCamera>() != null && p.GetComponent<CharacterAnimation>() != null);
            Animator animator = p.GetComponentInChildren<Animator>();
            Check($"CharacterAnimation drives the character's Animator ({animator.CurrentClip})", animator.IsValid && animator.CurrentClip != "");
            GameObject? camera = Scene.Find("Main Camera");
            float distance = camera is { } c ? Vector3.Distance(c.Transform.Position, p.Transform.Position) : -1;
            Check($"FollowCamera puts the camera behind the player ({distance:0.0} m)", distance > 3 && distance < 12);
        }
        GameObject? cameraObject = Scene.Find("Main Camera");
        Check("Digger and Hud are on the camera", cameraObject?.GetComponent<Digger>() != null && cameraObject?.GetComponent<Hud>() != null);
        VoxelTerrain? terrain = VoxelTerrain.Find(Scene);
        Check("VoxelTerrain.Find gives the sample's terrain", terrain is { } t && t.GameObject.Name == "Terrain");
        Check("VoxelTerrain.ModifySphere digs", terrain?.ModifySphere(new Vector3(20, 30, 20), 3, -1) == true);
        GameObject? boulder = Scene.Find("Boulder");
        VoxelObject voxels = boulder?.GetComponent<VoxelObject>() ?? default;
        Check("VoxelObject.Carve cuts the boulder", voxels.IsValid && voxels.Carve(boulder!.Value.Transform.Position, 0.9f));
        Check("the menu runs SampleMenu", Scene.Find("Sample Menu")?.GetComponent<SampleMenu>() != null);
        Log.Info("SAMPLE DONE");
        Application.Quit();
    }
}
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="Debug")
    parser.add_argument("--keep", action="store_true", help="keep the temporary project")
    args = parser.parse_args()
    windows = platform.system() == "Windows"
    target = f"{args.config}_{'Win64' if windows else 'Linux64'}"
    launcher = ROOT / "build" / target / "TallowLauncher" / ("TallowLauncher.exe" if windows else "TallowLauncher")
    if not launcher.is_file():
        print(f"Build the engine first: {launcher} is missing.", file=sys.stderr)
        return 2
    work = Path(tempfile.mkdtemp(prefix="tallow-csharp-sample-"))
    try:
        project = work / "SampleGame"
        created = subprocess.run([str(launcher), "--create", str(project), "--sample"], capture_output=True, text=True)
        if created.returncode != 0:
            print(created.stdout + created.stderr)
            return 1
        if (project / "BeefProj.toml").exists() or list((project / "src").rglob("*.bf")):
            print("The C# sample template still writes Beef files.", file=sys.stderr)
            return 1
        build_command = ["dotnet", "run", "--project", str(ROOT / "Managed/Tallow.Build/Tallow.Build.csproj"),
                         "--", "--project", str(project), "--engine-root", str(ROOT)]

        def build() -> bool:
            result = subprocess.run(build_command, capture_output=True, text=True)
            output = result.stdout + result.stderr
            warnings = [line for line in output.splitlines() if ": warning CS" in line]
            if result.returncode != 0 or warnings:
                print(output[-4000:])
                print("The sample's C# did not compile cleanly.", file=sys.stderr)
                return False
            return True

        if not build():
            return 1
        game = [str(launcher), "--game", "--project", str(project), "--headless"]
        # The first run builds Scenes/Main.tscene and Prefabs/Player.tprefab.
        first = subprocess.run(game + ["--frames", "20"], capture_output=True, text=True, timeout=300)
        scene_path = project / "src/Scenes/Main.tscene"
        if not scene_path.is_file() or not (project / "src/Prefabs/Player.tprefab").is_file():
            print(first.stdout[-3000:] + first.stderr[-2000:])
            print("The first run did not write the sample scene and player prefab.", file=sys.stderr)
            return 1
        scene = scene_path.read_text(encoding="utf-8")
        next_id = max(int(n) for n in re.findall(r"^object (\d+)", scene, re.M)) + 1
        scene += (f'object {next_id} parent 0 active 1 name "Sample Probe"\n'
                  "transform 0 0 0 0 0 0 1 1 1 1\n"
                  "component Tallow.CSharpBehaviour enabled 1\n"
                  'field scriptType "SampleGame.SampleProbe"\n'
                  'field fieldOverrides ""\n')
        scene_path.write_text(scene, encoding="utf-8")
        (project / "src/Scripts/SampleProbe.cs").write_text(PROBE, encoding="utf-8")
        if not build():
            return 1
        run = subprocess.run(game + ["--frames", "2000"], capture_output=True, text=True, timeout=300)
        output = run.stdout + run.stderr
        (work / "game.log").write_text(output, encoding="utf-8")
        lines = [line for line in output.splitlines() if "SAMPLE" in line or "[Tallow C#]" in line]
        print("\n".join(lines))
        passed = sum("SAMPLE PASS" in line for line in lines)
        failed = [line for line in lines if "SAMPLE FAIL" in line or "[Tallow C#]" in line]
        if failed or not any("SAMPLE DONE" in line for line in lines):
            if not lines:
                print(output[-4000:])
            print(f"C# sample checks failed ({passed} passed, {len(failed)} failed).", file=sys.stderr)
            return 1
        print(f"C# sample checks passed: {passed}.")
        return 0
    finally:
        if args.keep:
            print(f"Kept {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
