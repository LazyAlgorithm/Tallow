using System;
using System.IO;

namespace Tallow;

/// Runs a project as a game: the start scene in play mode, rendered straight to the window.
class GameApp : Application
{
	public String GameName = new .("Tallow") ~ delete _;
	public String StartScene = new .("Scenes/Main.tscene") ~ delete _;
	Scene mScene ~ delete _;
	RenderView mView ~ delete _;
	bool mGui;

	protected override void OnEvent(ref SDL.Event event)
	{
		if (mGui && !Input.HiddenFromInterface(event.type))
			ImGui.tn_imgui_event(&event);
	}

	protected override bool OnInit()
	{
		Title.Set(GameName);
		if (Window != null)
			SDL.SDL_SetWindowTitle(Window, Title.CStr());
		mScene = new Scene();
		let sceneArg = scope String();
		GetArg("--scene", sceneArg);
		if (!LoadScene(mScene, sceneArg)) return false;
		// --world-state <name or number>: start in that world state (for checks and screenshots).
		let stateArg = scope String();
		if (GetArg("--world-state", stateArg))
		{
			if (!mScene.SetWorldState(stateArg) && (int32.Parse(stateArg) case .Ok(let number)))
				mScene.WorldState = number;
		}
		if (!Headless)
		{
			mView = new RenderView(10);
			mView.ToBackbuffer = true;
			mGui = ImGui.tn_imgui_init(Window, null, 1.0f);
		}
		mScene.StartPlay();
		return true;
	}

	protected virtual bool LoadScene(Scene scene, StringView overridePath)
	{
		let path = scope String();
		Assets.ResolvePath(overridePath.IsEmpty ? (StringView)StartScene : overridePath, path);
		if (!AssetPack.Exists(path))
		{
			Log.Error(scope $"Start scene missing: {path}");
			return false;
		}
		SceneSerializer.LoadFromFile(scene, path);
		return true;
	}

	protected override void OnFixedUpdate()
	{
		mScene.FixedUpdate();
		if (HasArg("--trace") && Time.Tick % 20 == 0 && mScene.Network != null)
		{
			for (let identity in mScene.Network.Identities)
			{
				if (identity.GameObject.Name == "Player")
					Log.Info(scope $"tick {Time.Tick} player {identity.NetId & 0xff} owner {identity.ownerId} at {identity.Transform.Position}");
			}
		}
		if (Headless && Time.Tick % 300 == 0 && mScene.Network != null)
			Log.Info(scope $"tick {Time.Tick}: {mScene.Network.ClientCount} client(s), {mScene.Network.Identities.Count} networked objects");
	}

	protected override void OnUpdate()
	{
		// Scene packs that finished downloading (in a browser) join the others.
		AssetPack.Poll();
		SaveSystem.Update();
		SceneManager.Update(mScene);
		let camera = FindCamera();
		if (camera)
		{
			VoxelTerrain.ViewerPosition = camera.Transform.Position;
			Camera.ViewerPosition = camera.Transform.Position;
		}
		else if (mScene.Network != null && mScene.Network.Identities.Count > 0)
			VoxelTerrain.ViewerPosition = mScene.Network.Identities.Back.Transform.Position;
		// A server keeps the terrain loaded, and detailed, around every player as well.
		VoxelTerrain.Viewers.Clear();
		if (mScene.Network != null && mScene.Network.IsServer)
		{
			for (let identity in mScene.Network.Identities)
			{
				if (identity.ownerId > 0 && VoxelTerrain.Viewers.Count < 64)
					VoxelTerrain.Viewers.Add(identity.Transform.Position);
			}
		}
		mScene.Update();
#if !BF_PLATFORM_WASM
		// (A web page is closed with the browser; there, Escape only gives the mouse back.)
		if (GameWindow.EscapeQuits && Input.GetKeyDown(.Escape))
			Running = false;
#endif
	}

	String mEffectsArg = new .() ~ delete _;

	Camera FindCamera() => mScene.ViewCamera;

	protected override void OnRender()
	{
		let camera = FindCamera();
		if (!camera)
			return;
		mView.Resize(Width, Height);
		// --effects "ao=1,dof=0.6,...": try the screen effects on any scene (docs/post-processing.md).
		if (GetArg("--effects", mEffectsArg))
			PostProcess.ApplySettings(mEffectsArg, mScene.Environment);
		mView.Render(mScene, camera.GetCameraData((float)Width / Math.Max(Height, 1)));
		if (mGui)
		{
			// Components draw their interface into one invisible window covering the screen.
			ImGui.tn_imgui_new_frame();
			ImGui.SetNextWindowPos(.(0, 0));
			ImGui.SetNextWindowSize(.(InterfaceWidth, InterfaceHeight));
			ImGui.Begin("##GameGUI", null, ImGui.WindowFlags.NoDecoration | ImGui.WindowFlags.NoBackground | ImGui.WindowFlags.NoSavedSettings
				| ImGui.WindowFlags.NoMove | ImGui.WindowFlags.NoBringToFrontOnFocus | ImGui.WindowFlags.NoScrollWithMouse);
			GUI.Run(mScene, .(0, 0), .(InterfaceWidth, InterfaceHeight));
			// On a touch screen, the game's on-screen controls go over everything else.
			TouchControls.Draw();
			ImGui.End();
			ImGui.tn_imgui_render(250);
		}
	}

	protected override void OnShutdown()
	{
		if (mScene != null)
			mScene.StopPlay();
		if (mGui && Gfx.Initialized)
			ImGui.tn_imgui_shutdown();
	}
}

