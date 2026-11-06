using System;
using System.Collections;

namespace Tallow;

/// Looking back in time: lag compensation for the server's hit checks, smoothing other players' objects between snapshots, and correcting this machine's own predictions.
extension NetworkManager
{
	/// The furthest back, in ticks, that lag compensation will go: 24 is 0.4 seconds.
	public int32 MaxRewindTicks = 24;
	// Server: whose controls are being run right now, and the server tick their machine was showing them.
	int32 mSimulatingClient = -1;
	double mSimulatingView;
	bool mRewound;
	double mRewoundTick = -1;

	/// While lag compensation is in effect (between BeginLagCompensation and EndLagCompensation), the server tick
	/// everything was put back to; -1 otherwise. For game state the engine does not keep a history of (a player's
	/// team, dimension or cover), to be looked up for the same moment.
	public double LagCompensationTick => mRewound ? mRewoundTick : -1;
	List<(NetworkIdentity identity, BodyState state)> mRewoundStates = new .() ~ delete _;
	// Client: the server tick everything else is being shown at this tick.
	double mViewTick;

	/// Server, while a player's tick is being run (in Update or Simulate): puts every other networked object back
	/// where that player's machine was showing it when they gave these controls, until EndLagCompensation. A
	/// player aims at what they see, which is the past: the time their controls took to arrive, plus the moment's
	/// delay everything they do not control is shown with. Do the ray cast or overlap test for a shot or a swing
	/// between the two calls, and the server judges it against what the player was looking at.
	///
	/// Returns false, having done nothing, anywhere it does not apply: with no session, on a client, and for the
	/// host's own player and the server's objects, who see things as they are. Keep what happens in between
	/// short and free of side effects: find out what was hit, end, then deal the damage.
	public bool BeginLagCompensation(NetworkIdentity forObject)
	{
		if (!IsServer || mRewound || !forObject.IsValid || forObject.ownerId <= 0 || forObject.ownerId != mSimulatingClient)
			return false;
		let view = Math.Max(mSimulatingView, (double)mTick - Math.Max(MaxRewindTicks, 0));
		if (view >= (double)mTick)
			return false;
		for (let identity in mIdentities)
		{
			// A body clients predict is seen by the player where it is now, as their own player is.
			if (identity.ownerId == forObject.ownerId || !identity.IsActiveAndEnabled || identity.PhysicsPredictable)
				continue;
			BodyState then;
			if (!identity.Sample(view, 0, out then))
				continue;
			let now = identity.CaptureState();
			if ((now.position - then.position).LengthSquared < 1.0e-6f)
				continue;
			mRewoundStates.Add((identity, now));
			var moved = now;
			moved.position = then.position;
			moved.rotation = then.rotation;
			identity.ApplyState(moved);
		}
		mRewound = true;
		mRewoundTick = view;
		return true;
	}

	/// Puts everything back where it really is. Safe to call when nothing was moved.
	public void EndLagCompensation()
	{
		if (!mRewound)
			return;
		for (let entry in mRewoundStates)
		{
			if (!entry.identity.GameObject.IsDestroyed)
				entry.identity.ApplyState(entry.state);
		}
		mRewoundStates.Clear();
		mRewound = false;
	}

	/// What a snapshot says about a body this machine predicts.
	struct ServerBody
	{
		public NetworkIdentity identity;
		public BodyState state;
		public bool asleep;
	}

	/// Client, every tick: puts everything this machine does not control where the server had it a moment ago.
	/// Bodies this machine predicts are left to its own physics.
	void ApplyRemoteStates() => ApplyRemoteStates(mTick, true);

	/// Puts everything shown in the past where it was at one of this machine's ticks (a replayed one, or now).
	void ApplyRemoteStates(uint32 tick, bool now)
	{
		if (!mClockSet)
			return;
		let delay = InterpolationTicks > 0 ? InterpolationTicks : mServerInterval * 2;
		let at = (double)tick + mServerOffset - delay;
		if (now)
			mViewTick = at;
		for (let identity in mIdentities)
		{
			if (identity.ownerId == LocalClientId || identity.Predicted || !identity.HasKeys)
				continue;
			BodyState state;
			if (!identity.Sample(at, mServerInterval, out state))
				continue;
			if (now && at > (double)identity.NewestKeyTick && state.linearVelocity != .Zero)
				mStatHeld++;
			// Something lying still needs nothing done; leaving it alone also lets a physics body go to sleep.
			let transform = identity.Transform;
			if ((transform.Position - state.position).LengthSquared < 1.0e-8f && Mathf.Abs(Quaternion.Dot(transform.Rotation, state.rotation)) > 0.999999f)
				continue;
			identity.ApplyState(state);
		}
	}

	/// Client: checks what the server says about this machine's own objects, and the bodies it predicts, against
	/// what was predicted for the same tick, and if they differ, goes back to the server's state and runs the ticks
	/// since again.
	void Reconcile(uint32 ackTick, List<(NetworkIdentity identity, BodyState state)> owned, List<ServerBody> bodies)
	{
		// A body heard of for the first time is taken up; until it has a history there is nothing to compare.
		bool adopted = false;
		for (let body in bodies)
		{
			if (!body.identity.Predicted)
			{
				body.identity.Predicted = true;
				body.identity.PredictedSince = ackTick + 1;
				body.identity.ClearKeys();
				adopted = true;
			}
		}
		if (adopted)
			CountPredictedBodies();

		// Remember where things were drawn so that a correction can be eased in visually.
		List<(NetworkIdentity identity, Vector3 drawn)> before = scope .();
		for (let entry in owned)
			before.Add((entry.identity, entry.identity.Transform.Position + entry.identity.SmoothOffset));
		if (bodies.Count > 0)
		{
			for (let identity in mIdentities)
			{
				if (identity.Predicted)
					before.Add((identity, identity.Transform.Position + identity.SmoothOffset));
			}
		}
		defer
		{
			for (let entry in before)
			{
				if (!entry.identity.GameObject.IsDestroyed)
					entry.identity.SmoothOffset = entry.drawn - entry.identity.Transform.Position;
			}
		}

		if (ackTick > mTick)
		{
			JumpToServer(ackTick, owned, bodies);
			return;
		}

		// Until the server has consumed one of our inputs there is nothing to compare against: adopt its state.
		let comparable = ackTick > 0 && mTick - ackTick < NetworkIdentity.HistorySize;
		float worst = 0;
		if (comparable)
		{
			worst = PredictionError(ackTick, owned);
			mStatOwnWorst = Math.Max(mStatOwnWorst, worst);
			PendingInputs = (int32)(mTick - ackTick);
			let bodyWorst = BodyPredictionError(ackTick, bodies);
			mStatBodyWorst = Math.Max(mStatBodyWorst, Math.Min(bodyWorst, 1000));
			if (worst <= CorrectionThreshold && bodyWorst <= CorrectionThreshold)
			{
				// Nothing moved: leave any easing already under way alone.
				before.Clear();
				SettleResting(bodies);
				return;
			}
			if (worst <= CorrectionThreshold)
				PhysicsRollbacks++;
			worst = Math.Max(worst, bodyWorst);
		}

		LastCorrection = worst;
		Rollbacks++;
		mStatRollbacks++;
		if (!comparable)
		{
			for (let entry in owned)
				entry.identity.ApplyState(entry.state);
			for (let body in bodies)
			{
				body.identity.ApplyBodyState(body.state, body.asleep);
				body.identity.PredictedSince = mTick + 1;
			}
			return;
		}
		RewindTo(ackTick, owned, bodies);
		mStatReplayed += (int32)(mTick - ackTick);
		ReplayInputs(ackTick, owned);
	}

	/// Client: puts everything this machine predicts back as it was at the end of a tick: the server's word where
	/// there is one, and otherwise what this machine had then.
	void RewindTo(uint32 tick, List<(NetworkIdentity identity, BodyState state)> owned, List<ServerBody> bodies)
	{
		let slot = tick % NetworkIdentity.HistorySize;
		// For a predicted body this is the start of the replay, not a correction to show: the replay brings it
		// back to now, and SmoothOffset eases out what is left.
		Replaying = true;
		for (let identity in mIdentities)
		{
			if (identity.Predicted && (int32)(tick - identity.PredictedSince) >= 0)
				identity.ApplyBodyState(identity.History[slot], identity.HistoryAsleep[slot]);
		}
		for (let body in bodies)
		{
			body.identity.ApplyBodyState(body.state, body.asleep);
			body.identity.History[slot] = body.state;
			body.identity.HistoryAsleep[slot] = body.asleep;
			if ((int32)(tick - body.identity.PredictedSince) < 0)
				body.identity.PredictedSince = tick;
		}
		Replaying = false;
		for (let entry in owned)
		{
			entry.identity.ApplyState(entry.state);
			entry.identity.History[slot] = entry.state;
		}
	}

	/// The server has got ahead of this machine, which must have stopped for a moment. Takes its state and jumps the
	/// clock forward to where it should be, rather than limp along behind.
	void JumpToServer(uint32 ackTick, List<(NetworkIdentity identity, BodyState state)> owned, List<ServerBody> bodies)
	{
		let lead = (uint32)Math.Clamp(PendingInputs, 1, 30);
		let last = mInputs[mTick % InputHistory];
		for (let entry in owned)
		{
			entry.identity.ApplyState(entry.state);
			for (int i < NetworkIdentity.HistorySize)
				entry.identity.History[i] = entry.state;
		}
		uint32 target = ackTick + lead;
		for (let body in bodies)
		{
			body.identity.ApplyBodyState(body.state, body.asleep);
			body.identity.PredictedSince = target;
		}
		uint32 first = target >= (uint32)InputHistory ? target - (uint32)InputHistory + 1 : 1;
		for (uint32 tick = Math.Max(mTick + 1, first); tick <= target; tick++)
			mInputs[tick % InputHistory] = last;
		mServerOffset -= (double)(target - mTick);
		mTick = target;
		for (let identity in mIdentities)
		{
			if (identity.Predicted)
				identity.RecordTick(target);
		}
		Rollbacks++;
		mStatRollbacks++;
	}

	/// How far the prediction for a tick was from what the server says: the largest of the position error, the
	/// rotation error and a changed prediction state, over every owned object.
	float PredictionError(uint32 ackTick, List<(NetworkIdentity identity, BodyState state)> owned)
	{
		float worst = 0;
		for (let entry in owned)
		{
			let predicted = entry.identity.History[ackTick % NetworkIdentity.HistorySize];
			if (predicted.prediction0.w != entry.state.prediction0.w)
				worst = Math.Max(worst, 1);
			worst = Math.Max(worst, (predicted.position - entry.state.position).Length);
			worst = Math.Max(worst, (1.0f - Mathf.Abs(Quaternion.Dot(predicted.rotation, entry.state.rotation))) * 2.0f);
		}
		return worst;
	}

	/// The same for predicted bodies, counting a difference in speed as the distance it opens up by the next
	/// snapshot, so that a knock is put right before it shows. A body with no history yet always differs.
	///
	/// A body wrong in MissesBeforePause snapshots running is being moved by something this machine cannot know
	/// about (another player leaning on it, a script on the server carrying it). Running it again every snapshot
	/// would only jitter, so it is shown in the past, with whatever moves it, for PauseTicks, then tried again.
	float BodyPredictionError(uint32 ackTick, List<ServerBody> bodies)
	{
		const int32 MissesBeforePause = 3;
		const uint32 PauseTicks = 120;
		float worst = 0;
		for (let body in bodies)
		{
			if ((int32)(ackTick - body.identity.PredictedSince) < 0)
			{
				worst = float.MaxValue;
				continue;
			}
			let predicted = body.identity.History[ackTick % NetworkIdentity.HistorySize];
			let ahead = Time.FixedDeltaTime * Math.Max(mServerInterval, 1);
			var error = (predicted.position - body.state.position).Length;
			error = Math.Max(error, (1.0f - Mathf.Abs(Quaternion.Dot(predicted.rotation, body.state.rotation))) * 2.0f);
			error = Math.Max(error, (predicted.linearVelocity - body.state.linearVelocity).Length * ahead);
			worst = Math.Max(worst, error);
			if (error <= CorrectionThreshold)
				body.identity.Misses = 0;
			else if (++body.identity.Misses >= MissesBeforePause)
			{
				body.identity.Misses = 0;
				body.identity.Predicted = false;
				body.identity.PredictPausedUntil = mTick + PauseTicks;
				body.identity.ClearKeys();
				body.identity.PushBodyKey(mLastSnapshotTick, body.state, body.asleep);
			}
		}
		return worst;
	}

	/// A body resting here and on the server, a little apart, is put where the server has it: it is not moving, so
	/// there is nothing to run again, and the difference would otherwise last until something knocks it.
	void SettleResting(List<ServerBody> bodies)
	{
		for (let body in bodies)
		{
			let rigidbody = body.identity.GetComponent<Rigidbody>();
			if (!body.asleep || !rigidbody.IsSleeping)
				continue;
			let transform = body.identity.Transform;
			if ((transform.Position - body.state.position).LengthSquared < 1.0e-10f && Mathf.Abs(Quaternion.Dot(transform.Rotation, body.state.rotation)) > 0.9999999f)
				continue;
			let drawn = transform.Position + body.identity.SmoothOffset;
			body.identity.ApplyBodyState(body.state, true);
			body.identity.SmoothOffset = drawn - transform.Position;
			for (int i < NetworkIdentity.HistorySize)
			{
				body.identity.History[i] = body.state;
				body.identity.HistoryAsleep[i] = true;
			}
		}
	}

	void CountPredictedBodies()
	{
		PredictedBodies = 0;
		for (let identity in mIdentities)
		{
			if (identity.Predicted)
				PredictedBodies++;
		}
	}

	/// Replays every input the server has not acknowledged yet on top of the corrected state.
	void ReplayInputs(uint32 ackTick, List<(NetworkIdentity identity, BodyState state)> owned)
	{
		// Objects moved by the physics engine need it stepped as well. That moves every other body too, so those
		// this machine does not predict are put back afterwards: where they are is the server's business.
		List<(NetworkIdentity identity, BodyState state)> others = scope .();
		bool stepPhysics = PredictedBodies > 0 || AnyHasBody(owned);
		if (stepPhysics)
			CaptureOtherBodies(others);

		Replaying = true;
		mReplayOwned = owned;
		mReplayOthers = others;
		mReplayStepPhysics = stepPhysics;
		defer
		{
			Replaying = false;
			mReplayOwned = null;
			mReplayOthers = null;
		}
		// Each tick goes through the scene's ReplayPipeline (the Replay.* steps below, and any a game adds).
		for (uint32 tick = ackTick + 1; tick <= mTick; tick++)
		{
			mReplayTick = tick;
			mScene.RunReplayTick();
		}
		for (let entry in others)
			entry.identity.ApplyState(entry.state);
	}

	// The tick being replayed and what ReplayInputs gathered, for the Replay.* steps.
	uint32 mReplayTick;
	List<(NetworkIdentity identity, BodyState state)> mReplayOwned;
	List<(NetworkIdentity identity, BodyState state)> mReplayOthers;
	bool mReplayStepPhysics;

	/// Replay.RemoteStates: what is shown in the past is put where it was shown that tick, for predicted bodies to
	/// run into.
	void ReplayRemoteStates()
	{
		if (Replaying && PredictedBodies > 0)
			ApplyRemoteStates(mReplayTick, false);
	}

	/// Replay.Update: the networked Update (and Simulate) of what this machine controls, with that tick's controls.
	void ReplayUpdate()
	{
		if (!Replaying)
			return;
		SimulateOwned(LocalClientId, mInputs[mReplayTick % InputHistory]);
		// A replayed contact can hand a transform motor to a body during this tick.
		if (!mReplayStepPhysics && AnyHasBody(mReplayOwned))
		{
			mReplayStepPhysics = true;
			CaptureOtherBodies(mReplayOthers);
		}
	}

	/// Replay.Physics: objects moved by the physics engine need it stepped as well (bodies nobody here predicts are
	/// put back after the replay).
	void ReplayPhysics()
	{
		if (!Replaying || !mReplayStepPhysics)
			return;
		Water.[Friend]SimulateAt(mScene, Time.FixedDeltaTime, mReplayTick / (double)Time.TickRate);
		mScene.Physics.Step(Time.FixedDeltaTime);
	}

	/// Replay.Record: where what this machine moves ended the tick, for the next comparison with the server.
	void ReplayRecord()
	{
		if (!Replaying)
			return;
		for (let entry in mReplayOwned)
			entry.identity.History[mReplayTick % NetworkIdentity.HistorySize] = entry.identity.CaptureState();
		for (let identity in mIdentityStates)
		{
			if (identity.Predicted && (int32)(mReplayTick - identity.PredictedSince) >= 0)
				identity.RecordTick(mReplayTick);
		}
	}

	static bool AnyHasBody(List<(NetworkIdentity identity, BodyState state)> owned)
	{
		for (let entry in owned)
		{
			if (entry.identity.GetComponent<Rigidbody>().HasBody)
				return true;
		}
		return false;
	}

	/// The state of every physics body this machine neither owns nor predicts, to put back after a replay.
	void CaptureOtherBodies(List<(NetworkIdentity identity, BodyState state)> others)
	{
		for (let identity in mIdentities)
		{
			if (identity.ownerId != LocalClientId && !identity.Predicted && identity.GetComponent<Rigidbody>().HasBody)
				others.Add((identity, identity.CaptureState()));
		}
	}
}
