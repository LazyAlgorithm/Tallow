using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tallow;
using Bgfx;

namespace Tallow.Editor;

/// The Graph tab's pictures of a shader graph: the whole surface lit on a ball, and each node's value on a ball of its
/// own, unlit. The graph's preview shader (ShaderGraphCode with previews) is compiled on another thread, for the
/// backend the editor draws with only, once the graph has stopped changing for a moment. All the balls are drawn in
/// one picture, a grid of cells, and each node shows its own cell of it. The picture is drawn again a few times a
/// second, so nodes that use Time move. A compute graph instead runs for real, a step every frame, on a texture of
/// its own (the corner's picture), and a second run of it fills the grid: each cell that texture seen through one
/// node.
class ShaderGraphPreview
{
	/// RenderView.ViewCount views from here: after the reflection captures, before ImGui's (250).
	const uint16 ViewBase = Reflections.FaceViewBase + 6;
	/// The picture's size of one cell, in pixels.
	public const int32 CellSize = 128;
	const int32 MaxCells = 100;
	/// How long the graph must stay unchanged before it is compiled, and how often it is looked at for changes.
	const double SettleSeconds = 0.35;
	const double CheckSeconds = 0.2;
	const double RedrawSeconds = 1.0 / 15;
	/// The preview shader's name: what its materials' Shader names, and what its compiled files are called.
	const String ShaderName = "tessera_graph_preview";
	const String ComputeName = "tessera_graph_compute_preview";
	/// The width and height of the texture a compute graph's preview runs on.
	const int32 ComputeSize = 256;

	RenderView mView ~ delete _;
	Scene mScene ~ delete _;
	Camera mCamera;
	List<MeshRenderer> mBalls = new .() ~ delete _;
	int32 mColumns = 1, mRows = 1;
	// A compute graph's: the shader, the texture it runs on, and the grid of its nodes.
	ShaderAsset mCompute;
	ComputeTexture mComputed ~ delete _;
	ComputeTexture mComputeGrid ~ delete _;

	// The preview shader last written from the graph, and its node slots; what is compiling; what is shown.
	String mWritten = new .() ~ delete _;
	Dictionary<int32, int32> mWrittenSlots = new .() ~ delete _;
	String mCompiling = new .() ~ delete _;
	Dictionary<int32, int32> mCompilingSlots = new .() ~ delete _;
	Dictionary<int32, int32> mShownSlots = new .() ~ delete _;
	bool mHasPicture;
	double mWrittenAt, mCheckedAt, mDrawnAt;

	Thread mThread;
	bool mFinished;
	bool mSucceeded;
	String mLog = new .() ~ delete _;
	String mFolder = new .() ~ delete _;

	/// What went wrong the last time the graph was compiled, or empty.
	public String problem = new .() ~ delete _;

	public ~this()
	{
		if (mThread != null)
		{
			mThread.Join();
			delete mThread;
		}
	}

	/// A node's picture: a bgfx texture and the part of it (texture coordinates for ImGui.DrawPicture); false when
	/// the node has none.
	public bool NodePicture(int32 nodeId, out uint16 texture, out ImGui.Vec2 from, out ImGui.Vec2 to)
	{
		texture = uint16.MaxValue;
		from = to = default;
		if (!mHasPicture)
			return false;
		if (!mShownSlots.TryGetValue(nodeId, let slot))
			return false;
		if (mCompute != null)
		{
			texture = mComputeGrid.Texture.idx;
			Cell(slot, true, out from, out to);
			return true;
		}
		texture = mView.OutputTexture;
		Cell(slot, false, out from, out to);
		return true;
	}

	/// The whole shader's picture: the surface lit on a ball, or the texture a compute graph runs on.
	public bool SurfacePicture(out uint16 texture, out ImGui.Vec2 from, out ImGui.Vec2 to)
	{
		texture = uint16.MaxValue;
		from = to = default;
		if (!mHasPicture)
			return false;
		if (mCompute != null)
		{
			texture = mComputed.Texture.idx;
			from = .(0, 0);
			to = .(1, 1);
			Upright(ref from, ref to);
			return true;
		}
		texture = mView.OutputTexture;
		Cell(0, false, out from, out to);
		return true;
	}

	void Cell(int32 slot, bool computed, out ImGui.Vec2 from, out ImGui.Vec2 to)
	{
		let column = slot % mColumns, row = slot / mColumns;
		from = .((float)column / mColumns, (float)row / mRows);
		to = .((float)(column + 1) / mColumns, (float)(row + 1) / mRows);
		if (computed)
			Upright(ref from, ref to);
	}

	/// A compute shader writes its texture top row first on every backend, unlike a picture the graphics card
	/// draws, so its coordinates are turned over here for ImGui.DrawPicture to turn back.
	static void Upright(ref ImGui.Vec2 from, ref ImGui.Vec2 to)
	{
		if (!Gfx.OriginBottomLeft)
			return;
		from.y = 1 - from.y;
		to.y = 1 - to.y;
	}

	/// Called each frame the graph is on screen: notices changes, compiles once they settle, picks up a finished
	/// compile, and draws the picture again now and then.
	public void Update(NodeGraph graph)
	{
		if (!Gfx.Initialized)
			return;
		let now = Time.RealTime;
		if (now - mCheckedAt >= CheckSeconds)
		{
			mCheckedAt = now;
			let writer = scope ShaderGraphCode();
			let text = scope String();
			if (writer.Write(graph, text, true) && text != mWritten)
			{
				mWritten.Set(text);
				mWrittenSlots.Clear();
				for (let (node, slot) in writer.previewSlots)
					mWrittenSlots[node] = slot;
				mWrittenAt = now;
			}
			else if (!writer.problems.IsEmpty)
				problem.Set(writer.problems.Split('\n').GetNext().GetValueOrDefault());
		}
		Collect();
		if (mThread == null && !mWritten.IsEmpty && mWritten != mCompiling && now - mWrittenAt >= SettleSeconds)
			Start();
		if (!mHasPicture)
			return;
		// A simulation moves on every frame, as it does in the game; the pictures are only made a few times a second.
		if (mCompute != null)
			Compute.RunPreview(mCompute, mComputed, mComputed.Texture, 0);
		if (now - mDrawnAt >= RedrawSeconds)
		{
			mDrawnAt = now;
			Draw();
		}
	}

	/// Compiles the last written shader on another thread.
	void Start()
	{
		mCompiling.Set(mWritten);
		mCompilingSlots.Clear();
		for (let (node, slot) in mWrittenSlots)
			mCompilingSlots[node] = slot;
		if (mFolder.IsEmpty)
		{
			Path.GetTempPath(mFolder);
			mFolder.AppendF("/tessera-graph-preview-{}", (int)Platform.BfpProcess_GetCurrentId());
		}
		mLog.Clear();
		mFinished = false;
		let engineRoot = new String(Project.Current.EngineRoot);
		let name = mCompiling.Contains("\ncompute {") ? ComputeName : ShaderName;
		mThread = new Thread(new () =>
			{
				mSucceeded = ShaderCompiler.CompilePreview(engineRoot, mCompiling, name, mFolder, mLog);
				delete engineRoot;
				Interlocked.Store(ref mFinished, true);
			});
		mThread.Start(false);
	}

	/// Takes in a finished compile: the new program, and a ball for each node.
	void Collect()
	{
		if (mThread == null || !Interlocked.Load(ref mFinished))
			return;
		mThread.Join();
		DeleteAndNullify!(mThread);
		if (!mSucceeded)
		{
			let first = scope String();
			for (let line in mLog.Split('\n', .RemoveEmptyEntries))
			{
				first.Set(line);
				break;
			}
			problem.Set(first.IsEmpty ? "The preview did not compile." : first);
			return;
		}
		problem.Clear();
		let computed = mCompiling.Contains("\ncompute {");
		if (computed && !Compute.Supported)
		{
			problem.Set("This graphics backend cannot run compute shaders.");
			return;
		}
		let shader = ShaderAsset.FromCompiled(computed ? ComputeName : ShaderName, mCompiling, scope $"{mFolder}/{Gfx.ShaderFolder}");
		// Loaded now, before another compile can write over the files.
		if ((computed ? shader.ComputeProgram : shader.Program).idx == uint16.MaxValue)
		{
			problem.Set("The preview's compiled shader could not be loaded.");
			return;
		}
		mShownSlots.Clear();
		for (let (node, slot) in mCompilingSlots)
			mShownSlots[node] = slot;
		mCompute = computed ? shader : null;
		let cells = Math.Min(mShownSlots.Count + 1, MaxCells);
		if (computed)
			LayoutCompute(cells);
		else
			Layout(cells);
		mHasPicture = true;
		mDrawnAt = 0;
	}

	/// A compute graph's textures: the one it runs on (kept when it is compiled again, so a simulation carries on),
	/// and a grid of cells for so many nodes.
	void LayoutCompute(int cells)
	{
		mColumns = (int32)Math.Max(Math.Ceiling(Math.Sqrt((double)cells)), 1);
		mRows = (int32)Math.Max((cells + mColumns - 1) / mColumns, 1);
		let highPrecision = mCompute.highPrecision;
		if (mComputed == null || mComputed.HighPrecision != highPrecision)
		{
			delete mComputed;
			mComputed = new .(ComputeSize, ComputeSize, highPrecision);
		}
		let width = mColumns * ShaderGraphCode.PreviewCell, height = mRows * ShaderGraphCode.PreviewCell;
		if (mComputeGrid == null || mComputeGrid.Width != width || mComputeGrid.Height != height || mComputeGrid.HighPrecision != highPrecision)
		{
			delete mComputeGrid;
			mComputeGrid = new .(width, height, highPrecision);
		}
	}

	/// The scene the balls are in, made the first time.
	void EnsureScene()
	{
		if (mView != null)
			return;
		mView = new RenderView(ViewBase);
		mView.CapturesReflections = false;
		mView.ShowAmbientOcclusion = false;
		mView.ShowDepthOfField = false;
		mView.ShowMotionBlur = false;
		mScene = new Scene();
		mScene.Environment.ambientIntensity = 0.75f;
		mScene.Environment.fogDensity = 0;
		// A plain dark grey behind the balls, so that colours read against it as they do on the canvas.
		mScene.Environment.skyZenith = mScene.Environment.skyHorizon = mScene.Environment.skyGround = .(0.12f, 0.12f, 0.13f);
		mCamera = mScene.CreateGameObject("Preview Camera").AddComponent<Camera>();
		mCamera.orthographic = true;
		let lamp = mScene.CreateGameObject("Preview Light");
		lamp.Transform.SetParent(mCamera.Transform, false);
		// Over the viewer's left shoulder, as the Project panel's material balls are lit.
		lamp.Transform.LocalRotation = Quaternion.Euler(28, 38, 0);
		let light = lamp.AddComponent<Light>();
		light.castShadows = false;
		light.intensity = 1.6f;
	}

	/// A grid of cells for so many balls: the first lit (the whole surface), the others each showing one node.
	void Layout(int cells)
	{
		EnsureScene();
		mColumns = (int32)Math.Max(Math.Ceiling(Math.Sqrt((double)cells)), 1);
		mRows = (int32)Math.Max((cells + mColumns - 1) / mColumns, 1);
		while (mBalls.Count < cells)
		{
			let index = mBalls.Count;
			let ball = mScene.CreateGameObject(scope $"Ball {index}").AddComponent<MeshRenderer>();
			ball.mesh.Set("builtin:sphere");
			ball.flatShading = false;
			let materialName = scope $"graphpreview:{index}";
			let material = Material.Create(materialName);
			material.shader.Set(ShaderName);
			material.color = .White;
			material.roughness = 0.5f;
			material.flatShading = false;
			material.unlit = index > 0;
			material.previewOutput = (int32)index;
			material.Changed();
			ball.material.Set(materialName);
			mBalls.Add(ball);
		}
		for (int i < mBalls.Count)
		{
			let ball = mBalls[i];
			ball.GameObject.SetActive(i < cells);
			// Cell (column, row) is one metre square, counted from the top left; the ball nearly fills it.
			ball.Transform.Position = .((i % mColumns) + 0.5f, -((i / mColumns) + 0.5f), 0);
			ball.Transform.LocalScale = .(0.9f, 0.9f, 0.9f);
		}
		mCamera.orthographicSize = mRows * 0.5f;
		mCamera.nearClip = 0.1f;
		mCamera.farClip = 20;
		mCamera.Transform.Position = .(mColumns * 0.5f, -mRows * 0.5f, -5);
		mCamera.Transform.Rotation = .Identity;
		mView.Resize(mColumns * CellSize, mRows * CellSize);
	}

	void Draw()
	{
		if (mCompute != null)
			Compute.RunPreview(mCompute, mComputeGrid, mComputed.Texture, mColumns);
		else
			mView.Render(mScene, mCamera.GetCameraData((float)mColumns / mRows));
	}
}
