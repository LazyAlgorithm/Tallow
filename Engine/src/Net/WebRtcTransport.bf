using System;

namespace Tallow;

/// Browser to browser through WebRTC, for games built for the web (tools/web/shell/tessera-net.js does the work).
/// Hosting opens a room with a short code; joining takes that code as the address. The port is not used.
static class WebRtc
{
	/// Names the game, so rooms of different games never meet even with the same code. GameMain sets it from the
	/// game's name.
	public static String AppName = new .("tessera") ~ delete _;
	/// The code of the room this game is in (hosting or joined), or empty.
	public static String RoomCode = new .() ~ delete _;

	/// What the connection is doing ("Waiting for players", "Looking for the host", a reason it failed), for the
	/// game to show. Empty when there is nothing to say, or outside a web build.
	public static void GetStatus(String outStatus)
	{
#if BF_PLATFORM_WASM
		let status = WebRtcTransport.tn_rtc_status();
		if (status != null)
		{
			outStatus.Append(StringView(status));
			WebRtcTransport.tn_web_free(status);
		}
#endif
	}

	/// The address that joins the room this game is in: the page's address with #join=CODE, for the host or any
	/// player in it to share. Empty when not in a room, or outside a web build.
	public static void GetJoinLink(String outLink)
	{
		if (RoomCode.IsEmpty)
			return;
		WebPlatform.GetPageUrl(outLink);
		if (!outLink.IsEmpty)
			outLink.AppendF("#join={}", RoomCode);
	}

	/// The room code in the address the page was opened with (#join=CODE), so a shared link joins straight away.
	public static bool GetCodeFromLink(String outCode) => WebPlatform.GetUrlParam("join", outCode);
}

#if BF_PLATFORM_WASM
/// The NetTransport behind WebRtc: peer-to-peer data channels, run by tools/web/shell/tessera-net.js and reached
/// through the tn_rtc_* calls.
class WebRtcTransport : NetTransport
{
	[CLink] public static extern char8* tn_rtc_host(char8* app, char8* code);
	[CLink] public static extern int32 tn_rtc_connect(char8* app, char8* code);
	[CLink] public static extern char8* tn_rtc_status();
	[CLink] public static extern int32 tn_rtc_poll(int32* kind, int32* peer, uint8** data, int32* length);
	[CLink] public static extern void tn_rtc_send(int32 peer, uint8* data, int32 length, int32 reliable);
	[CLink] public static extern void tn_rtc_disconnect(int32 peer);
	[CLink] public static extern void tn_rtc_close();
	[CLink] public static extern void tn_web_free(void* ptr);

	bool mOpen;

	public ~this()
	{
		Close();
	}

	public override bool Host(uint16 port)
	{
		let code = tn_rtc_host(WebRtc.AppName.CStr(), "");
		if (code == null)
		{
			Log.Error("This page cannot host: tessera-net.js is missing from it.");
			return false;
		}
		WebRtc.RoomCode.Set(StringView(code));
		tn_web_free(code);
		mOpen = true;
		Log.Info(scope $"Hosting room {WebRtc.RoomCode}.");
		return true;
	}

	public override bool Connect(StringView address, uint16 port, out void* server)
	{
		// The one connection a player has is to the host, and it is always peer 1.
		server = (void*)(int)1;
		// As the page reads it: capitals and digits only.
		WebRtc.RoomCode.Clear();
		for (let c in address.RawChars)
		{
			if (c.IsLetterOrDigit)
				WebRtc.RoomCode.Append(c.ToUpper);
		}
		if (tn_rtc_connect(WebRtc.AppName.CStr(), scope String(address).CStr()) == 0)
			return false;
		mOpen = true;
		return true;
	}

	public override bool Poll(out NetEvent event)
	{
		event = default;
		if (!mOpen)
			return false;
		int32 kind = 0, peer = 0, length = 0;
		uint8* data = null;
		if (tn_rtc_poll(&kind, &peer, &data, &length) == 0)
			return false;
		event.kind = kind == 0 ? .Connected : kind == 1 ? .Disconnected : .Data;
		event.peer = (void*)(int)peer;
		event.data = data;
		event.length = length;
		return true;
	}

	public override void Send(void* peer, Span<uint8> data, bool reliable)
	{
		if (mOpen && peer != null)
			tn_rtc_send((int32)(int)peer, data.Ptr, (int32)data.Length, reliable ? 1 : 0);
	}

	public override void Disconnect(void* peer)
	{
		if (mOpen && peer != null)
			tn_rtc_disconnect((int32)(int)peer);
	}

	public override void Flush() { }

	public override void Close()
	{
		if (!mOpen)
			return;
		mOpen = false;
		tn_rtc_close();
		WebRtc.RoomCode.Clear();
	}
}
#endif
