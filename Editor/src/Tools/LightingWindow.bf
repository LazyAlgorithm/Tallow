using System;
using System.Threading;
using Tallow;

namespace Tallow.Editor;

/// Window > Lighting: bakes the scene's lighting (docs/baked-lighting.md) on the machine's spare cores while the editor
/// keeps running, then points the scene at the lightmaps and light probes it made (save the scene to keep them).
/// It also places probes (ProbePlacementTools.bf).
/// Switches: --lighting-window opens it, --bake-lighting bakes the scene at start-up and logs BAKE: and the result.
extension EditorApp
{
	bool mShowLighting;
	LightBaker mBaker ~ delete _;
	Thread mBakeThread;
	Scene mBakeScene;
	bool mBakeFinished;
	String mBakeReport = new .() ~ delete _;
	bool mBakeReportBad;
	// --bake-lighting: bake once the scene has drawn a frame, then log.
	int32 mBakeAtStart;

	static readonly StringView[8] sBakeStages = .("Preparing", "Building the scene's rays", "Direct light", "Gathering", "Bouncing", "Light probes", "Finishing", "Done");

	void ApplyLightingSwitches()
	{
		if (HasArg("--lighting-window"))
			mShowLighting = true;
		if (HasArg("--bake-lighting"))
			mBakeAtStart = 3;
	}

	int BakedRendererCount()
	{
		var count = 0;
		for (let renderer in mScene.Renderers)
		{
			if (renderer.bakedLighting)
				count++;
		}
		return count;
	}

	public bool Baking => mBaker != null;

	void StartBake()
	{
		if (Baking || Placing || mPlay != .Edit)
			return;
		let settings = scope BakeSettings();
		settings.FromScene(mScene.Environment);
		mBaker = new LightBaker(mScene, settings);
		mBakeScene = mScene;
		mBakeFinished = false;
		mBakeReport.Clear();
		let baker = mBaker;
		mBakeThread = new Thread(new () =>
			{
				baker.Run();
				mBakeFinished = true;
			});
		mBakeThread.SetName("LightBaker");
		mBakeThread.Start(false);
	}

	void CancelBake()
	{
		if (!Baking)
			return;
		mBaker.Cancel = true;
		mBakeThread.Join();
		DeleteAndNullify!(mBakeThread);
		DeleteAndNullify!(mBaker);
		mBakeReport.Set("Baking was stopped; the scene's lighting is as it was.");
		mBakeReportBad = true;
	}

	/// Each frame: picks up a finished bake (or drops one whose scene went away).
	void TickBake()
	{
		if (mBakeAtStart > 0 && --mBakeAtStart == 0)
		{
			StartBake();
			if (Baking)
			{
				// At start-up the bake is waited for, so the frames after it show the result. Not by joining: the
				// thread is joined below, and joining one twice can hang.
				while (!Volatile.Read(ref mBakeFinished))
					Thread.Sleep(5);
			}
		}
		if (!Baking)
			return;
		if (mBakeScene != mScene || mPlay != .Edit)
		{
			CancelBake();
			return;
		}
		if (!mBakeFinished)
			return;
		mBakeThread.Join();
		DeleteAndNullify!(mBakeThread);
		mBakeReport.Clear();
		let folder = LightBaker.FolderFor(mScene, .. scope .());
		mBakeReportBad = !mBaker.Apply(mScene, folder, mBakeReport);
		DeleteAndNullify!(mBaker);
		MarkDirty();
		Log.Info(scope $"BAKE: {mBakeReport}");
	}

	void DrawLightingWindow()
	{
		TickPlacement();
		TickBake();
		if (!mShowLighting)
			return;
		let viewport = ImGui.GetMainViewport();
		ImGui.SetNextWindowPos(.(viewport.workPos.x + viewport.workSize.x - 760, viewport.workPos.y + 80), 4);
		ImGui.SetNextWindowSize(.(380, 720), 4);
		if (ImGui.Begin("Lighting", &mShowLighting))
		{
			let env = mScene.Environment;
			ImGui.TextWrapped("Bakes light that bounces round the scene into lightmaps on objects with Baked Lighting ticked, and into light probes for everything else.");
			ImGui.SeparatorText("Settings (saved with the scene)");
			ImGui.BeginDisabled(Baking);
			var changed = false;
			changed |= ImGui.DragFloat("Texels per Metre", ref env.bakeTexelsPerMetre, 0.25f, 0.25f, 128, "%.2f");
			changed |= ImGui.DragInt("Rays per Texel", ref env.bakeSamples, 4, 4, 4096);
			changed |= ImGui.DragInt("Bounces", ref env.bakeBounces, 0.1f, 0, 16);
			changed |= ImGui.Checkbox("Light Probes", ref env.bakeProbes);
			if (env.bakeProbes)
				changed |= ImGui.DragFloat("Probe Spacing (m)", ref env.bakeProbeSpacing, 0.1f, 0.25f, 100, "%.2f");
			if (changed)
				MarkDirty();
			ImGui.EndDisabled();

			ImGui.SeparatorText("Bake");
			let count = BakedRendererCount();
			var bakedOnly = 0;
			for (let light in mScene.Lights)
			{
				if (light.bakedOnly)
					bakedOnly++;
			}
			ImGui.Text(scope $"{count} object{count == 1 ? "" : "s"} with Baked Lighting, {bakedOnly} Baked Only light{bakedOnly == 1 ? "" : "s"}");
			if (count == 0)
				ImGui.TextColored(EditorTheme.Warning, "Tick Baked Lighting on the Mesh Renderers of things that never move.");
			let selected = Selected;
			ImGui.BeginDisabled(selected == null || Baking);
			if (ImGui.Button("Tick Baked Lighting on Selected"))
			{
				MarkBaked(selected.Transform, true);
				MarkDirty();
			}
			ImGui.EndDisabled();
			if (Baking)
			{
				let stage = (int)mBaker.CurrentStage;
				ImGui.ProgressBar(mBaker.Progress, .(-1, 0), scope $"{sBakeStages[stage]}: {(int)(mBaker.Progress * 100)}%" .CStr());
				if (ImGui.Button("Cancel", .(-1, 0)))
					CancelBake();
			}
			else
			{
				ImGui.BeginDisabled(count == 0 || mPlay != .Edit);
				if (ImGui.Button("Bake", .(-1, 0)))
					StartBake();
				ImGui.EndDisabled();
				if (ImGui.Button("Clear Baked Lighting", .(-1, 0)))
				{
					LightBaker.Clear(mScene);
					mBakeReport.Set("The scene's baked lighting is cleared (the files are left where they are).");
					mBakeReportBad = false;
					MarkDirty();
				}
			}
			if (!mBakeReport.IsEmpty)
				ImGui.TextColored(mBakeReportBad ? EditorTheme.Error : EditorTheme.Good, mBakeReport.CStr());

			DrawProbePlacement();

			ImGui.SeparatorText("View");
			ImGui.Checkbox("Show Baked Lighting", ref RenderView.UseBakedLighting);
			if (!env.lightProbes.IsEmpty)
				ImGui.TextDisabled(scope $"Probes: {env.lightProbes}" .CStr());
		}
		ImGui.End();
	}

	/// Ticks (or unticks) Baked Lighting on an object's renderers and its children's.
	void MarkBaked(Transform transform, bool baked)
	{
		let renderer = transform.GameObject.GetComponent<MeshRenderer>();
		if (renderer)
			renderer.bakedLighting = baked;
		for (let child in transform.Children)
			MarkBaked(child, baked);
	}
}
