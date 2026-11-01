#!/usr/bin/env python3
"""Generate a mobile-friendly, static Beef API index from the checked-out engine source.

No third-party Python dependencies. This is a declaration index, not a semantic
compiler model; source links are authoritative. Fails on empty indexes.
"""
import argparse
import html
import json
import re
from pathlib import Path

DECL = re.compile(r"^\s*(?:(?:public|protected|internal|private|static|virtual|override|abstract|sealed|partial|extern|readonly|const|mut|new|comptime|mixin)\s+)*(?:(?:class|struct|interface|enum|namespace|extension|delegate|function)\s+[\w.<>]+.*|(?:public|protected)\s+(?:(?:static|virtual|override|abstract|sealed|extern|readonly|const|mut|new|mixin)\s+)*[\w.<>,\[\]?*]+\s+(?:\w+|this|operator\s*\S+)\s*(?:\(|[=;{]))")
TEMPLATE = """<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tallow API Reference</title><style>
:root{color-scheme:light dark;--bg:#f6f8fc;--fg:#152139;--card:#fff;--line:#c9d5e5;--accent:#326cdb}
@media(prefers-color-scheme:dark){:root{--bg:#101622;--fg:#e9effb;--card:#1b2638;--line:#3c4b62;--accent:#91b6ff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,sans-serif}main{max-width:1100px;margin:auto;padding:20px}header{border-bottom:1px solid var(--line);padding:14px 20px}a{color:var(--accent)}input{width:100%;font:inherit;padding:13px;background:var(--card);color:var(--fg);border:1px solid var(--line);border-radius:8px}article{background:var(--card);padding:12px 16px;margin:8px 0;border:1px solid var(--line);border-radius:8px;overflow-wrap:anywhere}code{white-space:pre-wrap;overflow-wrap:anywhere}small{display:block;color:var(--fg);opacity:.75}#results{padding-bottom:50px}
</style></head><body><header><a href="developer-preview.html">← Tallow developer website</a> · <a href="index.html">Original website</a> · <a href="https://github.com/LazyAlgorithm/Tallow/blob/__COMMIT__/LICENSE">MIT license</a> · <a href="https://github.com/LazyAlgorithm/Tallow/blob/__COMMIT__/THIRD_PARTY_LICENSES.txt">Third-party notices</a></header><main><h1>Complete source API index</h1><p>Generated from the Tallow engine's Beef declarations at commit <code>__COMMIT__</code>. __COUNT__ declarations in __FILES__ source files. Includes public/protected and other declarations to aid discovery; not every listed symbol is a stable public API. Check source for exact signatures, accessibility and semantics.</p><label for="q">Search classes, methods, fields, signatures or filenames</label><input id="q" type="search" placeholder="Rigidbody, NetworkManager, Water…" autocomplete="off"><p id="status" role="status"></p><div id="results"></div><noscript><p>JavaScript is required for interactive filtering. The full static data is available in <a href="api-index.json">api-index.json</a>.</p></noscript></main><script>
const DATA=__DATA__;const input=document.getElementById('q'),out=document.getElementById('results'),status=document.getElementById('status');let timer;
function escapeHTML(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
function render(){let q=input.value.trim().toLowerCase(),found=q?DATA.filter(x=>(x[0]+' '+x[1]).toLowerCase().includes(q)):DATA;status.textContent=found.length+' matching declarations'+(found.length>150?' (showing first 150; type to narrow)':'');out.innerHTML=found.slice(0,150).map(x=>'<article><code>'+escapeHTML(x[0])+'</code><small><a href="https://github.com/LazyAlgorithm/Tallow/blob/__COMMIT__/'+x[1].split('/').map(encodeURIComponent).join('/')+'#L'+x[2]+'" target="_blank" rel="noopener">'+escapeHTML(x[1])+':'+x[2]+'</a></small></article>').join('')}
input.addEventListener('input',()=>{clearTimeout(timer);timer=setTimeout(render,100)});render();
</script></body></html>"""

def generate(root, output, commit):
    entries = []
    files = list(sorted((root / "Engine").rglob("*.bf")))
    if not files:
        raise SystemExit("No Engine/*.bf files; refusing empty API output")
    for path in files:
        rel = path.relative_to(root).as_posix()
        try:
            content = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            raise SystemExit(f"Cannot read {rel}: {exc}")
        in_comment = False
        for number, line in enumerate(content.splitlines(), 1):
            trimmed = line.strip()
            if in_comment:
                if "*/" in trimmed:
                    in_comment = False
                continue
            if trimmed.startswith("/*"):
                if "*/" not in trimmed:
                    in_comment = True
                continue
            if not trimmed or trimmed.startswith(("//", "*", "#", "[")):
                continue
            if DECL.match(line):
                entries.append([trimmed.split("//", 1)[0][:300], rel, number])
    if len(entries) < 100:
        raise SystemExit(f"Only {len(entries)} declarations found; refusing suspicious API output")
    entries.sort(key=lambda x: (x[0].casefold(), x[1], x[2]))
    output.mkdir(parents=True, exist_ok=True)
    (output / "api-index.json").write_text(json.dumps({"commit": commit, "source_files": len(files), "declarations": entries}, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    page = TEMPLATE.replace("__DATA__", json.dumps(entries, ensure_ascii=False).replace("</", "<\\/")).replace("__COUNT__", str(len(entries))).replace("__FILES__", str(len(files))).replace("__COMMIT__", html.escape(commit, quote=True))
    (output / "api.html").write_text(page, encoding="utf-8")
    print(f"Generated {len(entries)} declarations from {len(files)} Beef files in {output}")

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--commit", required=True)
    a = p.parse_args()
    generate(a.root.resolve(), a.output.resolve(), a.commit)
