// What a web build of the engine asks of the browser: touch and phone detection, the clipboard and share sheet,
// the page address (join links), saving files to the browser's storage and telling the page the game has started.
// Built only for Emscripten; Engine/src/Platform/WebPlatform.bf is the Beef side.
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#include <stdlib.h>

EM_JS(int, tn_web_is_touch_device, (void), {
	return ((navigator.maxTouchPoints || 0) > 0 || ("ontouchstart" in window)) &&
		window.matchMedia("(pointer: coarse)").matches ? 1 : 0;
});

EM_JS(int, tn_web_is_mobile, (void), {
	if (navigator.userAgentData && navigator.userAgentData.mobile) return 1;
	const ua = navigator.userAgent || "";
	// iPads report themselves as Macs; a Mac with a touch screen is an iPad.
	if (/Android|iPhone|iPod|Mobile/i.test(ua)) return 1;
	if (/Macintosh/.test(ua) && (navigator.maxTouchPoints || 0) > 1) return 1;
	return 0;
});

EM_JS(void, tn_web_copy_text, (const char* text), {
	const value = UTF8ToString(text);
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
});

EM_JS(void, tn_web_share_text, (const char* title, const char* text), {
	const t = UTF8ToString(title);
	const value = UTF8ToString(text);
	if (navigator.share && /Android|iPhone|iPad|iPod|Mobile/i.test(navigator.userAgent || ""))
	{
		navigator.share({ title: t, text: value }).catch(() => {});
		return;
	}
	if (navigator.clipboard && navigator.clipboard.writeText)
		navigator.clipboard.writeText(value).catch(() => {});
});

EM_JS(char*, tn_web_page_url, (void), {
	return stringToNewUTF8(location.origin + location.pathname + location.search);
});

EM_JS(char*, tn_web_url_param, (const char* name), {
	const params = new URLSearchParams(location.hash.replace(/^#/, ""));
	const value = params.get(UTF8ToString(name));
	return value === null ? 0 : stringToNewUTF8(value);
});

EM_JS(void, tn_web_set_url_param, (const char* name, const char* value), {
	const params = new URLSearchParams(location.hash.replace(/^#/, ""));
	const n = UTF8ToString(name);
	const v = UTF8ToString(value);
	if (v.length) params.set(n, v); else params.delete(n);
	const hash = params.toString();
	history.replaceState(null, "", location.pathname + location.search + (hash.length ? "#" + hash : ""));
});

EM_JS(void, tn_web_persist, (void), {
	if (typeof Module.tallowPersist === "function") Module.tallowPersist();
});

EM_JS(void, tn_web_loading_done, (void), {
	if (typeof Module.tallowReady === "function") Module.tallowReady();
});

// A box for typing, from the browser: a phone shows its own keyboard for it (and offers Paste), which it does not
// for the game's canvas. Returns the text (free with tn_web_free), or null when the player cancelled.
EM_JS(char*, tn_web_prompt, (const char* title, const char* current), {
	const value = window.prompt(UTF8ToString(title), UTF8ToString(current));
	return value === null ? 0 : stringToNewUTF8(value);
});

// A scene pack the game needs now: the page downloads it before the others still waiting (index.html).
EM_JS(void, tn_web_request_pack, (const char* name), {
	if (Module.tallowRequestPack) Module.tallowRequestPack(UTF8ToString(name));
});

void tn_web_free(void* ptr)
{
	free(ptr);
}

// ---- multiplayer: WebRTC through tools/web/shell/tallow-net.js (window.TallowNet) ----

// Opens a room and returns its code (free with tn_web_free), or null when the page has no TallowNet.
EM_JS(char*, tn_rtc_host, (const char* app, const char* code), {
	if (!window.TallowNet) return 0;
	return stringToNewUTF8(TallowNet.host(UTF8ToString(app), UTF8ToString(code)));
});

EM_JS(int, tn_rtc_connect, (const char* app, const char* code), {
	if (!window.TallowNet) return 0;
	return TallowNet.connect(UTF8ToString(app), UTF8ToString(code)) ? 1 : 0;
});

EM_JS(char*, tn_rtc_status, (void), {
	return stringToNewUTF8(window.TallowNet ? TallowNet.status : "");
});

// Size of the next event's data, or -1 when there is no event.
EM_JS(int, tn_rtc_next_size, (void), {
	if (!window.TallowNet || !TallowNet.events.length) return -1;
	const data = TallowNet.events[0][2];
	return data ? data.length : 0;
});

// Takes the next event, copying its data to buffer (which holds tn_rtc_next_size() bytes).
EM_JS(void, tn_rtc_take, (int* kind, int* peer, unsigned char* buffer), {
	const event = TallowNet.events.shift();
	HEAP32[kind >> 2] = event[0];
	HEAP32[peer >> 2] = event[1];
	if (event[2]) HEAPU8.set(event[2], buffer);
});

EM_JS(void, tn_rtc_send, (int peer, const unsigned char* data, int length, int reliable), {
	if (window.TallowNet) TallowNet.send(peer, HEAPU8.slice(data, data + length), reliable !== 0);
});

EM_JS(void, tn_rtc_disconnect, (int peer), {
	if (window.TallowNet) TallowNet.disconnect(peer);
});

EM_JS(void, tn_rtc_close, (void), {
	if (window.TallowNet) TallowNet.close();
});

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
