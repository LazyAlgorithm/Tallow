using System;
using System.Collections;

namespace Tallow;

/// Interest management (6e): which clients hear about which objects. An object a client is told nothing of is not
/// destroyed there: it is hidden (GameObject.NetworkHidden), and shown again, where the server has it, when news of
/// it comes. Objects come into a client's area within SnapshotRelevanceRadius of its player and leave it only past
/// RelevanceHysteresis times that, so walking along the edge does not make them blink. Snapshots, [Sync] fields
/// and effects all follow it: an object coming back into the area is sent its fields afresh.
extension NetworkManager
{
	/// How much further than SnapshotRelevanceRadius an object must be before it leaves a client's area.
	public float RelevanceHysteresis = 1.2f;

	const uint8 MsgHide = 22;

	/// Client: how many objects are hidden here as out of this machine's area (for the panel and tests).
	public int32 HiddenObjects;

	/// Server, as a snapshot is put together for a client: whether a row is in its area, noting it going out (the
	/// client is told to hide it) and coming back (it is sent the object's fields; its record goes as new).
	bool UpdateRelevance(ClientInfo client, SnapshotRow row, GameObject player, Vector3 playerAt)
	{
		bool relevant;
		if (row.settings.relevance == .OwnerOnly)
			relevant = false;
		else if (Lockstep)
			// Every client runs the whole world.
			relevant = true;
		else if (!row.settings.distanceFiltered || SnapshotRelevanceRadius <= 0 || player == null)
			relevant = true;
		else
		{
			let outside = client.outside.Contains(row.netId);
			let radius = outside ? SnapshotRelevanceRadius : SnapshotRelevanceRadius * Math.Max(RelevanceHysteresis, 1);
			relevant = (row.position - playerAt).LengthSquared <= radius * radius;
		}
		if (relevant)
		{
			if (client.outside.Remove(row.netId))
				NetworkSync.SendFieldsTo(this, row.identity.Handle, client.id);
			return true;
		}
		if (client.outside.Add(row.netId))
		{
			client.delivered.Remove(row.netId);
			client.waiting.Remove(row.netId);
			mWriter.Clear();
			mWriter.Write(MsgHide);
			WriteNetId(mWriter, row.netId);
			mWriter.Write(mTick);
			Send(client.peer, true);
		}
		return false;
	}

	/// Server: whether a client is told about an object (it is in that client's area).
	public bool IsRelevantTo(int32 clientId, uint32 netId)
	{
		for (let client in mClients)
			if (client.id == clientId)
				return !client.outside.Contains(netId);
		return false;
	}

	/// Server: sends a reliable game message about an object to the clients whose area it is in.
	public void SendAbout(uint32 netId, uint8 id, NetWriter payload)
	{
		if (!IsServer)
			return;
		WriteCustom(id, payload);
		for (let client in mClients)
			if (!client.outside.Contains(netId))
				Send(client.peer, true);
	}

	/// Server: sends a reliable game message about something happening at a place to the clients whose player is
	/// within reach of it (the relevance radius with its hysteresis, or `reach` if further), or to all with no
	/// relevance radius set.
	public void SendNear(Vector3 position, uint8 id, NetWriter payload, float reach = 0)
	{
		if (!IsServer)
			return;
		if (SnapshotRelevanceRadius <= 0)
		{
			SendToAll(id, payload);
			return;
		}
		let radius = Math.Max(SnapshotRelevanceRadius * Math.Max(RelevanceHysteresis, 1), reach);
		WriteCustom(id, payload);
		for (let client in mClients)
		{
			let player = PlayerObject(client.id);
			if (player == null || (player.Transform.Position - position).LengthSquared <= radius * radius)
				Send(client.peer, true);
		}
	}

	/// Client: the server says an object has gone out of this machine's area; hide it until news of it comes.
	void ReadHide(ref NetReader reader)
	{
		let netId = ReadId(ref reader);
		let tick = reader.Read<uint32>();
		if (!reader.Ok)
			return;
		if (!mByNetId.TryGetValue(netId, let identity))
			return;
		if (identity.ownerId == LocalClientId)
			return;
		ForgetRemotePlayer(netId);
		identity.HiddenAt = Math.Max(tick, 1);
		if (!identity.GameObject.NetworkHidden)
			HiddenObjects++;
		identity.GameObject.NetworkHidden = true;
		identity.Predicted = false;
		identity.ClearKeys();
	}

	/// Client: news of a hidden object newer than its hiding shows it again, starting from where the news has it
	/// (not gliding from where it was last seen). Returns false when the news is older than the hiding.
	bool ShowIfHidden(NetworkIdentity identity, uint32 serverTick)
	{
		if (identity.HiddenAt == 0)
			return true;
		if ((int32)(serverTick - identity.HiddenAt) <= 0)
			return false;
		identity.HiddenAt = 0;
		if (identity.GameObject.NetworkHidden)
			HiddenObjects--;
		identity.GameObject.NetworkHidden = false;
		identity.ClearKeys();
		return true;
	}
}
