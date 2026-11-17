#!/usr/bin/env python3
"""C# games in a browser: builds Tests/CSharpInGame for the web (tools/build_player.py --platform web, which links the
engine with .NET's WebAssembly; set up with tools/web/csharp_web.py setup) and plays it in headless Chromium with
WebGL 2 (SwiftShader). The page is served as a static web host would, with no special headers. Its scripts log one
"INGAME PASS/FAIL" line per check and "INGAME DONE" when every one passed.

  python3 tools/test_csharp_web.py [--chrome PATH] [--keep]

Chromium: --chrome, TALLOW_CHROME, Playwright's headless shell (~/.cache/ms-playwright), or chromium/google-chrome on
PATH.
"""
import argparse
import http.server
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parent.parent
# Forwards the page's console (where the game's log goes) and its failures to the test's server.
CONSOLE = """<script>
(() => {
	const post = (text) => fetch("/log", { method: "POST", body: String(text) }).catch(() => {});
	for (const kind of ["log", "info", "warn", "error"]) {
		const original = console[kind];
		console[kind] = (...parts) => { post(parts.join(" ")); original(...parts); };
	}
	addEventListener("error", (event) => post("PAGE ERROR " + event.message));
	addEventListener("unhandledrejection", (event) => post("PAGE ERROR " + (event.reason && event.reason.stack || event.reason)));
	setInterval(() => {
		const status = document.getElementById("status");
		if (status && document.getElementById("gate").classList.contains("failed")) post("PAGE ERROR " + status.textContent);
	}, 1000);
})();
</script>"""


def find_chrome(given):
    candidates = [given, os.environ.get("TALLOW_CHROME")]
    playwright = Path.home() / ".cache" / "ms-playwright"
    if playwright.is_dir():
        candidates += [str(path) for path in sorted(playwright.glob("chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell"), reverse=True)]
        candidates += [str(path) for path in sorted(playwright.glob("chromium-*/chrome-*/chrome"), reverse=True)]
    candidates += [shutil.which(name) for name in ("chromium", "chromium-browser", "google-chrome", "google-chrome-stable")]
    return next((Path(path) for path in candidates if path and Path(path).is_file()), None)


def play(folder: Path, chrome: Path, query: str, limit: float):
    """Serves folder, opens its index.html in headless Chromium, returns the lines the page logged."""
    lines, done = [], threading.Event()

    class Handler(http.server.SimpleHTTPRequestHandler):
        extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, ".wasm": "application/wasm", ".js": "text/javascript"}

        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(folder), **kwargs)

        def log_message(self, *args):
            pass

        def do_POST(self):
            text = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8", "replace")
            lines.append(text)
            if "INGAME DONE" in text or "INGAME FAILED" in text or text.startswith("PAGE ERROR"):
                done.set()
            self.send_response(204)
            self.end_headers()

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="tallow-chrome-") as profile:
        browser = subprocess.Popen([str(chrome), "--headless=new", "--no-sandbox", "--enable-unsafe-swiftshader", "--use-angle=swiftshader",
                                    "--autoplay-policy=no-user-gesture-required", f"--user-data-dir={profile}",
                                    f"http://127.0.0.1:{server.server_address[1]}/index.html{query}"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            finished = done.wait(limit)
        finally:
            browser.kill()
            browser.wait()
            server.shutdown()
    return lines, finished


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--chrome", help="Chromium or Chrome to run the page in")
    parser.add_argument("--keep", action="store_true", help="keep the built page (its folder is printed)")
    parser.add_argument("--timeout", type=float, default=300)
    options = parser.parse_args()
    chrome = find_chrome(options.chrome)
    if chrome is None:
        print("Needs Chromium or Chrome (--chrome PATH).", file=sys.stderr)
        return 2
    work = Path(tempfile.mkdtemp(prefix="tallow-csharp-web-"))
    try:
        project = work / "InGame"
        shutil.copytree(ROOT / "Tests/CSharpInGame", project, ignore=shutil.ignore_patterns(".tallow-*", "build"))
        template = (ROOT / "Editor/templates/empty/Scripts/FirstPersonCharacter.cs.txt").read_text(encoding="utf-8")
        (project / "src/Scripts/FirstPersonCharacter.cs").write_text(template.replace("{NAMESPACE}", "InGame"), encoding="utf-8")
        (project / "project.tallow").write_text(f"name = InGame\nstartScene = Scenes/Main.tscene\nengine = {ROOT.as_posix()}\n", encoding="utf-8")
        out = work / "web"
        built = subprocess.run([sys.executable, str(ROOT / "tools/build_player.py"), str(project), "--platform", "web", "--output", str(out)],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if built.returncode != 0:
            print(built.stdout[-6000:])
            print("FAIL: the C# game did not build for the web.")
            return 1
        page = out / "index.html"
        page.write_text(page.read_text().replace("<head>", "<head>" + CONSOLE, 1))
        lines, finished = play(out, chrome, "?arg=--fixed-step&arg=--frames&arg=900", options.timeout)
        for line in lines:
            if "INGAME" in line or "ERROR" in line or "Graphics" in line:
                print(line)
        passed = sum("INGAME PASS" in line for line in lines)
        failed = [line for line in lines if "INGAME FAIL" in line or line.startswith("PAGE ERROR")]
        if not finished:
            print(f"FAIL: the game did not finish its checks in {options.timeout:.0f} s ({passed} passed)")
            return 1
        if failed or not any("INGAME DONE" in line for line in lines):
            print(f"FAIL: {len(failed)} failed, {passed} passed in the browser")
            return 1
        print(f"PASS: {passed} in-game C# checks pass in the browser (WebGL 2), from a page served with no special headers")
        return 0
    finally:
        if options.keep:
            print(f"Kept: {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
