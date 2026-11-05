using System;
using System.Collections;

namespace Tallow;

[Reflect(.All)]
enum RemoteSnapshotFormat : int32
{
	Legacy, ExactTransform, QuantizedTransform,
	/// A physics body shown in the past, with how it is moving: a finely packed position and rotation plus both
	/// velocities, about a third of the size of a full record. For many small bodies clients only watch.
	QuantizedBody }

/// Whether clients simulate a physics body themselves rather than showing it a moment in the past.
[Reflect(.All)]
enum PhysicsPrediction : int32
{
	/// Predicted if it is a server-owned dynamic Rigidbody with no Network Behaviour on it (a script that moves it
	/// on the server alone would make every prediction wrong).
	Auto,
	/// Predicted whenever it is a server-owned dynamic Rigidbody.
	On,
	/// Never predicted: shown a moment in the past, as other players are.
	Off
}

/// Marks an object as replicated. The server owns its state; clients predict it locally and are corrected.
[Component]
class NetworkIdentity : Component
{
	public const int HistorySize = 128;
	/// Send exact transform/body snapshots for small or precision-sensitive objects.
	public bool fullPrecision;
	BodyState mSentFull;
	bool mSentAsleep;
	/// Remote snapshot format only; the owning client's prediction always receives exact BodyState.
	public RemoteSnapshotFormat remoteFormat = .Legacy;
	/// Minimum server ticks between remote updates; zero uses the session snapshot interval.
	public int32 remoteIntervalTicks;
	/// Suppress periodic sleeping refreshes after a reliable final transform. Off by default.
	public bool dormantWhenSleeping;
	/// Distance filtering applies only to objects opting in. Zero session radius disables it.
	public bool distanceFiltered;
	/// Higher values are serviced first when a session has a bandwidth budget.
	public int32 snapshotPriority;
	public bool SnapshotSleeping => dormantWhenSleeping && GetComponent<Rigidbody>().IsSleeping;
	/// Whether clients simulate this body themselves while the server owns it (NetworkManager.PredictPhysics).
	public PhysicsPrediction physicsPrediction = .Auto;


	/// Whether a player controls this object: its scripts' Update gets that player's controls. Off for things the
	/// server runs by itself (NPCs, projectiles), whose Update gets empty controls even on a host. Objects the
	/// server spawns with NetworkManager.Adopt are switched off; player characters are on.
	public bool playerControlled = true;

	/// The controls of the last tick run, for TickInput.previous.
	[NonSerialized]
	public NetInput LastInput;

	public override void OnRegister()
	{
		GameObject.[Friend]mNetworked = true;
	}

	public override void OnUnregister()
	{
		// Another identity on the same object keeps it networked.
		var others = false;
		for (let component in GameObject.Components)
			others |= component != this && component is NetworkIdentity && component.[Friend]mRegistered;
		GameObject.[Friend]mNetworked = others;
	}

	/// This machine's controls for the object: from its Network Behaviours (GatherInput), or the project's input
	/// actions when it has none. Empty when no player controls it.
	public NetInput GatherControls()
	{
		NetInput input = default;
		if (!playerControlled)
			return input;
		if (!GatherFromBehaviours(ref input))
			LocalControls.Read(ref input);
		return input;
	}

	/// Calls GatherInput on the object's Network Behaviours; false if it has none.
	public bool GatherFromBehaviours(ref NetInput input)
	{
		bool any = false;
		for (let component in GameObject.Components)
		{
			if (let behaviour = component as NetworkBehaviour)
			{
				behaviour.GatherInput(ref input);
				any = true;
			}
		}
		return any;
	}

	/// Runs one tick of Update on every running component of this object (Component.Update).
	public void TickUpdate(NetInput input, float deltaTime)
	{
		TickInput tick;
		tick.raw = (playerControlled || ownerId != 0) ? input : default;
		tick.previous = LastInput;
		LastInput = tick.raw;
		let scene = GameObject.Scene;
		let components = GameObject.Components;
		for (int i = 0; i < components.Count; i++)
		{
			let component = components[i];
			if (component.[Friend]mCallbacks.HasFlag(.Update) && component.[Friend]mStarted && component.IsActiveAndEnabled)
				scene.[Friend]RunUpdate(component, tick, deltaTime);
		}
	}

	/// 0 means owned by the server; otherwise the id of the controlling client.
	[HideInInspector]
	public int32 ownerId = 0;

	/// The player's team in a session with teams (1 upward), set by the server when the player is spawned and
	/// shared with everyone. 0 when there are no teams.
	[Sync]
	public int32 team;

	[NonSerialized]
	public uint32 NetId;
	// Objects below this one made before this id were part of it when it joined the session (its prefab), so every
	// machine has them; ones a machine adds later are its own (NetworkSync's switches and lights).
	uint32 mPartsIdLimit;
	[NonSerialized]
	public BodyState[HistorySize] History;
	[NonSerialized]
	public String PrefabName = new .() ~ delete _;

	// ---- physics prediction ----

	/// Server: whether the last snapshot sent this body for clients to predict.
	[NonSerialized]
	public bool PhysicsPredictable;
	/// Client: whether this machine is simulating this body itself, ahead of the server, as it does its own player.
	[NonSerialized]
	public bool Predicted;
	/// Client: the first tick History holds for a predicted body.
	[NonSerialized]
	public uint32 PredictedSince;
	/// Client: whether a predicted body was resting at the end of each tick in History.
	[NonSerialized]
	public bool[HistorySize] HistoryAsleep;
	/// Client: what the server last said about a predicted body, at which of its ticks, and whether it was resting.
	[NonSerialized]
	public BodyState ServerState;
	[NonSerialized]
	public uint32 ServerStateTick;
	[NonSerialized]
	public bool ServerAsleep;
	/// Client: how many snapshots running have corrected this body, and the tick until which it is shown in the
	/// past instead because of that.
	[NonSerialized]
	public int32 Misses;
	[NonSerialized]
	public uint32 PredictPausedUntil;

	/// Server: whether clients can simulate this object (see physicsPrediction).
	public bool CanPredictPhysics
	{
		get
		{
			if (physicsPrediction == .Off || ownerId != 0)
				return false;
			let body = GetComponent<Rigidbody>();
			if (!body.IsValid || body.isKinematic || !body.HasBody)
				return false;
			if (physicsPrediction == .On)
				return true;
			for (let component in GameObject.Components)
			{
				if (component is NetworkBehaviour)
					return false;
			}
			return true;
		}
	}

	/// Client: notes the body's state at the end of a tick, for going back to it.
	public void RecordTick(uint32 tick)
	{
		History[tick % HistorySize] = CaptureState();
		HistoryAsleep[tick % HistorySize] = GetComponent<Rigidbody>().IsSleeping;
	}

	/// Client: puts a predicted body back in a state, resting if it was.
	public void ApplyBodyState(BodyState state, bool asleep)
	{
		ApplyState(state);
		if (asleep)
			GetComponent<Rigidbody>().Sleep();
	}

	public bool IsOwner => Scene.Network != null && ownerId == Scene.Network.LocalClientId;

	/// Remaining visual error after a server correction; it is blended out instead of popping.
	[NonSerialized]
	public Vector3 SmoothOffset;
	/// How quickly corrections are blended out (per second).
	public float correctionSmoothing = 12.0f;

	// Where the object was at the end of the last two ticks, for drawing it between them.
	Vector3 mTickPrevious, mTickCurrent;
	bool mTickSmoothing;
	Vector3 mVisualOffset;

	/// Where the object is drawn this frame: its position with corrections from the server eased in, and, for an
	/// object another machine controls, moved smoothly from one tick to the next. Mesh Renderers on the object use
	/// this by themselves; a camera or anything else that follows a networked object should use it too.
	public Vector3 VisualPosition => Transform.Position + mVisualOffset;

	/// Called by the network session at the end of every tick.
	public void NoteTick(bool smoothBetweenTicks)
	{
		let position = Transform.Position;
		mTickPrevious = mTickSmoothing ? mTickCurrent : position;
		mTickCurrent = position;
		mTickSmoothing = smoothBetweenTicks;
	}

	public override void OnFrame()
	{
		// Large errors (teleports, respawns) are not worth easing.
		if (SmoothOffset.LengthSquared < 1.0e-8f || SmoothOffset.LengthSquared > 25.0f)
			SmoothOffset = .Zero;
		else
			SmoothOffset = SmoothOffset * Math.Exp(-correctionSmoothing * Time.DeltaTime);
		var offset = SmoothOffset;
		if (mTickSmoothing)
		{
			// Only while it is still where the tick left it: something that has moved it since knows better.
			let position = Transform.Position;
			if ((position - mTickCurrent).LengthSquared < 1.0e-10f && (mTickCurrent - mTickPrevious).LengthSquared < 25.0f)
				offset += Vector3.Lerp(mTickPrevious, mTickCurrent, Mathf.Clamp01(Time.InterpolationAlpha)) - position;
		}
		if ((offset - mVisualOffset).LengthSquared > 0)
		{
			mVisualOffset = offset;
			ApplyVisualOffset(GameObject);
		}
	}

	void ApplyVisualOffset(GameObject gameObject)
	{
		if (gameObject.HasComponent<MeshRenderer>())
			gameObject.GetComponent<MeshRenderer>().VisualOffset = mVisualOffset;
		for (let child in gameObject.Transform.Children)
			ApplyVisualOffset(child.GameObject);
	}

	// ---- server: what the last snapshot said, so that only what changes is sent ----

	[NonSerialized]
	public NetPack.Packed Sent;
	/// The number of the snapshot in which this object last differed from the one before.
	[NonSerialized]
	public uint32 ChangedAt;
	bool mSentOnce;

	/// Server, once per snapshot: packs where the object is now and notes whether that is news.
	public void NoteSnapshot(uint32 number, bool includeFullState = false, bool predictPhysics = false)
	{
		let now = NetPack.Pack(Transform.Position, Transform.Rotation);
		let predictable = predictPhysics && CanPredictPhysics;
		// A predicted body is checked exactly: a client that knows it has not changed can compare against it.
		if (predictable != PhysicsPredictable)
		{
			PhysicsPredictable = predictable;
			mSentOnce = false;
		}
		if (fullPrecision || predictable)
		{
			let exact = CaptureState();
			let asleep = predictable && GetComponent<Rigidbody>().IsSleeping;
			if (mSentOnce && asleep == mSentAsleep && (!(includeFullState || predictable) || (exact.linearVelocity - mSentFull.linearVelocity).LengthSquared < 1.0e-12f && (exact.angularVelocity - mSentFull.angularVelocity).LengthSquared < 1.0e-12f && exact.prediction0 == mSentFull.prediction0 && exact.prediction1 == mSentFull.prediction1) && (exact.position - mSentFull.position).LengthSquared < 1.0e-12f && Math.Abs(Quaternion.Dot(exact.rotation, mSentFull.rotation)) > 0.9999999f && exact.prediction0.w == mSentFull.prediction0.w) return;
			mSentFull = exact;
			mSentAsleep = asleep;
		}
		else if (mSentOnce && now.Same(Sent))
			return;
		mSentOnce = true;
		Sent = now;
		ChangedAt = number;
	}

	// ---- client: an object some other machine controls is drawn a moment in the past, between two things the
	// server has said about it, so that it moves evenly however unevenly the news arrives ----

	struct Key
	{
		public uint32 tick;
		public Vector3 position;
		public Quaternion rotation;
		public Vector3 linearVelocity, angularVelocity;
		public bool hasVelocity;
		public bool stationary;
	}

	// Enough for the server to look back half a second, which is what lag compensation uses them for there.
	const int MaxKeys = 32;
	Key[MaxKeys] mKeys;
	int32 mKeyCount;

	public bool HasKeys => mKeyCount > 0;
	public uint32 NewestKeyTick => mKeyCount > 0 ? mKeys[mKeyCount - 1].tick : 0;
	public void ClearKeys()
	{
		mKeyCount = 0;
	}

	/// Adds what the server said the object was doing at one of its ticks. Old news is ignored.
	public void PushKey(uint32 tick, Vector3 position, Quaternion rotation, bool stationary = false)
	{
		if (mKeyCount > 0 && (int32)(tick - mKeys[mKeyCount - 1].tick) <= 0)
			return;
		if (mKeyCount == MaxKeys)
		{
			for (int i = 1; i < MaxKeys; i++)
				mKeys[i - 1] = mKeys[i];
			mKeyCount--;
		}
		mKeys[mKeyCount++] = .() { tick = tick, position = position, rotation = rotation, stationary = stationary };
	}

	/// Says again, at a later tick, what the newest key said: the server sends nothing while an object is still.
	public void HoldKey(uint32 tick)
	{
		if (mKeyCount > 0)
			PushKey(tick, mKeys[mKeyCount - 1].position, mKeys[mKeyCount - 1].rotation);
	}

	/// Preserve authoritative rigidbody velocities instead of estimating them across an impact.
	public void PushBodyKey(uint32 tick, BodyState state, bool stationary = false)
	{
		if (mKeyCount > 0 && (int32)(tick - mKeys[mKeyCount - 1].tick) <= 0) return;
		PushKey(tick, state.position, state.rotation, stationary);
		mKeys[mKeyCount - 1].linearVelocity = stationary ? .Zero : state.linearVelocity;
		mKeys[mKeyCount - 1].angularVelocity = stationary ? .Zero : state.angularVelocity;
		mKeys[mKeyCount - 1].hasVelocity = true;
	}

	/// Where the object was at a (fractional) server tick. Past the newest key it carries on as it was going for
	/// at most maxAhead ticks, then waits. False if the server has said nothing about it yet.
	public bool Sample(double tick, float maxAhead, out BodyState state)
	{
		state = default;
		if (mKeyCount == 0)
			return false;
		let newest = mKeys[mKeyCount - 1];
		state.position = newest.position;
		state.rotation = newest.rotation;
		if (newest.hasVelocity)
		{
			state.linearVelocity = newest.linearVelocity;
			state.angularVelocity = newest.angularVelocity;
		}
		if (mKeyCount == 1 || newest.stationary && tick >= newest.tick)
			return true;
		if (tick >= (double)newest.tick)
		{
			let before = mKeys[mKeyCount - 2];
			let span = (float)(newest.tick - before.tick);
			// Carry on only from two keys close together in time and place: not across a pause or a respawn.
			if (span <= maxAhead * 2 && (newest.position - before.position).LengthSquared < 25.0f)
			{
				state.linearVelocity = newest.hasVelocity ? newest.linearVelocity : (newest.position - before.position) / (span * Time.FixedDeltaTime);
				let ahead = Math.Min((float)(tick - (double)newest.tick), maxAhead);
				state.position = newest.position + state.linearVelocity * (ahead * Time.FixedDeltaTime);
				let angularSpeed = state.angularVelocity.Length;
				if (newest.hasVelocity && angularSpeed > 0.000001f)
				{
					let halfAngle = angularSpeed * ahead * Time.FixedDeltaTime * 0.5f;
					let axis = state.angularVelocity / angularSpeed;
					let sine = Math.Sin(halfAngle);
					state.rotation = Quaternion(axis.x * sine, axis.y * sine, axis.z * sine, Math.Cos(halfAngle)) * newest.rotation;
				}
			}
			return true;
		}
		for (int i = mKeyCount - 1; i > 0; i--)
		{
			let from = mKeys[i - 1];
			if (tick < (double)from.tick && i > 1)
				continue;
			let to = mKeys[i];
			let span = (float)(to.tick - from.tick);
			let amount = Mathf.Clamp01((float)(tick - (double)from.tick) / span);
			if ((to.position - from.position).LengthSquared >= 25.0f)
			{
				// A respawn or a teleport: be in one place and then the other, never in between.
				state.position = from.position;
				state.rotation = from.rotation;
				return true;
			}
			state.position = Vector3.Lerp(from.position, to.position, amount);
			state.rotation = Quaternion.Slerp(from.rotation, to.rotation, amount);
			state.linearVelocity = from.hasVelocity && to.hasVelocity ? Vector3.Lerp(from.linearVelocity, to.linearVelocity, amount) : (to.position - from.position) / (span * Time.FixedDeltaTime);
			if (from.hasVelocity && to.hasVelocity)
				state.angularVelocity = Vector3.Lerp(from.angularVelocity, to.angularVelocity, amount);
			return true;
		}
		return true;
	}

	public override void OnEnable()
	{
		if (NetId == 0)
			NetId = GameObject.Id;
		Scene.Network?.[Friend]Register(this);
	}

	public override void OnDisable()
	{
		NetworkSync.Forget(this);
		Scene.Network?.[Friend]Unregister(this);
	}

	public BodyState CaptureState()
	{
		let body = GetComponent<Rigidbody>();
		if (body.IsValid && body.HasBody)
		{
			var bodyState = body.State;
			for (let component in GameObject.Components)
			{
				if (let behaviour = component as NetworkBehaviour)
					behaviour.CaptureBodyPredictionState(ref bodyState);
			}
			return bodyState;
		}
		BodyState state = default;
		state.position = Transform.Position;
		state.rotation = Transform.Rotation;
		// A character controller has no body, but its velocity (falling speed above all) must survive a rewind.
		let controller = GetComponent<CharacterController>();
		if (controller.IsValid)
		{
			state.linearVelocity = controller.Velocity;
			// A character does not spin, so the unused slot carries how long it has been airborne (for the jump grace).
			state.angularVelocity = .(Math.Min(controller.AirTime, 1000), 0, 0);
		}
		for (let component in GameObject.Components)
		{
			if (let behaviour = component as NetworkBehaviour)
				behaviour.CapturePredictionState(ref state);
		}
		return state;
	}

	public void ApplyState(BodyState state)
	{
		// A hybrid motor may need to create/disable its body before this state's velocities are applied.
		for (let component in GameObject.Components)
		{
			if (let behaviour = component as NetworkBehaviour)
				behaviour.PreparePredictionState(state);
		}
		let body = GetComponent<Rigidbody>();
		if (body.IsValid && body.HasBody)
			body.SetState(state);
		else
		{
			Transform.SetPositionAndRotation(state.position, state.rotation);
			GetComponent<CharacterController>().Teleport(state.position, state.linearVelocity, state.angularVelocity.x);
		}
		for (let component in GameObject.Components)
		{
			if (let behaviour = component as NetworkBehaviour)
				behaviour.RestorePredictionState(state);
		}
	}
}

/// Base class for networked gameplay scripts.
///
/// Put movement in Simulate: it runs on the server for every client input, and on the owning
/// client immediately (prediction) and again when the server corrects it (replay). It must
/// depend only on the input, the delta time and simulation state.
[Component]
abstract class NetworkBehaviour : Component
{
	public NetworkIdentity Identity => GetComponent<NetworkIdentity>();
	public bool IsServer => Scene.Network == null || Scene.Network.IsServer;
	public bool IsOwner
	{
		get
		{
			let identity = Identity;
			return identity != null && identity.IsOwner;
		}
	}

	/// Server, inside Simulate or Update: until EndLagCompensation, every other networked object is where this
	/// object's player was seeing it when they gave the controls being run. Wrap the ray cast for a shot or a
	/// swing in the pair, so that it is judged against what the player aimed at; deal the damage after ending.
	/// Returns false and does nothing where it does not apply (no session, a client, the host's own player).
	public bool BeginLagCompensation() => Scene.Network != null && Scene.Network.BeginLagCompensation(Identity);
	public void EndLagCompensation() => Scene.Network?.EndLagCompensation();

	/// Custom transform-based motors can store rewindable simulation state in the unused velocity slots.
	/// Do not override slots owned by a Rigidbody or CharacterController on the same object.
	public virtual void CapturePredictionState(ref BodyState state) { }
	/// Extra motor metadata alongside an active body's actual velocities.
	public virtual void CaptureBodyPredictionState(ref BodyState state) { }
	/// Restore a motor/body mode before the transform and velocities are applied.
	public virtual void PreparePredictionState(BodyState state) { }
	public virtual void RestorePredictionState(BodyState state) { }

	/// Called once per tick on the owning client to sample the local controls.
	public virtual void GatherInput(ref NetInput input) { }
	/// Advance this object by one tick using the given input.
	public virtual void Simulate(NetInput input, float deltaTime) { }
}
