using System;
using System.Collections;

namespace Tallow;

/// Lets an editor watch this program's Profiler over the network (docs/profiler.md): `--profile-listen [port]` on a
/// game or a dedicated server, then Window > Profiler > Attach in the editor. While an editor is connected the
/// Profiler records, and each finished frame goes to it (names first, as they are made). A command from the editor
/// starts or stops recording.
public static class ProfilerServer
{
	public const uint16 DefaultPort = 7741;
	public const uint8 CommandRecord = 1;
	public const uint8 CommandStop = 2;

	static void* sHost;
	static List<void*> sPeers = new .() ~ delete _;
	static List<int32> sNames = new .() ~ delete _;
	static List<uint8> sBytes = new .() ~ delete _;
	/// Whether recording was started for the editors (and so stops when the last one goes).
	static bool sStarted;
	static bool sSubscribed;
	static bool sReady;

	public static bool Listening => sHost != null;
	/// How many editors are watching.
	public static int32 Watchers => (int32)sPeers.Count;
	public static uint16 Port;

	/// Opens the port for editors. False when it cannot be opened (in use, or a web build).
	public static bool Listen(uint16 port = DefaultPort)
	{
#if BF_PLATFORM_WASM
		return false;
#else
		Stop();
		if (!sReady)
		{
			ENet.enet_initialize();
			sReady = true;
		}
		ENet.Address address;
		address.host = 0;
		address.port = port;
		sHost = ENet.enet_host_create(&address, 4, 1, 0, 0);
		if (sHost == null)
		{
			Log.Error(scope $"The profiler could not listen on port {port}.");
			return false;
		}
		Port = port;
		if (!sSubscribed)
		{
			Profiler.OnFrame.Add(new => Send);
			sSubscribed = true;
		}
		Log.Info(scope $"Profiler listening on port {port}: in the editor, Window > Profiler > Attach.");
		return true;
#endif
	}

	public static void Stop()
	{
		if (sHost == null)
			return;
		for (let peer in sPeers)
			ENet.enet_peer_disconnect_now(peer, 0);
		sPeers.Clear();
		ENet.enet_host_destroy(sHost);
		sHost = null;
		if (sStarted)
		{
			Profiler.Enabled = false;
			sStarted = false;
		}
	}

	static void SendTo(void* peer, Span<uint8> bytes)
	{
		let packet = ENet.enet_packet_create(bytes.Ptr, (uint)bytes.Length, ENet.FlagReliable);
		ENet.enet_peer_send(peer, 0, packet);
	}

	/// Every name and thread so far, for an editor that has just connected.
	static void SendAllNames(void* peer)
	{
		sBytes.Clear();
		let local = Profiler.Local;
		for (int i < local.names.Count)
		{
			let name = local.names[i];
			if (name.text != null)
				ProfilerCapture.WriteName(sBytes, (int32)i, name.text, name.category, name.kind, name.unit);
		}
		for (int i < local.threads.Count)
			ProfilerCapture.WriteThread(sBytes, (int32)i, local.threads[i]);
		SendTo(peer, sBytes);
	}

	/// Answers editors connecting, leaving and asking (Application.Frame calls it each frame).
	public static void Update()
	{
		if (sHost == null)
			return;
		ENet.Event event = default;
		while (ENet.enet_host_service(sHost, &event, 0) > 0)
		{
			switch (event.type)
			{
			case ENet.EventConnect:
				sPeers.Add(event.peer);
				if (!Profiler.Enabled)
				{
					Profiler.Enabled = true;
					sStarted = true;
				}
				// Names made before now; later ones go with the frames.
				Profiler.TakeNewNames(sNames);
				sNames.Clear();
				SendAllNames(event.peer);
			case ENet.EventDisconnect:
				sPeers.Remove(event.peer);
				if (sPeers.IsEmpty && sStarted)
				{
					Profiler.Enabled = false;
					sStarted = false;
				}
			case ENet.EventReceive:
				if (event.packet != null)
				{
					if (event.packet.dataLength >= 1)
					{
						let command = event.packet.data[0];
						if (command == CommandRecord && !Profiler.Enabled)
						{
							Profiler.Enabled = true;
							sStarted = true;
						}
						else if (command == CommandStop && Profiler.Enabled)
						{
							Profiler.Enabled = false;
							sStarted = false;
						}
					}
					ENet.enet_packet_destroy(event.packet);
				}
			default:
			}
		}
	}

	static void Send(ProfilerFrame frame)
	{
		if (sHost == null || sPeers.IsEmpty)
			return;
		sBytes.Clear();
		Profiler.TakeNewNames(sNames);
		let local = Profiler.Local;
		for (let id in sNames)
		{
			if (id < 0)
			{
				let thread = -1 - id;
				ProfilerCapture.WriteThread(sBytes, thread, local.ThreadName(thread));
			}
			else if (id < local.names.Count && local.names[id].text != null)
				ProfilerCapture.WriteName(sBytes, id, local.names[id].text, local.names[id].category, local.names[id].kind, local.names[id].unit);
		}
		sNames.Clear();
		ProfilerCapture.WriteFrame(sBytes, frame);
		for (let peer in sPeers)
			SendTo(peer, sBytes);
		ENet.enet_host_flush(sHost);
	}
}

/// The editor's end of ProfilerServer: connects to a running game or server and fills its own capture with the
/// frames it is sent.
public class ProfilerClient
{
	public ProfilerCapture capture = new .() ~ delete _;
	void* mHost;
	void* mPeer;
	static bool sReady;
	public bool Connected { get; private set; }
	/// Waiting for the other end to answer.
	public bool Connecting => mPeer != null && !Connected;
	public String address = new .() ~ delete _;
	/// Bytes received since connecting.
	public int64 received;

	public ~this()
	{
		Disconnect();
	}

	public bool Connect(StringView host, uint16 port)
	{
		Disconnect();
		if (!sReady)
		{
			ENet.enet_initialize();
			sReady = true;
		}
		mHost = ENet.enet_host_create(null, 1, 1, 0, 0);
		if (mHost == null)
			return false;
		ENet.Address target = default;
		ENet.enet_address_set_host(&target, scope String(host).CStr());
		target.port = port;
		mPeer = ENet.enet_host_connect(mHost, &target, 1, 0);
		address.Clear();
		address.AppendF("{}:{}", host, port);
		capture.Clear();
		received = 0;
		return mPeer != null;
	}

	public void Disconnect()
	{
		if (mPeer != null)
		{
			ENet.enet_peer_disconnect_now(mPeer, 0);
			mPeer = null;
		}
		if (mHost != null)
		{
			ENet.enet_host_destroy(mHost);
			mHost = null;
		}
		Connected = false;
	}

	/// Starts or stops the other end's recording.
	public void SetRecording(bool on)
	{
		if (mPeer == null || !Connected)
			return;
		uint8 command = on ? ProfilerServer.CommandRecord : ProfilerServer.CommandStop;
		let packet = ENet.enet_packet_create(&command, 1, ENet.FlagReliable);
		ENet.enet_peer_send(mPeer, 0, packet);
		ENet.enet_host_flush(mHost);
	}

	/// Takes what has arrived (call it every frame). `wait` milliseconds for the first event (tests).
	public void Update(uint32 wait = 0)
	{
		if (mHost == null)
			return;
		ENet.Event event = default;
		var timeout = wait;
		while (ENet.enet_host_service(mHost, &event, timeout) > 0)
		{
			timeout = 0;
			switch (event.type)
			{
			case ENet.EventConnect:
				Connected = true;
			case ENet.EventDisconnect:
				Connected = false;
				mPeer = null;
			case ENet.EventReceive:
				if (event.packet != null)
				{
					received += (int64)event.packet.dataLength;
					capture.Read(.(event.packet.data, (int)event.packet.dataLength));
					ENet.enet_packet_destroy(event.packet);
				}
			default:
			}
		}
	}
}
