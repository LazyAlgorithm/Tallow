using System;
using System.Collections;
using System.Diagnostics;
using Tallow;

namespace Tallow.Editor;

/// Test switch --model-select-bench: times drawing and hovering a big selection in edit mode (a sphere of about
/// 3000 faces, every face picked, then every vertex), logs MODEL-SELECT-BENCH lines (run with --frames 40).
extension EditorApp
{
	int32 mModelBenchFrames = -1;

	void TickModelSelectBench()
	{
		if (mModelBenchFrames < 0)
		{
			mModelBenchFrames = HasArg("--model-select-bench") ? 20 : 0;
			return;
		}
		if (mModelBenchFrames > 0 && --mModelBenchFrames == 0)
			RunModelSelectBench();
	}

	void RunModelSelectBench()
	{
		mCamPosition = .(0, 1.5f, -4);
		mCamYaw = 0;
		mCamPitch = 10;
		UpdateSceneCamera(mSceneSize.x / Math.Max(mSceneSize.y, 1));
		var settings = MeshShapes.Settings();
		settings.size = .(2, 2, 2);
		settings.sides = 64;
		settings.steps = 48;
		let shape = MeshShapes.Create(.Sphere, settings);
		defer delete shape;
		let made = CreateModelObject("Bench Sphere", shape, .Zero);
		let model = GameObject.ComponentOn<ModelMesh>(made);
		let mesh = model.Edit;
		StartModelEditing(made);
		let world = model.Transform.LocalToWorld;
		let toLocal = model.Transform.WorldToLocal;
		let center = ImGui.Vec2(mSceneOrigin.x + mSceneSize.x * 0.5f, mSceneOrigin.y + mSceneSize.y * 0.5f);
		for (int run < 4)
		{
			ModelSelectMode mode = run == 2 ? .Vertex : (run == 3 ? .Edge : .Face);
			SetModelMode(mode, mesh);
			SelectAllModel(mesh, false);
			// The first run picks 500 faces (a selection small enough to be checked for what can be seen).
			if (run == 0)
				mModelFaces.RemoveWhere(scope (f) => f >= 500);
			UpdateModelShown(mesh);
			let watch = scope Stopwatch()..Start();
			let runs = 10;
			for (int i < runs)
			{
				DrawModelSelection(mesh, world, toLocal);
				mModelHover = ModelElementAt(mesh, world, toLocal, center, mModelMode);
			}
			watch.Stop();
			let gizmos = scope Stopwatch()..Start();
			for (int i < runs)
				BuildModelGizmos();
			gizmos.Stop();
			Log.Info(scope $"MODEL-SELECT-BENCH {mode} faces={mesh.faces.Count} verts={mesh.positions.Count} selected={ModelSelectionCount} hover={mModelHover} ms/frame={watch.Elapsed.TotalMilliseconds / runs:0.000} gizmos ms/frame={gizmos.Elapsed.TotalMilliseconds / runs:0.000}");
		}
		Log.Info("MODEL-SELECT-BENCH DONE");
	}
}
