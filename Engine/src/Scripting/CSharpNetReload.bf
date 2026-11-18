using System;
using System.IO;

namespace Tallow;

/// C# hot reload in a network session. Every machine must run the same code, and code is never sent over the
/// network: each machine builds its own. Tallow.Build writes the code's ID (a hash of the sources) beside
/// Tallow.Game.dll. The host tells each client which code it runs, when they join and after each hot reload; a client
/// that built a change waits for the host to reload the same code before it reloads, and one that built the code the
/// host already runs reloads at once. A client whose code differs from the host's is warned, once per change.
/// Clients reload when the host's message reaches them, a few ticks after the host.
static class CSharpNetReload
{
	/// Engine message id (MsgCustom range; the engine's own use 235 and up).
	public const uint8 MsgCode = 235;
	/// ReloadAssembly's answer when a client keeps a build until the host reloads the same code.
	public const int32 Waiting = -2;

	static bool sRegistered;
	/// The code this machine runs ("" when its build wrote no ID: a web game, an old build).
	static String sCodeId = new .() ~ delete _;
	/// Client: the code the host last said it runs.
	static String sHostCodeId = new .() ~ delete _;
	/// Client: a build of a change, waiting for the host.
	static String sPendingDll = new .() ~ delete _;
	static String sWarnedId = new .() ~ delete _;

	public static StringView CodeId => sCodeId;
	public static StringView HostCodeId => sHostCodeId;

	/// The ID beside a Tallow.Game.dll (Tallow.Game.codeid), or "" when there is none.
	public static void ReadCodeId(StringView gameDll, String into)
	{
		into.Clear();
		let path = scope String();
		if (Path.GetDirectoryPath(gameDll, path) case .Err)
			return;
		path.Append("/Tallow.Game.codeid");
		let text = scope String();
		if (File.ReadAllText(path, text) case .Ok)
		{
			text.Trim();
			into.Append(text);
		}
	}

	/// A C# game loaded from gameDll.
	public static void Loaded(StringView gameDll)
	{
		if (!sRegistered)
		{
			sRegistered = true;
			NetworkManager.RegisterMessage(MsgCode, new => OnMessage);
		}
		ReadCodeId(gameDll, sCodeId);
		sHostCodeId.Clear();
		sPendingDll.Clear();
		sWarnedId.Clear();
	}

	/// The game stopped.
	public static void Stopped()
	{
		sCodeId.Clear();
		sHostCodeId.Clear();
		sPendingDll.Clear();
		sWarnedId.Clear();
	}

	static bool InSession(NetworkManager network) => network != null && network.IsConnected && (network.IsClient || network.ClientCount > 0);

	/// Before a hot reload: true when this machine is a client and the build is a change the host has not made yet
	/// (it is kept and loaded when the host reloads the same code).
	public static bool ShouldWait(NetworkManager network, StringView gameDll)
	{
		if (network == null || !network.IsConnected || !network.IsClient)
			return false;
		let id = scope String();
		ReadCodeId(gameDll, id);
		// No ID (an old build): reload here only, as before (Reloaded warns).
		if (id.IsEmpty || id == sHostCodeId || id == sCodeId)
			return false;
		sPendingDll.Set(gameDll);
		Log.Info("C# change built. This machine is a client: it loads when the host reloads the same code (save it on the host too).");
		return true;
	}

	/// After a hot reload worked on this machine.
	public static void Reloaded(NetworkManager network, StringView gameDll)
	{
		let previous = scope String(sCodeId);
		ReadCodeId(gameDll, sCodeId);
		if (sPendingDll == gameDll)
			sPendingDll.Clear();
		if (!InSession(network))
			return;
		if (sCodeId.IsEmpty)
		{
			// Every machine in a session must run the same code: without an ID nothing can follow this reload.
			Log.Warning("C# hot reload changed the code on this machine only; the other players in the session still run the old code and may go out of sync. Restart the session to share the change.");
			return;
		}
		if (network.IsServer)
		{
			if (sCodeId != previous)
			{
				Announce(network, -1);
				Log.Info(scope $"C# hot reload sent to the session ({network.ClientCount} client{(network.ClientCount == 1 ? "" : "s")}): each follows once it has built the same code.");
			}
		}
		else if (sCodeId != sHostCodeId)
			Log.Warning("C# hot reload changed the code on this client only; the host runs other code and the session may go out of sync.");
	}

	/// Server: tells one client (or every client, -1) which code this machine runs.
	static void Announce(NetworkManager network, int32 clientId)
	{
		let writer = scope NetWriter();
		writer.WriteString(sCodeId);
		if (clientId < 0)
			network.SendToAll(MsgCode, writer);
		else
			network.SendToClient(clientId, MsgCode, writer);
	}

	/// Server: a client joined; it learns which code the host runs (a client built from other sources is warned).
	public static void ClientJoined(NetworkManager network, int32 clientId)
	{
		if (network != null && network.IsServer && !sCodeId.IsEmpty)
			Announce(network, clientId);
	}

	static void OnMessage(int32 sender, ref NetReader reader)
	{
		let network = NetworkManager.Dispatching ?? Scene.Active?.Network;
		let id = scope String();
		reader.ReadString(id);
		// Only the host says which code the session runs.
		if (!reader.Ok || network == null || network.IsServer || id.IsEmpty || sCodeId.IsEmpty)
			return;
		sHostCodeId.Set(id);
		if (id == sCodeId)
			return;
		if (!sPendingDll.IsEmpty)
		{
			let pending = scope String();
			ReadCodeId(sPendingDll, pending);
			if (pending == id)
			{
				let dll = scope String(sPendingDll);
				let kept = CSharpRuntime.ReloadNow(dll);
				if (kept >= 0)
					Log.Info(scope $"C# hot reload: following the host's code ({kept} script{(kept == 1 ? "" : "s")} kept their fields).");
				return;
			}
		}
		if (sWarnedId == id)
			return;
		sWarnedId.Set(id);
		Log.Warning(scope $"The host runs other C# code than this machine (host {id}, here {sCodeId}): this machine keeps its code and may go out of sync. Build the host's code here (save the same files) to follow it.");
	}
}
