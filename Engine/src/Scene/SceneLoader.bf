using System;

namespace Tallow;

/// Loads a scene in the background without a line of code: for a loading screen, a level streamed in as the player
/// nears it, or the next level got ready while this one is played.
///
/// Scene is the file; Additive adds it to the running scene (else the game changes to it once it has loaded).
/// Load On Start starts it as the game starts; otherwise call Begin. Progress (0 to 1) can be shown on a UI Document
/// bar with bind="progress". With Activate When Ready off, a finished load waits at 0.9 until Activate is called,
/// for "press any key to continue".
///
/// Every machine loads scenes for itself, as it does its start scene: nothing about loading is sent.
[Component]
class SceneLoader : Component
{
	/// The scene file to load.
	public String scene = new .() ~ delete _;
	/// Add it to the running scene instead of changing to it.
	public bool additive = false;
	/// With Additive: take its sky, fog and ambient light too.
	public bool applyEnvironment = false;
	public bool loadOnStart = true;
	/// Off: wait at 0.9 until Activate is called.
	public bool activateWhenReady = true;
	/// How far it has got, 0 to 1, for a loading bar (bind="progress").
	[NonSerialized]
	public float progress;

	SceneLoad mLoad;

	/// True once it has finished (the scene changed, or the additive content is in).
	public bool IsDone => mLoad != null && mLoad.IsDone;
	/// With Additive, once done: the object holding what was added.
	public GameObject Group => mLoad?.Group;

	public override void Start()
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

	public override void OnLocalUpdate()
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
