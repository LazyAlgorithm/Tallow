using System;
using System.Threading;
using Tallow;

namespace Tallow.Editor;

/// Window > Lighting's Place Probes (docs/probe-placement.md): looks at the scene on a background thread, shows the
/// probes it would place in the Scene view, and places them (one undo step) or throws the preview away.
/// Switch: --place-probes places them at start-up (before --bake-lighting bakes) and logs PLACE: and the result.
extension EditorApp
{
	ProbePlacementSettings mPlacementSettings = new .() ~ delete _;
	ProbePlacer mPlacer ~ delete _;
	Thread mPlaceThread;
	bool mPlaceFinished;
	Scene mPlaceScene;
	// The finished preview, waiting to be placed or discarded.
	ProbePlan mPlacementPlan ~ delete _;
	String mPlaceReport = new .() ~ delete _;
	// --place-probes: place once the scene has drawn a frame, and at once (no preview).
	int32 mPlaceAtStart;
	bool mPlaceAtOnce;

	public bool Placing => mPlacer != null;

	void ApplyPlacementSwitches()
	{
		if (HasArg("--place-probes"))
		{
			mPlaceAtStart = 2;
			mPlaceAtOnce = true;
		}
	}

	void StartPlacement()
	{
		if (Placing || Baking || mPlay != .Edit)
			return;
		DeleteAndNullify!(mPlacementPlan);
		mPlacementSettings.openSpacing = mScene.Environment.bakeProbeSpacing;
		mPlacer = new ProbePlacer(mScene, mPlacementSettings);
		mPlaceScene = mScene;
		mPlaceFinished = false;
		mPlaceReport.Clear();
		let placer = mPlacer;
		mPlaceThread = new Thread(new () =>
			{
				placer.Run();
				mPlaceFinished = true;
			});
		mPlaceThread.SetName("ProbePlacer");
		mPlaceThread.Start(false);
	}

	void CancelPlacement()
	{
		if (!Placing)
			return;
		mPlacer.Cancel = true;
		mPlaceThread.Join();
		DeleteAndNullify!(mPlaceThread);
		DeleteAndNullify!(mPlacer);
		mPlaceReport.Set("Placing was stopped.");
	}

	/// Each frame: picks up a finished look at the scene as a preview (or places it at once for --place-probes).
	void TickPlacement()
	{
		if (mPlaceAtStart > 0 && --mPlaceAtStart == 0)
		{
			StartPlacement();
			// Waited for without joining: the thread is joined below, and joining one twice can hang.
			if (Placing)
			{
				while (!Volatile.Read(ref mPlaceFinished))
					Thread.Sleep(5);
			}
		}
		if (mPlacementPlan != null && mPlaceScene != mScene)
			DeleteAndNullify!(mPlacementPlan);
		if (!Placing)
			return;
		if (mPlaceScene != mScene || mPlay != .Edit)
		{
			CancelPlacement();
			return;
		}
		if (!mPlaceFinished)
			return;
		mPlaceThread.Join();
		DeleteAndNullify!(mPlaceThread);
		mPlacementPlan = mPlacer.Plan;
		mPlacer.Plan = null;
		DeleteAndNullify!(mPlacer);
		mPlaceReport.Clear();
		mPlacementPlan.Describe(mPlaceReport);
		if (mPlaceAtOnce)
		{
			mPlaceAtOnce = false;
			CommitPlacement();
			Log.Info(scope $"PLACE: {mPlaceReport}");
		}
	}

	/// Makes the previewed probes, in place of those placed before.
	void CommitPlacement()
	{
		if (mPlacementPlan == null)
			return;
		let removed = ProbePlacer.Apply(mScene, mPlacementPlan);
		mPlaceReport.Clear();
		mPlaceReport.Append("Placed ");
		mPlacementPlan.Describe(mPlaceReport);
		if (removed > 0)
			mPlaceReport.AppendF(" Took away {} placed before.", removed);
		mPlaceReport.Append(" Bake to fill the light probe volumes.");
		DeleteAndNullify!(mPlacementPlan);
		mSelectedId = 0;
		MarkDirty();
	}

	int PlacedProbeCount()
	{
		var count = 0;
		for (let gameObject in mScene.FindAllWithTag(ProbePlacer.Tag, .. scope .()))
		{
			if (gameObject.GetComponent<ReflectionProbe>() != null || gameObject.GetComponent<LightProbeVolume>() != null)
				count++;
		}
		return count;
	}

	/// The Place Probes part of the Lighting window.
	void DrawProbePlacement()
	{
		ImGui.SeparatorText("Place Probes");
		ImGui.TextWrapped("Looks at the scene and places reflection probes and light probe volumes where they make sense. They are ordinary objects under Placed Probes: move or delete them, or take the Placed Probe tag off one to keep it when placing again.");
		let settings = mPlacementSettings;
		ImGui.BeginDisabled(Placing || Baking);
		ImGui.Checkbox("Reflection Probes", ref settings.reflectionProbes);
		if (settings.reflectionProbes)
		{
			ImGui.Indent();
			ImGui.Checkbox("Only Where Something Is Shiny", ref settings.onlyWhereShiny);
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("Leaves rooms and open ground out when nothing in them is metallic or smoother than Shiny Roughness:\nthey mirror so little that the sky's reflection does.");
			if (settings.onlyWhereShiny)
				ImGui.DragFloat("Shiny Roughness", ref settings.shinyRoughness, 0.01f, 0, 1, "%.2f");
			ImGui.Checkbox("Doorways", ref settings.doorways);
			ImGui.DragFloat("Open Probe Size (m)", ref settings.openProbeSize, 1, 4, 500, "%.0f");
			ImGui.Unindent();
		}
		ImGui.Checkbox("Light Probe Volumes", ref settings.lightProbes);
		if (settings.lightProbes)
		{
			ImGui.Indent();
			ImGui.DragFloat("Detail Spacing (m)", ref settings.detailSpacing, 0.05f, 0.25f, 10, "%.2f");
			ImGui.DragFloat("Light Change / m", ref settings.lightChange, 0.01f, 0.02f, 4, "%.2f");
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("How quickly light has to change for closer probes: lower places more volumes.");
			ImGui.TextDisabled("Open space uses the Probe Spacing above.");
			ImGui.Unindent();
		}
		ImGui.EndDisabled();

		if (Placing)
		{
			ImGui.ProgressBar(mPlacer.Progress, .(-1, 0), scope $"Looking at the scene: {(int)(mPlacer.Progress * 100)}%" .CStr());
			if (ImGui.Button("Cancel##placing", .(-1, 0)))
				CancelPlacement();
		}
		else if (mPlacementPlan != null)
		{
			ImGui.TextColored(EditorTheme.Good, "Preview (shown in the Scene view):");
			ImGui.TextWrapped(mPlaceReport.CStr());
			if (ImGui.Button("Place", .(ImGui.GetContentRegionAvail().x * 0.5f - 4, 0)))
				CommitPlacement();
			ImGui.SameLine();
			if (ImGui.Button("Discard", .(-1, 0)))
			{
				DeleteAndNullify!(mPlacementPlan);
				mPlaceReport.Set("The preview was thrown away.");
			}
		}
		else
		{
			ImGui.BeginDisabled(Baking || mPlay != .Edit);
			if (ImGui.Button("Preview Placement", .(-1, 0)))
				StartPlacement();
			ImGui.EndDisabled();
			if (!mPlaceReport.IsEmpty)
				ImGui.TextWrapped(mPlaceReport.CStr());
		}
		let placed = PlacedProbeCount();
		ImGui.BeginDisabled(placed == 0 || Placing);
		if (ImGui.Button(scope $"Remove Placed Probes ({placed})" .CStr(), .(-1, 0)))
		{
			ProbePlacer.Remove(mScene);
			mSelectedId = 0;
			mPlaceReport.Set("The placed probes are taken away.");
			MarkDirty();
		}
		ImGui.EndDisabled();
	}

	/// The preview's boxes in the Scene view: reflection probes blue with where they see from, volumes amber.
	void BuildProbePlacementGizmos()
	{
		if (mPlacementPlan == null)
			return;
		for (let probe in mPlacementPlan.reflections)
		{
			let tint = Color(0.35f, 0.8f, 1.0f, 0.9f);
			Gizmos.Lines.Box(probe.area, .Identity, tint);
			let eye = probe.eye;
			Gizmos.Lines.Line(eye - .(0.3f, 0, 0), eye + .(0.3f, 0, 0), tint);
			Gizmos.Lines.Line(eye - .(0, 0.3f, 0), eye + .(0, 0.3f, 0), tint);
			Gizmos.Lines.Line(eye - .(0, 0, 0.3f), eye + .(0, 0, 0.3f), tint);
		}
		for (let volume in mPlacementPlan.volumes)
			Gizmos.Lines.Box(volume.area, .Identity, Color(1.0f, 0.75f, 0.3f, 0.7f));
	}
}
