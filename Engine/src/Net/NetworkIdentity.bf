using System;
using System.Collections;

namespace Tallow;

[Reflect(.All)]
enum RemoteSnapshotFormat : int32
{
	/// The packed transform (2 mm steps, two bytes of turn while upright): the smallest record for most things, and
	/// what Automatic uses for players and moving objects.
	Legacy,
	/// Exact floats.
	ExactTransform,
	/// Finer steps (0.1 mm) and a full rotation.
	QuantizedTransform,
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

/// What the engine takes an object to be when it chooses how to share it (NetworkIdentity.automatic), shown in the
/// network panel.
[Reflect(.All)]
enum NetworkObjectKind : int32
{
	/// A player's character: packed transforms to everyone else (2 mm steps, two bytes of turn while upright), sent
	/// first.
	Player,
	/// A dynamic Rigidbody nobody controls: QuantizedBody, quiet while it sleeps, near players only (when the
	/// session has a relevance radius).
	Body,
	/// Anything else that moves (doors, platforms, NPCs): packed transforms, near players only. One that never
	/// moves costs nothing after it is spawned, as an unchanged object is not sent.
	Moving,
	/// Automatic is off: the settings are used as they are.
	AsSet
}

/// A NetworkIdentity's settings, in its entity (NetworkIdentity is the handle).
[Component, HandleData]
struct NetworkIdentityData
{
	/// On: the engine chooses the format, dormancy, relevance and priority below from what is on the object (a
	/// player, a physics body, something else that moves), for each one still at its default; one set by hand is
	/// kept. The network panel shows what it chose and why. Off: the settings below are used exactly as they are.
	[Advanced]
	public bool automatic = true;
	/// Send exact transform/body snapshots for small or precision-sensitive objects.
	[Advanced]
	public bool fullPrecision = default;
	/// Remote snapshot format only; the owning client's prediction always receives exact BodyState.
	[Advanced]
	public RemoteSnapshotFormat remoteFormat = .Legacy;
	/// Minimum server ticks between remote updates; zero uses the session snapshot interval.
	[Advanced]
	public int32 remoteIntervalTicks = default;
	/// Suppress periodic sleeping refreshes after a reliable final transform. Off by default.
	[Advanced]
	public bool dormantWhenSleeping = default;
	/// Distance filtering applies only to objects opting in. Zero session radius disables it.
	[Advanced]
	public bool distanceFiltered = default;
	/// Higher values are serviced first when a session has a bandwidth budget.
	[Advanced]
	public int32 snapshotPriority = default;
	/// Whether clients simulate this body themselves while the server owns it (NetworkManager.PredictPhysics).
	[Advanced]
	public PhysicsPrediction physicsPrediction = .Auto;
	/// Whether a player controls this object: its scripts' Update gets that player's controls. Off for things the
	/// server runs by itself (NPCs, projectiles), whose Update gets empty controls even on a host. Objects the
	/// server spawns with NetworkManager.Adopt are switched off; player characters are on.
	public bool playerControlled = true;
	/// 0 means owned by the server; otherwise the id of the controlling client.
	[HideInInspector]
	public int32 ownerId = 0;
	/// The player's team in a session with teams (1 upward), set by the server when the player is spawned and
	/// shared with everyone. 0 when there are no teams.
	[Sync]
	public int32 team = default;
	/// How quickly corrections are blended out (per second).
	[Advanced]
	public float correctionSmoothing = 12.0f;

	public this() { }
}

/// Marks an object as replicated. The server owns its state; clients predict it locally and are corrected.
///
/// A handle (ComponentHandle): its settings are NetworkIdentityData's fields, what it keeps between frames its NetworkIdentityState.
/// OnAdded does what OnRegister and OnEnable did, FrameAll (in Scene.RunOnFrames) OnFrame and switching on and off,
/// OnRemove OnDisable and OnUnregister. NetworkManager and NetworkSync hold the state (NetworkIdentityState).
[Component, HandleFields]
struct NetworkIdentity : ComponentHandle<NetworkIdentityData>
{
	/// What it keeps between frames, made the first time it is asked for.
	public NetworkIdentityState Runtime
	{
		get
		{
			CheckValid();
			let state = ComponentState<NetworkIdentityState>.Make(mGameObject.Scene.World, mGameObject.Entity);
			if (state.[Friend]mGameObject == null)
			{
				state.[Friend]mGameObject = mGameObject;
			}
			return state;
		}
	}

	// The API, unchanged: each member is documented on NetworkIdentityState.
	public const int HistorySize = NetworkIdentityState.HistorySize;
	public bool SnapshotSleeping => Runtime.SnapshotSleeping;
	public ref NetInput LastInput => ref Runtime.LastInput;
	public NetInput GatherControls() => Runtime.GatherControls();
	public bool GatherFromBehaviours(ref NetInput input) => Runtime.GatherFromBehaviours(ref input);
	public void TickUpdate(NetInput input, float deltaTime) => Runtime.TickUpdate(input, deltaTime);
	public ref uint32 NetId => ref Runtime.NetId;
	public ref BodyState[HistorySize] History => ref Runtime.History;
	public ref String PrefabName => ref Runtime.PrefabName;
	public ref bool PhysicsPredictable => ref Runtime.PhysicsPredictable;
	public ref bool Predicted => ref Runtime.Predicted;
	public ref uint32 PredictedSince => ref Runtime.PredictedSince;
	public ref bool[HistorySize] HistoryAsleep => ref Runtime.HistoryAsleep;
	public ref BodyState ServerState => ref Runtime.ServerState;
	public ref uint32 ServerStateTick => ref Runtime.ServerStateTick;
	public ref bool ServerAsleep => ref Runtime.ServerAsleep;
	public ref int32 Misses => ref Runtime.Misses;
	public ref uint32 PredictPausedUntil => ref Runtime.PredictPausedUntil;
	public bool CanPredictPhysics => Runtime.CanPredictPhysics;
	public void RecordTick(uint32 tick) => Runtime.RecordTick(tick);
	public void ApplyBodyState(BodyState state, bool asleep) => Runtime.ApplyBodyState(state, asleep);
	public bool IsOwner => Runtime.IsOwner;
	public ref Vector3 SmoothOffset => ref Runtime.SmoothOffset;
	public Vector3 VisualPosition => Runtime.VisualPosition;
	public void NoteTick(bool smoothBetweenTicks) => Runtime.NoteTick(smoothBetweenTicks);
	public ref NetPack.Packed Sent => ref Runtime.Sent;
	public ref uint32 ChangedAt => ref Runtime.ChangedAt;
	public void NoteSnapshot(uint32 number, bool includeFullState = false, bool predictPhysics = false) => Runtime.NoteSnapshot(number, includeFullState, predictPhysics);
	public bool HasKeys => Runtime.HasKeys;
	public uint32 NewestKeyTick => Runtime.NewestKeyTick;
	public void ClearKeys() => Runtime.ClearKeys();
	public void PushKey(uint32 tick, Vector3 position, Quaternion rotation, bool stationary = false) => Runtime.PushKey(tick, position, rotation, stationary);
	public void HoldKey(uint32 tick) => Runtime.HoldKey(tick);
	public void PushBodyKey(uint32 tick, BodyState state, bool stationary = false) => Runtime.PushBodyKey(tick, state, stationary);
	public bool Sample(double tick, float maxAhead, out BodyState state) => Runtime.Sample(tick, maxAhead, out state);
	public BodyState CaptureState() => Runtime.CaptureState();
	public void ApplyState(BodyState state) => Runtime.ApplyState(state);
	/// The per-frame easing (what the class's OnFrame did); the scene runs it, so a script need not.
	public void OnFrame() => Runtime.Frame();

	/// The scene's identities in the order their objects were made (the order the class components had, which
	/// is the order snapshots list them in).
	public static void InSceneOrder(Scene scene, List<NetworkIdentity> into)
	{
		for (let gameObject in scene.Objects)
		{
			if (gameObject.[Friend]mNetworked)
				into.Add(gameObject.GetComponent<NetworkIdentity>());
		}
	}

	/// Once a frame (from Scene.RunOnFrames, where the class's OnFrame ran): eases corrections in.
	public static void FrameAll(Scene scene)
	{
		// Every identity has a state from the moment it is added (OnAdded). One with no correction to ease, not
		// smoothed between ticks and drawn where it is has nothing to do, which is most of them on a server.
		let world = scene.World;
		for (let (entity, state) in ComponentState<NetworkIdentityState>.In(world, .. scope .()))
		{
			if (!state.[Friend]HasFrameWork)
				continue;
			let gameObject = state.GameObject;
			if (gameObject != null && gameObject.ActiveInHierarchy && world.IsEnabled(entity, DataIndex))
				state.Frame();
		}
	}

	/// As soon as one is added: the object's Update runs per tick (what OnRegister did), and while playing it joins
	/// the session at once (what OnEnable did then), so that a spawn goes out the same tick.
	static void OnAdded(GameObject gameObject)
	{
		gameObject.[Friend]mNetworked = true;
		let identity = gameObject.GetComponent<NetworkIdentity>();
		if (gameObject.Scene.IsPlaying && identity.IsActiveAndEnabled)
			identity.Runtime.Enable();
	}

	/// Joins or leaves the session as it is switched on or off while playing (OnEnable, OnDisable).
	static void OnSwitched(GameObject gameObject, bool on)
	{
		let state = gameObject.GetComponent<NetworkIdentity>().Runtime;
		if (on)
			state.Enable();
		else
			state.OnDisable();
	}

	static void OnRemove(void* world, uint64 entity)
	{
		// As OnDisable and OnUnregister did: it leaves the session. Neither touches the object's other components,
		// so this is safe while the whole object goes too.
		if (let state = ComponentState<NetworkIdentityState>.Get((World)Internal.UnsafeCastToObject(world), Entity(entity)))
		{
			state.OnDisable();
			state.[Friend]mGameObject.[Friend]mNetworked = false;
		}
		ComponentState<NetworkIdentityState>.Release(world, entity);
	}
}

/// What a NetworkIdentity keeps between frames. Its settings are read from the entity each time.
[DataFields(typeof(NetworkIdentityData), "Settings")]
class NetworkIdentityState
{
	GameObject mGameObject;
	// In the session's identities (Enable) and not taken out since (OnDisable).
	bool mJoined;

	public GameObject GameObject => mGameObject;
	public Transform Transform => mGameObject.Transform;
	public Scene Scene => mGameObject.Scene;
	public NetworkIdentity Handle => mGameObject.GetComponent<NetworkIdentity>();
	/// The session keeps its identities' states as well as their handles (NetworkManager.IdentityStates), so that
	/// its loops over every object do not look each one's state up again; where a handle is wanted, a state is one.
	public static implicit operator NetworkIdentity(NetworkIdentityState state) => state.Handle;
	public T GetComponent<T>() where T : Component => mGameObject.GetComponent<T>();
	public T GetComponent<T>() where T : struct, IComponentHandle => mGameObject.GetComponent<T>();
	public bool HasComponent<T>() where T : struct, IComponentHandle => mGameObject.HasComponent<T>();
	public bool IsActiveAndEnabled => mGameObject.ActiveInHierarchy && mGameObject.Scene.World.IsEnabled(mGameObject.Entity, NetworkIdentity.DataIndex);
	ref NetworkIdentityData Settings
	{
		[Inline]
		get => ref *mGameObject.GetComponent<NetworkIdentityData>();
	}

	public const int HistorySize = 128;
	BodyState mSentFull;
	bool mSentAsleep;
	public bool SnapshotSleeping => Chosen.dormantWhenSleeping && GetComponent<Rigidbody>().IsSleeping;

	/// Server: the settings snapshots use, worked out by Choose each snapshot (the identity's own settings when
	/// automatic is off), and what the engine took the object to be.
	[NonSerialized]
	public NetworkIdentityData Chosen;
	[NonSerialized]
	public NetworkObjectKind ChosenKind = .AsSet;

	/// Server: snapshot bytes sent about this object (to all clients) and how many times it was sent, this second
	/// so far and over the last whole second (the network panel).
	int32 mStatBytes, mStatSends;
	public int32 BytesPerSecond, SendsPerSecond;

	public void NoteSent(int bytes)
	{
		mStatBytes += (int32)bytes;
		mStatSends++;
	}

	void RollStats()
	{
		BytesPerSecond = mStatBytes;
		SendsPerSecond = mStatSends;
		mStatBytes = mStatSends = 0;
	}

	/// Server: why Choose chose what it did, in a few words (the network panel).
	public void Explain(NetworkManager network, String into)
	{
		let settings = Settings;
		switch (ChosenKind)
		{
		case .AsSet:
			into.Append("Automatic is off: the settings as set");
			return;
		case .Player:
			if (settings.ownerId != 0)
				into.AppendF("a player's (client {}): sent to the others first", settings.ownerId);
			else
				into.Append("the host's player: sent to the others first");
		case .Body:
			into.Append("a dynamic Rigidbody: body motion");
			if (Chosen.dormantWhenSleeping)
				into.Append(", quiet while asleep");
			else if (network.PredictPhysics && CanPredictPhysics)
				into.Append(", predicted on clients (so mentioned while asleep)");
		case .Moving:
			into.Append("no Rigidbody: packed transform; sent only when it moves");
		}
		if (Chosen.distanceFiltered)
			into.Append(network.SnapshotRelevanceRadius > 0 ? scope $", near players only ({network.SnapshotRelevanceRadius:0} m)" : ", to everyone (no relevance radius set)");
		bool byHand = settings.remoteFormat != .Legacy || settings.fullPrecision || settings.remoteIntervalTicks != 0 || settings.dormantWhenSleeping || settings.distanceFiltered || settings.snapshotPriority != 0;
		if (byHand)
			into.Append("; some settings set by hand are kept");
	}

	/// Server: works out Chosen from the object as it is now (NetworkIdentityData.automatic). Only settings left at
	/// their defaults are chosen: one set by hand (in the Inspector or from code) is kept.
	public void Choose(NetworkManager network)
	{
		Chosen = Settings;
		if (!Chosen.automatic)
		{
			ChosenKind = .AsSet;
			return;
		}
		RemoteSnapshotFormat format;
		bool dormant, near;
		int32 priority;
		let body = GetComponent<Rigidbody>();
		if (Chosen.ownerId != 0 || (!PrefabName.IsEmpty && PrefabName == network.PlayerPrefab))
		{
			ChosenKind = .Player;
			(format, dormant, near, priority) = (.Legacy, false, false, 1);
		}
		else if (body.IsValid && !body.isKinematic)
		{
			ChosenKind = .Body;
			// Quiet while it sleeps only when clients do not predict it: a predicted body at rest is mentioned now
			// and then, which is how a client that stopped predicting it (a script moved it, prediction was off)
			// takes it up again.
			(format, dormant, near, priority) = (.QuantizedBody, !(network.PredictPhysics && CanPredictPhysics), true, 0);
		}
		else
		{
			ChosenKind = .Moving;
			(format, dormant, near, priority) = (.Legacy, false, true, 0);
		}
		if (Chosen.remoteFormat == .Legacy)
			Chosen.remoteFormat = format;
		Chosen.dormantWhenSleeping |= dormant;
		Chosen.distanceFiltered |= near;
		if (Chosen.snapshotPriority == 0)
			Chosen.snapshotPriority = priority;
	}



	/// The controls of the last tick run, for TickInput.previous.
	[NonSerialized]
	public NetInput LastInput;



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

	// Whether Frame would change anything (see FrameAll).
	bool HasFrameWork => mTickSmoothing || SmoothOffset.LengthSquared > 0 || mVisualOffset.LengthSquared > 0;

	public void Frame()
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
		if (Chosen.fullPrecision || predictable)
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

	/// What OnEnable did: joins the session (OnAdded, and FrameAll when switched on again).
	public void Enable()
	{
		mJoined = true;
		if (NetId == 0)
			NetId = mGameObject.Id;
		Chosen = Settings;
		mGameObject.Scene.Network?.[Friend]Register(Handle);
	}

	/// What OnDisable did: leaves the session (switched off, removed, or play stopping). Once per Enable.
	public void OnDisable()
	{
		if (!mJoined)
			return;
		mJoined = false;
		let handle = Handle;
		NetworkSync.Forget(handle);
		mGameObject.Scene.Network?.[Friend]Unregister(handle);
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
