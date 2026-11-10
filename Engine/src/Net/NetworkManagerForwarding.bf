using System;
using System.Collections;

namespace Tallow;

/// Input forwarding (6g). The server tells each client the controls the other players relevant to it were run
/// with, tick by tick, with every snapshot. A client then runs those players in the present, as it runs its own
/// player, instead of showing them a moment in the past: a crate another player walks into moves on this screen
/// the tick it is hit, as it does on theirs. For a tick it has no controls for yet, it repeats the last it has,
/// which is right while a player holds the same keys; when the real ones differ, it goes back and runs the ticks
/// since again. The server still sends the exact state of those players and stays in charge: anything that drifts
/// is put right as before.
extension NetworkManager
{
	/// Send each client the controls of the players near it, so that it can run them in the present (on by
	/// default). Off: other players are shown a moment in the past, as before.
	public bool InputForwarding = true;

	const uint8 MsgForward = 23;

	/// Server: the controls the host's own player was run with, by tick, and the last tick they changed.
	NetInput[InputHistory] mHostApplied;
	uint32 mHostAppliedNewest;
	uint32 mHostInputChangedAt;

	/// Server: a player run on a client from forwarded controls comes out there as it does here, so its state goes
	/// to that client only to check on it: for a few snapshots after its controls change (that client guessed
	/// the old ones for a moment and must be put right), and every fourth snapshot otherwise.
	bool SkipForwarded(ClientInfo client, SnapshotRow row)
	{
		if (!ForwardsFor(row.identity) || !client.forwarded.ContainsKey(row.netId))
			return false;
		uint32 changedAt = 0;
		if (row.settings.ownerId == 0)
			changedAt = mMode == .Host ? mHostInputChangedAt : mTick;
		else
		{
			changedAt = mTick;
			for (let other in mClients)
			{
				if (other.id == row.settings.ownerId)
					changedAt = other.inputChangedAt;
			}
		}
		let interval = (uint32)Math.Max(SnapshotInterval, 1);
		if (mTick - changedAt <= interval * 3)
			return false;
		return ((mTick / interval) + row.netId) % 4 != 0;
	}

	/// Client: another player run here in the present from forwarded controls.
	class RemotePlayer
	{
		public NetworkIdentity identity;
		/// Controls known for each of this machine's ticks (knownAt says which tick a slot holds), and the ones
		/// used for each tick when it was run (usedAt likewise), to tell when a guess was wrong.
		public NetInput[InputHistory] known;
		public uint32[InputHistory] knownAt;
		public NetInput[InputHistory] used;
		public uint32[InputHistory] usedAt;
		public uint32 newestKnown;
		public NetInput last;
		/// The tick of this machine at which controls last came for it.
		public uint32 heardAt;
		/// Ticks up to here were checked against a snapshot already.
		public uint32 settledTo;

		public NetInput For(uint32 tick) => knownAt[tick % InputHistory] == tick ? known[tick % InputHistory] : last;
	}

	Dictionary<uint32, RemotePlayer> mRemotePlayers = new .() ~ DeleteDictionaryAndValues!(_);
	/// Client: how many forwarded controls differed from the guess for their tick, and how many were the same.
	public int32 GuessesWrong, GuessesRight;
	/// Client: how many times ticks were run again only because another player's controls differed from the guess
	/// (not counted in Rollbacks: nothing was wrong with what this machine worked out).
	public int32 InputReplays;
	/// Client: how many other players are being run here in the present.
	public int32 RemotePlayersRun => (int32)mRemotePlayers.Count;

	/// Server, as each tick's controls are taken: remembers what each player was run with.
	void NoteApplied(uint32 tick)
	{
		if (mMode == .Host)
		{
			if (!InputsSame(mHostApplied[(tick - 1) % InputHistory], mHostInput))
				mHostInputChangedAt = tick;
			mHostApplied[tick % InputHistory] = mHostInput;
			mHostAppliedNewest = tick;
		}
		for (let client in mClients)
		{
			if (client.lastProcessedTick == 0)
				continue;
			if (!InputsSame(client.applied[(tick - 1) % InputHistory], client.lastInput))
				client.inputChangedAt = tick;
			client.applied[tick % InputHistory] = client.lastInput;
			client.appliedNewest = tick;
		}
	}

	/// Whether a player's object goes to other clients exactly (FlagFull), for running it from its controls.
	bool ForwardsFor(NetworkIdentityState identity) => (InputForwarding || Lockstep) && identity.ChosenKind == .Player && identity.Chosen.playerControlled;

	/// Server, after a client's snapshot: the controls of the players in its area for the last two snapshots'
	/// worth of ticks (so one lost packet loses nothing), each as a difference from the one before.
	void SendForwarded(ClientInfo to)
	{
		if (!(InputForwarding || Lockstep) || to.lastProcessedTick == 0)
			return;
		// (Not to a client about to be sent the whole state again: it could not match until it has it.)
		let hashDue = Lockstep && to.lockstepSynced && mTick % HashEvery == 0;
		let count = (uint32)Math.Clamp(SnapshotInterval * 2 + 1, 1, 32);
		mWriter.Clear();
		mWriter.Write(MsgForward);
		mWriter.Write(mTick);
		mWriter.Write(to.lastProcessedTick);
		let countAt = mWriter.Data.Count;
		mWriter.Write((uint8)0);
		int players = 0;
		void Add(int32 ownerId, NetInput[InputHistory] applied, uint32 newest)
		{
			if (newest != mTick || players >= 255)
				return;
			let player = PlayerObject(ownerId);
			if (player == null)
				return;
			let identity = player.GetComponent<NetworkIdentity>();
			if (!identity.IsValid || to.outside.Contains(identity.NetId))
				return;
			let n = (uint32)Math.Min(count, newest);
			// Nothing new since the last sent, which the client keeps on using: said again only once a second.
			if (ownerId != to.id && to.forwarded.TryGetValue(identity.NetId, let sent) && mTick - sent.tick < (uint32)Time.TickRate)
			{
				bool same = true;
				for (uint32 i < n)
					same &= InputsSame(applied[(newest - i) % InputHistory], sent.input);
				if (same)
					return;
			}
			to.forwarded[identity.NetId] = (applied[newest % InputHistory], mTick);
			WriteNetId(mWriter, identity.NetId);
			mWriter.Write((uint8)n);
			NetInput previous = default;
			for (int i = (int)n - 1; i >= 0; i--)
			{
				let input = applied[(newest - (uint32)i) % InputHistory];
				NetPack.WriteInput(mWriter, input, previous, i != (int)n - 1);
				previous = input;
			}
			players++;
		}
		if (mMode == .Host)
			Add(0, mHostApplied, mHostAppliedNewest);
		for (let client in mClients)
		{
			if (client != to)
				Add(client.id, client.applied, client.appliedNewest);
		}
		// Lockstep: a client whose controls the server had to guess (they came late) is told what it ran with.
		if (Lockstep && (int32)(to.ownInputsUntil - mTick) > 0)
			Add(to.id, to.applied, to.appliedNewest);
		if (players == 0 && !hashDue)
			return;
		mWriter.Data[countAt] = (uint8)players;
		if (Lockstep)
		{
			mWriter.Write((uint8)(hashDue ? 1 : 0));
			if (hashDue)
				mWriter.Write(ServerHash());
		}
		Send(to.peer, false);
	}

	/// Client: forwarded controls. The server's ticks become this machine's through the snapshot's pair of ticks
	/// (the server tick and the tick of this machine's controls it had just used), as predicted bodies' are.
	void ReadForwarded(ref NetReader reader)
	{
		reader.Read<uint32>(); // The server tick: not needed here.
		let ackTick = reader.Read<uint32>();
		let players = (int)reader.Read<uint8>();
		if (!reader.Ok || !(InputForwarding || Lockstep) || ackTick == 0)
			return;
		for (int p < players)
		{
			let netId = ReadId(ref reader);
			let count = (int)reader.Read<uint8>();
			if (!reader.Ok || count > 32)
				return;
			NetInput previous = default;
			RemotePlayer remote = null;
			bool mine = false;
			if (mByNetId.TryGetValue(netId, let mineIdentity) && mineIdentity.ownerId == LocalClientId)
				mine = Lockstep;
			else if (mByNetId.TryGetValue(netId, let identity) && identity.ownerId != LocalClientId && identity.IsActiveAndEnabled && !identity.GameObject.NetworkHidden)
			{
				if (!mRemotePlayers.TryGetValue(netId, out remote))
				{
					remote = new .();
					remote.identity = identity;
					mRemotePlayers[netId] = remote;
					identity.RemoteRun = true;
					identity.Predicted = false;
					// Run from the exact state the server sends from now on; until it comes, from where it is shown.
					for (int i < NetworkIdentity.HistorySize)
						identity.History[i] = identity.CaptureState();
				}
				remote.heardAt = mTick;
			}
			for (int i < count)
			{
				let input = NetPack.ReadInput(ref reader, previous);
				if (!reader.Ok)
					return;
				previous = input;
				if (remote == null && !mine)
					continue;
				// The server ran this one at serverTick - (count - 1 - i), which is this machine's ackTick minus as much.
				let local = (int64)ackTick - (int64)(count - 1 - i);
				if (local <= 0)
					continue;
				let tick = (uint32)local;
				if (mine)
				{
					// What the server really ran this machine's player with, where it differs from what was given.
					if ((int32)(mTick - tick) >= 0 && mTick - tick < (uint32)ExactRingSize && !InputsSame(mInputs[tick % InputHistory], input))
					{
						mInputs[tick % InputHistory] = input;
						if (mOwnFixedFrom == 0 || (int32)(tick - mOwnFixedFrom) < 0)
							mOwnFixedFrom = tick;
					}
					continue;
				}
				let slot = tick % InputHistory;
				if (remote.knownAt[slot] == tick)
					continue;
				remote.known[slot] = input;
				remote.knownAt[slot] = tick;
				if ((int32)(tick - remote.newestKnown) > 0)
				{
					remote.newestKnown = tick;
					remote.last = input;
				}
				// Already run with a guess: was it right?
				if (remote.usedAt[slot] == tick && (int32)(mTick - tick) >= 0)
				{
					if (!InputsSame(remote.used[slot], input))
						GuessesWrong++;
					else
						GuessesRight++;
				}
			}
		}
		if (Lockstep)
		{
			bool hasHash = false;
			uint64 hash = 0;
			if (reader.Remaining > 0 && reader.Read<uint8>() != 0)
			{
				hash = reader.Read<uint64>();
				hasHash = reader.Ok;
			}
			LockstepCatchUp(ackTick, hasHash, hash);
		}
	}

	/// Client, as a snapshot is checked: whether any other player was run, since the snapshot before, with
	/// controls that turned out different from the ones now known for that tick. Ticks up to the snapshot's are
	/// then taken as settled (its state has the right ones in).
	bool GuessedWrong(uint32 ackTick)
	{
		bool wrong = false;
		for (let remote in mRemotePlayers.Values)
		{
			for (uint32 back < 40)
			{
				let tick = mTick - back;
				if (tick == 0 || (int32)(tick - remote.settledTo) <= 0)
					break;
				let slot = tick % InputHistory;
				if (remote.knownAt[slot] != tick || remote.usedAt[slot] != tick)
					continue;
				if (!InputsSame(remote.known[slot], remote.used[slot]))
				{
					wrong = true;
					if ((int32)(tick - ackTick) <= 0)
						remote.used[slot] = remote.known[slot];
				}
			}
			if ((int32)(ackTick - remote.settledTo) > 0)
				remote.settledTo = ackTick;
		}
		return wrong;
	}

	static bool InputsSame(NetInput a, NetInput b) => a.moveX == b.moveX && a.moveZ == b.moveZ && a.yaw == b.yaw && a.pitch == b.pitch && a.buttons == b.buttons;

	/// Client, every tick after its own player: runs the other players it has controls for, guessing the last
	/// controls where the real ones have not come yet. One not heard of for two seconds goes back to being shown
	/// in the past.
	void RunRemotePlayers(uint32 tick, bool replaying, bool beforeOwn)
	{
		if (mRemotePlayers.Count == 0)
			return;
		List<uint32> dropped = null;
		for (let (netId, remote) in mRemotePlayers)
		{
			let identity = remote.identity;
			// In the order the server runs them: the host's, then each client's by joining (owner id).
			if ((identity.ownerId < LocalClientId) != beforeOwn)
				continue;
			if (!replaying && (!(InputForwarding || Lockstep) || (int32)(mTick - remote.heardAt) > Time.TickRate * 2 || !identity.IsActiveAndEnabled || identity.ownerId == LocalClientId || identity.GameObject.NetworkHidden))
			{
				if (dropped == null)
					dropped = scope:: .();
				dropped.Add(netId);
				continue;
			}
			let input = remote.For(tick);
			remote.used[tick % InputHistory] = input;
			remote.usedAt[tick % InputHistory] = tick;
			SimulateIdentity(identity, input);
		}
		if (dropped != null)
		{
			for (let netId in dropped)
				ForgetRemotePlayer(netId);
		}
	}

	void ForgetRemotePlayer(uint32 netId)
	{
		if (mRemotePlayers.GetAndRemove(netId) case .Ok(let pair))
		{
			if (!pair.value.identity.GameObject.IsDestroyed)
			{
				pair.value.identity.RemoteRun = false;
				pair.value.identity.ClearKeys();
			}
			delete pair.value;
		}
	}

	/// Client: a fresh session; nobody is run from forwarded controls yet.
	void ResetForwarding()
	{
		for (let netId in mRemotePlayers.Keys)
		{
			let remote = mRemotePlayers[netId];
			if (!remote.identity.GameObject.IsDestroyed)
				remote.identity.RemoteRun = false;
			delete remote;
		}
		mRemotePlayers.Clear();
	}
}
