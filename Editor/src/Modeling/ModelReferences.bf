using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Reference images to model from (docs/modeling.md): pictures of the thing being made, from the front, side or top,
/// stood in the scene behind the model, square to that view, so the model can be traced over them in the matching
/// Model View or Scene view direction. Only the editor's views draw them (RenderView.EditorOnlyObjects); they are not
/// part of the scene, cannot be picked, and are kept for this project with the editor's settings
/// (references_<project>.txt). Each is an object of its own while shown (transient: never saved).
extension EditorApp
{
	class ModelReference
	{
		public String image = new .() ~ delete _;
		public ModelViewKind view = .Front;
		/// The middle of the thing the picture shows, in the scene.
		public Vector3 centre;
		/// How wide the picture is, in metres (its height follows the picture's shape).
		public float width = 2;
		/// How far behind the middle the picture stands, away from the view.
		public float behind = 1;
		public float opacity = 0.6f;
		public bool show = true;
		/// The picture's width over its height, read from the file.
		public float aspect = 1;
		public String aspectOf = new .() ~ delete _;
		public uint32 objectId;
	}

	List<ModelReference> mModelReferences ~ DeleteContainerAndItems!(_);
	Mesh mReferenceQuad ~ delete _;
	String mReferenceNewImage = new .() ~ delete _;
	int32 mReferenceNewView = (int32)ModelViewKind.Front;

	void ModelReferencesFile(String file)
	{
		RecentProjects.GetConfigFolder(file);
		file.AppendF("references_{}.txt", Path.GetFileName(scope String(Assets.ProjectPath)..TrimEnd('/'), .. scope .()));
	}

	void LoadModelReferences()
	{
		if (mModelReferences != null)
			return;
		mModelReferences = new .();
		let text = scope String();
		if (File.ReadAllText(ModelReferencesFile(.. scope .()), text) case .Err)
			return;
		for (let line in text.Split('\n'))
		{
			// view|image|x y z|width|behind|opacity|show
			let parts = scope List<StringView>(line.Split('|'));
			if (parts.Count < 7)
				continue;
			let reference = new ModelReference();
			for (int k < sModelViewNames.Count)
			{
				if (sModelViewNames[k] == parts[0])
					reference.view = (ModelViewKind)k;
			}
			reference.image.Set(parts[1]);
			let xyz = scope List<StringView>(parts[2].Split(' '));
			if (xyz.Count == 3)
				reference.centre = .(float.Parse(xyz[0]).GetValueOrDefault(), float.Parse(xyz[1]).GetValueOrDefault(), float.Parse(xyz[2]).GetValueOrDefault());
			reference.width = (float.Parse(parts[3]) case .Ok(let w)) ? w : 2;
			reference.behind = (float.Parse(parts[4]) case .Ok(let b)) ? b : 1;
			reference.opacity = (float.Parse(parts[5]) case .Ok(let o)) ? o : 0.6f;
			reference.show = parts[6].StartsWith("1");
			mModelReferences.Add(reference);
		}
	}

	void SaveModelReferences()
	{
		let text = scope String();
		for (let reference in mModelReferences)
			text.AppendF("{}|{}|{} {} {}|{}|{}|{}|{}\n", sModelViewNames[(int)reference.view], reference.image, reference.centre.x, reference.centre.y, reference.centre.z, reference.width, reference.behind, reference.opacity, reference.show ? 1 : 0);
		File.WriteAllText(ModelReferencesFile(.. scope .()), text).IgnoreError();
	}

	/// A picture's width over its height (1 if it cannot be read).
	static float ImageAspect(StringView image)
	{
		let full = Assets.ResolvePath(image, .. scope .());
		int32 width = 0, height = 0;
		let pixels = Native.tn_image_load(full.CStr(), &width, &height);
		if (pixels == null)
			return 1;
		Native.tn_image_free(pixels);
		return height > 0 ? (float)width / height : 1;
	}

	/// A square of side 1 facing back along +Z (the way its view looks), the picture the right way up, from both sides.
	Mesh ReferenceQuad()
	{
		if (mReferenceQuad != null)
			return mReferenceQuad;
		mReferenceQuad = new Mesh();
		mReferenceQuad.Name.Set("Reference");
		for (int side < 2)
		{
			let normal = Vector3(0, 0, side == 0 ? -1 : 1);
			let a = mReferenceQuad.AddVertex(.(-0.5f, -0.5f, 0), normal, .White, .(0, 1));
			let b = mReferenceQuad.AddVertex(.(-0.5f, 0.5f, 0), normal, .White, .(0, 0));
			let c = mReferenceQuad.AddVertex(.(0.5f, 0.5f, 0), normal, .White, .(1, 0));
			let d = mReferenceQuad.AddVertex(.(0.5f, -0.5f, 0), normal, .White, .(1, 1));
			if (side == 0)
			{
				mReferenceQuad.AddTriangle(a, b, c);
				mReferenceQuad.AddTriangle(a, c, d);
			}
			else
			{
				mReferenceQuad.AddTriangle(a, c, b);
				mReferenceQuad.AddTriangle(a, d, c);
			}
		}
		mReferenceQuad.Upload();
		return mReferenceQuad;
	}

	/// Keeps an object for each shown reference, where and as it should be; removes the others. Every frame.
	void SyncModelReferences()
	{
		LoadModelReferences();
		RenderView.EditorOnlyObjects.Clear();
		for (let reference in mModelReferences)
		{
			var object = reference.objectId != 0 ? mScene.FindById(reference.objectId) : null;
			let wanted = reference.show && !reference.image.IsEmpty && mPlay == .Edit;
			if (!wanted)
			{
				if (object != null)
					mScene.Destroy(object);
				reference.objectId = 0;
				continue;
			}
			if (object == null || object.IsDestroyed)
			{
				object = mScene.CreateGameObject(scope $"Reference ({sModelViewNames[(int)reference.view]})");
				object.Transient = true;
				let made = object.AddComponent<MeshRenderer>();
				made.castShadows = false;
				made.unlit = true;
				made.RuntimeMesh = ReferenceQuad();
				reference.objectId = object.Id;
			}
			if (reference.aspectOf != reference.image)
			{
				reference.aspect = ImageAspect(reference.image);
				reference.aspectOf.Set(reference.image);
			}
			let renderer = object.GetComponent<MeshRenderer>();
			if (renderer.texture != reference.image)
				renderer.texture.Set(reference.image);
			renderer.color = .(1, 1, 1, Math.Clamp(reference.opacity, 0.02f, 1));
			float yaw, pitch;
			ModelViewAngles(reference.view, out yaw, out pitch);
			let rotation = Quaternion.Euler(pitch, yaw, 0);
			object.Transform.Position = reference.centre + rotation * Vector3.Forward * reference.behind;
			object.Transform.Rotation = rotation;
			object.Transform.LocalScale = .(reference.width, reference.width / Math.Max(reference.aspect, 0.01f), 1);
			RenderView.EditorOnlyObjects.Add(object.Id);
		}
	}

	/// The Model window's Reference Images section.
	void DrawModelReferences()
	{
		LoadModelReferences();
		if (!ImGui.CollapsingHeader(scope String()..AppendF("Reference Images ({})###references", mModelReferences.Count).CStr()))
			return;
		ImGui.TextDisabled("Pictures to model from, stood behind the model square to a view.\nDrag an image from the Project window onto a picture field.");
		bool changed = false;
		int remove = -1;
		for (int i < mModelReferences.Count)
		{
			let reference = mModelReferences[i];
			ImGui.PushID((int32)i);
			ImGui.Separator();
			changed |= ImGui.Checkbox("##show", ref reference.show);
			ImGui.SameLine();
			ImGui.SetNextItemWidth(100);
			int32 view = (int32)reference.view - 1;
			if (RigCombo("##view", ref view, "Top;Bottom;Front;Back;Left;Right"))
			{
				reference.view = (ModelViewKind)(view + 1);
				changed = true;
			}
			ImGui.SameLine();
			if (ImGui.Button("Remove"))
				remove = i;
			ImGui.SetNextItemWidth(-70);
			changed |= ImGui.InputText("Picture", reference.image);
			changed |= AcceptImageDrop(reference.image);
			ImGui.SetNextItemWidth(-70);
			changed |= ImGui.DragFloat3("Middle", ref reference.centre, 0.01f);
			ImGui.SetNextItemWidth(-70);
			changed |= ImGui.DragFloat("Width", ref reference.width, 0.01f, 0.01f, 1000, "%.2f m");
			ImGui.SetNextItemWidth(-70);
			changed |= ImGui.DragFloat("Behind", ref reference.behind, 0.01f, -1000, 1000, "%.2f m");
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("How far behind the middle the picture stands, away from its view, so the model is in front of it.");
			ImGui.SetNextItemWidth(-70);
			changed |= ImGui.SliderFloat("Opacity", ref reference.opacity, 0.05f, 1, "%.2f");
			if (ImGui.Button("Middle at Selection", .(-1, 0)))
			{
				Vector3 at;
				float radius;
				ModelViewTarget(out at, out radius);
				reference.centre = at;
				reference.behind = radius + 0.05f;
				changed = true;
			}
			ImGui.PopID();
		}
		if (remove >= 0)
		{
			let reference = mModelReferences[remove];
			if (reference.objectId != 0 && mScene.FindById(reference.objectId) != null)
				mScene.Destroy(mScene.FindById(reference.objectId));
			mModelReferences.RemoveAt(remove);
			delete reference;
			changed = true;
		}
		ImGui.SeparatorText("Add");
		ImGui.SetNextItemWidth(100);
		var view = mReferenceNewView - 1;
		if (RigCombo("##newview", ref view, "Top;Bottom;Front;Back;Left;Right"))
			mReferenceNewView = view + 1;
		ImGui.SameLine();
		ImGui.SetNextItemWidth(-1);
		ImGui.InputText("##newimage", mReferenceNewImage, 0, "Picture (drag one here)");
		AcceptImageDrop(mReferenceNewImage);
		ImGui.BeginDisabled(mReferenceNewImage.IsEmpty);
		if (ImGui.Button("Add Reference Image", .(-1, 0)))
		{
			let reference = new ModelReference();
			reference.view = (ModelViewKind)mReferenceNewView;
			reference.image.Set(mReferenceNewImage);
			Vector3 at;
			float radius;
			ModelViewTarget(out at, out radius);
			reference.centre = at;
			reference.width = radius * 2;
			reference.behind = radius + 0.05f;
			mModelReferences.Add(reference);
			mReferenceNewImage.Clear();
			changed = true;
		}
		ImGui.EndDisabled();
		if (changed)
			SaveModelReferences();
	}

	/// An image dragged from the Project window onto the last field: its path. True when one was dropped.
	bool AcceptImageDrop(String into)
	{
		if (!ImGui.BeginDragDropTarget())
			return false;
		var dropped = false;
		let asset = ImGui.AcceptDragDropPayload("ASSET");
		if (asset != null)
		{
			let path = StringView((char8*)asset.data, asset.dataSize);
			let lower = scope String(path)..ToLower();
			if (lower.EndsWith(".png") || lower.EndsWith(".jpg") || lower.EndsWith(".jpeg") || lower.EndsWith(".tga") || lower.EndsWith(".bmp"))
			{
				into.Set(path);
				dropped = true;
			}
		}
		ImGui.EndDragDropTarget();
		return dropped;
	}
}
