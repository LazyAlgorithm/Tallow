using System;
using System.Collections;

namespace Tallow;

/// ENet: reliable and unreliable channels over UDP.
static class ENet
{
	[CRepr] public struct Address
	{
		public uint32 host;
		public uint16 port;
	}

	[CRepr] public struct Packet
	{
		public uint referenceCount;
		public uint32 flags;
		public uint8* data;
		public uint dataLength;
		public void* freeCallback;
		public void* userData;
	}

	[CRepr] public struct Event
	{
		public int32 type;
		public void* peer;
		public uint8 channelId;
		public uint32 data;
		public Packet* packet;
	}

	public const int32 EventConnect = 1;
	public const int32 EventDisconnect = 2;
	public const int32 EventReceive = 3;
	public const uint32 FlagReliable = 1;

	[CLink] public static extern int32 enet_initialize();
	[CLink] public static extern int32 enet_host_compress_with_range_coder(void* host);
	[CLink] public static extern int32 enet_address_set_host(Address* address, char8* hostName);
	[CLink] public static extern void* enet_host_create(Address* address, uint peerCount, uint channelLimit, uint32 incomingBandwidth, uint32 outgoingBandwidth);
	[CLink] public static extern void enet_host_destroy(void* host);
	[CLink] public static extern void* enet_host_connect(void* host, Address* address, uint channelCount, uint32 data);
	[CLink] public static extern void enet_peer_throttle_configure(void* peer, uint32 interval, uint32 acceleration, uint32 deceleration);
	[CLink] public static extern int32 enet_host_service(void* host, Event* event, uint32 timeout);
	[CLink] public static extern void enet_host_flush(void* host);
	[CLink] public static extern Packet* enet_packet_create(void* data, uint length, uint32 flags);
	[CLink] public static extern void enet_packet_destroy(Packet* packet);
	[CLink] public static extern int32 enet_peer_send(void* peer, uint8 channel, Packet* packet);
	[CLink] public static extern void enet_peer_disconnect(void* peer, uint32 data);
	[CLink] public static extern void enet_peer_disconnect_now(void* peer, uint32 data);
}
