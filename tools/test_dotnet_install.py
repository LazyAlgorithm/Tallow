#!/usr/bin/env python3
"""Checks Tallow's own .NET SDK install (Editor/src/Project/DotNetSdk.bf) in a scratch folder (TALLOW_DOTNET_HOME),
never the user's real one:
  1. a damaged archive is refused and leaves nothing behind;
  2. a staging folder left by an install that was killed (older than an hour) is cleared by the next install;
  3. the pinned SDK installs (downloaded, about 230 MB, or --archive FILE: an offline copy of the same file);
  4. installing again reuses it without downloading;
  5. --check-dependencies then reports the pinned SDK and runtime with no problems (PATH and DOTNET_ROOT routing).
Run: python3 tools/test_dotnet_install.py [--archive dotnet-sdk-<version>-<rid>.tar.gz] [--keep]
Not in CI (it downloads the SDK).
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
PINNED = re.search(r'PinnedVersion = "([^"]+)"', (ROOT / "Editor/src/Project/DotNetSdk.bf").read_text()).group(1)


def run(home: Path, *args: str, timeout: int = 900):
    env = {**os.environ, "TALLOW_DOTNET_HOME": str(home)}
    result = subprocess.run([str(LAUNCHER), *args], capture_output=True, text=True, env=env, timeout=timeout)
    return result.returncode, result.stdout + result.stderr


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", help="an offline copy of the pinned SDK archive")
    parser.add_argument("--keep", action="store_true", help="keep the scratch folder")
    options = parser.parse_args()
    failed = []

    def check(label: str, ok: bool, detail: str = "") -> None:
        print(f"{'PASS' if ok else 'FAIL'}: {label}")
        if not ok:
            failed.append(label)
            if detail:
                print(detail[-2000:])

    work = Path(tempfile.mkdtemp(prefix="tallow-dotnet-install-"))
    home = work / "dotnet"
    try:
        bogus = work / "bogus.tar.gz"
        bogus.write_bytes(os.urandom(1 << 20))
        code, output = run(home, "--install-dotnet", "--from-archive", str(bogus))
        leftovers = list(home.iterdir()) if home.exists() else []
        check("a damaged archive is refused and leaves nothing", code != 0 and "damaged" in output and not leftovers,
              output)

        stale = home / f".staging-{PINNED}-1"
        (stale / "root").mkdir(parents=True)
        old = time.time() - 3 * 3600
        os.utime(stale, (old, old))
        started = time.perf_counter()
        args = ["--install-dotnet"] + (["--from-archive", options.archive] if options.archive else [])
        code, output = run(home, *args)
        took = time.perf_counter() - started
        installed = home / PINNED / ("dotnet.exe" if os.name == "nt" else "dotnet")
        check(f"the pinned SDK {PINNED} installs ({took:.0f} s)", code == 0 and installed.exists(), output)
        check("a killed install's staging folder is cleared, and this one's is gone",
              not any(path.name.startswith(".staging-") for path in home.iterdir()), str(list(home.iterdir())))

        started = time.perf_counter()
        code, output = run(home, "--install-dotnet")
        check(f"installing again reuses it ({time.perf_counter() - started:.1f} s)",
              code == 0 and "already installed" in output, output)

        code, output = run(home, "--check-dependencies", timeout=300)
        check("the launcher's checks use it (PATH, DOTNET_ROOT)",
              code == 0 and f".NET SDK: {PINNED}\n" in output and "Everything C# gameplay needs" in output, output)
    finally:
        if options.keep:
            print(f"Kept {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)
    if failed:
        print(f".NET install checks FAILED: {len(failed)}")
        return 1
    print(".NET install checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
