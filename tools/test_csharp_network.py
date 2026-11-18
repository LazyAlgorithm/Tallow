#!/usr/bin/env python3
"""C# [Sync] fields between a real server and client.

Builds Tests/CSharpNetwork, starts a headless server and a headless client of it
on localhost, and passes when the client logs "NETTEST DONE" with no failures.

    python3 tools/test_csharp_network.py [--config Debug] [--port 47777]
"""
from __future__ import annotations

import argparse
import platform
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))  # noqa: E402
import dotnet_sdk  # noqa: E402,F401  (the released .NET SDK Tallow pins, when installed)

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="Debug")
    parser.add_argument("--port", type=int, default=47777)
    parser.add_argument("--keep", action="store_true", help="keep the temporary project")
    args = parser.parse_args()

    windows = platform.system() == "Windows"
    target = f"{args.config}_{'Win64' if windows else 'Linux64'}"
    launcher = ROOT / "build" / target / "TallowLauncher" / ("TallowLauncher.exe" if windows else "TallowLauncher")
    if not launcher.is_file():
        print(f"Build the engine first: {launcher} is missing.", file=sys.stderr)
        return 2

    work = Path(tempfile.mkdtemp(prefix="tallow-csharp-network-"))
    server = None
    try:
        project = work / "NetGame"
        shutil.copytree(ROOT / "Tests/CSharpNetwork", project, ignore=shutil.ignore_patterns(".tallow-*", "build"))
        (project / "project.tallow").write_text(
            f"name = NetGame\nstartScene = Scenes/Main.tscene\nengine = {ROOT.as_posix()}\n", encoding="utf-8")
        build = subprocess.run(
            ["dotnet", "run", "--project", str(ROOT / "Managed/Tallow.Build/Tallow.Build.csproj"),
             "--", "--project", str(project), "--engine-root", str(ROOT)],
            capture_output=True, text=True)
        if build.returncode != 0:
            print(build.stdout + build.stderr)
            print("C# network test project did not compile.", file=sys.stderr)
            return 1
        subprocess.run(["dotnet", "build", str(ROOT / "Managed/Tallow.ManagedRuntime/Tallow.ManagedRuntime.csproj"),
                        "--configuration", "Debug", "--nologo", "--verbosity", "quiet"], check=True)

        common = [str(launcher), "--game", "--project", str(project), "--headless", "--port", str(args.port)]
        server_log = open(work / "server.log", "w")
        server = subprocess.Popen(common + ["--server", "--frames", "100000"], stdout=server_log,
                                  stderr=subprocess.STDOUT, text=True)
        time.sleep(2)
        client = subprocess.run(common + ["--connect", "127.0.0.1", "--frames", "100000"],
                                capture_output=True, text=True, timeout=120)
        output = client.stdout + client.stderr
        (work / "client.log").write_text(output, encoding="utf-8")
        lines = [line for line in output.splitlines() if "NETTEST" in line or "[Tallow C#]" in line]
        print("\n".join(lines))
        passed = sum("NETTEST PASS" in line for line in lines)
        failed = [line for line in lines if "NETTEST FAIL" in line or "[Tallow C#]" in line]
        if failed or not any("NETTEST DONE" in line for line in lines):
            if not lines:
                print(output[-4000:])
            server_log.flush()
            print("--- server ---")
            print((work / "server.log").read_text(errors="replace")[-3000:])
            print(f"C# network checks failed ({passed} passed, {len(failed)} failed).", file=sys.stderr)
            return 1
        print(f"C# network checks passed: {passed}.")
        return 0
    finally:
        if server is not None:
            server.kill()
            server.wait()
        if args.keep:
            print(f"Kept {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
