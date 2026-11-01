using System;
using System.Collections;
using System.IO;
using Tallow;
using Bgfx;

namespace Tallow.Editor;

/// Per-frame editor UI: dock layout, menu bar and toolbar.
extension EditorApp
{
	static ProfilerMarker sUIMarker = .("Editor.DrawUI", .Editor);

	void DrawUI()
	{
		UpdateProfiler();
		sUIMarker.Begin();
		defer Profiler.End();
		// Outside play mode the Scene view's camera is the listener, so sounds can be auditioned where you look from.
		Audio.EditorListening = mPlay == .Edit;
		if (Audio.EditorListening)
		{
			let look = Quaternion.Euler(mCamPitch, mCamYaw, 0);
			Audio.SetListener(mCamPosition, look * Vector3.Forward, look * Vector3.Up);
		}
		DrawMenuBar();
		DrawToolbar();

		let viewport = ImGui.GetMainViewport();
		let dockId = ImGui.GetID("TesseraDock");
		if (!mLayoutBuilt || mResetLayout)
		{
			BuildDefaultLayout(dockId, viewport.workSize);
			mLayoutBuilt = true;
			mResetLayout = false;
		}
		SaveOpenWindows();
		// Leave room for the toolbar strip under the menu bar.
		let toolbarHeight = ImGui.GetFrameHeight() + 10;
		ImGui.SetNextWindowPos(.(viewport.workPos.x, viewport.workPos.y + toolbarHeight));
		ImGui.SetNextWindowSize(.(viewport.workSize.x, viewport.workSize.y - toolbarHeight));
		ImGui.PushStyleVar(ImGui.StyleVar.WindowPadding, ImGui.Vec2(0, 0));
		ImGui.Begin("##DockHost", null, ImGui.WindowFlags.NoDecoration | ImGui.WindowFlags.NoMove | ImGui.WindowFlags.NoDocking
			| ImGui.WindowFlags.NoBringToFrontOnFocus | ImGui.WindowFlags.NoNavFocus | ImGui.WindowFlags.NoSavedSettings | ImGui.WindowFlags.NoBackground);
		ImGui.PopStyleVar();
		DockSpace(dockId);
		ImGui.End();

		DrawHierarchy();
		DrawInspector();
		DrawProject();
		DrawConsole();
		DrawGameView();
		DrawSceneView();
		DrawModelViews();
		DrawScripts();
		DrawGraph();
		DrawBehavior();
		DrawDialogue();
		DrawSequencer();
		DrawAnimator();
		DrawAnimation();
		DrawHandPosing();
		DrawBoneMap();
		DrawUIEditor();
		DrawPopups();
		DrawProjectSettings();
		DrawBuildWindow();
		DrawAchievements();
		DrawInputActions();
		DrawModelWindow();
		DrawQualityWindow();
		DrawProfilerWindow();
		DrawWorldMapWindow();
		DrawPreferencesWindow();
		DrawLightingWindow();
		DrawRigWindow();
		CommitUndoWhenIdle();
		if (mShowScene)
		{
			ImGui.SetWindowFocus("Scene");
			mShowScene = false;
		}
		if (mFocusScene && Time.FrameCount > 4)
		{
			// Scene is the tab shown when the editor opens, whatever tab the saved layout had in
			// front. Repeated for a few frames because docking settles over the first frames.
			if (mScripts.Count == 0 && mGraph == null && mUiData == null)
				ImGui.SetWindowFocus("Scene");
			if (Time.FrameCount > 10)
				mFocusScene = false;
		}
		// The Inspector in front of the tabs docked with it, for a few frames while docking settles.
		if (mFocusInspector > 0)
		{
			mFocusInspector--;
			if (mRig == null && !mFocusRig)
				ImGui.SetWindowFocus("Inspector");
		}
		if (mFocusGame && Time.FrameCount > 3)
		{
			// Bring the Game tab forward once every panel exists this frame.
			ImGui.SetWindowFocus("Game");
			mFocusGame = false;
		}
		HandleShortcuts();
	}

	[CLink] static extern uint32 igDockSpace(uint32 id, ImGui.Vec2 size, int32 flags, void* windowClass);

	void DockSpace(uint32 id)
	{
		igDockSpace(id, .(0, 0), 0, null);
	}

	/// The windows that can be closed, as they are named in the open-windows file. The layout file keeps where they
	/// are docked, but not whether they are open, so that is kept beside it (windows5_<project>.txt).
	static StringView[?] sOpenWindowNames = .("Model", "Rigging", "Animation", "Animator", "Dialogue", "Sequencer", "Map Builder", "UV Editor", "Graphics Quality", "Lighting", "Model Views", "Scripts", "Profiler", "World Map");
	int32 mOpenWindowsSaved = -1;
	bool mRetiredWindow;

	bool* OpenWindowFlag(int index)
	{
		switch (index)
		{
		case 0: return &mShowModel;
		case 1: return &mShowRig;
		case 2: return &mShowAnimation;
		case 3: return &mShowAnimator;
		case 4: return &mShowDialogue;
		case 5: return &mShowSequencer;
		// 6 was the Map Builder window: kept so that saved layouts read the same.
		case 6: return &mRetiredWindow;
		case 7: return &mShowUVEditor;
		case 8: return &mShowQuality;
		case 9: return &mShowLighting;
		case 10: return &mShowModelViews;
		case 12: return &mShowProfiler;
		case 13: return &mShowWorldMap;
		default: return &mShowScripts;
		}
	}

	void OpenWindowsFile(String file)
	{
		file.Append(mIniPath);
		file.Replace("layout5_", "windows5_");
		file.Replace(".ini", ".txt");
	}

	int32 OpenWindowsMask()
	{
		int32 mask = 0;
		for (int i < sOpenWindowNames.Count)
		{
			if (*OpenWindowFlag(i))
				mask |= 1 << i;
		}
		return mask;
	}

	/// Opens the windows that were open last time; with nothing saved yet, the default layout's (Model and Rigging).
	void LoadOpenWindows()
	{
		let text = scope String();
		if (File.ReadAllText(OpenWindowsFile(.. scope .()), text) case .Ok)
		{
			for (int i < sOpenWindowNames.Count)
			{
				bool open = false;
				for (var line in text.Split('\n'))
				{
					line.Trim();
					open |= line == sOpenWindowNames[i];
				}
				*OpenWindowFlag(i) = open;
			}
		}
		else
		{
			// The first time: the Model and Rigging windows beside the Inspector, Model Views and Scripts beside the Scene view.
			mShowModel = mShowRig = mShowModelViews = mShowScripts = true;
			mDockModelViews = mDockScripts = true;
		}
		mOpenWindowsSaved = OpenWindowsMask();
	}

	/// Writes which windows are open when that changes.
	void SaveOpenWindows()
	{
		let mask = OpenWindowsMask();
		if (mask == mOpenWindowsSaved)
			return;
		mOpenWindowsSaved = mask;
		let text = scope String();
		for (int i < sOpenWindowNames.Count)
		{
			if ((mask & (1 << i)) != 0)
				text.AppendF("{}\n", sOpenWindowNames[i]);
		}
		File.WriteAllText(OpenWindowsFile(.. scope .()), text).IgnoreError();
	}

	void BuildDefaultLayout(uint32 dockId, ImGui.Vec2 size)
	{
		ImGui.DockBuilderRemoveNode(dockId);
		ImGui.DockBuilderAddNode(dockId, ImGui.DockFlags.DockSpace);
		ImGui.DockBuilderSetNodeSize(dockId, size);
		uint32 left, right, bottom, center, rest;
		ImGui.DockBuilderSplitNode(dockId, ImGui.Dir.Left, 0.17f, out left, out rest);
		ImGui.DockBuilderSplitNode(rest, ImGui.Dir.Right, 0.26f, out right, out rest);
		ImGui.DockBuilderSplitNode(rest, ImGui.Dir.Down, 0.28f, out bottom, out center);
		mAssetCenterDock = center;
		mBottomDock = bottom;
		ImGui.DockBuilderDockWindow("Hierarchy", left);
		// The Model and Rigging windows are tabs beside the Inspector (which stays the tab shown).
		ImGui.DockBuilderDockWindow("Inspector", right);
		ImGui.DockBuilderDockWindow("Model", right);
		ImGui.DockBuilderDockWindow("Rigging", right);
		mShowModel = true;
		mShowRig = true;
		mDockModel = mDockRig = false;
		mFocusInspector = 5;
		ImGui.DockBuilderDockWindow("Project", bottom);
		ImGui.DockBuilderDockWindow("Console", bottom);
		// Tab order follows docking order: Game, Scene, then Scripts on the far right.
		ImGui.DockBuilderDockWindow("Game", center);
		ImGui.DockBuilderDockWindow("Scene", center);
		ImGui.DockBuilderDockWindow("Model Views", center);
		ImGui.DockBuilderDockWindow("Scripts", center);
		mShowModelViews = mShowScripts = true;
		mFocusScene = true;
		ImGui.DockBuilderFinish(dockId);
	}

	void DrawMenuBar()
	{
		if (!ImGui.BeginMainMenuBar())
			return;
		if (ImGui.BeginMenu("File"))
		{
			if (ImGui.MenuItem("New Scene"))
				NewScene();
			if (ImGui.MenuItem("Save Scene", "Ctrl+S"))
				SaveScene();
			if (ImGui.MenuItem("Save Scene As..."))
				mOpenSaveAs = true;
			ImGui.Separator();
			if (ImGui.MenuItem("Reload Scripts", "Ctrl+R"))
				RequestRebuild();
			if (ImGui.MenuItem("Full Rebuild & Restart"))
			{
				SaveAllScripts();
				mWantFullRestart = true;
				mBusyFrames = 3;
			}
			if (ImGui.MenuItem("Project Settings..."))
				mShowSettings = true;
			if (ImGui.MenuItem("Build..."))
				OpenBuildWindow();
			ImGui.Separator();
			if (ImGui.MenuItem("Open Project Folder"))
			{
				Terminal.Open(Project.Current.Path);
			}
			if (ImGui.MenuItem("Exit"))
				Close();
			ImGui.EndMenu();
		}
		if (ImGui.BeginMenu("Edit"))
		{
			if (ImGui.MenuItem("Undo", "Ctrl+Z", false, CanUndo))
				Undo();
			if (ImGui.MenuItem("Redo", "Ctrl+Y", false, CanRedo))
				Redo();
			ImGui.Separator();
			if (ImGui.MenuItem("Duplicate", "Ctrl+D", false, Selected != null))
				DuplicateSelected();
			if (ImGui.MenuItem("Delete", "Del", false, Selected != null))
				DeleteSelected();
			if (ImGui.MenuItem("Frame Selected", "F", false, Selected != null))
				FocusSelected();
			if (ImGui.MenuItem("Drop to Surface", "End", false, Selected != null))
				DropToSurface(Selected);
			if (ImGui.MenuItem("Snap to Grid", null, false, Selected != null))
				SnapSelectedToGrid();
			if (ImGui.MenuItem("Turn 90 Degrees", null, false, Selected != null))
				TurnSelected(90);
			ImGui.Separator();
			if (ImGui.MenuItem("Preferences..."))
				mShowPreferences = true;
			ImGui.Separator();
			if (ImGui.MenuItem("Play / Stop", "Ctrl+P"))
				TogglePlay();
			ImGui.EndMenu();
		}
		if (ImGui.BeginMenu("GameObject"))
		{
			DrawCreateMenu();
			ImGui.EndMenu();
		}
		if (ImGui.BeginMenu("Window"))
		{
			if (ImGui.MenuItem("Achievements"))
				mShowAchievements = true;
			if (ImGui.MenuItem("Input Actions"))
				mShowInputActions = true;
			if (ImGui.MenuItem("Animator"))
			{
				mShowAnimator = true;
				mDockAnimator = true;
			}
			if (ImGui.MenuItem("Animation"))
				mShowAnimation = true;
			if (ImGui.MenuItem("Dialogue"))
			{
				mShowDialogue = true;
				mDockDialogue = true;
			}
			if (ImGui.MenuItem("Sequencer"))
			{
				mShowSequencer = true;
				mDockSequencer = true;
			}
			if (ImGui.MenuItem("Model Views", null, mShowModelViews))
				mShowModelViews = mFocusModelViews = !mShowModelViews;
			if (ImGui.MenuItem("Model", null, mShowModel))
			{
				mShowModel = !mShowModel;
				mDockModel = mModelFocus = mShowModel;
			}
			if (ImGui.MenuItem("UV Editor", null, mShowUVEditor))
				mShowUVEditor = !mShowUVEditor;
			if (ImGui.MenuItem("Graphics Quality", null, mShowQuality))
				mShowQuality = !mShowQuality;
			if (ImGui.MenuItem("Profiler", null, mShowProfiler))
				mShowProfiler = !mShowProfiler;
			if (ImGui.MenuItem("World Map", null, mShowWorldMap))
				mShowWorldMap = !mShowWorldMap;
			if (ImGui.MenuItem("Lighting", null, mShowLighting))
				mShowLighting = !mShowLighting;
			if (ImGui.MenuItem("Rigging", null, mShowRig))
			{
				mShowRig = !mShowRig;
				mDockRig = mFocusRig = mShowRig;
			}
			if (ImGui.MenuItem("Reset Layout"))
				mResetLayout = true;
			if (ImGui.MenuItem("Scene Grid", null, mShowGrid))
				mShowGrid = !mShowGrid;
			if (ImGui.MenuItem("Scene Occlusion Culling", null, mSceneOcclusion))
				mSceneOcclusion = !mSceneOcclusion;
			if (ImGui.MenuItem("Occlusion Picture", null, mShowOcclusionPicture))
				mShowOcclusionPicture = !mShowOcclusionPicture;
			ImGui.EndMenu();
		}
		let label = scope String();
		label.AppendF("{}{}  |  {:0} fps", mScene.Name, mDirty ? "*" : "", Time.SmoothedFps);
		let width = ImGui.CalcTextSize(label.CStr()).x;
		ImGui.SetCursorPosX(ImGui.GetWindowWidth() - width - 16);
		ImGui.TextDisabled(label.CStr());
		ImGui.EndMainMenuBar();
	}

	void DrawCreateMenu()
	{
		for (let kind in StringView[?]("Create Empty", "Spawn Point", "Audio Source", "Folder"))
		{
			if (ImGui.MenuItem(scope String(kind).CStr()))
				CreateBuiltin(kind);
		}
		if (ImGui.BeginMenu("3D Object"))
		{
			for (let kind in StringView[?]("Cube", "Sphere", "Capsule", "Cylinder", "Cone", "Plane", "Quad"))
			{
				if (ImGui.MenuItem(scope String(kind).CStr()))
					CreateBuiltin(kind);
			}
			ImGui.EndMenu();
		}
		if (ImGui.BeginMenu("Light"))
		{
			for (let kind in StringView[?]("Directional Light", "Point Light", "Spot Light"))
			{
				if (ImGui.MenuItem(scope String(kind).CStr()))
					CreateBuiltin(kind);
			}
			ImGui.EndMenu();
		}
		for (let kind in StringView[?]("Camera", "Decal", "Reflection Probe", "Light Probe Volume", "Particle System", "Destructible Voxel Object", "Voxel Terrain", "Network Session"))
		{
			if (ImGui.MenuItem(scope String(kind).CStr()))
				CreateBuiltin(kind);
		}
		if (ImGui.BeginMenu("Water"))
		{
			for (let kind in StringView[?]("Water", "Water (Low Poly)", "Ocean", "Ocean (Low Poly)"))
			{
				if (ImGui.MenuItem(scope String(kind).CStr()))
					CreateBuiltin(kind);
			}
			ImGui.EndMenu();
		}
		ImGui.Separator();
		DrawAssetCreateMenu("Prefabs", true);
		DrawAssetCreateMenu("Models", false);
		if (ImGui.BeginMenu("With Component"))
		{
			mScriptCatalog.Refresh(Assets.ProjectPath, Project.Current.Name);
			for (let category in StringView[?]("Rendering", "Physics", "Animation", "Audio", "UI", "Particles", "World", "Networking", "AI", "Scripts"))
			{
				if (!ImGui.BeginMenu(scope String(category).CStr()))
					continue;
				for (let info in ComponentRegistry.Types)
				{
					if (!mScriptCatalog.IsVisible(info) || ComponentCategory(info.fullName, info.name) != category)
						continue;
					let label = scope String();
					NiceName(info.name, label);
					if (ImGui.MenuItem(scope $"{StringView(ComponentIcon(info.name))}  {label}##{info.fullName}" .CStr()))
						CreateWithComponent(info);
				}
				ImGui.EndMenu();
			}
			ImGui.EndMenu();
		}
		ImGui.Separator();
		if (ImGui.MenuItem("Model...", null, mShowModel))
			mShowModel = !mShowModel;
	}

	/// The project's prefabs or models, one submenu per folder; choosing one puts it in the middle of the Scene view.
	void DrawAssetCreateMenu(char8* title, bool prefabs)
	{
		if (!ImGui.BeginMenu(title))
			return;
		if (!mPaletteListed)
			RefreshPalette();
		for (let folder in mPaletteFolders)
		{
			bool open = false;
			bool any = false;
			for (let relative in mPaletteAssets)
			{
				if (relative.EndsWith(".tprefab") != prefabs || MapPieces.IsPiece(relative))
					continue;
				let slash = relative.LastIndexOf('/');
				if ((slash >= 0 ? relative.Substring(0, slash) : StringView()) != folder)
					continue;
				if (!any)
				{
					any = true;
					open = ImGui.BeginMenu(folder.IsEmpty ? "(project root)" : folder.CStr());
				}
				if (!open)
					break;
				let name = scope String();
				Path.GetFileNameWithoutExtension(relative, name);
				if (ImGui.MenuItem(scope $"{name}##{relative}" .CStr()))
				{
					let made = InstantiateAsset(relative);
					Vector3 point, normal;
					if (made != null && RaycastScene(mSceneCamera.ViewportPointToRay(0.5f, 0.5f), out point, out normal, made, true, 60))
						PlaceOnSurface(made, point, normal, false);
				}
			}
			if (open)
				ImGui.EndMenu();
		}
		if (mPaletteFolders.IsEmpty)
			ImGui.TextDisabled("None in this project");
		ImGui.EndMenu();
	}

	void RequestRebuild()
	{
		mWantRebuild = true;
		mBusyFrames = 3;
		mStatus.Set("Compiling scripts...");
	}

	void TogglePlay()
	{
		if (mPlay == .Edit)
			StartPlay();
		else
			StopPlay();
	}

	void DuplicateSelected()
	{
		let selected = Selected;
		if (selected == null)
			return;
		let copy = Duplicate(selected, selected.Transform.Parent);
		mSelectedId = copy.Id;
		MarkDirty();
	}

	bool ToolButton(char8* label, bool active, float width = 0)
	{
		if (active)
			ImGui.PushStyleColor(ImGui.Col.Button, EditorTheme.Accent);
		let pressed = ImGui.Button(label, .(width, 0));
		if (active)
			ImGui.PopStyleColor();
		return pressed;
	}

	void DrawToolbar()
	{
		let viewport = ImGui.GetMainViewport();
		let height = ImGui.GetFrameHeight() + 10;
		ImGui.SetNextWindowPos(viewport.workPos);
		ImGui.SetNextWindowSize(.(viewport.workSize.x, height));
		ImGui.PushStyleVar(ImGui.StyleVar.WindowPadding, ImGui.Vec2(8, 5));
		ImGui.PushStyleVar(ImGui.StyleVar.WindowBorderSize, 0.0f);
		ImGui.Begin("##Toolbar", null, ImGui.WindowFlags.NoDecoration | ImGui.WindowFlags.NoMove | ImGui.WindowFlags.NoDocking
			| ImGui.WindowFlags.NoSavedSettings | ImGui.WindowFlags.NoBringToFrontOnFocus | ImGui.WindowFlags.NoScrollWithMouse);
		ImGui.PopStyleVar(2);

		if (ToolButton("Move", mGizmoOperation == 0))
			mGizmoOperation = 0;
		ImGui.SameLine();
		if (ToolButton("Rotate", mGizmoOperation == 1))
			mGizmoOperation = 1;
		ImGui.SameLine();
		if (ToolButton("Scale", mGizmoOperation == 2))
			mGizmoOperation = 2;
		ImGui.SameLine();
		if (ToolButton("All", mGizmoOperation == 3))
			mGizmoOperation = 3;
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Move, turn and scale handles together (T).");
		ImGui.SameLine(0, 16);
		if (ImGui.Button(mGizmoLocal ? "Local" : "Global", .(64, 0)))
			mGizmoLocal = !mGizmoLocal;
		ImGui.SameLine(0, 16);
		if (ToolButton("Bones", mShowBones))
			mShowBones = !mShowBones;
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Show a selected rigged model's bones and IK handles, seen through it; click one to select it.\nThe model needs Expose Bones on its Skinned Mesh Renderer.");
		DrawSnapToolbar();

		// Which world state the Scene and Game views show (and, while playing, the game is in).
		if (ProjectConfig.WorldStates.Count > 1)
		{
			ImGui.SameLine(0, 16);
			let current = Math.Clamp(mScene.WorldState, 0, (int32)ProjectConfig.WorldStates.Count - 1);
			ImGui.SetNextItemWidth(150);
			if (ImGui.BeginCombo("##worldstate", scope String(ProjectConfig.WorldStates[current]).CStr()))
			{
				for (int32 i < (int32)ProjectConfig.WorldStates.Count)
				{
					if (ImGui.Selectable(ProjectConfig.WorldStates[i].CStr(), i == current))
						mScene.WorldState = i;
				}
				ImGui.EndCombo();
			}
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("World state shown. Objects outside it are hidden, silent and do not collide, as in the game. Set what each object is in at the top of the Inspector.");
		}

		// Play controls sit in the middle like Unity's.
		let buttonWidth = 64.0f;
		ImGui.SameLine(viewport.workSize.x * 0.5f - buttonWidth * 1.5f - 6);
		// Capture the state first: pressing the button changes it before the matching pop.
		let wasPlaying = mPlay != .Edit;
		if (wasPlaying)
			ImGui.PushStyleColor(ImGui.Col.Button, EditorTheme.Accent);
		if (ImGui.Button(wasPlaying ? Icons.StopLabel : Icons.PlayLabel, .(buttonWidth, 0)))
			TogglePlay();
		if (wasPlaying)
			ImGui.PopStyleColor();
		ImGui.SameLine();
		ImGui.BeginDisabled(mPlay == .Edit);
		if (ToolButton(Icons.PauseLabel, mPlay == .Paused, buttonWidth))
			mPlay = mPlay == .Paused ? .Playing : .Paused;
		ImGui.SameLine();
		if (ImGui.Button(Icons.StepLabel, .(buttonWidth, 0)) && mPlay == .Paused)
		{
			mScene.FixedUpdate();
			mScene.Update();
		}
		ImGui.EndDisabled();
		ImGui.SameLine(0, 16);
		if (ToolButton("Lock Mouse", mLockMouse))
			mLockMouse = !mLockMouse;
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Let the game keep the mouse inside the Game view while you play (games ask with Input.LockCursor). Esc frees it.");

		if (!mStatus.IsEmpty)
		{
			ImGui.SameLine(0, 24);
			ImGui.TextColored(EditorTheme.Warning, mStatus.CStr());
		}
		else if (mScene.Network != null && mScene.Network.Mode != .Offline)
		{
			let network = mScene.Network;
			let text = scope String();
			if (network.IsServer)
				text.AppendF("{}: {} client(s), tick {}, {:0.0} kB/s out, {:0.0} in", network.Mode, network.ClientCount, network.Tick, network.BytesSentPerSecond / 1000.0f, network.BytesReceivedPerSecond / 1000.0f);
			else
				text.AppendF("Client {}: {} corrections, {} bodies predicted, {} ticks ahead, {:0.0} kB/s out, {:0.0} in", network.LocalClientId, network.Rollbacks, network.PredictedBodies, network.PendingInputs, network.BytesSentPerSecond / 1000.0f, network.BytesReceivedPerSecond / 1000.0f);
			ImGui.SameLine(0, 24);
			ImGui.TextDisabled(text.CStr());
		}
		ImGui.End();
	}
}
