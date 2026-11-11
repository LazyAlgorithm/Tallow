using System;
using System.Collections;
using System.IO;
using Tallow;
using Bgfx;

namespace Tallow.Editor;

/// The Tallow editor: Hierarchy, Scene, Game, Inspector, Project and Console panels around
/// a dockable workspace, with Play / Pause / Stop running the scene in place.
class EditorApp : Application
{
	enum PlayState { Edit, Playing, Paused }

	const uint16 ImGuiView = 250;
	static readonly Color Accent = .(0.36f, 0.62f, 0.92f, 1);

	Scene mScene ~ delete _;
	RenderView mSceneView ~ delete _;
	RenderView mGameView ~ delete _;
	PlayState mPlay = .Edit;
	/// The game asked to quit while playing: Play stops at the start of the next frame (not in the middle of the
	/// component that asked, whose scene stopping would replace).
	bool mStopPlayRequested;
	String mSnapshot = new .() ~ delete _;
	uint32 mPrePlaySelection;
	bool mPrePlayDirty;
	String mIniPath = new .() ~ delete _;
	String mBrowsePath = new .() ~ delete _;
	String mComponentSearch = new .() ~ delete _;
	ComponentClipboard mComponentClipboard = new .() ~ delete _;
	bool mFocusComponentSearch;
	String mHierarchySearch = new .() ~ delete _;
	String mNewScriptName = new .("NewScript") ~ delete _;
	String mSceneSaveName = new .() ~ delete _;
	String mStatus = new .() ~ delete _;
	uint32 mSelectedId;
	bool mDirty;
	bool mLayoutBuilt;
	bool mResetLayout;
	bool mGameFocused;
	/// Toolbar button: games may lock the mouse to the Game view while it is being played in.
	bool mLockMouse = true;
	/// Escape was pressed while the mouse was locked: the lock stays off until the Game view is clicked again.
	bool mLockHeldOff;
	bool mSceneHovered;
	/// The Hierarchy or the Scene view has the keyboard: Delete there deletes the selected object. Elsewhere it is
	/// the panel's own (the Project panel's deletes the selected asset) or nothing.
	bool mHierarchyFocused;
	bool mSceneFocused;
	bool mFlying;
	bool mWantRebuild;
	bool mWantBuildGame;
	int32 mBusyFrames;
	bool mOpenNewScript;
	bool mOpenSaveAs;
	bool mFocusGame;
	bool mFocusScene = true;
	int32 mFocusInspector;
	/// Bring the Scene view to the front now, whatever else is open (set when a prefab is opened).
	bool mShowScene;
	uint32 mAssetCenterDock;
	uint32 mBottomDock;
	uint32 mInspectorDock;
	bool mShowScripts;
	bool mShowGraph;
	bool mShowUI;
	bool mDockScripts;
	bool mDockGraph;
	bool mDockUI;
	int32 mLogVersion;

	// Scene view camera and tools.
	Vector3 mCamPosition = .(9, 7, -12);
	float mCamYaw = -35;
	float mCamPitch = 24;
	int32 mGizmoOperation = 0;
	bool mGizmoLocal = true;
	bool mShowGrid = true;
	// The Scene view's camera culls what is hidden (as a game camera with Occlusion Culling does), and shows its picture.
	bool mSceneOcclusion;
	bool mShowOcclusionPicture;
	CameraData mSceneCamera;
	ImGui.Vec2 mSceneSize = .(640, 360);
	ImGui.Vec2 mGameSize = .(640, 360);
	bool mSceneVisible, mGameVisible;

	public this()
	{
		Material.FreeUnusedMaterials = false;
		// The window is the editor's; a game played in it cannot take the whole screen.
		GameWindow.Allowed = false;
		StartMaximized = true;
		Title.Set("Tallow");
	}

	GameObject Selected => mSelectedId != 0 ? mScene.FindById(mSelectedId) : null;

	// ------------------------------------------------------------------ lifecycle

	protected override bool OnInit()
	{
		let project = Project.Current;
		Title.Set(scope $"Tallow - {project.Name}");
		SDL.SDL_SetWindowTitle(Window, Title.CStr());
		if (!project.EngineRoot.IsEmpty)
			SetWindowIcon(scope $"{project.EngineRoot}/icon.png");
		RecentProjects.Load();
		RecentProjects.Add(project.Path);

		RecentProjects.GetConfigFolder(mIniPath);
		mIniPath.AppendF("layout5_{}.ini", project.Name);
		mLayoutBuilt = File.Exists(mIniPath);
		if (!ImGui.tn_imgui_init(Window, mIniPath.CStr(), 1.0f))
			return false;
		LoadOpenWindows();
		// The editor's colours (docs/themes.md): the theme last used, or --theme <name> for this run.
		let themeArg = scope String();
		GetArg("--theme", themeArg);
		let codeThemeArg = scope String();
		GetArg("--code-theme", codeThemeArg);
		EditorTheme.Init(themeArg, codeThemeArg);

		mBrowsePath.Set(Assets.ProjectPath);
		InitializeScriptReload();
		mSceneView = new RenderView(10);
		mSceneView.DrawGizmos = true;
		mSceneView.drawEditorOnly = true;
		// Depth of field and motion blur get in the way of editing (Scene Settings > Screen Effects can show them).
		mSceneView.ShowDepthOfField = false;
		mSceneView.ShowMotionBlur = false;
		mGameView = new RenderView((uint16)(10 + RenderView.ViewCount));
		ProjectConfig.Load();
		mScene = new Scene();
		let sceneArg = scope String();
		GetArg("--scene", sceneArg);
		EditorMain.LoadStartScene(mScene, sceneArg);
		Log.Info(scope $"Opened project {project.Name} ({project.Path})");
		LoadSceneToolSettings();
		AlignSceneCameraToGameCamera();
		// A streamed world: only the cells round the view (docs/world-streaming.md).
		LoadStreamedCellsAroundView();
		ResetUndo();
		// Shaders edited outside the editor, or never compiled on this machine, are built before anything draws.
		CompileStaleShaders();
		ApplyStartupSwitches();
		return true;
	}

	/// A switch naming an asset (--prefab Prefabs/crate.tprefab), as a full path. False when the switch is not given.
	bool AssetArg(StringView name, String full)
	{
		let value = scope String();
		if (!GetArg(name, value))
			return false;
		Assets.ResolvePath(value, full);
		return true;
	}

	/// The command-line switches that open the editor on something (a folder, an asset, a window), mostly for
	/// automated checks.
	void ApplyStartupSwitches()
	{
		let full = scope String();
		if (AssetArg("--browse", full..Clear()) && Directory.Exists(full))
			mBrowsePath.Set(full);
		if (AssetArg("--prefab", full..Clear()) && File.Exists(full))
			OpenPrefab(full);
		if (AssetArg("--material", full..Clear()) && File.Exists(full))
			OpenMaterial(full);
		if (AssetArg("--ui", full..Clear()))
		{
			OpenUI(full);
			let pick = scope String();
			if (GetArg("--ui-select", pick) && mUiData != null && mUiData.root != null)
				mUiSelected = mUiData.root.Find(pick);
		}
		if (HasArg("--achievements"))
			mShowAchievements = true;
		if (HasArg("--input-actions"))
			mShowInputActions = true;
		if (HasArg("--build-window"))
			ApplyBuildSwitches();
		if (AssetArg("--animator", full..Clear()))
			OpenAnimatorFromSwitch(full);
		if (AssetArg("--animation", full..Clear()))
		{
			if (File.Exists(full))
				OpenAnimationClip(full);
			else
				mShowAnimation = true;
		}
		if (AssetArg("--sequence", full..Clear()) && File.Exists(full))
		{
			OpenSequence(full);
			mSeqFocusAfter = 30;
			let seconds = scope String();
			if (GetArg("--sequence-time", seconds) && (float.Parse(seconds) case .Ok(let time)))
			{
				mSeqTime = time;
				ApplySequencePreview(false, time);
			}
		}
		if (AssetArg("--dialogue", full..Clear()) && File.Exists(full))
		{
			OpenDialogue(full);
			mDialogueFocusAfter = 30;
		}
		if (AssetArg("--behavior", full..Clear()) && File.Exists(full))
		{
			OpenBehavior(full);
			mTreeFocusAfter = 30;
		}
		if (AssetArg("--graph", full..Clear()))
			OpenGraphFromSwitch(full);
		if (AssetArg("--script", full..Clear()))
			OpenScript(full);
		ApplyBrushSwitches();
		// Test switch: --undo-test-foliage paints plants on the scene's first Foliage twice and checks that undo and
		// redo take the strokes off and put them back without making the object again.
		if (HasArg("--undo-test-foliage"))
			RunFoliageUndoTest();
		let selectName = scope String();
		// Test switch: --lod-level <n> draws every LOD Group at that level.
		let lodArg = scope String();
		if (GetArg("--lod-level", lodArg))
			LODGroup.ForceLevel = (int32)SceneSerializer.ParseInt(lodArg);
		if (HasArg("--scene-occlusion"))
			mSceneOcclusion = mShowOcclusionPicture = true;
		if (HasArg("--quality-window"))
			mShowQuality = true;
		if (HasArg("--preferences"))
			mShowPreferences = true;
		ApplyProfilerSwitches();
		ApplyNetworkSwitches();
		// --model-views: Window > Model Views open; --scene-view "front|top|...|ortho": the Scene view's view selector.
		if (HasArg("--model-views"))
			mShowModelViews = true;
		let sceneViewArg = scope String();
		GetArg("--scene-view", sceneViewArg);
		for (let part in sceneViewArg.Split(','))
		{
			if (part == "ortho")
				SetSceneOrtho(true);
			for (int k = 1; k < sModelViewNames.Count; k++)
			{
				if (StringView.Compare(part, sModelViewNames[k], true) == 0)
				{
					float yaw, pitch;
					ModelViewAngles((ModelViewKind)k, out yaw, out pitch);
					LookSceneAlong(AnglesForward(yaw, pitch));
				}
			}
		}
		// --preferences-page modelling: Preferences open on its Modelling page.
		let preferencesPage = scope String();
		GetArg("--preferences-page", preferencesPage);
		if (preferencesPage == "modelling")
		{
			mShowPreferences = true;
			mPreferencesPage = 1;
		}
		// As Window > Reset Layout.
		if (HasArg("--reset-layout"))
			mResetLayout = true;
		ApplyLightingSwitches();
		ApplyPlacementSwitches();
		ApplyRiggerSwitches();
		if (HasArg("--theme-test"))
			RunThemeTest();
		if (HasArg("--visibility-test"))
			RunVisibilityTest();
		if (HasArg("--drag-test"))
			StartDragTest();
		if (HasArg("--model-import-test"))
			RunModelImportTest();
		if (HasArg("--asset-ids-test"))
			RunAssetIdsTest();
		if (HasArg("--packages-test"))
			RunPackagesTest();
		// Asset packages (docs/packages.md): --package-manager [files|catalogs], --export-package <asset or folder>,
		// --import-package <file.tpackage> [--import-into <folder>] opens those windows.
		let packageArg = scope String();
		if (GetArg("--package-manager", packageArg) || HasArg("--package-manager"))
		{
			OpenPackageManager();
			mPackageTab = packageArg == "files" ? 1 : (packageArg == "catalogs" ? 2 : 0);
		}
		if (AssetArg("--export-package", full..Clear()))
		{
			let picked = scope List<StringView>();
			picked.Add(full);
			OpenExportPackage(picked);
			// --export-package-to <file>: exports it straight away (automated checks).
			if (GetArg("--export-package-to", mExportFile))
				ExportPackageNow();
		}
		if (GetArg("--package-download", packageArg..Clear()))
			StartCatalogSwitch(packageArg);
		if (GetArg("--import-package", packageArg..Clear()))
		{
			GetArg("--import-into", mImportFolder);
			// --import-package-now: imports it straight away (automated checks).
			if (OpenImportPackage(packageArg) && HasArg("--import-package-now"))
				ImportPackageNow();
		}
		if (HasArg("--world-streaming-test"))
			RunWorldStreamingTest();
		if (HasArg("--separate-worlds-test"))
			RunSeparateWorldsTest();
		if (HasArg("--palette-test"))
			RunPaletteTest();
		// --scene-hide <name> / --scene-lock <name>: as pressing that object's eye or lock in the Hierarchy.
		let visibilityName = scope String();
		if (GetArg("--scene-hide", visibilityName) && mScene.Find(visibilityName) != null)
			SetSceneHidden(mScene.Find(visibilityName), true);
		if (GetArg("--scene-lock", visibilityName..Clear()) && mScene.Find(visibilityName) != null)
			SetPickLocked(mScene.Find(visibilityName), true);
		// Bakes every Navigation Surface in the scene (not saved), to see the grid without pressing Bake.
		if (HasArg("--bake-navigation"))
		{
			for (let component in mScene.ComponentsOfType(typeof(NavigationSurface)))
				((NavigationSurface)component).Bake();
		}
		if (GetArg("--select", selectName))
		{
			let found = mScene.Find(selectName);
			if (found != null)
			{
				mSelectedId = found.Id;
				FocusSelected();
			}
		}
		ApplyRigSwitches();
		ApplyModelSwitches();
		ApplySoftBodySwitches();
		// Test switch: saves the opened scene as Ctrl+S does, with the map warning, once the layout has settled
		// (the first frames bring the Scene tab forward, which would close the warning).
		if (HasArg("--save-scene"))
			mSaveSceneSwitchFrames = 15;
		ApplyCameraSwitch();
		if (HasArg("--play"))
			StartPlay();
	}

	/// Test switch --camera "x y z yaw pitch": puts the Scene view's camera there (degrees), for screenshots.
	void ApplyCameraSwitch()
	{
		let text = scope String();
		if (!GetArg("--camera", text))
			return;
		let values = scope List<float>();
		for (let part in text.Split(' ', ','))
		{
			if (!part.IsEmpty)
				values.Add(SceneSerializer.ParseFloat(part));
		}
		if (values.Count < 3)
			return;
		mCamPosition = .(values[0], values[1], values[2]);
		if (values.Count >= 5)
		{
			mCamYaw = values[3];
			mCamPitch = values[4];
		}
	}

	/// --build-window, with --build-windows, --build-web or --build-editor choosing what is built, and --build-now
	/// <folder> building it straight away (for automated checks).
	void ApplyBuildSwitches()
	{
		OpenBuildWindow();
		if (HasArg("--build-windows"))
			mBuildTarget = .Windows;
		if (HasArg("--build-web"))
			mBuildTarget = .Web;
		if (HasArg("--build-editor"))
			mBuildEditor = true;
		let folder = scope String();
		if (GetArg("--build-now", folder))
		{
			mBuildFolder.Set(folder);
			mWantBuildGame = true;
			mBusyFrames = 3;
		}
	}

	/// --animator <controller>, and the test switch --animator-state <name>, which selects a state (and shows its layer).
	void OpenAnimatorFromSwitch(StringView full)
	{
		if (File.Exists(full))
			OpenAnimator(full);
		else
			mShowAnimator = true;
		let stateName = scope String();
		if (!GetArg("--animator-state", stateName) || mAnimController == null)
			return;
		let index = mAnimController.FindState(stateName);
		if (index >= 0)
		{
			mAnimState = index;
			mAnimLayer = mAnimController.states[index].layer;
		}
	}

	/// --graph <graph>: opens it, or makes it if there is no such file; with --compile-graph it is compiled too.
	void OpenGraphFromSwitch(StringView full)
	{
		if (!File.Exists(full))
		{
			let saved = scope String(mBrowsePath);
			Path.GetDirectoryPath(full, mBrowsePath..Clear()).IgnoreError();
			let graphName = scope String();
			Path.GetFileNameWithoutExtension(full, graphName);
			CreateGraphAsset(graphName);
			mBrowsePath.Set(saved);
		}
		else
			OpenGraph(full);
		if (HasArg("--compile-graph"))
			CompileGraph();
	}

	/// Test switches for the terrain brush: --brush <0-4> picks a tool, --brush-preview "x,z" or "x,z,size" shows its
	/// preview there.
	void ApplyBrushSwitches()
	{
		let brushArg = scope String();
		if (GetArg("--brush", brushArg) && (int32.Parse(brushArg) case .Ok(let tool)))
			mBrushTool = Math.Clamp(tool, 0, 4);
		if (!GetArg("--brush-preview", brushArg))
			return;
		var parts = brushArg.Split(',');
		if ((parts.GetNext() case .Ok(let xText)) && (parts.GetNext() case .Ok(let zText)) && (float.Parse(xText) case .Ok(let x)) && (float.Parse(zText) case .Ok(let z)))
		{
			mBrushTestPoint = .(x, 0, z);
			mBrushTest = true;
			if ((parts.GetNext() case .Ok(let sizeText)) && (float.Parse(sizeText) case .Ok(let brushSize)))
				mBrushSize = Math.Clamp(brushSize, 1, 40);
		}
	}

	void RunFoliageUndoTest()
	{
		let foliage = mScene.FindComponent<Foliage>();
		if (!foliage)
		{
			Log.Error("UNDO-TEST FAIL: the scene has no Foliage");
			return;
		}
		ResetUndo();
		let n0 = foliage.Count;
		foliage.Paint(foliage.Transform.Position + Vector3(5, 0, 5), 4);
		MarkDirty();
		mUndoPending = false;
		CommitSceneStep();
		let n1 = foliage.Count;
		foliage.Paint(foliage.Transform.Position + Vector3(20, 0, 5), 4);
		MarkDirty();
		mUndoPending = false;
		CommitSceneStep();
		let n2 = foliage.Count;
		Undo();
		let u1 = mScene.FindComponent<Foliage>();
		let afterOne = u1 ? u1.Count : -1;
		Undo();
		let u2 = mScene.FindComponent<Foliage>();
		let afterTwo = u2 ? u2.Count : -1;
		Redo();
		let r1 = mScene.FindComponent<Foliage>();
		let afterRedo = r1 ? r1.Count : -1;
		let pass = n1 > n0 && n2 > n1 && afterOne == n1 && afterTwo == n0 && afterRedo == n1 && u1 == foliage && u2 == foliage && r1 == foliage;
		Log.Info(scope $"UNDO-TEST {pass ? "PASS" : "FAIL"}: plants {n0} -> {n1} -> {n2}; undo {afterOne}, undo {afterTwo}, redo {afterRedo}; same component kept: {u1 == foliage && u2 == foliage && r1 == foliage}");
	}

	protected override void OnShutdown()
	{
		// A rig being made is kept (RigEditor.bf).
		StopRig();
		AssetPreviews.Shutdown();
		if (mCheckThread != null)
			mCheckThread.Join();
		if (mScene != null && mPlay != .Edit)
			mScene.StopPlay();
		if (Gfx.Initialized)
			ImGui.tn_imgui_shutdown();
	}

	protected override void OnEvent(ref SDL.Event event)
	{
		// While a game has the mouse locked, the editor's own panels must not see it move or click.
		if (!Input.HiddenFromInterface(event.type))
			ImGui.tn_imgui_event(&event);
		// Files dragged in from the desktop file manager are copied into the folder shown in Project.
		if (event.type == 0x1000)
		{
			let file = *(char8**)((uint8*)&event + 40);
			if (file != null)
				ImportExternalFile(StringView(file));
		}
	}

	protected override void OnFixedUpdate()
	{
		if (mPlay == .Playing)
		{
			Input.Enabled = mGameFocused;
			mScene.FixedUpdate();
			Input.Enabled = true;
		}
	}

	/// A game quitting (Application.Quit, or Running = false) stops Play rather than closing the editor.
	protected override bool OnQuitRequested()
	{
		if (mPlay == .Edit)
			return false;
		mStopPlayRequested = true;
		return true;
	}

	protected override void OnUpdate()
	{
		TickDragTest();
		if (mStopPlayRequested)
		{
			mStopPlayRequested = false;
			StopPlay();
		}
		PollScriptReload();
		PollProjectFolders();
		// A game changing scene: only while playing, so that the scene being edited is never replaced.
		if (mPlay == .Playing)
		{
			SaveSystem.Update();
			SceneManager.Update(mScene);
		}
		let gameCamera = FindGameCamera();
		VoxelTerrain.ViewerPosition = (mPlay != .Edit && gameCamera) ? gameCamera.Transform.Position : mCamPosition;
		Camera.ViewerPosition = VoxelTerrain.ViewerPosition;
		if (mPlay != .Paused)
		{
			Input.Enabled = mPlay == .Playing && mGameFocused;
			mScene.Update();
			Input.Enabled = true;
		}
		// A game may lock the mouse only while its view is being played in. Escape always gives the pointer back.
		if (Input.CursorLocked && Input.GetKeyDown(.Escape))
			mLockHeldOff = true;
		if (mPlay != .Playing)
			mLockHeldOff = false;
		Input.LockAllowed = mPlay == .Playing && mGameFocused && mLockMouse && !mLockHeldOff;
	}

	/// Starts the Scene view near the game camera so a freshly opened scene shows its content.
	void AlignSceneCameraToGameCamera()
	{
		let camera = FindGameCamera();
		if (!camera)
			return;
		let euler = camera.Transform.EulerAngles;
		mCamPitch = Mathf.Clamp(euler.x + 8, -89, 89);
		mCamYaw = euler.y;
		let rotation = Quaternion.Euler(mCamPitch, mCamYaw, 0);
		mCamPosition = camera.Transform.Position - rotation * Vector3.Forward * 6.0f + Vector3(0, 2, 0);
	}

	Camera FindGameCamera() => mScene.ViewCamera;

	protected override void OnRender()
	{
		bgfx.set_view_clear(0, 0x0003, 0x1e1e1eff, 1.0f, 0);
		bgfx.touch(0);

		ImGui.tn_imgui_new_frame();
		DrawUI();
		// Hidden dock tabs do not need a second scene render or editor gizmos.
		UpdateModelShowOnly();
		mSceneView.shading = mSceneShading;
		SyncModelReferences();
		if (mSceneVisible || AnyModelViewVisible)
			BuildGizmos();
		if (mSceneVisible)
		{
			mSceneView.Render(mScene, mSceneCamera);
		}
		RenderModelViews();

		AssetPreviews.Update();
		let gameCamera = FindGameCamera();
		if (mGameVisible && gameCamera)
		{
			mGameView.Render(mScene, gameCamera.GetCameraData(mGameSize.x / Math.Max(mGameSize.y, 1)));
		}
		ImGui.tn_imgui_render(ImGuiView);

		// Long blocking jobs run after a frame that shows the "working" message has been presented.
		if (mBusyFrames > 0 && --mBusyFrames == 0)
		{
			// Clear the previous operation before dispatch: actions may set a
			// new status that must remain visible while asynchronous work runs.
			mStatus.Clear();
			if (mWantRebuild)
				RebuildAndReload();
			if (mWantBuildGame)
				BuildGame();
			if (mWantFullRestart)
				FullRebuildAndRestart();
			mWantFullRestart = false;
			mWantRebuild = false;
			mWantBuildGame = false;
		}
	}
}
