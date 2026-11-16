#!/usr/bin/env python3
"""Make the typed C# handles of Tallow's built-in components from the engine's own field list.

    TallowLauncher --write-component-catalog catalog.tsv
    python3 tools/gen_csharp_components.py catalog.tsv            # writes Managed/Tallow.API/NativeComponents.Generated.cs
    python3 tools/gen_csharp_components.py catalog.tsv --check    # fails when the checked-in file differs (CI)

A component that already has a hand-written handle ([NativeComponent("Tallow.X")] elsewhere in Tallow.API) is left
to it. Each Inspector field becomes a property over NativeComponent (scene-file text, as the Inspector edits it);
lists, object references and hidden fields are left out. Docs come from the Beef data struct's /// comments.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
API = ROOT / "Managed/Tallow.API"
OUTPUT = API / "NativeComponents.Generated.cs"
ENGINE = ROOT / "Engine/src"

# Components C# reaches through their own API instead (CSharpJoints for joints, Network for sessions).
SKIP = {"Tallow.Joint", "Tallow.NetworkSession"}

GETTERS = {
    "Float": ("float", "GetFloat"),
    "Int": ("int", "GetInt"),
    "Bool": ("bool", "GetBool"),
    "Color": ("Color", "GetColor"),
    "String": ("string", "GetString"),
    "Vector2": ("Vector2", "GetVector2"),
    "Vector3": ("Vector3", "GetVector3"),
    "Vector4": ("Vector4", "GetVector4"),
}


def pascal(name: str) -> str:
    return name[:1].upper() + name[1:]


def enum_name(full: str) -> str:
    # Tallow.LODGroup.Source -> LODGroupSource; Tallow.LightType -> LightType
    parts = full.split(".")[1:]
    return "".join(parts)


def beef_sources() -> str:
    return "\n".join(p.read_text(encoding="utf-8", errors="replace") for p in sorted(ENGINE.rglob("*.bf")))


def same_stem(a: str, b: str) -> bool:
    """Whether two field names share a stem of four letters or more at either end (startWidth/endWidth,
    positionX/positionY)."""
    a, b = a.lower(), b.lower()
    prefix = len(__import__("os").path.commonprefix([a, b]))
    suffix = len(__import__("os").path.commonprefix([a[::-1], b[::-1]]))
    return max(prefix, suffix) >= 4


def enum_docs(source: str, full: str) -> tuple[list[str], dict[str, list[str]]]:
    """An enum's own documentation and each case's."""
    short = full.split(".")[-1]
    match = re.search(r"\benum\s+" + re.escape(short) + r"\b[^{]*\{", source)
    if not match:
        return [], {}
    body = struct_body(source, match.start())
    cases = {}
    for case in re.finditer(r"^\s*(?:\[[^\]\n]*\]\s*)*([A-Za-z_]\w*)\s*(?:=[^,\n]*)?,?\s*(?://.*)?$", body, re.M):
        cases[case.group(1)] = doc_before(body, case.start())
    return doc_before(source, match.start()), cases


def inherited_doc(source: str, field: str) -> list[str]:
    """The documentation of a field a component inherits (Collider's center and isTrigger): the field as declared in
    an abstract base class."""
    for base in re.finditer(r"\babstract\s+class\s+\w+\s*:\s*\w+", source):
        body = struct_body(source, base.start())
        match = re.search(r"^\s*(?:\[[^\]\n]*\]\s*)*public\s+[\w.<>\[\]]+\s+" + re.escape(field) + r"\s*(=|;)", body, re.M)
        if match:
            docs = doc_before(body, match.start())
            if docs:
                return docs
    return []


def doc_before(text: str, index: int) -> list[str]:
    """The /// lines right above a declaration, without the slashes."""
    lines = text[:index].splitlines()
    docs: list[str] = []
    for line in reversed(lines):
        stripped = line.strip()
        if stripped.startswith("///"):
            docs.insert(0, stripped[3:].strip())
        elif stripped.startswith("[") or stripped == "":
            if docs or stripped.startswith("["):
                if stripped == "" and docs:
                    break
                continue
            break
        else:
            break
    return docs


def struct_body(text: str, start: int) -> str:
    brace = text.find("{", start)
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1:i]
    return ""


def xml(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def summary(lines: list[str], indent: str) -> list[str]:
    if not lines:
        return []
    out = [f"{indent}/// <summary>"]
    out += [f"{indent}/// {xml(line)}" if line else f"{indent}///" for line in lines]
    out.append(f"{indent}/// </summary>")
    return out


def source_enum_cases(source: str, full: str) -> list[tuple[str, int]]:
    short = full.split(".")[-1]
    match = re.search(r"\benum\s+" + re.escape(short) + r"\b[^{]*\{", source)
    if not match:
        return []
    body = re.sub(r"//[^\n]*", "", struct_body(source, match.start()))
    cases, value = [], 0
    for raw in body.split(","):
        item = re.sub(r"//.*", "", raw).strip()
        item = re.sub(r"\[[^\]]*\]", "", item).strip()
        if not item:
            continue
        name, _, given = item.partition("=")
        name = name.strip().split()[-1]
        if given.strip():
            value = int(given.strip(), 0)
        cases.append((name, value))
        value += 1
    return cases


def handwritten() -> set[str]:
    names = set()
    for path in API.glob("*.cs"):
        if path == OUTPUT:
            continue
        names |= set(re.findall(r'\[NativeComponent\("([\w.]+)"\)\]', path.read_text(encoding="utf-8")))
    return names


def existing_types() -> set[str]:
    names = set()
    for path in API.glob("*.cs"):
        if path == OUTPUT:
            continue
        text = path.read_text(encoding="utf-8")
        # A partial declaration adds to a generated handle (NativeComponentActions.cs); it does not replace it.
        names |= set(re.findall(r"(?<!partial record )\b(?:class|struct|enum|interface)\s+(\w+)", text))
        names -= set(re.findall(r"\bpartial\s+record\s+struct\s+(\w+)", text))
    return names


def existing_enums() -> set[str]:
    names = set()
    for path in API.glob("*.cs"):
        if path == OUTPUT:
            continue
        names |= set(re.findall(r"\benum\s+(\w+)", path.read_text(encoding="utf-8")))
    return names


def generate(catalog: str) -> str:
    components: dict[str, list[list[str]]] = {}
    enums: dict[str, list[tuple[str, int]]] = {}
    for line in catalog.splitlines():
        cols = line.split("\t")
        if cols[0] == "component":
            components[cols[1]] = []
        elif cols[0] == "field":
            components[cols[1]].append(cols[2:])
        elif cols[0] == "enum":
            enums[cols[1]] = [(c.split("=")[0], int(c.split("=")[1])) for c in cols[2:] if "=" in c]
    source = beef_sources()
    done = handwritten()
    have_enums = existing_enums()
    have_types = existing_types()
    used_enums: set[str] = set()
    out = [
        "// Generated by tools/gen_csharp_components.py from TallowLauncher --write-component-catalog. Do not edit:",
        "// change the Beef component (or add a hand-written handle elsewhere in Tallow.API) and run the tool.",
        "using System.Numerics;",
        "",
        "namespace Tallow;",
        "",
    ]
    made: list[tuple[str, str]] = []
    for native, fields in sorted(components.items()):
        if native in done or native in SKIP:
            continue
        name = native.split(".")[-1]
        if name in have_types:
            continue  # Reached through its own C# API (SoftBody...).
        decl = re.search(r"struct\s+" + re.escape(name) + r"\s*:\s*ComponentHandle<\s*(\w+)\s*>", source)
        if not decl:
            decl = re.search(r"\bclass\s+" + re.escape(name) + r"\s*:\s*\w+", source)
        docs = doc_before(source, decl.start()) if decl else []
        # Paragraphs about how the Beef side is built mean nothing to a C# author.
        paragraphs, current = [], []
        for line in docs + [""]:
            if line:
                current.append(line)
            elif current:
                paragraphs.append(current)
                current = []
        docs = []
        for paragraph in paragraphs:
            if any(word in " ".join(paragraph) for word in ("ComponentHandle", "HandleData", "World.", "Beef")):
                continue
            docs += ([""] if docs else []) + paragraph
        field_docs: dict[str, list[str]] = {}
        if decl:
            data = (re.search(r"struct\s+" + re.escape(decl.group(1)) + r"\b[^;{]*\{", source)
                    if decl.groups() else decl)
            if data:
                body = struct_body(source, data.start())
                previous = None
                for match in re.finditer(r"^\s*(?:\[[^\]\n]*\]\s*)*public\s+[\w.<>\[\]]+\s+(\w+)\s*(=|;)", body, re.M):
                    own = doc_before(body, match.start())
                    # One comment over a run of related fields ("width at the start and end" over startWidth and
                    # endWidth): a field right below a documented one, with a name sharing its stem, shares it.
                    if not own and previous and same_stem(previous[0], match.group(1)) and \
                            body[previous[1]:match.start()].count("\n") <= 1:
                        own = field_docs.get(previous[0], [])
                    if own or match.group(1) not in field_docs:  # a nested struct's same name keeps the component's doc
                        field_docs[match.group(1)] = own
                    line_end = body.find("\n", match.end())
                    previous = (match.group(1), line_end if line_end >= 0 else len(body))
        out += summary(docs or [f"The built-in {name} component."], "")
        out.append(f'[NativeComponent("{native}")]')
        out.append(f"public readonly partial record struct {name}(GameObject GameObject) : IComponent")
        out.append("{")
        out.append(f'    private NativeComponent Data => new(GameObject, "{native}");')
        out.append("    /// <summary>Whether the object still exists and has this component.</summary>")
        out.append("    public bool IsValid => Data.IsValid;")
        taken = {"IsValid", "GameObject", "Data", name}
        for entry in fields:
            field, kind, ftype, flags = (entry + ["", "", ""])[:4]
            if "hidden" in flags.split():
                continue
            prop = pascal(field)
            if prop in taken:
                prop += "Value"
            if kind == "Enum" and ftype:
                cs_type = enum_name(ftype)
                if ftype not in enums or not enums[ftype]:
                    enums[ftype] = source_enum_cases(source, ftype)
                if not enums[ftype]:
                    continue
                used_enums.add(ftype)
                getter = f"Data.GetEnum<{cs_type}>(\"{field}\")"
            elif kind in GETTERS:
                cs_type, method = GETTERS[kind]
                getter = f"Data.{method}(\"{field}\")"
            else:
                continue
            taken.add(prop)
            docs_for = field_docs.get(field) or inherited_doc(source, field)
            out += summary(docs_for, "    ")
            out.append(f"    public {cs_type} {prop} {{ get => {getter}; set => Data.Set(\"{field}\", value); }}")
        out.append("}")
        out.append("")
        made.append((name, native))
    for full in sorted(used_enums):
        cs = enum_name(full)
        if cs in have_enums:
            continue
        own, case_docs = enum_docs(source, full)
        out += summary(own or [f"Values of the engine's {full.split('.')[-1]}."], "")
        out.append(f"public enum {cs}")
        out.append("{")
        for case, value in enums[full]:
            out += summary(case_docs.get(case, []), "    ")
            out.append(f"    {case} = {value},")
        out.append("}")
        out.append("")
    out.append("internal static partial class NativeComponentTypes")
    out.append("{")
    out.append("    static partial void AddGenerated()")
    out.append("    {")
    out += [f'        Known[typeof({name})] = ("{native}", o => new {name}(o));' for name, native in made]
    out.append("    }")
    out.append("}")
    return "\n".join(out) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("catalog")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    text = generate(Path(args.catalog).read_text(encoding="utf-8"))
    if args.check:
        current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
        if current.replace("\r\n", "\n") != text:
            print(f"{OUTPUT.relative_to(ROOT)} is out of date: run tools/gen_csharp_components.py on a fresh catalog")
            return 1
        print(f"{OUTPUT.relative_to(ROOT)} matches the engine's components")
        return 0
    OUTPUT.write_text(text, encoding="utf-8", newline="\n")
    print(f"Wrote {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
