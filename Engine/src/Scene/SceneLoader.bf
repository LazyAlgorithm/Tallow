using System;

namespace Tallow;

/// A SceneLoader's settings, in its entity (SceneLoader is the handle).
[Component, HandleData]
struct SceneLoaderData
{
	/// The scene file to load.
	public String scene = new .();
	/// Add it to the running scene instead of changing to it.
	public bool additive = false;
	/// With Additive: take its sky, fog and ambient light too.
	public bool applyEnvironment = false;
	public bool loadOnStart = true;
	/// Off: wait at 0.9 until Activate is called.
	public bool activateWhenReady = true;
	/// How far it has got, 0 to 1, for a loading bar (bind="progress").
	[NonSerialized]
	public float progress = default;

	public this() { }
}

/// Loads a scene in the background without a line of code: for a loading screen, a level streamed in as the player
/// nears it, or the next level got ready while this one is played.
///
/// Scene is the file; Additive adds it to the running scene (else the game changes to it once it has loaded).
/// Load On Start starts it as the game starts; otherwise call Begin. Progress (0 to 1) can be shown on a UI Document
/// bar with bind="progress". With Activate When Ready off, a finished load waits at 0.9 until Activate is called,
/// for "press any key to continue".
///
/// Every machine loads scenes for itself, as it does its start scene: nothing about loading is sent.
///
/// A handle (ComponentHandle): its settings are SceneLoaderData's fields, what it keeps between frames its SceneLoaderState.
/// SceneLoader.FrameAll (a step in the frame pipeline) does what Start, OnLocalUpdate and OnDisable did.
[Component, HandleFields]
struct SceneLoader : ComponentHandle<SceneLoaderData>
{
	/// What it keeps between frames, made the first time it is asked for.
	public SceneLoaderState Runtime
	{
		get
		{
			CheckValid();
			let state = ComponentState<SceneLoaderState>.Make(mGameObject.Scene.World, mGameObject.Entity);
			if (state.[Friend]mGameObject == null)
			{
				state.[Friend]mGameObject = mGameObject;
			}
			return state;
		}
	}

	// The API, unchanged: each member is documented on SceneLoaderState.
	public bool IsDone => Runtime.IsDone;
	public GameObject Group => Runtime.Group;
	public void Begin() => Runtime.Begin();
	public void Activate() => Runtime.Activate();
	public bool Finished => Runtime.Finished;

	/// Starts SceneLoaders that have not started, moves every switched-on one on an active object a frame on, and
	/// tells one that has been switched off (OnDisable).
	public static void FrameAll(Scene scene)
	{
		if (!scene.IsPlaying)
			return;
		for (let component in scene.FindComponents<SceneLoader>(.. scope .()))
		{
			let state = component.Runtime;
			if (!component.IsActiveAndEnabled)
			{
				if (state.[Friend]mWasActive)
				{
					state.[Friend]mWasActive = false;
					
				}
				continue;
			}
			state.[Friend]mWasActive = true;
			if (!state.[Friend]mStarted)
			{
				state.[Friend]mStarted = true;
				state.Start();
			}
			state.Frame();
		}
	}

	/// When play stops, they start again next time (as Start runs once per play).
	public static void StopAll(Scene scene)
	{
		for (let (entity, state) in ComponentState<SceneLoaderState>.In(scene.World, .. scope .()))
		{
			state.[Friend]mStarted = false;
			state.[Friend]mWasActive = false;
		}
	}

	static void OnRemove(void* world, uint64 entity)
	{
		ComponentState<SceneLoaderState>.Release(world, entity);
		HandleComponents.FreeLists(world, entity, typeof(SceneLoader));
	}
}

/// What a SceneLoader keeps between frames. Its settings are read from the entity each time.
[DataFields(typeof(SceneLoaderData), "Settings")]
class SceneLoaderState
{
	GameObject mGameObject;
	bool mStarted;
	bool mWasActive;

	public GameObject GameObject => mGameObject;
	public Transform Transform => mGameObject.Transform;
	public Scene Scene => mGameObject.Scene;
	public SceneLoader Handle => mGameObject.GetComponent<SceneLoader>();
	T GetComponent<T>() where T : Component => mGameObject.GetComponent<T>();
	T GetComponent<T>() where T : struct, IComponentHandle => mGameObject.GetComponent<T>();
	bool HasComponent<T>() where T : struct, IComponentHandle => mGameObject.HasComponent<T>();
	ref SceneLoaderData Settings
	{
		[Inline]
		get => ref *mGameObject.GetComponent<SceneLoaderData>();
	}

	SceneLoad mLoad;

	/// True once it has finished (the scene changed, or the additive content is in).
	public bool IsDone => mLoad != null && mLoad.IsDone;
	/// With Additive, once done: the object holding what was added.
	public GameObject Group => mLoad?.Group;

	public void Start()
	{
		if (loadOnStart)
			Begin();
	}

	/// Starts loading (does nothing if it already has).
	public void Begin()
	{
		if (mLoad != null || scene.IsEmpty)
			return;
		mLoad = additive ? SceneManager.LoadAdditiveAsync(Scene, scene, applyEnvironment) : SceneManager.LoadAsync(scene);
		mLoad.allowActivation = activateWhenReady;
	}

	/// Lets a load that is waiting at 0.9 finish.
	public void Activate()
	{
		if (mLoad != null)
			mLoad.allowActivation = true;
	}

	public void Frame()
	{
		if (mLoad == null)
			return;
		progress = mLoad.Progress;
		// SceneManager lets go of a load the frame after it is done; this keeps only what it needs.
		if (mLoad.IsDone)
		{
			progress = 1;
			mLoad = null;
			mFinished = true;
		}
	}

	bool mFinished;
	/// True once it has finished, after the load itself has been let go.
	public bool Finished => mFinished || IsDone;
}
