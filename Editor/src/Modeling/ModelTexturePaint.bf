using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Painting a model's texture in the Scene view (docs/modeling.md): the brush paints the picture where it lies on
/// the model, through the faces' texture coordinates. Shift+click fills the face under the pointer, Alt+click picks
/// the colour there. Each stroke is written to the PNG when it ends; Undo Stroke takes strokes back.
extension EditorApp
{
	/// What the paint brush paints: the vertex colours, or the texture.
	bool mModelPaintTexture;
	float mModelPaintHardness = 0.5f;
	TexturePaint mModelPaint = new .() ~ delete _;
	uint32 mModelPaintObject;
	List<uint8[]> mModelPaintUndo = new .() ~ DeleteContainerAndItems!(_);
	bool mModelPaintDabbed;
	Vector3 mModelPaintLastDab;
	float mModelPaintUploaded;
	int32 mModelPaintSize = 1024;

	/// The paint picture for the model, loaded from its texture when that changed. False when it has none.
	bool ModelPaintReady(ModelMesh model)
	{
		let path = ModelTexturePath(model, .. scope .());
		if (path.IsEmpty)
			return false;
		if (mModelPaint.IsLoaded && mModelPaintObject == model.GameObject.Id && mModelPaint.path == path)
			return true;
		ClearAndDeleteItems!(mModelPaintUndo);
		mModelPaintObject = model.GameObject.Id;
		if (!mModelPaint.Load(path))
		{
			Log.Warning(scope $"Cannot paint {path}: it could not be read as a picture.");
			return false;
		}
		return true;
	}

	/// The Model window's settings for painting the texture.
	void DrawTexturePaintSettings(ModelMesh model, EditMesh mesh)
	{
		let path = ModelTexturePath(model, .. scope .());
		if (path.IsEmpty)
		{
			ImGui.TextDisabled("The model has no texture to paint yet.");
			ImGui.SetNextItemWidth(-140);
			ImGui.DragInt("Size (pixels)", ref mModelPaintSize, 8, 64, 4096);
			if (ImGui.Button("New Paint Texture", .(-1, 0)))
				NewModelPaintTexture(model, mesh);
			return;
		}
		ImGui.TextDisabled(scope $"Painting {path}" .CStr());
		ImGui.SetNextItemWidth(-90);
		ImGui.SliderFloat("Hardness", ref mModelPaintHardness, 0, 1);
		let all = scope List<int32>();
		for (int32 f < (int32)mesh.faces.Count)
			all.Add(f);
		if (MeshUV.Overlap(mesh, all, 64) > 0.001f)
			ImGui.TextColored(EditorTheme.Warning, "Faces share parts of the picture, so paint shows in two places. Smart Unwrap first.");
		if (HalfButton("Undo Stroke") && !mModelPaintUndo.IsEmpty && ModelPaintReady(model))
		{
			let last = mModelPaintUndo.PopBack();
			if (last.Count == mModelPaint.pixels.Count)
				last.CopyTo(mModelPaint.pixels);
			delete last;
			mModelPaint.Upload();
			mModelPaint.Save();
		}
		if (HalfButton("Fill Picked Faces", true) && ModelPaintReady(model))
		{
			let faces = scope List<int32>();
			for (let f in mModelFaces)
				faces.Add(f);
			if (faces.IsEmpty)
				Log.Warning("Pick faces first (3, then click them), then paint.");
			else
			{
				PushModelPaintUndo();
				mModelPaint.Fill(mesh, faces, mModelColor);
				mModelPaint.Upload();
				mModelPaint.Save();
			}
		}
		ImGui.TextDisabled("Drag to paint. Shift+click fills a face, Alt+click picks its colour.");
	}

	/// Makes a white picture for the model, gives the model it, and unwraps the model if its faces overlap.
	void NewModelPaintTexture(ModelMesh model, EditMesh mesh)
	{
		let name = scope String(model.GameObject.Name);
		for (var c in ref name.RawChars)
		{
			if (!c.IsLetterOrDigit && c != '_' && c != '-')
				c = '_';
		}
		let path = scope $"Textures/{name}_paint.png";
		mModelPaint.Create(path, mModelPaintSize, mModelPaintSize, .White);
		if (!mModelPaint.Save())
		{
			Log.Error(scope $"Could not write {path}.");
			return;
		}
		Assets.Forget(path);
		let all = scope List<int32>();
		for (int32 f < (int32)mesh.faces.Count)
			all.Add(f);
		if (MeshUV.Overlap(mesh, all, 64) > 0.001f)
		{
			MeshUV.SmartUnwrap(mesh, all);
			CommitModel(model);
			Log.Info("Unwrapped the model so every face has its own part of the picture.");
		}
		mModelPaintObject = model.GameObject.Id;
		ClearAndDeleteItems!(mModelPaintUndo);
		if (SetModelTexture(model, path))
			Log.Info(scope $"Made {path}.");
	}

	void PushModelPaintUndo()
	{
		if (mModelPaint.pixels == null)
			return;
		let copy = new uint8[mModelPaint.pixels.Count];
		mModelPaint.pixels.CopyTo(copy);
		mModelPaintUndo.Add(copy);
		while (mModelPaintUndo.Count > 16)
		{
			delete mModelPaintUndo[0];
			mModelPaintUndo.RemoveAt(0);
		}
	}

	/// One frame of texture painting, with the pointer on the model at a point (in the model's space) of a face.
	void UpdateTexturePaint(ModelMesh model, EditMesh mesh, int32 face, Vector3 localPoint)
	{
		if (!ModelPaintReady(model))
			return;
		let alt = ImGui.IsKeyDown(ImGui.Key.LeftAlt);
		let shift = ImGui.IsKeyDown(ImGui.Key.LeftShift);
		if (ImGui.IsMouseClicked(0))
		{
			if (alt)
			{
				MeshOps.Sample(mesh, mesh.faces[face], localPoint, let uv, ?);
				mModelColor = mModelPaint.Sample(uv);
				return;
			}
			PushModelPaintUndo();
			mModelPaintDabbed = false;
			if (shift)
			{
				var only = face;
				mModelPaint.Fill(mesh, .(&only, 1), mModelColor);
				mModelPaint.Upload();
				return;
			}
		}
		if (alt || shift)
			return;
		// Dabs a quarter of the brush apart along the stroke.
		let radius = mModelPaintRadius * ModelLocalPerWorld(model);
		if (mModelPaintDabbed && (localPoint - mModelPaintLastDab).Length < radius * 0.25f)
			return;
		mModelPaintDabbed = true;
		mModelPaintLastDab = localPoint;
		mModelPaint.Dab(mesh, localPoint, radius, mModelColor, mModelPaintStrength, mModelPaintHardness, true);
		// Shown a few times a second while painting (making the texture's smaller levels takes a moment).
		if (Time.RealTime - mModelPaintUploaded > 0.06f)
		{
			mModelPaint.Upload();
			mModelPaintUploaded = Time.RealTime;
		}
	}

	/// The end of a stroke: shown in full and written to the file.
	void EndTexturePaintStroke()
	{
		if (!mModelPaint.dirty)
			return;
		mModelPaint.Upload();
		if (!mModelPaint.Save())
			Log.Error(scope $"Could not write {mModelPaint.path}.");
	}
}
