#!/usr/bin/env python3
"""Serve Tallow's source-snapshot semantic requests using the .NET SDK's Roslyn compiler.

Same request.tsv/response.tsv wire format as the editor's existing code widget.
Never edits project sources. .NET 11 SDK is required; untrusted mod loading is
not part of this tooling.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
SERVICE = ROOT / "Managed" / "Tallow.LanguageService" / "Tallow.LanguageService.csproj"
BUILD = ROOT / "Managed" / "Tallow.LanguageService" / "bin" / "Debug" / "net11.0" / "Tallow.LanguageService.dll"


def clean(text: object) -> str:
    return " ".join(str(text).split())


def response(folder: Path, kind: str, detail: str) -> None:
    (folder / "response.tsv").write_text(f"{kind}\t{clean(detail)}\n", encoding="utf-8")


def request(folder: Path) -> tuple[dict[str, str], dict[Path, Path]]:
    values: dict[str, str] = {}
    overlays: dict[Path, Path] = {}
    for line in (folder / "request.tsv").read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        if len(fields) == 3 and fields[0] == "overlay":
            overlays[Path(fields[1]).resolve()] = Path(fields[2]).resolve()
        elif len(fields) == 2:
            values[fields[0]] = fields[1]
        else:
            raise ValueError("Invalid language-service request record.")
    return values, overlays


def dotnet() -> str:
    path = shutil.which(os.environ.get("TALLOW_DOTNET", "dotnet"))
    if path is None:
        raise RuntimeError("C# IntelliSense requires the .NET 11 SDK.")
    return path


def ensure_compiled(executable: str, folder: Path) -> None:
    sources = [SERVICE, SERVICE.with_name("Program.cs")]
    if BUILD.exists() and BUILD.stat().st_mtime_ns >= max(f.stat().st_mtime_ns for f in sources):
        return
    result = subprocess.run(
        [executable, "build", str(SERVICE), "-c", "Debug", "--nologo", "--verbosity", "quiet"],
        capture_output=True, text=True, timeout=120)
    (folder / "roslyn-build.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode != 0 or not BUILD.is_file():
        raise RuntimeError("Roslyn language-service build failed; see roslyn-build.log.")


def semantic(project: Path, folder: Path) -> None:
    values, overlays = request(folder)
    operation = values["operation"]
    path = Path(values["file"]).resolve()
    src = (project / "src").resolve()
    if path.suffix != ".cs" or not path.is_relative_to(src):
        raise ValueError("The C# language service only accepts project C# sources.")
    if operation not in ("completion", "signature", "definition", "symbol",
                         "diagnostics", "references", "rename"):
        raise ValueError(f"Unsupported C# editor operation: {operation}")

    sources = {}
    for source in sorted(src.rglob("*.cs")):
        if ".tallow-csharp" in source.parts:
            continue
        resolved = source.resolve()
        sources[resolved] = source.read_text(encoding="utf-8")
    for source in sorted((ROOT / "Managed" / "Tallow.API").rglob("*.cs")):
        sources[source.resolve()] = source.read_text(encoding="utf-8")
    for source, replacement in overlays.items():
        if not source.is_relative_to(src) or source.suffix != ".cs":
            raise ValueError("Unexpected C# source overlay.")
        sources[source] = replacement.read_text(encoding="utf-8")

    payload = {
        "operation": operation,
        "file": str(path),
        "cursor": int(values.get("cursor", "0")),
        "newName": values.get("new_name", ""),
        "sources": [{"path": str(source), "text": text}
                    for source, text in sources.items()],
    }
    if path not in sources:
        raise ValueError("The requested C# source is not part of the project.")

    input_file = folder / "roslyn-request.json"
    input_file.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    executable = dotnet()
    ensure_compiled(executable, folder)
    result = subprocess.run(
        [executable, str(BUILD), str(input_file), str(folder / "response.tsv")],
        capture_output=True, text=True, timeout=90)
    if result.returncode and not (folder / "response.tsv").is_file():
        raise RuntimeError(f"Roslyn worker exited {result.returncode}: {clean(result.stderr[-250:])}")
    if not (folder / "response.tsv").exists():
        raise RuntimeError("Roslyn worker did not write a response.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True, type=Path)
    parser.add_argument("--request", required=True, type=Path)
    args = parser.parse_args()
    folder = args.request.resolve()
    try:
        semantic(args.project.resolve(), folder)
    except (OSError, KeyError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        response(folder, "error", str(error))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
