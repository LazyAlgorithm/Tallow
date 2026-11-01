using System;
using System.Collections;

namespace Tallow;

/// How a network session reaches other machines.
[Reflect(.All)]
enum NetworkTransportKind : int32
{
	/// UDP straight to an IP address and port (ENet). Works on a LAN, or over the internet with the port forwarded.
	Direct,
	/// Through Steam: players are found by Steam ID and traffic goes over Steam's relay network, so nobody
	/// forwards a port or reveals an address. Needs the Steam client running.
	Steam,
	/// Browser to browser (WebRTC), for games built for the web: the host gets a room code, players join with it,
	/// and nobody forwards a port. A web build uses this whatever the kind says, since a browser can do nothing else.
	WebRtc
}

enum NetEventKind { Connected, Disconnected, Data }

struct NetEvent
{
	public NetEventKind kind;
	/// Who it concerns; the same value is passed back to Send.
	public void* peer;
	/// Valid until the next call to Poll.
	public uint8* data;
	public int length;
}

/// Carries packets for NetworkManager. One reliable ordered stream and one unreliable stream per peer.
abstract class NetTransport
{
	/// Starts accepting connections.
	public abstract bool Host(uint16 port);
	public virtual uint32 WireSent => 0;
	public virtual uint32 WireReceived => 0;
	/// Starts connecting to a host. A Connected event follows when it succeeds.
	public abstract bool Connect(StringView address, uint16 port, out void* server);
	/// Next thing that happened, or false when there is nothing more for now.
	public abstract bool Poll(out NetEvent event);
	public abstract void Send(void* peer, Span<uint8> data, bool reliable);
	public abstract void Disconnect(void* peer);
	/// Pushes queued packets out now.
	public abstract void Flush();
	public abstract void Close();

	public static NetTransport Create(NetworkTransportKind kind)
	{
#if BF_PLATFORM_WASM
		// A web page can open neither a UDP port nor Steam's network.
		return new WebRtcTransport();
#else
		switch (kind)
		{
		case .Steam: return new SteamTransport();
		case .Direct: return new ENetTransport();
		case .WebRtc:
			// Only a web build talks WebRTC; elsewhere the address is taken as an ordinary one.
			Log.Warning("WebRTC is for games built for the web; using a direct connection.");
			return new ENetTransport();
		}
#endif
	}
}

/// UDP through ENet.
class ENetTransport : NetTransport
{
	static bool sReady;
	public bool LosslessCompression;
	[CLink] static extern uint32 tallow_net_sent(void* host);
	[CLink] static extern uint32 tallow_net_received(void* host);
	public override uint32 WireSent => tallow_net_sent(mHost);
	public override uint32 WireReceived => tallow_net_received(mHost);
	bool ConfigureCompression() => !LosslessCompression || ENet.enet_host_compress_with_range_coder(mHost) == 0;
	void* mHost;
	ENet.Packet* mHeld;

	public this()
	{
		if (!sReady)
		{
			ENet.enet_initialize();
			sReady = true;
		}
	}

	public ~this()
	{
		Close();
	}

	public override bool Host(uint16 port)
	{
		Close();
		ENet.Address address;
		address.host = 0;
		address.port = port;
		mHost = ENet.enet_host_create(&address, 32, 2, 0, 0);
		if (mHost == null)
			Log.Error(scope $"Could not open UDP port {port}.");
		if (mHost != null && !ConfigureCompression())
		{
			Close();
			return false;
		}
		return mHost != null;
	}

	public override bool Connect(StringView address, uint16 port, out void* server)
	{
		Close();
		server = null;
		mHost = ENet.enet_host_create(null, 1, 2, 0, 0);
		if (mHost == null)
			return false;
		if (!ConfigureCompression())
		{
			Close();
			return false;
		}
		ENet.Address target = default;
		ENet.enet_address_set_host(&target, scope String(address).CStr());
		target.port = port;
		server = ENet.enet_host_connect(mHost, &target, 2, 0);
		if (server == null)
		{
			Close();
			return false;
		}
		return true;
	}

	/// ENet throttles a connection whose round trip suddenly gets slower by dropping unreliable packets at random.
	/// Snapshots and voice already cope with loss and lateness themselves (interpolation, a jitter buffer), and losing
	/// them on a moment's jitter (Wi-Fi, a busy machine) makes other players stutter; so the throttle never slows.
	/// Each end sets it once connected (setting it while connecting would send a command before the handshake).
	static void KeepUnreliable(void* peer)
	{
		ENet.enet_peer_throttle_configure(peer, 5000, 32, 0);
	}

	void Release()
	{
		if (mHeld != null)
			ENet.enet_packet_destroy(mHeld);
		mHeld = null;
	}

	public override bool Poll(out NetEvent event)
	{
		event = default;
		Release();
		if (mHost == null)
			return false;
		ENet.Event raw = default;
		while (ENet.enet_host_service(mHost, &raw, 0) > 0)
		{
			event.peer = raw.peer;
			switch (raw.type)
			{
			case ENet.EventConnect:
				KeepUnreliable(raw.peer);
				event.kind = .Connected;
				return true;
			case ENet.EventDisconnect:
				event.kind = .Disconnected;
				return true;
			case ENet.EventReceive:
				event.kind = .Data;
				event.data = raw.packet.data;
				event.length = (int)raw.packet.dataLength;
				mHeld = raw.packet;
				return true;
			default:
			}
		}
		return false;
	}

	public override void Send(void* peer, Span<uint8> data, bool reliable)
	{
		if (mHost == null || peer == null)
			return;
		let packet = ENet.enet_packet_create(data.Ptr, (uint)data.Length, reliable ? ENet.FlagReliable : 0);
		ENet.enet_peer_send(peer, reliable ? 0 : 1, packet);
	}

	public override void Disconnect(void* peer)
	{
		if (mHost != null && peer != null)
			ENet.enet_peer_disconnect_now(peer, 0);
	}

	public override void Flush()
	{
		if (mHost != null)
			ENet.enet_host_flush(mHost);
	}

	public override void Close()
	{
		Release();
		if (mHost != null)
		{
			ENet.enet_host_flush(mHost);
			ENet.enet_host_destroy(mHost);
		}
		mHost = null;
	}
}
