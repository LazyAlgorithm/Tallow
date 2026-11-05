using System;
using System.Collections;
using System.IO;
using Tallow;
using Bgfx;

namespace Tallow.Editor;

/// Small rendered pictures of assets for the Project panel: a material or a shader on a ball, a model as it looks,
/// a prefab with everything in it. Each is drawn once in a little scene of its own, kept, and drawn again when the
/// file changes. One is made per frame, so opening a folder full of models does not stall the editor.
static class AssetPreviews
{
	const int32 PreviewSize = 128;
	/// The preview scene renders after the Scene and Game views; the copy into the kept picture happens in the view after its last.
	/// The copy must come after the tonemap pass, or each picture is the asset made before it.
	const uint16 ViewBase = 10 + RenderView.ViewCount * 2;
	const uint16 CopyView = ViewBase + RenderView.ViewCount;

	class Entry
	{
		public bgfx.TextureHandle texture = .() { idx = uint16.MaxValue };
		public DateTime stamp;
		public bool failed;
	}

	static Dictionary<String, Entry> sEntries = new .() ~ delete _;
	static List<String> sQueue = new .() ~ DeleteContainerAndItems!(_);
	static RenderView sView ~ delete _;
	static Scene sScene ~ delete _;
	static Camera sCamera;
	static int32 sRevision;

	/// True for files that get a rendered preview.
	public static bool Wants(StringView name) => name.EndsWith(".tmat") || name.EndsWith(".tshader") || name.EndsWith(".tsgraph") || name.EndsWith(".tprefab") || Assets.IsModelPath(name);

	static DateTime Stamp(StringView fullPath)
	{
		if (MapPieces.IsPiece(fullPath))
			return default;
		if (File.GetLastWriteTimeUtc(fullPath) case .Ok(let time))
			return time;
		return default;
	}

	/// The picture for a file, if it has been made. Asking also queues it to be made, or made again if the file
	/// has changed since.
	public static bool TryGet(StringView fullPath, out uint16 texture)
	{
		texture = uint16.MaxValue;
		if (!Gfx.Initialized)
			return false;
		if (sEntries.TryGetValueAlt(fullPath, let entry))
		{
			if (entry.texture.idx != uint16.MaxValue)
				texture = entry.texture.idx;
			// Checked now and then, not every frame: a file's time is a system call.
			if ((Time.FrameCount + (int64)fullPath.Length) % 90 == 0 && Stamp(fullPath) != entry.stamp)
				Queue(fullPath);
			return texture != uint16.MaxValue;
		}
		Queue(fullPath);
		return false;
	}

	static void Queue(StringView fullPath)
	{
		for (let queued in sQueue)
		{
			if (queued == fullPath)
				return;
		}
		sQueue.Add(new String(fullPath));
	}

	/// Makes a file's picture again: call when it was saved from inside the editor.
	public static void Invalidate(StringView fullPath)
	{
		if (sEntries.ContainsKeyAlt(fullPath))
			Queue(fullPath);
	}

	/// Makes every material and shader picture again: a shader was compiled, or a texture they share changed.
	public static void InvalidateMaterials()
	{
		for (let path in sEntries.Keys)
		{
			if (path.EndsWith(".tmat") || path.EndsWith(".tshader") || path.EndsWith(".tsgraph"))
				Queue(path);
		}
	}

	static void ClearScene()
	{
		for (int i = sScene.Objects.Count - 1; i >= 0; i--)
		{
			if (i < sScene.Objects.Count && sScene.Objects[i].Transform.Parent == null && sScene.Objects[i] != sCamera.GameObject)
				sScene.DestroyImmediate(sScene.Objects[i]);
		}
	}

	/// Only what can be seen is brought into the preview scene. A prefab's scripts, physics, sound and networking
	/// are left out: nothing in a thumbnail should run.
	public static void VisualOnly(StringView prefabText, String output)
	{
		bool keep = true;
		for (let line in prefabText.Split('\n'))
		{
			if (line.StartsWith("component "))
				keep = line.StartsWith("component Tallow.MeshRenderer ") || line.StartsWith("component Tallow.SkinnedMeshRenderer ") || line.StartsWith("component Tallow.Light ");
			else if (!line.StartsWith("field "))
				keep = true;
			if (keep)
				output..Append(line).Append('\n');
		}
	}

	static bool Build(StringView fullPath)
	{
		// A Map Builder piece is made, not read from a file.
		if (MapPieces.IsPiece(fullPath))
			return MapPieces.Create(sScene, fullPath) != null;
		let relative = scope String();
		Assets.MakeRelative(fullPath, relative);
		if (fullPath.EndsWith(".tprefab"))
		{
			let text = scope String();
			if (File.ReadAllText(fullPath, text, true) case .Err)
				return false;
			let visual = scope String();
			VisualOnly(text, visual);
			let root = SceneSerializer.Instantiate(sScene, visual);
			if (root == null)
				return false;
			root.Transform.Position = .Zero;
			return true;
		}
		// A compute graph makes no surface shader, so it has no picture: its icon stands for it.
		if (fullPath.EndsWith(".tsgraph") && !File.Exists(scope $"{fullPath.Substring(0, fullPath.Length - 8)}.tshader"))
			return false;
		let object = sScene.CreateGameObject("Preview");
		let renderer = object.AddComponent<MeshRenderer>();
		renderer.flatShading = false;
		if (fullPath.EndsWith(".tmat"))
		{
			renderer.mesh.Set("builtin:sphere");
			renderer.material.Set(relative);
		}
		else if (fullPath.EndsWith(".tshader") || fullPath.EndsWith(".tsgraph"))
		{
			// A shader graph is shown by the shader it generates.
			if (relative.EndsWith(".tsgraph"))
			{
				relative.RemoveFromEnd(8);
				relative.Append(".tshader");
			}
			// A plain grey material drawn by the shader, with the shader's own default values.
			let material = Material.Create(scope $"preview:{relative}");
			material.shader.Set(relative);
			material.color = .(0.75f, 0.75f, 0.78f, 1);
			material.flatShading = false;
			material.roughness = 0.5f;
			material.Changed();
			renderer.mesh.Set("builtin:sphere");
			renderer.material.Set(scope $"preview:{relative}");
		}
		else
		{
			renderer.mesh.Set(relative);
			renderer.flatShading = true;
			// A rigged model is drawn through its skinned renderer.
			if (renderer.ActiveMesh == null)
			{
				let skinned = object.AddComponent<SkinnedMeshRenderer>();
				skinned.model.Set(relative);
				skinned.OnValidate();
			}
		}
		return true;
	}

	/// Points the camera at everything in the preview scene.
	static void Frame()
	{
		Bounds bounds = .Empty;
		bool any = false;
		for (let renderer in sScene.Renderers)
		{
			if (renderer.ActiveMesh == null)
				continue;
			let world = renderer.WorldBounds;
			bounds.min = .(Math.Min(bounds.min.x, world.min.x), Math.Min(bounds.min.y, world.min.y), Math.Min(bounds.min.z, world.min.z));
			bounds.max = .(Math.Max(bounds.max.x, world.max.x), Math.Max(bounds.max.y, world.max.y), Math.Max(bounds.max.z, world.max.z));
			any = true;
		}
		if (!any)
			bounds = .(.(-0.5f, -0.5f, -0.5f), .(0.5f, 0.5f, 0.5f));
		let radius = Math.Max(bounds.Extents.Length, 0.05f);
		let rotation = Quaternion.Euler(18, -32, 0);
		sCamera.fieldOfView = 30;
		sCamera.nearClip = Math.Max(radius * 0.05f, 0.01f);
		sCamera.farClip = radius * 12;
		sCamera.Transform.Rotation = rotation;
		sCamera.Transform.Position = bounds.Center - (rotation * Vector3.Forward) * (radius / Math.Tan(15 * Math.PI_f / 180) * 1.05f);
	}

	/// Called once a frame by the editor, before it renders: makes at most one picture.
	public static void Update()
	{
		if (!Gfx.Initialized || sQueue.Count == 0)
			return;
		if (sView == null)
		{
			sView = new RenderView(ViewBase);
			// Its scene is not the one being edited: the reflection captures follow the editor's views.
			sView.CapturesReflections = false;
			sView.ShowAmbientOcclusion = false;
			sView.ShowDepthOfField = false;
			sView.ShowMotionBlur = false;
			sScene = new Scene();
			sScene.Environment.ambientIntensity = 0.75f;
			sScene.Environment.fogDensity = 0;
			sCamera = sScene.CreateGameObject("Preview Camera").AddComponent<Camera>();
			let lamp = sScene.CreateGameObject("Preview Light");
			lamp.Transform.SetParent(sCamera.Transform, false);
			// Over the viewer's left shoulder, so that shape and shine both read.
			lamp.Transform.LocalRotation = Quaternion.Euler(28, 38, 0);
			let light = lamp.AddComponent<Light>();
			light.castShadows = false;
			light.intensity = 1.6f;
		}
		let path = sQueue.PopFront();
		defer delete path;
		Entry entry;
		if (sEntries.TryGetValue(path, let existing))
			entry = existing;
		else
		{
			entry = new Entry();
			sEntries[new String(path)] = entry;
		}
		entry.stamp = Stamp(path);
		ClearScene();
		entry.failed = (!MapPieces.IsPiece(path) && !File.Exists(path)) || !Build(path);
		if (entry.failed)
			return;
		Frame();
		sView.Resize(PreviewSize, PreviewSize);
		sView.Render(sScene, sCamera.GetCameraData(1));
		if (entry.texture.idx == uint16.MaxValue)
			entry.texture = bgfx.create_texture_2d((uint16)PreviewSize, (uint16)PreviewSize, false, 1, .RGBA8, (uint64)bgfx.TextureFlags.BlitDst, null, 0);
		// The scene's picture is copied out in a later view of the same frame, so the next asset can reuse the scene.
		bgfx.TextureRegion from = default, to = default;
		from.handle.idx = sView.OutputTexture;
		from.width = (uint16)PreviewSize;
		from.height = (uint16)PreviewSize;
		from.depth = 1;
		to.handle = entry.texture;
		to.width = (uint16)PreviewSize;
		to.height = (uint16)PreviewSize;
		to.depth = 1;
		bgfx.blit(CopyView, &to, &from);
		sRevision++;
	}

	public static void Shutdown()
	{
		for (let (path, entry) in sEntries)
		{
			if (entry.texture.idx != uint16.MaxValue && Gfx.Initialized)
				bgfx.destroy_texture(entry.texture);
			delete path;
			delete entry;
		}
		sEntries.Clear();
		DeleteAndNullify!(sView);
		DeleteAndNullify!(sScene);
		sCamera = default;
	}
}
