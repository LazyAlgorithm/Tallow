using System;
using System.Collections;

namespace Tallow;

/// Where a Sequence Player is.
enum SequenceState
{
	Stopped,
	Playing,
	Paused,
	/// Reached the end (and holds its last frame).
	Finished
}

/// Plays a sequence (a `.tsequence` file: a cutscene, or a timed piece of a level) on the scene: moves its objects,
/// shows its camera shots, plays its animations, sounds and subtitles, fades the screen and tells the game about its
/// events. See docs/sequencer.md.
///
///   let cutscene = GetComponent<SequencePlayer>();
///   cutscene.OnEvent.Add(new (name, value) => { if (name == "GateOpened") gate.Open(); });
///   cutscene.OnFinished.Add(new () => player.controlsEnabled = true);
///   cutscene.Play();
[Component]
class SequencePlayer : Component
{
	/// The sequence (.tsequence file).
	public String sequence = new .() ~ delete _;
	/// Starts when the scene starts.
	public bool playOnStart = false;
	/// Starts again from the beginning when it ends.
	public bool loop = false;
	[Range(0, 4)]
	public float speed = 1;
	/// The player can skip it (Enter, a controller's Start button, or the project's "Sequence Skip" input action).
	public bool skippable = true;
	/// When it stops or ends, the objects it moved, showed or hid go back as they were before it started.
	public bool restoreWhenDone = false;
	/// While it plays and has camera shots, the game is seen through them; afterwards through its own camera again.
	public bool useCameraShots = true;
	/// In a network session, one sequence for every player, timed by the server (the object gets a Network Identity
	/// by itself). Off: each machine plays its own.
	public bool shared = false;
	/// With Shared: only the player who owns this object (or the server) may start, pause or skip it.
	public bool onlyOwnerControls = false;

	// What a shared sequence's server last decided: other machines follow it.
	[Sync, HideInInspector] public int32 syncSerial;
	[Sync, HideInInspector] public int32 syncState;
	[Sync, HideInInspector] public float syncTime;
	[Sync, HideInInspector] public int32 syncTick;

	[Saved, HideInInspector] public int32 savedState;
	[Saved, HideInInspector] public float savedTime;

	/// An Event key was passed (on the server, for a shared sequence).
	public Event<delegate void(StringView name, float value)> OnEvent ~ _.Dispose();
	/// It reached its end (not when stopped or skipped... skipping ends it too, so this is called then as well).
	public Event<delegate void()> OnFinished ~ _.Dispose();

	SequenceEvaluator mEvaluator = new .() ~ delete _;
	SequenceState mState;
	float mTime;
	int32 mAppliedSerial;
	bool mBound;
	GameObject mCameraObject;
	static int32 sPlaying;

	/// How many Sequence Players are playing now, anywhere (a game can keep its controls off while it is above 0).
	public static int32 PlayingCount => sPlaying;

	public SequenceState State => mState;
	public bool IsPlaying => mState == .Playing;
	/// Seconds into the sequence.
	public float Time => mTime;
	public SequenceAsset Asset => mEvaluator.Asset;
	/// How far the screen is faded now (0 clear, 1 covered), for a game drawing its own fade.
	public float ScreenFade => mState == .Playing || mState == .Paused ? mEvaluator.Fade : 0;
	/// How long it is (its last key, or its length if that is later).
	public float Length => mEvaluator.Asset?.End ?? 0;

	public override void Awake()
	{
		mEvaluator.OnEvent.Add(new => EvaluatorEvent);
	}

	public override void Start()
	{
		if (playOnStart && Mine)
			Play();
	}

	public override void OnDisable()
	{
		if (mState == .Playing)
			sPlaying--;
		mState = .Stopped;
		Release();
	}

	/// True where this sequence is decided: always unless it is shared in a session, then on the server.
	bool Mine => !shared || !NetworkSync.InSession(Scene) || (Scene.Network != null && Scene.Network.IsServer);

	void EvaluatorEvent(StringView name, float value) => OnEvent(name, value);

	/// Reads the file and finds its objects.
	bool Bind()
	{
		let asset = SequenceAsset.Load(sequence);
		if (asset == null)
			return false;
		if (mBound && mEvaluator.Asset == asset)
			return true;
		mEvaluator.Bind(asset, Scene, GameObject);
		mBound = true;
		// Shots are shown through a camera of the sequence's own, made the first time.
		var hasShots = false;
		for (let track in asset.tracks)
			hasShots |= track.kind == .Camera;
		if (hasShots && mCameraObject == null)
		{
			mCameraObject = Scene.CreateGameObject("Sequence Camera");
			mCameraObject.Transform.SetParent(Transform, false);
			let camera = mCameraObject.AddComponent<Camera>();
			// The scene's own camera keeps its post-processing and ears; this one only looks.
			mCameraObject.SetActive(false);
			mEvaluator.ViewCamera = camera;
		}
		return true;
	}

	/// Plays from the beginning. False when the file cannot be read.
	public bool Play()
	{
		if (!Mine)
		{
			NetworkSync.SequenceRequest(this, 0, 0);
			return true;
		}
		if (!Bind())
			return false;
		if (mState == .Playing)
			sPlaying--;
		mEvaluator.Silence();
		SetState(.Playing);
		mTime = 0;
		mEvaluator.FireEvents = true;
		mEvaluator.Apply(0, -1, true);
		Show();
		Changed();
		return true;
	}

	/// Holds it where it is.
	public void Pause()
	{
		if (!Mine)
		{
			NetworkSync.SequenceRequest(this, 1, 0);
			return;
		}
		if (mState != .Playing)
			return;
		SetState(.Paused);
		Changed();
	}

	/// Carries on after Pause.
	public void Resume()
	{
		if (!Mine)
		{
			NetworkSync.SequenceRequest(this, 2, 0);
			return;
		}
		if (mState != .Paused)
			return;
		SetState(.Playing);
		Changed();
	}

	/// Ends it where it is: its sounds and subtitles go, the camera goes back.
	public void Stop()
	{
		if (!Mine)
		{
			NetworkSync.SequenceRequest(this, 3, 0);
			return;
		}
		if (mState == .Stopped)
			return;
		SetState(.Stopped);
		Release();
		Changed();
	}

	/// Jumps to the end: everything stands as it would at the end, events passed over still happen, and it finishes.
	public void Skip()
	{
		if (!Mine)
		{
			NetworkSync.SequenceRequest(this, 4, 0);
			return;
		}
		if (mState != .Playing && mState != .Paused)
			return;
		let end = Length;
		mEvaluator.Silence();
		mEvaluator.FireEventsBetween(mTime, end);
		mEvaluator.SettleAnimations(end);
		mTime = end;
		mEvaluator.Apply(end, end, false);
		Finish();
		Changed();
	}

	/// Moves it to a time without its sounds, subtitles and events in between (for a game's own scrubbing).
	public void Seek(float time)
	{
		if (!Mine)
		{
			NetworkSync.SequenceRequest(this, 5, time);
			return;
		}
		if (!Bind())
			return;
		mTime = Math.Clamp(time, 0, Length);
		mEvaluator.Silence();
		mEvaluator.SettleAnimations(mTime);
		mEvaluator.Apply(mTime, mTime, false);
		if (mState == .Stopped || mState == .Finished)
			SetState(.Paused);
		Show();
		Changed();
	}

	/// Server: a client asked to control a shared sequence.
	public void ApplyRequest(int32 action, float time)
	{
		switch (action)
		{
		case 0: Play();
		case 1: Pause();
		case 2: Resume();
		case 3: Stop();
		case 4: Skip();
		case 5: Seek(time);
		}
	}

	void SetState(SequenceState state)
	{
		if (state == .Playing && mState != .Playing)
			sPlaying++;
		else if (state != .Playing && mState == .Playing)
			sPlaying--;
		mState = state;
	}

	void Finish()
	{
		SetState(.Finished);
		Release();
		OnFinished();
	}

	/// Shows the game through the sequence's camera while it has a shot.
	void Show()
	{
		let camera = mEvaluator.ViewCamera;
		if (!camera || !useCameraShots)
			return;
		let shot = mEvaluator.HasShot(mTime) && (mState == .Playing || mState == .Paused);
		if (shot)
		{
			// The sequence's camera looks like the scene's own (its effects, clip planes), only from the shot.
			if (!camera.GameObject.ActiveSelf)
			{
				let own = Scene.ViewCamera;
				if (own && own != camera)
				{
					camera.nearClip = own.nearClip;
					camera.farClip = own.farClip;
				}
				camera.GameObject.SetActive(true);
			}
			Scene.CameraOverride = camera;
		}
		else
			ReleaseCamera();
	}

	void ReleaseCamera()
	{
		let camera = mEvaluator.ViewCamera;
		if (!camera)
			return;
		if (Scene.CameraOverride == camera)
			Scene.CameraOverride = default;
		if (camera.GameObject.ActiveSelf)
			camera.GameObject.SetActive(false);
	}

	void Release()
	{
		mEvaluator.Silence();
		ReleaseCamera();
		if (restoreWhenDone)
			mEvaluator.Restore();
	}

	/// After the server changed it: written for the other machines.
	void Changed()
	{
		syncSerial++;
		syncState = (int32)mState;
		syncTime = mTime;
		syncTick = Scene.Network != null ? (int32)Scene.Network.Tick : 0;
		mAppliedSerial = syncSerial;
	}

	/// A client of a shared sequence: where the server's sequence is now.
	float ServerTime()
	{
		var time = syncTime;
		if ((SequenceState)syncState == .Playing && Scene.Network != null)
			time += (float)((Scene.Network.ServerTick - syncTick) / Tallow.Time.TickRate) * speed;
		return time;
	}

	/// A client of a shared sequence: takes up what the server last sent.
	void Follow()
	{
		mAppliedSerial = syncSerial;
		let state = (SequenceState)syncState;
		if (!Bind())
			return;
		mEvaluator.FireEvents = false;
		let was = mState;
		SetState(state);
		switch (state)
		{
		case .Playing,.Paused:
			let time = Math.Clamp(ServerTime(), 0, Length);
			// Starting from the top plays its first moments; joining part way, or a jump, does not.
			if (was != .Playing && was != .Paused && time < 0.25f)
			{
				mTime = time;
				mEvaluator.Silence();
				mEvaluator.Apply(time, -1, true);
			}
			else if (Math.Abs(time - mTime) > 0.25f || (was != .Playing && was != .Paused))
			{
				mTime = time;
				mEvaluator.Silence();
				mEvaluator.SettleAnimations(time);
				mEvaluator.Apply(time, time, false);
			}
			Show();
		case .Finished:
			let end = Length;
			if (was != .Finished)
			{
				mEvaluator.Silence();
				mEvaluator.SettleAnimations(end);
				mTime = end;
				mEvaluator.Apply(end, end, false);
				Release();
				OnFinished();
			}
		case .Stopped:
			Release();
		}
	}

	public override void OnLocalUpdate()
	{
		if (!Mine)
		{
			if (syncSerial != mAppliedSerial)
				Follow();
			if (mState == .Playing)
			{
				// Kept on the server's clock: moved on by frame, and nudged towards where the server says it is.
				let previous = mTime;
				var next = mTime + Tallow.Time.DeltaTime * speed;
				let target = ServerTime();
				if (Math.Abs(target - next) > 0.25f)
					next = target;
				else
					next += (target - next) * 0.1f;
				mTime = Math.Min(next, Length);
				mEvaluator.Apply(mTime, previous, true);
				Show();
			}
			if (skippable && mState == .Playing && SkipPressed())
				Skip();
			return;
		}
		if (mState != .Playing)
			return;
		if (skippable && SkipPressed())
		{
			Skip();
			return;
		}
		let previous = mTime;
		mTime += Tallow.Time.DeltaTime * speed;
		let end = Length;
		if (mTime >= end)
		{
			mEvaluator.Apply(end, previous, true);
			if (loop)
			{
				mTime -= end;
				mEvaluator.Apply(mTime, -1, true);
				Changed();
			}
			else
			{
				mTime = end;
				Finish();
				Changed();
				return;
			}
		}
		else
			mEvaluator.Apply(mTime, previous, true);
		Show();
	}

	static bool SkipPressed()
	{
		if (InputActions.Find("Sequence Skip") != null)
			return InputActions.Pressed("Sequence Skip");
		return Input.GetKeyDown(.Return) || Gamepad.GetButtonDown(.Start);
	}

	public override void OnGUI()
	{
		let fade = mEvaluator.Fade;
		if (fade <= 0 || (mState != .Playing && mState != .Paused))
			return;
		var color = mEvaluator.FadeColor;
		color.a = fade;
		GUI.Box(0, 0, GUI.Width, GUI.Height, color);
	}

	public override void OnSaving()
	{
		savedState = (int32)mState;
		savedTime = mTime;
	}

	public override void OnLoaded()
	{
		let state = (SequenceState)savedState;
		if (state != .Playing && state != .Paused)
			return;
		Seek(savedTime);
		if (state == .Playing)
			Resume();
	}
}
