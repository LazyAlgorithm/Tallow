#!/usr/bin/env python3
"""C# hot reload in a network session (CSharpNetReload): Tests/CSharpNetReload runs as a headless server and two
clients. Version 2 is built into another folder (each machine builds its own code; none is sent over the network).

  1. Client A loads version 2 early (--csharp-reload-after 1.5 s): it is a client, so it waits for the host.
  2. The server reloads version 2 later (6 s) and announces its code ID; client A follows at once.
  3. Version 2 on client A checks it runs and that the server's [Sync] value comes from version 2.
  4. Client B joins afterwards on version 1: it is told the host runs other code and warned.

    python3 tools/test_csharp_network_reload.py [--config Debug] [--port 47787]
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
EXPECTED = 7


def build(project: Path, *extra: str) -> bool:
    run = subprocess.run(["dotnet", "run", "--project", str(ROOT / "Managed/Tallow.Build/Tallow.Build.csproj"), "--",
                          "--project", str(project), "--engine-root", str(ROOT), *extra], capture_output=True, text=True)
    if run.returncode != 0:
        print(run.stdout + run.stderr)
    return run.returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", default="Debug")
    parser.add_argument("--port", type=int, default=47787)
    parser.add_argument("--keep", action="store_true", help="keep the temporary projects")
    args = parser.parse_args()
    windows = platform.system() == "Windows"
    target = f"{args.config}_{'Win64' if windows else 'Linux64'}"
    launcher = ROOT / "build" / target / "TallowLauncher" / ("TallowLauncher.exe" if windows else "TallowLauncher")
    if not launcher.is_file():
        print(f"Build the engine first: {launcher} is missing.", file=sys.stderr)
        return 2
    work = Path(tempfile.mkdtemp(prefix="tallow-csharp-netreload-"))
    server = None
    try:
        project = work / "NetReload"
        shutil.copytree(ROOT / "Tests/CSharpNetReload", project, ignore=shutil.ignore_patterns(".tallow-*", "build", "v2"))
        (project / "project.tallow").write_text(
            f"name = NetReload\nstartScene = Scenes/Main.tscene\nengine = {ROOT.as_posix()}\n", encoding="utf-8")
        second = work / "NetReload2"
        shutil.copytree(project, second)
        shutil.rmtree(second / "src/Scripts")
        shutil.copytree(ROOT / "Tests/CSharpNetReload/v2/Scripts", second / "src/Scripts")
        if not build(project) or not build(second, "--output", str(work / "v2bin")):
            print("The network reload test project did not compile.", file=sys.stderr)
            return 1
        v1_id = (project / ".tallow-csharp/bin/Tallow.Game/Tallow.Game.codeid").read_text().strip()
        v2_id = (work / "v2bin/Tallow.Game/Tallow.Game.codeid").read_text().strip()
        subprocess.run(["dotnet", "build", str(ROOT / "Managed/Tallow.ManagedRuntime/Tallow.ManagedRuntime.csproj"),
                        "--configuration", "Debug", "--nologo", "--verbosity", "quiet"], check=True)
        passed = 0
        failed: list[str] = []

        def check(ok: bool, what: str) -> None:
            nonlocal passed
            print(("NETRELOAD PASS " if ok else "NETRELOAD FAIL ") + what)
            if ok:
                passed += 1
            else:
                failed.append(what)

        check(len(v1_id) == 16 and len(v2_id) == 16 and v1_id != v2_id, f"each build has a code ID ({v1_id}, {v2_id})")
        # The same sources built elsewhere (another folder, a Release build) have the same ID.
        if build(project, "--configuration", "Release", "--output", str(work / "v1release")):
            again = (work / "v1release/Tallow.Game/Tallow.Game.codeid").read_text().strip()
            check(again == v1_id, f"the same sources built elsewhere have the same ID ({again})")
        else:
            check(False, "the Release build compiled")

        v2 = str(work / "v2bin/Tallow.Game/Tallow.Game.dll")
        common = [str(launcher), "--game", "--project", str(project), "--headless", "--port", str(args.port)]
        server_log = open(work / "server.log", "w")
        server = subprocess.Popen(common + ["--server", "--frames", "100000", "--csharp-reload-test", v2,
                                            "--csharp-reload-after", "6"],
                                  stdout=server_log, stderr=subprocess.STDOUT, text=True)
        time.sleep(2)
        client = subprocess.run(common + ["--connect", "127.0.0.1", "--frames", "1000000", "--csharp-reload-test", v2,
                                          "--csharp-reload-after", "1.5"], capture_output=True, text=True, timeout=180)
        output = client.stdout + client.stderr
        (work / "client.log").write_text(output, encoding="utf-8")
        lines = output.splitlines()
        waited = next((i for i, line in enumerate(lines) if "This machine is a client: it loads when the host" in line), -1)
        followed = next((i for i, line in enumerate(lines) if "following the host's code" in line), -1)
        check(waited >= 0, "a client that built a change first waits for the host")
        check(followed > waited >= 0, "it reloads when the host reloads the same code")
        for line in lines:
            if "NETRELOAD PASS" in line or "NETRELOAD FAIL" in line:
                print(line)
        check(any("NETRELOAD PASS" in line for line in lines) and not any("NETRELOAD FAIL" in line for line in lines)
              and any("NETRELOAD DONE" in line for line in lines), "version 2 runs on the client and on the server")

        late = subprocess.run(common + ["--connect", "127.0.0.1", "--frames", "240"], capture_output=True, text=True,
                              timeout=120)
        late_output = late.stdout + late.stderr
        (work / "late.log").write_text(late_output, encoding="utf-8")
        check(f"The host runs other C# code than this machine (host {v2_id}, here {v1_id})" in late_output,
              "a client that joins on other code is warned")
        server_log.flush()
        server_text = (work / "server.log").read_text(errors="replace")
        check("C# hot reload sent to the session (1 client)" in server_text, "the host tells the session it reloaded")
        if failed or passed != EXPECTED:
            print("--- client ---\n" + output[-3000:])
            print("--- server ---\n" + server_text[-3000:])
            print(f"C# network reload checks failed ({passed} of {EXPECTED} passed).", file=sys.stderr)
            return 1
        print(f"C# network reload checks passed: {passed}.")
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
