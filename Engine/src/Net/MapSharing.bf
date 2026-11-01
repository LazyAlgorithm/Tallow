using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// Where a player's download of the host's map is.
enum MapDownloadState
{
	None,
	/// Asked the host, nothing back yet.
	Asking,
	Downloading,
	/// The map is in the Maps folder (DownloadedFile).
	Done,
	/// It could not be had (Error says why).
	Failed
}

/// Sends map files (MapFiles) from the host to players who lack them, or whose copy is another version.
///
/// The host offers the maps it has; a player compares the Id and Hash of the host's map with its own and asks for the
/// file when it has no map of that Id or a different Hash:
///
///   // Host, for each map it found:
///   MapSharing.Offer(map);
///   // Player, told the host's map (the session context, or a [Sync] field):
///   if (!MapSharing.Have(id, hash))
///       MapSharing.Request(Scene.Network, id, hash);
///   // Then, each frame: MapSharing.State, Progress; once Done, find the maps again and load it.
///
/// The file comes in pieces, a few at a time (each piece is acknowledged before more are sent, so a slow connection
/// is not flooded and Steam's send buffer never overflows). The player checks the whole file's hash before it writes
/// it into its Maps folder, replacing an older version of the same map. Maps larger than MaxBytes are refused. A map
/// is only data (a scene and its models): it never carries code.
static class MapSharing
{
	public const uint8 MsgMap = 242;
	/// The largest map a player will take.
	public const int MaxBytes = 64 * 1024 * 1024;
	const int PieceBytes = 16 * 1024;
	/// Pieces sent and not yet acknowledged, for each player.
	const int Window = 8;
	/// A download with nothing from the host for this long has failed.
	const float TimeoutSeconds = 20;

	const uint8 KindRequest = 1;
	const uint8 KindBegin = 2;
	const uint8 KindPiece = 3;
	const uint8 KindMissing = 4;
	const uint8 KindAck = 5;

	class Offered
	{
		public String File = new .() ~ delete _;
		public String Id = new .() ~ delete _;
		public String Hash = new .() ~ delete _;
		public String Name = new .() ~ delete _;
	}

	class Sending
	{
		public int32 Client;
		public List<uint8> Data = new .() ~ delete _;
		public int Sent;
		public int Acknowledged;
	}

	static List<Offered> sOffered = new .() ~ DeleteContainerAndItems!(_);
	static List<Sending> sSending = new .() ~ DeleteContainerAndItems!(_);
	static bool sRegistered;
	static NetWriter sWriter = new .() ~ delete _;

	static MapDownloadState sState;
	static String sWantedId = new .() ~ delete _;
	static String sWantedHash = new .() ~ delete _;
	static String sName = new .() ~ delete _;
	static List<uint8> sReceived = new .() ~ delete _;
	static int sTotal;
	static float sQuiet;
	// The session the download was asked for in.
	static NetworkManager sAsker;
	static String sError = new .() ~ delete _;
	static String sDownloadedFile = new .() ~ delete _;
	static String sFolder = new .() ~ delete _;

	public static MapDownloadState State => sState;
	/// How much of the map has arrived, 0 to 1.
	public static float Progress => sTotal > 0 ? (float)sReceived.Count / sTotal : 0;
	/// The size of the map being downloaded, once the host has said.
	public static int TotalBytes => sTotal;
	/// The Id of the map being (or last) downloaded.
	public static StringView WantedId => sWantedId;
	/// The map's name, as the host's file is called.
	public static StringView Name => sName;
	/// Why the download failed.
	public static StringView Error => sError;
	/// The file the downloaded map was written to.
	public static StringView DownloadedFile => sDownloadedFile;
	/// Where downloaded maps are written: MapFiles.Folder unless set.
	public static StringView Folder
	{
		get
		{
			if (sFolder.IsEmpty)
				MapFiles.Folder(sFolder);
			return sFolder;
		}
		set => sFolder.Set(value);
	}

	/// Host: makes a map available to players who ask for it by Id. The map is read from its file when asked for.
	public static void Offer(MapFileInfo map)
	{
		Register();
		if (map == null || map.Id.IsEmpty)
			return;
		for (let offered in sOffered)
		{
			if (offered.Id == map.Id)
			{
				offered.File.Set(map.File);
				offered.Hash.Set(map.Hash);
				offered.Name.Set(map.Name);
				return;
			}
		}
		let offered = new Offered();
		offered.File.Set(map.File);
		offered.Id.Set(map.Id);
		offered.Hash.Set(map.Hash);
		offered.Name.Set(map.Name);
		sOffered.Add(offered);
	}

	/// Host: forgets every offered map.
	public static void ClearOffers() => ClearAndDeleteItems!(sOffered);

	/// Whether the folder has a map with this Id and Hash (an empty hash matches any version).
	public static bool Have(StringView id, StringView hash, StringView folder = "")
	{
		let found = scope List<MapFileInfo>();
		defer
		{
			ClearAndDeleteItems!(found);
		}
		MapFiles.Find(folder.IsEmpty ? Folder : folder, found);
		for (let map in found)
		{
			if (map.Id == id && (hash.IsEmpty || map.Hash == hash))
				return true;
		}
		return false;
	}

	/// Player: asks the host for its map. Does nothing while that map is already coming.
	public static void Request(NetworkManager network, StringView id, StringView hash)
	{
		Register();
		if (network == null || !network.IsClient)
			return;
		if ((sState == .Asking || sState == .Downloading) && sWantedId == id && sWantedHash == hash)
			return;
		sWantedId.Set(id);
		sWantedHash.Set(hash);
		sName.Clear();
		sReceived.Clear();
		sTotal = 0;
		sQuiet = 0;
		sError.Clear();
		sDownloadedFile.Clear();
		sState = .Asking;
		sAsker = network;
		sWriter.Clear();
		sWriter.Write(KindRequest);
		sWriter.WriteString(id);
		sWriter.WriteString(hash);
		network.SendToServer(MsgMap, sWriter);
		Log.Info(scope $"Asking the host for map {id}.");
	}

	/// Player: forgets the download (back to None), or gives up on one still coming. Call it when leaving a game.
	public static void Reset()
	{
		sState = .None;
		sAsker = null;
		sReceived.Clear();
		sTotal = 0;
	}

	/// Called by NetworkManager every tick: sends the next pieces to each player, and gives up on a host that has
	/// gone quiet.
	public static void Tick(NetworkManager network)
	{
		Register();
		if (network.IsServer)
		{
			for (let sending in sSending)
			{
				while (sending.Sent < sending.Data.Count && sending.Sent - sending.Acknowledged < Window * PieceBytes)
				{
					let length = Math.Min(PieceBytes, sending.Data.Count - sending.Sent);
					sWriter.Clear();
					sWriter.Write(KindPiece);
					sWriter.Write((int32)sending.Sent);
					sWriter.Write((uint16)length);
					sWriter.Data.AddRange(Span<uint8>(sending.Data.Ptr + sending.Sent, length));
					network.SendToClient(sending.Client, MsgMap, sWriter);
					sending.Sent += length;
				}
			}
		}
		if ((sState == .Asking || sState == .Downloading) && network == sAsker)
		{
			sQuiet += Time.FixedDeltaTime;
			if (!network.IsClient || sQuiet > TimeoutSeconds)
				Fail(network.IsClient ? "The host stopped sending the map." : "Left the game before the map arrived.");
		}
	}

	/// Called by NetworkManager when a player leaves: stops sending to them.
	public static void ClientLeft(int32 clientId)
	{
		for (int i = sSending.Count - 1; i >= 0; i--)
		{
			if (sSending[i].Client == clientId)
			{
				delete sSending[i];
				sSending.RemoveAt(i);
			}
		}
	}

	static void Register()
	{
		if (sRegistered)
			return;
		sRegistered = true;
		NetworkManager.RegisterMessage(MsgMap, new => OnMessage);
	}

	static void OnMessage(int32 sender, ref NetReader reader)
	{
		let kind = reader.Read<uint8>();
		let network = NetworkManager.Dispatching ?? Scene.Active?.Network;
		switch (kind)
		{
		case KindRequest: OnRequest(network, sender, ref reader);
		case KindAck: OnAck(sender, ref reader);
		case KindBegin: OnBegin(ref reader);
		case KindPiece: OnPiece(network, ref reader);
		case KindMissing: Fail("The host does not have that map any more.");
		}
	}

	static void OnRequest(NetworkManager network, int32 sender, ref NetReader reader)
	{
		let id = scope String();
		let hash = scope String();
		reader.ReadString(id);
		reader.ReadString(hash);
		if (!reader.Ok || network == null || !network.IsServer || sender <= 0)
			return;
		ClientLeft(sender);
		Offered offered = null;
		for (let entry in sOffered)
		{
			if (entry.Id == id)
				offered = entry;
		}
		let sending = new Sending();
		sending.Client = sender;
		bool readable = offered != null;
		if (readable && System.IO.File.ReadAll(offered.File, sending.Data) case .Err)
			readable = false;
		if (!readable || sending.Data.Count > MaxBytes)
		{
			delete sending;
			sWriter.Clear();
			sWriter.Write(KindMissing);
			network.SendToClient(sender, MsgMap, sWriter);
			Log.Warning(scope $"A player asked for map {id}, which this host cannot send.");
			return;
		}
		let actual = MapFiles.Hash(sending.Data, .. scope .());
		sWriter.Clear();
		sWriter.Write(KindBegin);
		sWriter.WriteString(offered.Id);
		sWriter.WriteString(actual);
		sWriter.WriteString(offered.Name);
		sWriter.Write((int32)sending.Data.Count);
		network.SendToClient(sender, MsgMap, sWriter);
		sSending.Add(sending);
		Log.Info(scope $"Sending map {offered.Name} ({sending.Data.Count / 1024} KB) to player {sender}.");
	}

	static void OnAck(int32 sender, ref NetReader reader)
	{
		let received = reader.Read<int32>();
		if (!reader.Ok)
			return;
		for (int i = sSending.Count - 1; i >= 0; i--)
		{
			let sending = sSending[i];
			if (sending.Client != sender)
				continue;
			sending.Acknowledged = Math.Clamp(received, sending.Acknowledged, sending.Sent);
			if (sending.Acknowledged >= sending.Data.Count)
			{
				delete sending;
				sSending.RemoveAt(i);
			}
		}
	}

	static void OnBegin(ref NetReader reader)
	{
		let id = scope String();
		let hash = scope String();
		let name = scope String();
		reader.ReadString(id);
		reader.ReadString(hash);
		reader.ReadString(name);
		let total = reader.Read<int32>();
		if (!reader.Ok || sState != .Asking || id != sWantedId)
			return;
		if (total <= 0 || total > MaxBytes)
		{
			Fail(scope $"The map is too large ({total / (1024 * 1024)} MB; the most is {MaxBytes / (1024 * 1024)} MB).");
			return;
		}
		// The host's own copy may be newer than the one the session named: the file's hash is what is checked.
		sWantedHash.Set(hash);
		sName.Set(name);
		sTotal = total;
		sReceived.Clear();
		sReceived.Reserve(total);
		sQuiet = 0;
		sState = .Downloading;
	}

	static void OnPiece(NetworkManager network, ref NetReader reader)
	{
		let offset = reader.Read<int32>();
		let length = (int)reader.Read<uint16>();
		if (!reader.Ok || sState != .Downloading)
			return;
		if (offset != sReceived.Count || offset + length > sTotal)
		{
			Fail("The map arrived out of order.");
			return;
		}
		let bytes = scope uint8[length];
		for (int i < length)
			bytes[i] = reader.Read<uint8>();
		if (!reader.Ok)
		{
			Fail("A piece of the map was cut short.");
			return;
		}
		sReceived.AddRange(bytes);
		sQuiet = 0;
		if (network != null)
		{
			sWriter.Clear();
			sWriter.Write(KindAck);
			sWriter.Write((int32)sReceived.Count);
			network.SendToServer(MsgMap, sWriter);
		}
		if (sReceived.Count == sTotal)
			Finish();
	}

	static void Finish()
	{
		let hash = MapFiles.Hash(sReceived, .. scope .());
		if (hash != sWantedHash)
		{
			Fail("The map that arrived is not the one the host sent (its hash differs).");
			return;
		}
		let folder = Folder;
		Directory.CreateDirectory(folder).IgnoreError();
		// Replaces the older version of the same map, wherever it is in the folder.
		let found = scope List<MapFileInfo>();
		defer
		{
			ClearAndDeleteItems!(found);
		}
		MapFiles.Find(folder, found);
		let target = scope String();
		for (let map in found)
		{
			if (map.Id == sWantedId && target.IsEmpty)
				target.Set(map.File);
		}
		if (target.IsEmpty)
		{
			let fileName = scope String();
			for (let c in sName.RawChars)
				fileName.Append((c.IsLetterOrDigit || c == ' ' || c == '-' || c == '_') ? c : '_');
			fileName.Trim();
			if (fileName.IsEmpty)
				fileName.Set(sWantedId);
			target.AppendF("{}/{}{}", folder, fileName, MapFiles.Extension);
			if (System.IO.File.Exists(target))
			{
				target.Clear();
				target.AppendF("{}/{} {}{}", folder, fileName, sWantedId, MapFiles.Extension);
			}
		}
		if (System.IO.File.WriteAll(target, sReceived) case .Err)
		{
			Fail(scope $"Could not write {target}.");
			return;
		}
		sDownloadedFile.Set(target);
		sState = .Done;
		sReceived.Clear();
		Log.Info(scope $"Downloaded map {sName} into {target}.");
	}

	static void Fail(StringView reason)
	{
		if (sState != .Asking && sState != .Downloading)
			return;
		sError.Set(reason);
		sState = .Failed;
		sReceived.Clear();
		Log.Warning(scope $"Map download failed: {reason}");
	}
}
