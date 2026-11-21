// What a web build of the engine asks of the browser: touch and phone detection, the clipboard and share sheet,
// the page address (join links), saving files to the browser's storage and telling the page the game has started.
// Built only for Emscripten; Engine/src/Platform/WebPlatform.bf is the Beef side.
//
// A C# game with threads runs on a Web Worker: with .NET's threading on (WasmEnableThreads) the managed entry
// point runs on the runtime's deputy worker, not the page's thread. (A Beef game's own code stays on the page's
// thread; only its jobs run elsewhere.) The browser's DOM (window, document, location, history) lives on the page's
// thread only, so every function that touches it uses MAIN_THREAD_EM_ASM: Emscripten runs that code on the page's
// thread, synchronously, and returns here with the result. The same calls run in place in a single-threaded build,
// so one helper serves both. Writes to the file system need no such care: Emscripten proxies syscalls to the page's
// thread, where the file system lives.
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#include <stdlib.h>

// A threaded build draws through the page's WebGL context (Emscripten's offscreen framebuffer proxy), so on the
// worker GL.currentContext is only the context's handle. Emscripten's WebGL layer rotates its temporary vertex
// buffers in GL.newRenderingFrameStarted() before every main loop iteration, which needs the context object and
// throws on the handle. Nothing on the worker uses those buffers (client-side arrays are proxied whole), so the
// rotation is turned off there; on the page's thread, where the context lives, it stays.
EM_JS(void, tn_web_prepare_proxied_gl, (void), {
	if (typeof ENVIRONMENT_IS_PTHREAD !== "undefined" && ENVIRONMENT_IS_PTHREAD && typeof GL !== "undefined")
		GL.newRenderingFrameStarted = function() {};
});

int tn_web_is_touch_device(void)
{
	return MAIN_THREAD_EM_ASM_INT({
		return ((navigator.maxTouchPoints || 0) > 0 || ("ontouchstart" in window)) &&
			window.matchMedia("(pointer: coarse)").matches ? 1 : 0;
	});
}

int tn_web_is_mobile(void)
{
	return MAIN_THREAD_EM_ASM_INT({
		if (navigator.userAgentData && navigator.userAgentData.mobile) return 1;
		const ua = navigator.userAgent || "";
		// iPads report themselves as Macs; a Mac with a touch screen is an iPad.
		if (/Android|iPhone|iPod|Mobile/i.test(ua)) return 1;
		if (/Macintosh/.test(ua) && (navigator.maxTouchPoints || 0) > 1) return 1;
		return 0;
	});
}

// How many threads the browser can run at once (the display's cores). 1 when it will not say. A worker's navigator
// has this too, so it is asked where it is called.
EM_JS(int, tn_web_hardware_threads, (void), {
	return (navigator.hardwareConcurrency || 1) | 0;
});

// Whether the page allows sharing memory between threads (a build with threads needs a cross-origin isolated page:
// see coi-serviceworker.js). A worker can see both, so it is asked where it is called.
EM_JS(int, tn_web_threads_available, (void), {
	if (typeof SharedArrayBuffer === "undefined") return 0;
	return (typeof crossOriginIsolated === "undefined" || crossOriginIsolated) ? 1 : 0;
});

// Whether this module was linked with threads. The engine's native libraries are always compiled with -pthread (one
// build serves both kinds of module), so a compile-time test would say yes even for a single-threaded link: ask the
// module instead. Only a threaded link has shared memory; a single-threaded one has an ordinary ArrayBuffer.
// Starting a thread in a module without them throws (C++ std::thread raises, which would end the frame).
EM_JS(int, tn_web_built_with_threads, (void), {
	if (typeof SharedArrayBuffer === "undefined") return 0;
	var memory = typeof wasmMemory !== "undefined" ? wasmMemory : (typeof Module !== "undefined" ? Module.wasmMemory : undefined);
	return (memory && memory.buffer instanceof SharedArrayBuffer) ? 1 : 0;
});

void tn_web_copy_text(const char* text)
{
	MAIN_THREAD_EM_ASM({
		const value = UTF8ToString($0);
		const fallback = () => {
			const area = document.createElement("textarea");
			area.value = value;
			area.style.position = "fixed";
			area.style.opacity = "0";
			document.body.appendChild(area);
			area.select();
			try { document.execCommand("copy"); } catch (e) {}
			document.body.removeChild(area);
		};
		if (navigator.clipboard && navigator.clipboard.writeText)
			navigator.clipboard.writeText(value).catch(fallback);
		else
			fallback();
	}, text);
}

void tn_web_share_text(const char* title, const char* text)
{
	MAIN_THREAD_EM_ASM({
		const t = UTF8ToString($0);
		const value = UTF8ToString($1);
		if (navigator.share && /Android|iPhone|iPad|iPod|Mobile/i.test(navigator.userAgent || ""))
		{
			navigator.share({ title: t, text: value }).catch(() => {});
			return;
		}
		if (navigator.clipboard && navigator.clipboard.writeText)
			navigator.clipboard.writeText(value).catch(() => {});
	}, title, text);
}

char* tn_web_page_url(void)
{
	return (char*)MAIN_THREAD_EM_ASM_PTR({
		const text = location.origin + location.pathname + location.search;
		var length = lengthBytesUTF8(text) + 1;
		var pointer = _malloc(length);
		stringToUTF8Array(text, HEAPU8, pointer, length);
		return pointer;
	});
}

char* tn_web_url_param(const char* name)
{
	char* value = (char*)MAIN_THREAD_EM_ASM_PTR({
		const params = new URLSearchParams(location.hash.replace(/^#/, ""));
		const value = params.get(UTF8ToString($0));
		if (value === null) return 0;
		var length = lengthBytesUTF8(value) + 1;
		var pointer = _malloc(length);
		stringToUTF8Array(value, HEAPU8, pointer, length);
		return pointer;
	}, name);
	return value;
}

void tn_web_set_url_param(const char* name, const char* value)
{
	MAIN_THREAD_EM_ASM({
		const params = new URLSearchParams(location.hash.replace(/^#/, ""));
		const n = UTF8ToString($0);
		const v = UTF8ToString($1);
		if (v.length) params.set(n, v); else params.delete(n);
		const hash = params.toString();
		history.replaceState(null, "", location.pathname + location.search + (hash.length ? "#" + hash : ""));
	}, name, value);
}

void tn_web_persist(void)
{
	// The page's Module (its tallowPersist writes the saved files through); a worker's copy of Module has no such
	// function, as the page's callbacks are not sent to it.
	MAIN_THREAD_EM_ASM({
		if (typeof Module.tallowPersist === "function") Module.tallowPersist();
	});
}

void tn_web_loading_done(void)
{
	MAIN_THREAD_EM_ASM({
		if (typeof Module.tallowReady === "function") Module.tallowReady();
	});
}

// A box for typing, from the browser: a phone shows its own keyboard for it (and offers Paste), which it does not
// for the game's canvas. Returns the text (free with tn_web_free), or null when the player cancelled.
char* tn_web_prompt(const char* title, const char* current)
{
	char* value = (char*)MAIN_THREAD_EM_ASM_PTR({
		const value = window.prompt(UTF8ToString($0), UTF8ToString($1));
		if (value === null) return 0;
		var length = lengthBytesUTF8(value) + 1;
		var pointer = _malloc(length);
		stringToUTF8Array(value, HEAPU8, pointer, length);
		return pointer;
	}, title, current);
	return value;
}

// A scene pack the game needs now: the page downloads it before the others still waiting (index.html).
void tn_web_request_pack(const char* name)
{
	MAIN_THREAD_EM_ASM({
		if (Module.tallowRequestPack) Module.tallowRequestPack(UTF8ToString($0));
	}, name);
}

void tn_web_free(void* ptr)
{
	free(ptr);
}

// ---- multiplayer: WebRTC through tools/web/shell/tallow-net.js (window.TallowNet) ----
// TallowNet is a page script, so its queue and sockets live on the page's thread; every call goes there. The data
// buffers it reads and writes are in the module's memory, which the page's thread shares with this one.

// Opens a room and returns its code (free with tn_web_free), or null when the page has no TallowNet.
char* tn_rtc_host(const char* app, const char* code)
{
	char* value = (char*)MAIN_THREAD_EM_ASM_PTR({
		if (!window.TallowNet) return 0;
		const text = TallowNet.host(UTF8ToString($0), UTF8ToString($1));
		var length = lengthBytesUTF8(text) + 1;
		var pointer = _malloc(length);
		stringToUTF8Array(text, HEAPU8, pointer, length);
		return pointer;
	}, app, code);
	return value;
}

int tn_rtc_connect(const char* app, const char* code)
{
	return MAIN_THREAD_EM_ASM_INT({
		if (!window.TallowNet) return 0;
		return TallowNet.connect(UTF8ToString($0), UTF8ToString($1)) ? 1 : 0;
	}, app, code);
}

char* tn_rtc_status(void)
{
	char* value = (char*)MAIN_THREAD_EM_ASM_PTR({
		const text = window.TallowNet ? TallowNet.status : "";
		var length = lengthBytesUTF8(text) + 1;
		var pointer = _malloc(length);
		stringToUTF8Array(text, HEAPU8, pointer, length);
		return pointer;
	});
	return value;
}

// Size of the next event's data, or -1 when there is no event.
int tn_rtc_next_size(void)
{
	return MAIN_THREAD_EM_ASM_INT({
		if (!window.TallowNet || !TallowNet.events.length) return -1;
		const data = TallowNet.events[0][2];
		return data ? data.length : 0;
	});
}

// Takes the next event, copying its data to buffer (which holds tn_rtc_next_size() bytes).
void tn_rtc_take(int* kind, int* peer, unsigned char* buffer)
{
	MAIN_THREAD_EM_ASM({
		const event = TallowNet.events.shift();
		HEAP32[$0 >> 2] = event[0];
		HEAP32[$1 >> 2] = event[1];
		if (event[2]) HEAPU8.set(event[2], $2);
	}, kind, peer, buffer);
}

void tn_rtc_send(int peer, const unsigned char* data, int length, int reliable)
{
	MAIN_THREAD_EM_ASM({
		if (window.TallowNet) TallowNet.send($0, HEAPU8.slice($1, $1 + $2), $3 !== 0);
	}, peer, data, length, reliable);
}

void tn_rtc_disconnect(int peer)
{
	MAIN_THREAD_EM_ASM({
		if (window.TallowNet) TallowNet.disconnect($0);
	}, peer);
}

void tn_rtc_close(void)
{
	MAIN_THREAD_EM_ASM({
		if (window.TallowNet) TallowNet.close();
	});
}

static unsigned char* s_rtcBuffer;
static int s_rtcCapacity;

// Next event: kind 0 connected, 1 disconnected, 2 data. Data stays valid until the next call. Returns 0 when none.
int tn_rtc_poll(int* kind, int* peer, unsigned char** data, int* length)
{
	int size = tn_rtc_next_size();
	if (size < 0) return 0;
	if (size > s_rtcCapacity)
	{
		int capacity = s_rtcCapacity ? s_rtcCapacity : 4096;
		while (capacity < size) capacity *= 2;
		unsigned char* grown = (unsigned char*)realloc(s_rtcBuffer, (size_t)capacity);
		if (grown == NULL) return 0;
		s_rtcBuffer = grown;
		s_rtcCapacity = capacity;
	}
	tn_rtc_take(kind, peer, s_rtcBuffer);
	*data = s_rtcBuffer;
	*length = size;
	return 1;
}
#endif
