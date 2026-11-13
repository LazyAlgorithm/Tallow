#!/usr/bin/env python3
"""Build trusted Tallow C# gameplay assemblies with the .NET 11 SDK.

A folder containing a *.asmdef JSON file owns its descendant .cs files, except
files under a nested assembly-definition folder. Files without an asmdef belong
to Tallow.Game. External plug-ins/mod assemblies are intentionally unsupported.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_.]*$")


def xml_write(root: ET.Element, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tree = ET.ElementTree(root)
    ET.indent(tree, space="  ")
    tree.write(path, encoding="unicode", xml_declaration=True)


def project_xml(name: str, files: list[Path], api: Path,
                refs: list[Path], output: Path) -> ET.Element:
    root = ET.Element("Project", Sdk="Microsoft.NET.Sdk")
    group = ET.SubElement(root, "PropertyGroup")
    properties = {
        "TargetFramework": "net11.0",
        "LangVersion": "15.0",
        "Nullable": "enable",
        "ImplicitUsings": "enable",
        "EnableDefaultCompileItems": "false",
        "AssemblyName": name,
        "RootNamespace": name,
        "AllowUnsafeBlocks": "false",
        "Deterministic": "true",
        "OutputPath": str(output) + os.sep,
        "AppendTargetFrameworkToOutputPath": "false",
        "AppendRuntimeIdentifierToOutputPath": "false",
    }
    for key, value in properties.items():
        ET.SubElement(group, key).text = value
    includes = ET.SubElement(root, "ItemGroup")
    for file in files:
        ET.SubElement(includes, "Compile", Include=str(file))
    references = ET.SubElement(root, "ItemGroup")
    ET.SubElement(references, "ProjectReference", Include=str(api))
    for ref in refs:
        ET.SubElement(references, "ProjectReference", Include=str(ref))
    return root


def generate(project: Path, engine: Path) -> tuple[Path, dict[str, Path]]:
    source = project / "src"
    if not source.is_dir():
        raise ValueError(f"Missing game source folder: {source}")
    api = engine / "Managed" / "Tallow.API" / "Tallow.API.csproj"
    if not api.is_file():
        raise ValueError(f"Missing managed engine API: {api}")

    generated = project / ".tallow-csharp" / "generated"
    output = project / ".tallow-csharp" / "bin"
    definitions: dict[str, tuple[Path, list[str]]] = {}
    roots: dict[Path, str] = {}
    for definition in sorted(source.rglob("*.asmdef")):
        data = json.loads(definition.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError(f"Assembly definition must be a JSON object: {definition}")
        name = data.get("name")
        deps = data.get("references", [])
        if not isinstance(name, str) or not NAME.fullmatch(name) or name in ("Tallow.Game", "Tallow.API"):
            raise ValueError(f"Invalid assembly name in {definition}: {name!r}")
        if name in definitions or definition.parent in roots:
            raise ValueError(f"Duplicate assembly name/folder: {definition}")
        if not isinstance(deps, list) or any(not isinstance(d, str) for d in deps):
            raise ValueError(f"Invalid references in {definition}")
        definitions[name] = (definition.parent, deps)
        roots[definition.parent] = name

    for name, (folder, deps) in definitions.items():
        for dep in deps:
            if dep == name or dep not in definitions:
                raise ValueError(f"{name} references missing or itself: {dep}")
    visited: set[str] = set()
    visiting: set[str] = set()

    def visit(name: str) -> None:
        if name in visiting:
            raise ValueError(f"Circular assembly definition reference involving {name}")
        if name in visited:
            return
        visiting.add(name)
        for ref in definitions[name][1]:
            visit(ref)
        visiting.remove(name)
        visited.add(name)

    for name in definitions:
        visit(name)

    sources: dict[str, list[Path]] = {"Tallow.Game": []}
    sources.update({name: [] for name in definitions})
    for file in sorted(source.rglob("*.cs")):
        owner = "Tallow.Game"
        for directory in (file.parent, *file.parent.parents):
            if directory in roots:
                owner = roots[directory]
                break
            if directory == source:
                break
        sources[owner].append(file.resolve())

    paths = {name: (generated / name / f"{name}.csproj").resolve() for name in sources}
    for name, files in sources.items():
        refs = definitions[name][1] if name in definitions else list(definitions)
        ref_paths = [paths[ref] for ref in refs]
        xml_write(project_xml(name, files, api.resolve(), ref_paths,
                              (output / name).resolve()), paths[name])
    return paths["Tallow.Game"], paths


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True, help="Game project folder")
    parser.add_argument("--engine-root", type=Path,
                        default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--dotnet", default="dotnet", help="Path to the .NET 11 SDK CLI")
    parser.add_argument("--generate-only", action="store_true")
    args = parser.parse_args()
    try:
        main_project, projects = generate(args.project.resolve(), args.engine_root.resolve())
        print(f"Generated {len(projects)} C# assemblies; game assembly: {main_project}", flush=True)
        if args.generate_only:
            return 0
        command = [args.dotnet, "build", str(main_project), "--configuration", "Debug",
                   "--nologo", "--verbosity", "minimal"]
        return subprocess.run(command, check=False).returncode
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"C# build setup failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
