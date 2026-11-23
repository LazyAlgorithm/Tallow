using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// How a World Text is drawn.
[Reflect(.All)]
enum WorldTextMode : int32
{
	/// Flat letters in the scene: drawn like a mesh, so they are hidden behind walls and grow smaller with distance.
	/// For signs, labels over doors, floating names above a head that still belong to the world.
	World,
	/// A label pinned to a point in the world but drawn flat on the screen at a size in pixels (a name tag, a damage
	/// number, a marker): always readable, over the scene and under the game's own interface.
	Screen
}

/// Which part of the text sits on the object's position.
[Reflect(.All)]
enum WorldTextAlign : int32
{
	Left,
	Center,
	Right
}

/// Which way 3D text faces.
[Reflect(.All)]
enum WorldTextFacing : int32
{
	/// The object's own rotation: it can be a sign on a wall, or laid flat.
	Transform,
	/// Turns about its up axis to face the camera wherever it moves, like a name plate over a character.
	Camera
}

/// A World Text's settings, in its entity (WorldText is the handle).
[Component, HandleData]
struct WorldTextData
{
	/// The words. Several lines are drawn one under another, split at their new lines.
	[Multiline]
	public SharedString text = "World Text";
	/// A .ttf or .otf file in the project. Empty draws it in the engine's own font (Roboto, the interface's font).
	public SharedString font = default;
	/// Letters in the scene, or a label pinned to a point on the screen (Name Tag).
	public WorldTextMode mode = .World;
	/// The text's colour. An alpha below 1 makes it see-through.
	public Color color = .White;
	/// How big it is: the height of a line in metres in the scene, or the font size in screen pixels on the screen.
	[Range(0.01f, 200)]
	public float size = 0.5f;
	/// How far the letters stick out, in metres: 0 keeps them flat, as paper; more makes solid letters with faces,
	/// backs and walls (a full 3D model). The depth is centred on the object's position. Screen labels stay flat.
	[Range(0, 5)]
	public float depth = 0;
	/// Which part of the text sits on the object's position.
	public WorldTextAlign alignment = .Center;
	/// Whether the backs of the letters are drawn too (off: only from the front, as a sign on a wall).
	public bool doubleSided = true;
	/// Drawn in its own colour, unlit by the scene's lights. Off: it takes the scene's light like a painted sign.
	public bool unlit = true;
	/// How strongly it glows in its own colour (through bloom): 0 not at all.
	[Range(0, 10)]
	public float glow = 0;
	/// Whether scene text casts a shadow. Solid letters (Depth above 0) can; flat text rarely looks right.
	public bool castShadows = false;
	/// Which way it faces (in the scene): with its object, or turning to face the camera.
	public WorldTextFacing facing = .Transform;
	/// The number of texture pixels a metre of scene text is drawn with (a higher count is sharper close up and
	/// more memory per label).
	[Advanced, Range(16, 1024)]
	public float pixelDensity = 128;
	/// Whether scene text is drawn in the editor while not playing.
	public bool showInEditor = true;

	/// A name tag's place on the screen, in pixels, from where its object is (positive x to the right, positive y down).
	public Vector2 screenOffset = .Zero;
	/// A name tag's furthest distance in metres (0: no limit). Past it the label is not drawn.
	public float maxDistance = 0;
	/// A name tag's dark shadow, so it stays readable over bright scenery.
	public bool shadow = true;

	public this() { }
}

/// Text that lives in the world (tallowengine.com/docs/world-text), in either of two ways:
///
///   World: flat letters drawn in the scene, rasterized from a font file (or the engine's own) into a texture on a
///   quad, through a hidden child object. A sign over a shop, a label on a wall, a name floating over a character:
///   hidden behind walls like the rest of the scene, and smaller with distance.
///
///   Screen: a name tag. A dot in the world, drawn flat on the screen with the interface's text at a size in pixels,
///   over the scene and under the game's interface, so it is always readable.
///
///   WorldText label = go.AddComponent<WorldText>();
///   label.Text = "Night 1";
///   label.Size = 0.8f;
///
/// A handle (ComponentHandle): its settings are WorldTextData's fields; what it keeps between frames (the texture and
/// the quad) is its WorldTextState.
[Component, HandleFields]
struct WorldText : ComponentHandle<WorldTextData>
{
	/// What it keeps between frames, with the settings copied in now.
	public WorldTextState State
	{
		get
		{
			CheckValid();
			let state = ComponentState<WorldTextState>.Make(mGameObject.Scene.World, mGameObject.Entity);
			state.[Friend]mGameObject = mGameObject;
			state.data = Data;
			return state;
		}
	}

	/// The Mesh Renderer drawing scene text (on a hidden child object), for changing what its fields do not cover.
	/// Not valid before its first frame, for screen text, or in a headless run.
	public MeshRenderer DrawnBy => State.Renderer;

	/// The size the text takes: in metres in the scene, or in screen pixels on the screen. Measured from the font,
	/// so a background box or a neighbouring label can be laid out around it.
	public Vector2 Measure() => State.Measure();

	/// In the editor, and each frame while playing before the scene is drawn: keeps up the texture and the quad.
	public static void FrameAll(Scene scene)
	{
		HideSwitchedOff(scene);
		for (let label in scene.Components<WorldText>(.. scope .()))
		{
			if (!label.GameObject.ActiveInHierarchy)
				continue;
			if (!scene.IsPlaying && !label.showInEditor)
			{
				label.State.Detach();
				continue;
			}
			label.State.Step();
		}
	}

	/// While playing: boxes follow what the scripts moved, and turning text turns to the camera.
	public static void LateAll(Scene scene)
	{
		for (let label in scene.Components<WorldText>(.. scope .()))
		{
			if (label.GameObject.ActiveInHierarchy)
				label.State.Step();
		}
	}

	/// GUI.Run: the screen-text labels, after the scene is drawn and before the game's own interface (so a HUD
	/// draws over them).
	public static void DrawScreen(Scene scene)
	{
		if (scene == null || !Gfx.Initialized || GUI.Width <= 0 || GUI.Height <= 0)
			return;
		let camera = scene.ViewCamera;
		if (!camera)
			return;
		let data = camera.GetCameraData(GUI.Width / GUI.Height);
		for (let label in scene.Components<WorldText>(.. scope .()))
		{
			if (label.mode != .Screen || !label.IsActiveAndEnabled)
				continue;
			let text = (StringView)label.text;
			if (text.IsEmpty)
				continue;
			let position = label.Transform.Position;
			// Behind the camera, past the far clip, or too far for the label: not drawn.
			let depth = Vector3.Dot(position - data.position, data.forward);
			if (depth <= data.near || depth >= data.far)
				continue;
			if (label.maxDistance > 0 && depth > label.maxDistance)
				continue;
			let point = data.WorldToViewportPoint(position);
			if (point.x < -0.05f || point.x > 1.05f || point.y < -0.05f || point.y > 1.05f)
				continue;
			let x = GUI.Origin.x + point.x * GUI.Width + label.screenOffset.x;
			let y = GUI.Origin.y + point.y * GUI.Height + label.screenOffset.y;
			UIFonts.Push(label.font, Math.Max(label.size, 1));
			let extent = ImGui.CalcStringSize(text);
			var tx = x;
			let ty = y - extent.y * 0.5f;
			switch (label.alignment)
			{
			case .Center: tx -= extent.x * 0.5f;
			case .Right: tx -= extent.x;
			case .Left:
			}
			if (label.shadow)
				ImGui.DrawString(.(tx + 1, ty + 1), .(0, 0, 0, label.color.a * 0.75f), text);
			ImGui.DrawString(.(tx, ty), label.color, text);
			ImGui.PopFont();
		}
	}

	/// Labels switched off, or switched to screen text, stop drawing.
	static void HideSwitchedOff(Scene scene)
	{
		for (let (entity, state) in ComponentState<WorldTextState>.In(scene.World, .. scope .()))
		{
			let gameObject = state.GameObject;
			if (gameObject == null)
				continue;
			let label = gameObject.GetComponent<WorldText>();
			if (!label || !label.enabled || label.mode != .World)
				state.Detach();
		}
	}

	static void OnRemove(void* world, uint64 entity)
	{
		if (let state = ComponentState<WorldTextState>.Get((World)Internal.UnsafeCastToObject(world), Entity(entity)))
			state.Remove();
		ComponentState<WorldTextState>.Release(world, entity);
	}
}

/// Fonts for text drawn in the world, read once from their file (the engine's own font when none is named).
static class WorldTextFonts
{
	static Dictionary<String, void*> sFonts = new .() ~ DeleteDictionaryAndKeys!(_);

	/// The font for a file (empty: the engine's own), or null if even that cannot be made.
	public static void* Get(StringView path)
	{
		if (path.IsEmpty)
			return tn_text_font_default();
		if (sFonts.TryGetValueAlt(path, let font))
			return font;
		List<uint8> bytes = scope .();
		void* loaded = null;
		if (Assets.ReadBytes(path, bytes) && bytes.Count > 0)
			loaded = tn_text_font_load(bytes.Ptr, (int32)bytes.Count);
		if (loaded == null)
		{
			Log.Warning(scope $"Font {path} could not be read; the engine's own font is used.");
			loaded = tn_text_font_default();
		}
		sFonts[new String(path)] = loaded;
		return loaded;
	}

	[CLink] public static extern void* tn_text_font_load(uint8* data, int32 size);
	[CLink] public static extern void* tn_text_font_default();
	[CLink] public static extern uint8* tn_text_rasterize(void* font, char8* text, int32 length, float pixelHeight, int32 align,
		int32* outWidth, int32* outHeight, int32* outLineHeight, int32* outPad);
	[CLink] public static extern void tn_text_bitmap_free(uint8* pixels);
	[CLink] public static extern WorldTextMesh* tn_text_mesh_build(void* font, char8* text, int32 length, float pixelHeight,
		int32 align, float depth);
	[CLink] public static extern void tn_text_mesh_free(WorldTextMesh* mesh);
}

/// The C TnTextMesh (tallow_text.c): the words' bitmap and their extruded letters, in bitmap pixels.
[CRepr]
struct WorldTextMesh
{
	public int32 width, height, lineHeight, pad;
	public uint8* pixels;
	public int32 faceVertexCount, faceIndexCount;
	public float* facePositions;
	public float* faceNormals;
	public float* faceUvs;
	public uint32* faceIndices;
	public int32 sideVertexCount, sideIndexCount;
	public float* sidePositions;
	public float* sideNormals;
	public uint32* sideIndices;
}

/// What a World Text keeps between frames: the texture the text was rasterized into and the geometry on hidden
/// child objects that draws it (scene text: a quad, or solid letters with depth), or the measurements a screen label
/// needs. `data` is a copy of the settings.
[DataFields(typeof(WorldTextData), "data")]
class WorldTextState
{
	/// The settings the text and quad were made from, copied in by WorldText.State.
	public WorldTextData data = .();

	GameObject mGameObject;
	// The hidden children, by their ids: they may outlive this state (children go before their parent's components).
	Scene mScene;
	uint32 mHolderId;
	uint32 mSidesHolderId;
	Mesh mMesh ~ delete _;
	Mesh mSidesMesh ~ delete _;
	bgfx.TextureHandle mTexture = .() { idx = uint16.MaxValue };
	bool mHasQuad;
	/// Whether the letters are the extruded mesh (with depth) rather than the flat quad.
	bool mExtruded;

	// What the current texture and geometry were made from.
	String mBuiltText = new .() ~ delete _;
	String mBuiltFont = new .() ~ delete _;
	/// The text that last failed to build, so the warning is logged once rather than every frame.
	String mWarned = new .() ~ delete _;
	float mBuiltSize;
	float mBuiltDepth;
	bool mBuiltUnlit;
	int32 mBuiltPixels;
	int32 mBuiltAlign = -1;
	// The block's size in metres, without the texture's padding, and how much of the image is padding.
	Vector2 mBlock;
	Vector2 mUvPad;

	public GameObject GameObject => mGameObject;
	Transform Transform => mGameObject.Transform;

	GameObject Holder
	{
		get
		{
			if (mScene == null || mHolderId == 0)
				return null;
			let holder = mScene.FindById(mHolderId);
			return (holder != null && !holder.IsDestroyed) ? holder : null;
		}
	}

	/// The renderer drawing the text (on the hidden child), or not valid before the first frame.
	public MeshRenderer Renderer
	{
		get
		{
			let holder = Holder;
			return (holder != null && holder.HasComponent<MeshRenderer>()) ? holder.GetComponent<MeshRenderer>() : default;
		}
	}

	GameObject SidesHolder
	{
		get
		{
			if (mScene == null || mSidesHolderId == 0)
				return null;
			let holder = mScene.FindById(mSidesHolderId);
			return (holder != null && !holder.IsDestroyed) ? holder : null;
		}
	}

	/// The renderer drawing the walls of solid letters, or not valid (flat text has none).
	MeshRenderer SidesRenderer
	{
		get
		{
			let holder = SidesHolder;
			return (holder != null && holder.HasComponent<MeshRenderer>()) ? holder.GetComponent<MeshRenderer>() : default;
		}
	}

	/// Keeps the texture and the quad up to date, and turns the text to the camera when it should.
	public void Step()
	{
		if (mGameObject == null || mGameObject.IsDestroyed)
			return;
		if (data.mode != .World || !data.showInEditor && mGameObject.Scene != null && !mGameObject.Scene.IsPlaying)
		{
			Detach();
			return;
		}
		if (data.text.IsEmpty || !Gfx.Initialized)
		{
			Detach();
			return;
		}
		Attach(mGameObject);
		let renderer = Renderer;
		if (!renderer || mMesh == null)
			return;
		// A new font, size, depth or copy of the text needs new geometry.
		let pixelHeight = PixelHeight();
		if (!mTexture.Valid || mBuiltAlign != (int32)data.alignment || mBuiltPixels != pixelHeight || mBuiltSize != data.size ||
			mBuiltDepth != data.depth || mBuiltUnlit != data.unlit ||
			mBuiltText != data.text.View || mBuiltFont != data.font.View)
		{
			if (!Build(pixelHeight))
			{
				Detach();
				return;
			}
		}
		ApplyLook(renderer);
		ApplySidesLook();
		ApplyFacing();
	}

	void Attach(GameObject owner)
	{
		var holder = Holder;
		if (holder == null)
		{
			holder = owner.Scene.CreateGameObject(scope $"{owner.Name} (text)");
			holder.Transient = true;
			holder.Transform.SetParent(owner.Transform, false);
			mScene = owner.Scene;
			mHolderId = holder.Id;
			let made = holder.AddComponent<MeshRenderer>();
			made.mesh.Clear();
			made.material.Clear();
			made.texture.Clear();
			made.backFaceCulling = false;
			made.flatShading = false;
			made.castShadows = false;
			// Text is a label, not part of the room: reflections of it are rarely wanted.
			made.inReflectionProbes = false;
			if (mMesh == null)
				mMesh = new Mesh();
			mMesh.Name.Set(owner.Name);
			made.RuntimeMesh = mMesh;
			mHasQuad = false;
		}
		if (!holder.ActiveSelf)
			holder.SetActive(true);
		let renderer = holder.GetComponent<MeshRenderer>();
		if (!renderer.Enabled)
			renderer.Enabled = true;
	}

	/// Makes the hidden child that draws the walls of solid letters, if it is not there.
	void EnsureSidesHolder(GameObject owner)
	{
		var holder = SidesHolder;
		if (holder != null)
			return;
		holder = owner.Scene.CreateGameObject(scope $"{owner.Name} (text sides)");
		holder.Transient = true;
		holder.Transform.SetParent(owner.Transform, false);
		mSidesHolderId = holder.Id;
		let made = holder.AddComponent<MeshRenderer>();
		made.mesh.Clear();
		made.material.Clear();
		made.texture.Clear();
		made.flatShading = false;
		made.castShadows = false;
		made.inReflectionProbes = false;
		if (mSidesMesh == null)
			mSidesMesh = new Mesh();
		mSidesMesh.Name.Set(owner.Name);
		made.RuntimeMesh = mSidesMesh;
	}

	/// Stops drawing the text (it comes back with the next Step).
	public void Detach()
	{
		let renderer = Renderer;
		if (renderer && renderer.Enabled)
			renderer.Enabled = false;
		let sides = SidesRenderer;
		if (sides && sides.Enabled)
			sides.Enabled = false;
	}

	/// Removes the hidden children and the texture, when the label itself is removed.
	public void Remove()
	{
		if (let holder = Holder)
		{
			// Not while the scene is emptied: everything is going anyway.
			if (!holder.Scene.[Friend]mClearing)
			{
				holder.GetComponent<MeshRenderer>().RuntimeMesh = null;
				holder.Scene.Destroy(holder);
			}
		}
		if (let sides = SidesHolder)
		{
			if (!sides.Scene.[Friend]mClearing)
			{
				sides.GetComponent<MeshRenderer>().RuntimeMesh = null;
				sides.Scene.Destroy(sides);
			}
		}
		mScene = null;
		mHolderId = 0;
		mSidesHolderId = 0;
		ReleaseTexture();
		mHasQuad = false;
		mExtruded = false;
	}

	void ReleaseTexture()
	{
		if (mTexture.Valid && Gfx.Initialized)
		{
			bgfx.destroy_texture(mTexture);
			Textures.Sizes.Remove(mTexture.idx);
		}
		mTexture.idx = uint16.MaxValue;
	}

	int32 PixelHeight() => (int32)Math.Clamp(Math.Round(data.size * Math.Max(data.pixelDensity, 1)), 4.0f, 1024.0f);

	/// The texture and geometry for the current settings: a flat quad, or solid letters when Depth is above 0.
	bool Build(int32 pixelHeight)
	{
		if (data.depth > 0.0005f)
			return Extrude(pixelHeight);
		return Rasterize(pixelHeight);
	}

	/// The texture pixels for flat text, and the quad sized to match. False when the text could not be rasterized
	/// (too long for a texture, or out of memory).
	bool Rasterize(int32 pixelHeight)
	{
		let font = WorldTextFonts.Get(data.font);
		if (font == null)
			return false;
		let text = (StringView)data.text;
		int32 width = 0, height = 0, lineHeight = 0, pad = 0;
		let pixels = WorldTextFonts.tn_text_rasterize(font, text.Ptr, (int32)text.Length, (float)pixelHeight,
			(int32)data.alignment, &width, &height, &lineHeight, &pad);
		if (pixels == null)
		{
			WarnOnce(text, "is too long to draw in one piece");
			return false;
		}
		defer WorldTextFonts.tn_text_bitmap_free(pixels);
		// A line's height in pixels is the size the field names, so Size of a line in metres is this much per pixel.
		let unitsPerPixel = data.size / (lineHeight > 0 ? (float)lineHeight : (float)Math.Max(pixelHeight, 1));
		mBlock = .((width - pad * 2) * unitsPerPixel, (height - pad * 2) * unitsPerPixel);
		mUvPad = .(pad / (float)Math.Max(width, 1), pad / (float)Math.Max(height, 1));
		ReleaseTexture();
		mTexture = Textures.Create("", pixels, width, height, .Data);
		NoteBuilt(text, pixelHeight);
		if (!mTexture.Valid)
			return false;
		// The mesh may still hold extruded letters: the quad is made again from scratch.
		mHasQuad = false;
		mExtruded = false;
		BuildQuad();
		return true;
	}

	/// The words' bitmap and their extruded letters (faces, backs and walls), from the font's outlines.
	bool Extrude(int32 pixelHeight)
	{
		let font = WorldTextFonts.Get(data.font);
		if (font == null)
			return false;
		let text = (StringView)data.text;
		// Depth in the bitmap's pixels: the same pixels the letters' Height is measured in.
		let unitsPerPixelForDepth = data.size / (float)Math.Max(pixelHeight, 1);
		let depthPixels = Math.Max(data.depth / Math.Max(unitsPerPixelForDepth, 1.0e-6f), 0.0001f);
		let mesh = WorldTextFonts.tn_text_mesh_build(font, text.Ptr, (int32)text.Length, (float)pixelHeight,
			(int32)data.alignment, depthPixels);
		if (mesh == null)
		{
			WarnOnce(text, "is too long to make solid in one piece");
			return false;
		}
		defer WorldTextFonts.tn_text_mesh_free(mesh);
		let unitsPerPixel = data.size / (mesh.lineHeight > 0 ? (float)mesh.lineHeight : (float)Math.Max(pixelHeight, 1));
		mBlock = .((mesh.width - mesh.pad * 2) * unitsPerPixel, (mesh.height - mesh.pad * 2) * unitsPerPixel);
		mUvPad = .(mesh.pad / (float)Math.Max(mesh.width, 1), mesh.pad / (float)Math.Max(mesh.height, 1));
		ReleaseTexture();
		mTexture = Textures.Create("", mesh.pixels, mesh.width, mesh.height, .Data);
		NoteBuilt(text, pixelHeight);
		if (!mTexture.Valid)
			return false;
		// The letters are pivoted where the flat quad is: the alignment's edge, centred top to bottom.
		float pivotX;
		switch (data.alignment)
		{
		case .Left: pivotX = mesh.pad;
		case .Right: pivotX = mesh.width - mesh.pad;
		case .Center: pivotX = mesh.width * 0.5f;
		}
		let pivotY = mesh.height * 0.5f;
		// The faces (front and back) sample the words' picture.
		if (mMesh == null)
			mMesh = new Mesh();
		mMesh.Name.Set(mGameObject.Name);
		mMesh.Vertices.Clear();
		mMesh.Indices.Clear();
		for (int i < mesh.faceVertexCount)
		{
			let position = Vector3((mesh.facePositions[i * 3] - pivotX) * unitsPerPixel,
				(mesh.facePositions[i * 3 + 1] - pivotY) * unitsPerPixel, mesh.facePositions[i * 3 + 2] * unitsPerPixel);
			let normal = Vector3(mesh.faceNormals[i * 3], mesh.faceNormals[i * 3 + 1], mesh.faceNormals[i * 3 + 2]);
			mMesh.AddVertex(position, normal, .White, .(mesh.faceUvs[i * 2], mesh.faceUvs[i * 2 + 1]));
		}
		for (int i < mesh.faceIndexCount)
			mMesh.Indices.Add(mesh.faceIndices[i]);
		mMesh.Upload();
		// The walls: solid, shaded by their own directions so unlit letters still look three-dimensional.
		EnsureSidesHolder(mGameObject);
		if (mSidesMesh == null)
			mSidesMesh = new Mesh();
		mSidesMesh.Name.Set(mGameObject.Name);
		mSidesMesh.Vertices.Clear();
		mSidesMesh.Indices.Clear();
		let light = Vector3(-0.35f, 0.55f, -0.75f).Normalized;
		for (int i < mesh.sideVertexCount)
		{
			let position = Vector3((mesh.sidePositions[i * 3] - pivotX) * unitsPerPixel,
				(mesh.sidePositions[i * 3 + 1] - pivotY) * unitsPerPixel, mesh.sidePositions[i * 3 + 2] * unitsPerPixel);
			let normal = Vector3(mesh.sideNormals[i * 3], mesh.sideNormals[i * 3 + 1], mesh.sideNormals[i * 3 + 2]);
			var shade = 1.0f;
			if (data.unlit)
				shade = 0.55f + 0.45f * Math.Max(Vector3.Dot(normal, light), 0);
			let color = Color(shade, shade, shade, 1);
			mSidesMesh.AddVertex(position, normal, color);
		}
		for (int i < mesh.sideIndexCount)
			mSidesMesh.Indices.Add(mesh.sideIndices[i]);
		mSidesMesh.Upload();
		mHasQuad = false;
		mExtruded = true;
		return true;
	}

	/// Warns about text that cannot be built, once per piece of text.
	void WarnOnce(StringView text, StringView problem)
	{
		if (mWarned == text)
			return;
		mWarned.Set(text);
		Log.Warning(scope $"The text \"{text}\" {problem}.");
	}

	/// Records what the current texture and geometry were made from.
	void NoteBuilt(StringView text, int32 pixelHeight)
	{
		mBuiltText.Set(text);
		mBuiltFont.Set(data.font.View);
		mBuiltSize = data.size;
		mBuiltDepth = data.depth;
		mBuiltUnlit = data.unlit;
		mBuiltPixels = pixelHeight;
		mBuiltAlign = (int32)data.alignment;
	}

	/// Four corners, in this object's own space, big enough for the block and with the texture's margin cut off.
	void BuildQuad()
	{
		if (!EnsureQuad())
			return;
		let width = mBlock.x, height = mBlock.y;
		float left, right;
		switch (data.alignment)
		{
		case .Left:
			left = 0;
			right = width;
		case .Right:
			left = -width;
			right = 0;
		case .Center:
			left = -width * 0.5f;
			right = width * 0.5f;
		}
		let bottom = -height * 0.5f, top = height * 0.5f;
		let u0 = mUvPad.x, u1 = 1 - mUvPad.x;
		let v0 = mUvPad.y, v1 = 1 - mUvPad.y;
		// The text is read from the -Z side (a camera looking along +Z, as the front of an object usually is): its
		// front faces the viewer when the object's rotation is its own. Clockwise seen from there, the way
		// Mesh.AddQuad expects its corners; the picture's first row is the top of the text.
		let normal = Vector3(0, 0, -1);
		let white = Color.White;
		mMesh.Vertices[0] = .(.(left, top, 0), normal, white.ToABGR(), .(u0, v0));
		mMesh.Vertices[1] = .(.(right, top, 0), normal, white.ToABGR(), .(u1, v0));
		mMesh.Vertices[2] = .(.(right, bottom, 0), normal, white.ToABGR(), .(u1, v1));
		mMesh.Vertices[3] = .(.(left, bottom, 0), normal, white.ToABGR(), .(u0, v1));
		mMesh.RecalculateBounds();
		mMesh.UpdateDynamic();
	}

	bool EnsureQuad()
	{
		if (mHasQuad)
			return true;
		if (!Gfx.Initialized)
			return false;
		mMesh.Vertices.Clear();
		mMesh.Indices.Clear();
		for (int i < 4)
			mMesh.AddVertex(.Zero, .(0, 0, -1), .White, .Zero);
		mMesh.AddTriangle(0, 1, 2);
		mMesh.AddTriangle(0, 2, 3);
		mMesh.UploadDynamic();
		mHasQuad = true;
		return true;
	}

	void ApplyLook(MeshRenderer renderer)
	{
		renderer.color = data.color;
		renderer.unlit = data.unlit;
		// The letters' faces are mostly clear: drawn see-through, over what is behind them.
		renderer.vertexAlpha = true;
		// Solid letters are closed: their backs are their own faces.
		renderer.backFaceCulling = mExtruded || !data.doubleSided;
		renderer.castShadows = data.castShadows;
		renderer.emissiveFromColor = data.glow > 0;
		renderer.emissiveIntensity = data.glow > 0 ? data.glow : 0;
		// The glow takes the text's own colour: emissive from colour multiplies it by the letters.
		renderer.emissive = data.glow > 0 ? .White : .Black;
		renderer.TextureOverride = mTexture;
	}

	/// The walls of solid letters: solid (or see-through with a see-through colour), lit like the faces.
	void ApplySidesLook()
	{
		let sides = SidesRenderer;
		if (!sides)
			return;
		if (sides.Enabled != mExtruded)
			sides.Enabled = mExtruded;
		if (!mExtruded)
			return;
		sides.color = data.color;
		sides.unlit = data.unlit;
		sides.vertexAlpha = data.color.a < 0.999f;
		sides.castShadows = data.castShadows;
		sides.emissiveFromColor = data.glow > 0;
		sides.emissiveIntensity = data.glow > 0 ? data.glow : 0;
		sides.emissive = data.glow > 0 ? .White : .Black;
	}

	/// Turns the text to the camera about its up axis (when it should face the viewer).
	void ApplyFacing()
	{
		if (data.facing != .Camera)
			return;
		let position = Transform.Position;
		let toCamera = Camera.ViewerPosition - position;
		let flat = Vector3(toCamera.x, 0, toCamera.z);
		if (flat.LengthSquared < 1.0e-8f)
			return;
		// Its front is -Z, so its +Z (Forward) points away from the camera. Both halves of solid letters turn
		// together, or the walls would stay behind.
		let rotation = Quaternion.LookRotation(-flat, .Up);
		if (let holder = Holder)
			holder.Transform.Rotation = rotation;
		if (let sides = SidesHolder)
			sides.Transform.Rotation = rotation;
	}

	/// The size of the text in metres (scene text) or pixels (screen text), without making a texture.
	public Vector2 Measure()
	{
		if (data.text.IsEmpty)
			return .Zero;
		if (data.mode == .Screen && Gfx.Initialized)
		{
			UIFonts.Push(data.font, Math.Max(data.size, 1));
			let extent = ImGui.CalcStringSize((StringView)data.text);
			ImGui.PopFont();
			return .(extent.x, extent.y);
		}
		let font = WorldTextFonts.Get(data.font);
		if (font == null)
			return .Zero;
		let text = (StringView)data.text;
		// On the screen (with no interface to ask, as in a headless run) the field is the pixel size itself.
		let screen = data.mode == .Screen;
		let pixelHeight = screen ? (float)Math.Clamp(Math.Round(data.size), 4.0f, 1024.0f) : (float)PixelHeight();
		int32 width = 0, height = 0, lineHeight = 0, pad = 0;
		let pixels = WorldTextFonts.tn_text_rasterize(font, text.Ptr, (int32)text.Length, pixelHeight,
			(int32)data.alignment, &width, &height, &lineHeight, &pad);
		if (pixels == null)
			return .Zero;
		WorldTextFonts.tn_text_bitmap_free(pixels);
		if (screen)
			return .(width - pad * 2, height - pad * 2);
		let unitsPerPixel = data.size / (lineHeight > 0 ? (float)lineHeight : Math.Max(pixelHeight, 1));
		return .((width - pad * 2) * unitsPerPixel, (height - pad * 2) * unitsPerPixel);
	}
}
