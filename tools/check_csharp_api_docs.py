#!/usr/bin/env python3
"""Every public Tallow.API member has an XML doc comment (its tooltip in the code editor and the API docs).

Builds Tallow.API with CS1591 (missing XML comment) turned on and fails on any member that is not an enum value:
enum values (KeyCode.A, GamepadButton.South) say what they are by name. Run after the bindings are generated.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
API = ROOT / "Managed" / "Tallow.API"

enums = set()
for source in API.rglob("*.cs"):
    if "/obj/" in str(source) or "/bin/" in str(source):
        continue
    enums.update(re.findall(r"\benum\s+(\w+)", source.read_text(encoding="utf-8")))

result = subprocess.run(
    ["dotnet", "build", str(API / "Tallow.API.csproj"), "-c", "Debug", "--nologo", "--no-incremental",
     "-p:NoWarn=CS8618", "-p:TreatWarningsAsErrors=false"],
    capture_output=True, text=True)
if result.returncode != 0:
    sys.stdout.write(result.stdout[-4000:])
    sys.exit("Tallow.API did not build.")

missing = set()
for line in result.stdout.splitlines():
    if "warning CS1591" not in line:
        continue
    match = re.search(r"Tallow\.API/([^(]+)\((\d+),.*?'([^']+)'", line)
    if not match:
        continue
    member = match.group(3)
    owner = re.sub(r"<.*?>", "", member).split(".")[0]
    if owner in enums and "." in member:
        continue
    missing.add(f"{match.group(1)}:{match.group(2)} {member}")

if missing:
    print("Public Tallow.API members without a /// <summary> (their code editor tooltip):")
    for entry in sorted(missing):
        print("  " + entry)
    sys.exit(1)
print("Every public Tallow.API member outside enum values has an XML doc comment.")
