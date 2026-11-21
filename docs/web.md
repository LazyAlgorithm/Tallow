# Web builds: threads, headers and hosting

`tools/build_player.py <project> --platform web --output <folder>` writes a folder to put on a web server: `index.html`, the game (WebAssembly), its asset packs and `_framework/` (a C# game's .NET runtime). Publish that folder as-is. To create it, use a Tallow source checkout with the Web toolchain installed. For C# games, run `tools/web/setup.sh` and then `python3 tools/web/csharp_web.py setup` from the checkout.

## Single-threaded and threaded builds

A web module is either single-threaded or threaded. A threaded module has shared memory and can spread work over the page's cores; a single-threaded one runs everything on one thread.

| Build | Threads | Which environment variable |
| --- | --- | --- |
| C# game | Single-threaded by default | `TALLOW_WEB_THREADS=1` adds threads |
| Beef game | Threaded by default | `TALLOW_WEB_THREADS=0` leaves them out |

With threads, `Engine/src/Core/Jobs.bf`, asset loading, physics and a C# game's `Task.Run`/`Parallel.For` use the browser's cores. A C# game needs .NET's own threading (`WasmEnableThreads`), so the two are always set together.

A threaded C# game runs on .NET's deputy Web Worker (the managed main thread), not the page's thread. The engine reaches the browser through the page:

- WebGL is drawn into Emscripten's offscreen framebuffer and copied to the page's canvas once per frame (`tn_gfx_commit_frame`, called after `bgfx.frame`).
- The page's callbacks (clipboard, share, prompt, URL fragment, saving, the "tap to play" gate, WebRTC) and touch/phone detection are proxied with `MAIN_THREAD_EM_ASM` in `native/tallow_web.c`.
- SDL registers its input callbacks for the thread that created the window, so keyboard, mouse, pointer-lock and touch events reach the game.
- File system calls from the game's thread are proxied to the page by Emscripten, where the file system (and its IndexedDB mount) lives, so saves are unaffected.

### Threads and .NET's worker pool

A WebAssembly thread is a Web Worker, and .NET's runtime creates its threads from a pool of workers. The page must create that pool **before the game starts**:

- `index.html` passes `pthreadPoolInitialSize` (three workers per core, plus a few spare) and `pthreadPoolUnusedSize: 0` to .NET. A worker added later is created by the game's own thread and never receives its runtime configuration, so it never starts; the pool has to cover every thread the game will use.
- `tools/web/csharp_web.py` caps the core count .NET sees at 8 (a few lines at the top of `dotnet.js`), so a game asking for "one worker per core" asks for 7, not 23 on a 24-core machine. Without the cap, a game and the engine's own jobs over-subscribe the page and the frame rate collapses.
- A game that insists on more threads than the pool holds will not get them. Keep a game's web worker count at or below the core count (8 at most).

## Cross-origin isolation headers

Shared memory (`SharedArrayBuffer`) is only available to a **cross-origin isolated** page. Serve the game with these response headers:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

The page must be on HTTPS or `localhost` (a secure context). Any cross-origin resource it loads (fonts, images, scripts) must also allow embedding with `Cross-Origin-Resource-Policy: cross-origin`, or be fetched with CORS.

Examples:

```nginx
# nginx
add_header Cross-Origin-Opener-Policy same-origin always;
add_header Cross-Origin-Embedder-Policy require-corp always;
```

```python
# A quick local server with the headers (Python 3).
import http.server, functools
class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()
http.server.ThreadingHTTPServer(("127.0.0.1", 8000), functools.partial(Handler, directory="Builds/Tallowcraft-Web")).serve_forever()
```

Cloudflare Pages and Netlify can set the headers in a `_headers` file:

```
/*
  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Embedder-Policy: require-corp
```

### Hosts that cannot set headers

GitHub Pages, itch.io and a plain folder on a web server cannot set response headers. For those, `tools/web/shell/coi-serviceworker.js` is copied beside `index.html` and registered by the page; it answers the page's requests with the two headers and reloads the page once when it takes over. It needs a service worker (a secure context, and not a browser or mode that blocks service workers). A threaded build **cannot start without isolation**: the page says so instead of failing with a WebAssembly error. A single-threaded build needs none of this and runs anywhere.

## Saved files

Saved files go through Emscripten's file system, which lives on the page's thread; a worker's file calls are proxied there, so a threaded game's saves reach the same IDBFS mount as a single-threaded one. The page writes them through to the browser's IndexedDB every few seconds and when it is hidden (`tallowPersist`).

## Limitations and performance

- A threaded page uses more memory (one Web Worker per .NET thread, each with a 1 MB stack) and its first frames are slower while the pool's workers instantiate the runtime. The pool is created at start-up and does not grow.
- **WebGL calls from the game's thread are proxied to the page's thread.** Simple games see no difference; a game with many draw calls per frame pays for each one, and the offscreen frame is copied to the canvas once per frame. This is the cost of .NET's deputy-thread design (a WebGL context cannot be created directly in a Web Worker without transferring an OffscreenCanvas to it, which .NET's runtime does not do). Distance, draw-call and character-heavy scenes are the first to feel it. If the browser is using software WebGL (SwiftShader), the cost is much larger; check `chrome://gpu` and enable hardware acceleration.
- The game's frame loop runs from a worker timer at about 60 fps rather than the page's `requestAnimationFrame`. Input and rendering still work; frame timing follows the timer.
- Audio, fullscreen and pointer lock need a tap or click on the page first, as before.
- A single-threaded build has none of the threading costs and is the better choice for a game that does not need background work.
