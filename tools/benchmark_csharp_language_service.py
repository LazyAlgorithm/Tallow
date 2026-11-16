#!/usr/bin/env python3
"""Times the C# code editor's Roslyn service the way the editor uses it: one long-running
`Tallow.LanguageService --serve` process taking request folders from a queue.

Phases (on a scratch copy of Tests/CSharpInGame, whose ApiChecks.cs is ~1,400 lines):
  start       process start until the service writes its ready file
  cold        the first request (references loaded, every source parsed, compilation made)
  warm        the same request again, nothing changed
  edit        a request right after the open file changed (the editor's unsaved-text overlay)
  completion  member completion after "Transform." with an edit each time
  signature   signature help inside a call, with an edit each time
  definition  Go to Definition on a field, nothing changed
Prints median and slowest milliseconds per phase and the service's peak memory (Linux).

  python3 tools/benchmark_csharp_language_service.py [--runs 15]
"""
import argparse
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SERVICE = ROOT / "Managed/Tallow.LanguageService/bin/Debug/net11.0/Tallow.LanguageService.dll"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=15)
    args = parser.parse_args()
    subprocess.run(["dotnet", "build", str(ROOT / "Managed/Tallow.LanguageService/Tallow.LanguageService.csproj"),
                    "-c", "Debug", "--nologo", "--verbosity", "quiet"], check=True)
    work = Path(tempfile.mkdtemp(prefix="tallow-ls-bench-"))
    try:
        project = work / "Game"
        shutil.copytree(ROOT / "Tests/CSharpInGame", project,
                        ignore=shutil.ignore_patterns(".tallow-csharp", "bin", "obj"))
        source = project / "src/Scripts/ApiChecks.cs"
        text = source.read_text(encoding="utf-8")
        queue = work / "queue"
        started = time.perf_counter()
        process = subprocess.Popen(["dotnet", str(SERVICE), "--serve", str(queue), "--project", str(project),
                                    "--engine-root", str(ROOT)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            while not (queue / "ready").exists():
                if process.poll() is not None:
                    sys.exit("The language service exited before it was ready.")
                time.sleep(0.005)
            start_ms = (time.perf_counter() - started) * 1000
            counter = [0]

            def request(operation, body, needle, after=True):
                """One request with the open file's text as an overlay; the caret at needle (after it or at it)."""
                counter[0] += 1
                folder = queue / f"r{counter[0]}"
                folder.mkdir()
                overlay = folder / "overlay.cs"
                overlay.write_text(body, encoding="utf-8")
                index = body.index(needle) + (len(needle) if after else 0)
                cursor = len(body[:index].encode("utf-8"))
                pending = folder / "request.tsv.tmp"
                pending.write_text(f"operation\t{operation}\nfile\t{source}\ncursor\t{cursor}\n"
                                   f"overlay\t{source}\t{overlay}\n", encoding="utf-8")
                begin = time.perf_counter()
                pending.rename(folder / "request.tsv")
                response = folder / "response.tsv"
                while not response.exists():
                    if process.poll() is not None:
                        sys.exit("The language service exited during a request.")
                    time.sleep(0.001)
                elapsed = (time.perf_counter() - begin) * 1000
                answer = response.read_text(encoding="utf-8")
                shutil.rmtree(folder)
                if answer.startswith("error\t"):
                    sys.exit(f"{operation} failed: {answer.strip()}")
                return elapsed, answer

            # A method body to type into: completion after "Transform." and signature help inside Log.Info(.
            marker = "    public override void Start() => _started = true;"
            assert marker in text, "ApiChecks.cs changed: update the benchmark's marker"

            def edited(n, insert):
                return text.replace(marker, f"    void Typing{n}() {{ var n{n} = {n}; {insert} }}\n" + marker)

            results = {}
            cold, _ = request("diagnostics", text, marker)
            results["cold (diagnostics)"] = [cold]
            results["warm (diagnostics)"] = [request("diagnostics", text, marker)[0] for _ in range(args.runs)]
            results["edit (diagnostics)"] = [request("diagnostics", edited(i, ""), marker)[0] for i in range(args.runs)]
            # Correctness: an error typed into the game file is reported there; nothing from Tallow.API's sources.
            _, answer = request("diagnostics", edited(99, "int broken = ;"), marker)
            problems = [line.split("\t") for line in answer.splitlines() if line.startswith("diagnostic\t")]
            same = lambda a, b: os.path.normcase(a) == os.path.normcase(str(b))
            if not any(same(fields[1], source) and fields[4] == "error" for fields in problems):
                sys.exit("an error typed into ApiChecks.cs was not reported:\n" + answer[:800])
            if any(not os.path.normcase(fields[1]).startswith(os.path.normcase(str(project))) for fields in problems):
                sys.exit("diagnostics were reported outside the game's sources:\n" + answer[:800])
            completions = []
            for i in range(args.runs):
                elapsed, answer = request("completion", edited(i, "Transform."), "Transform.")
                if "completion\tPosition\t" not in answer:
                    sys.exit("completion after Transform. did not offer Position:\n" + answer[:500])
                completions.append(elapsed)
            results["completion"] = completions
            signatures = []
            for i in range(args.runs):
                elapsed, answer = request("signature", edited(i, 'Log.Info("x");'), 'Log.Info(')
                if "signature\t" not in answer:
                    sys.exit("signature help inside Log.Info( found nothing:\n" + answer[:500])
                signatures.append(elapsed)
            results["signature"] = signatures
            definition = "Speed == 3f"
            assert definition in text
            results["definition"] = [request("definition", text, definition, after=False)[0] for _ in range(args.runs)]

            peak = ""
            status = Path(f"/proc/{process.pid}/status")
            if status.exists():
                for line in status.read_text().splitlines():
                    if line.startswith("VmHWM:"):
                        peak = f"{int(line.split()[1]) / 1024:.0f} MB"
            print(f"source: {source.name} ({text.count(chr(10))} lines) plus Tallow.API sources")
            print(f"{'start':<22}{start_ms:>9.0f} ms")
            for name, times in results.items():
                if len(times) == 1:
                    print(f"{name:<22}{times[0]:>9.0f} ms")
                else:
                    print(f"{name:<22}{statistics.median(times):>9.1f} ms median, {max(times):.1f} ms slowest ({len(times)} runs)")
            if peak:
                print(f"{'peak memory':<22}{peak:>12}")
        finally:
            (queue / "stop").write_text("stop")
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
