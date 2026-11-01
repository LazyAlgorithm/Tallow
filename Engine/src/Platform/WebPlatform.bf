using System;

namespace Tallow;

/// What the engine needs from the browser when it is built for the web (WebAssembly through Emscripten).
/// On every other platform the members do nothing and IsWeb is false, so game code can call them freely.
static class WebPlatform
{
#if BF_PLATFORM_WASM
	public const bool IsWeb = true;

	[CLink] static extern void emscripten_set_main_loop(function void() func, int32 fps, int32 simulateInfiniteLoop);
	[CLink] static extern void emscripten_cancel_main_loop();
	[CLink] static extern int32 tn_web_is_touch_device();
	[CLink] static extern int32 tn_web_is_mobile();
	[CLink] static extern void tn_web_copy_text(char8* text);
	[CLink] static extern void tn_web_share_text(char8* title, char8* text);
	[CLink] static extern char8* tn_web_page_url();
	[CLink] static extern char8* tn_web_url_param(char8* name);
	[CLink] static extern void tn_web_set_url_param(char8* name, char8* value);
	[CLink] static extern void tn_web_persist();
	[CLink] static extern void tn_web_loading_done();
	[CLink] static extern void tn_web_free(void* ptr);
	[CLink] static extern char8* tn_web_prompt(char8* title, char8* current);

	static Application sApp;

	/// Hands the application's frame to the browser, which calls it once per display refresh. Does not return:
	/// the page keeps running until it is closed, and Application.Running going false stops the loop.
	public static void RunMainLoop(Application app)
	{
		sApp = app;
		tn_web_loading_done();
		// fps 0: follow the display (requestAnimationFrame). simulateInfiniteLoop 1: leave Run here for good, so
		// nothing the caller made on its stack is torn down while the game is still using it.
		emscripten_set_main_loop( => BrowserFrame, 0, 1);
	}

	static void BrowserFrame()
	{
		if (sApp.Running)
			sApp.Frame();
		if (!sApp.Running)
		{
			emscripten_cancel_main_loop();
			sApp.Shutdown();
		}
	}

	/// True on a phone or tablet, or any screen that is mainly touched.
	public static bool IsTouchDevice => tn_web_is_touch_device() != 0;
	/// True on a phone or tablet: a weaker graphics chip and less memory than a desktop.
	public static bool IsMobile => tn_web_is_mobile() != 0;

	/// Puts text on the clipboard (the browser allows this while handling a click or a key press).
	public static void CopyText(StringView text) => tn_web_copy_text(scope String(text).CStr());

	/// Opens the device's share sheet (phones); where there is none, copies the text instead.
	public static void ShareText(StringView title, StringView text) => tn_web_share_text(scope String(title).CStr(), scope String(text).CStr());

	/// The page's address without its #fragment, e.g. "https://name.github.io/game/".
	public static void GetPageUrl(String outUrl)
	{
		let url = tn_web_page_url();
		if (url != null)
		{
			outUrl.Append(StringView(url));
			tn_web_free(url);
		}
	}

	/// A value from the page address's #fragment ("#join=ABCD" gives "ABCD" for "join"). False when absent.
	public static bool GetUrlParam(StringView name, String outValue)
	{
		let value = tn_web_url_param(scope String(name).CStr());
		if (value == null)
			return false;
		outValue.Append(StringView(value));
		tn_web_free(value);
		return true;
	}

	/// Asks for a line of text in the browser's own box, which brings up a phone's keyboard. False when cancelled.
	public static bool PromptText(StringView title, String text)
	{
		let value = tn_web_prompt(scope String(title).CStr(), scope String(text).CStr());
		if (value == null)
			return false;
		text.Set(StringView(value));
		tn_web_free(value);
		return true;
	}

	/// Sets (or, with an empty value, removes) a value in the address's #fragment without reloading the page.
	public static void SetUrlParam(StringView name, StringView value) => tn_web_set_url_param(scope String(name).CStr(), scope String(value).CStr());

	/// Writes saved files (settings, achievements) through to the browser's storage now rather than at the next
	/// automatic save a few seconds later.
	public static void Persist() => tn_web_persist();
#else
	public const bool IsWeb = false;

	public static void RunMainLoop(Application app) { }
	public static bool IsTouchDevice => false;
	public static bool IsMobile => false;
	public static void CopyText(StringView text) => SDL.SDL_SetClipboardText(scope String(text).CStr());
	public static void ShareText(StringView title, StringView text) => CopyText(text);
	public static void GetPageUrl(String outUrl) { }
	public static bool GetUrlParam(StringView name, String outValue) => false;
	public static bool PromptText(StringView title, String text) => false;
	public static void SetUrlParam(StringView name, StringView value) { }
	public static void Persist() { }
#endif
}
