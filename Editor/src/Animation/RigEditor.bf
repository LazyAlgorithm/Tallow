using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Window > Rigging (docs/rigging.md): rigs a still model the way Mixamo does, for people, cats, dogs and anything
/// else. Pick a template, drag its markers onto the model in the Scene view (chin, wrists, elbows, knees and groin
/// for a person; nose, neck, tail, paws, elbows, hocks and ears for a four-legged animal), and the skeleton is built
/// from them. Then: adjust the bones, make the weights automatically, paint them, try poses, and write a rigged .glb
/// that a Skinned Mesh Renderer plays animations on.
///
/// While rigging, the model's own renderer is hidden and the editor draws the model itself, posed, coloured by the
/// weights when painting. The rig is kept beside the model as a .trig file, so it can be picked up again.
/// Switches: --rigger <object name> starts rigging an object; --rigger-test runs its self-test (RigEditorTest.bf).
extension EditorApp
{
	enum RigStep
	{
		Markers,
		Bones,
		Weights,
		Pose
	}

	/// A rig as it was, for Undo.
	class RigSnapshot
	{
		public List<RigMarker> markers = new .() ~ delete _;
		public List<RigBone> bones = new .() ~ DeleteContainerAndItems!(_);
		public List<float> weights = new .() ~ delete _;
		public RigTemplate template;
		public RigSettings settings;
		public Vector3 facing;
	}

	bool mShowRig;
	bool mFocusRig;
	/// Docked beside the Inspector the next time it opens (when opened from the Window menu after being closed).
	bool mDockRig;
	Rig mRig ~ delete _;
	WeightPainter mRigPainter ~ delete _;
	RigRays mRigRays ~ delete _;
	uint32 mRigObject;
	String mRigPath = new .() ~ delete _;
	String mRiggedPath = new .() ~ delete _;
	RigStep mRigStep = .Markers;
	bool mRigSymmetry = true;
	/// The model shown on its own (the rest of the scene hidden in the Scene view).
	bool mRigIsolate = true;
	bool mRigCentre = true;
	bool mRigMoveChildren;
	int32 mRigMarker = -1;
	int32 mRigBone = -1;
	int32 mRigHover = -1;
	bool mRigDragging;
	bool mRigGizmoWasUsing;
	WeightTools.Brush mRigBrush = .Add;
	/// The brush's size, as a share of the model's height.
	float mRigRadius = 0.06f;
	float mRigStrength = 0.5f;
	float mRigValue = 0.5f;
	bool mRigMirrorPaint = true;
	bool mRigStroke;
	bool mRigBrushHit;
	Vector3 mRigBrushPoint;
	Vector3 mRigBrushNormal;
	/// How the model is coloured: 0 the selected bone's weights, 1 every bone in its own colour, 2 plain.
	int32 mRigColours = 0;
	bool mRigFlex;
	float mRigFlexTime;
	bool mRigWeightsStale;
	List<Vector3> mRigShown = new .() ~ delete _;
	List<Vector3> mRigShownNormals = new .() ~ delete _;
	List<uint32> mRigTriangles = new .() ~ delete _;
	List<RigSnapshot> mRigUndo = new .() ~ DeleteContainerAndItems!(_);
	List<RigSnapshot> mRigRedo = new .() ~ DeleteContainerAndItems!(_);
	String mRigMessage = new .() ~ delete _;
	bool mRigMessageBad;
	int32 mRiggerTestFrames;

	static readonly StringView[4] sRigSteps = .("1. Markers", "2. Bones", "3. Weights", "4. Pose");

	public bool Rigging => mRig != null;

	void RigMessage(StringView text, bool bad = false)
	{
		mRigMessage.Set(text);
		mRigMessageBad = bad;
		if (bad)
			Log.Warning(scope $"RIG: {text}");
		else
			Log.Info(scope $"RIG: {text}");
	}

	/// The object being rigged, if it still exists.
	GameObject RigTarget => mRig != null ? mScene.FindById(mRigObject) : null;

	// ---- starting and stopping ----

	/// The model file an object shows: a Mesh Renderer's .glb/.gltf, a rigged model's file, or (for an editable model)
	/// one written for it now. Empty when there is none.
	void RigSourceFor(GameObject target, String output)
	{
		let model = target.GetComponent<ModelMesh>();
		let renderer = target.GetComponent<MeshRenderer>();
		let skinned = target.GetComponent<SkinnedMeshRenderer>();
		if (skinned && !skinned.model.IsEmpty)
			output.Set(skinned.model);
		else if (model != null)
		{
			// An editable model is written out as a .glb to rig.
			let name = scope String(target.Name);
			for (var c in ref name.RawChars)
			{
				if (!c.IsLetterOrDigit && c != '_' && c != '-')
					c = '_';
			}
			output.Set(scope $"Models/{name}.glb");
			let names = scope List<StringView>();
			names.Add((renderer && !renderer.material.IsEmpty) ? renderer.material : "Material");
			for (let slot in model.materials.Split(';'))
				names.Add(slot);
			let full = Assets.ResolvePath(output, .. scope .());
			Directory.CreateDirectory(Path.GetDirectoryPath(full, .. scope .())).IgnoreError();
			if (!GlbWriter.Write(full, model.Edit, names))
				output.Clear();
		}
		else if (renderer && (Assets.IsModelPath(renderer.mesh) && !renderer.mesh.EndsWith(".tmesh", .OrdinalIgnoreCase)))
			output.Set(renderer.mesh);
	}

	/// Starts rigging an object's model: its rig file if it has one, else a new humanoid rig with the markers guessed.
	void StartRig(GameObject target)
	{
		StopRig();
		if (target == null)
			return;
		let source = RigSourceFor(target, .. scope .());
		if (source.IsEmpty)
		{
			RigMessage("Pick an object showing a model (.glb or .gltf), or an editable model.", true);
			return;
		}
		// A rigged copy made here: rig its still model again.
		var stillModel = scope String(source);
		if (stillModel.EndsWith("_Rigged.glb"))
		{
			let original = scope $"{stillModel.Substring(0, stillModel.Length - 11)}.glb";
			if (File.Exists(Assets.ResolvePath(original, .. scope .())))
				stillModel.Set(original);
		}
		mRigPath.Clear();
		mRiggedPath.Clear();
		Rig.PathsFor(stillModel, mRigPath, mRiggedPath);
		let problems = scope String();
		if (File.Exists(Assets.ResolvePath(mRigPath, .. scope .())))
		{
			mRig = Rig.Load(mRigPath, problems);
			if (mRig != null && !problems.IsEmpty)
				RigMessage(scope $"{mRigPath}: {problems}" , true);
		}
		if (mRig == null)
		{
			mRig = new Rig();
			if (!mRig.LoadSource(stillModel, problems))
			{
				RigMessage(problems, true);
				DeleteAndNullify!(mRig);
				return;
			}
			mRig.template = RigTemplates.GuessTemplate(mRig);
			RigTemplates.GuessMarkers(mRig);
		}
		mRigObject = target.Id;
		RenderView.HiddenObjects.Add(mRigObject);
		mRig.Triangles(mRigTriangles);
		mRigRays = new RigRays(mRig.positions, mRigTriangles);
		if (mRig.bones.IsEmpty)
		{
			RigTemplates.CentreMarkers(mRig, mRigRays);
			RigTemplates.Build(mRig, mRigRays);
		}
		mRigPainter = new WeightPainter(mRig);
		mRig.ResetPose();
		mRigStep = mRig.HasWeights ? .Weights : (mRig.bones.Count > 0 && mRig.template == .Custom ? .Bones : .Markers);
		mRigMarker = -1;
		mRigBone = mRig.bones.IsEmpty ? -1 : 0;
		mRigWeightsStale = false;
		mRigFlex = false;
		ClearAndDeleteItems!(mRigUndo);
		ClearAndDeleteItems!(mRigRedo);
		mShowRig = true;
		mFocusRig = true;
		RigFrontView();
		if (problems.IsEmpty)
			RigMessage(scope $"Rigging {stillModel} ({mRig.VertexCount} vertices).");
	}

	/// Stops rigging: the rig is saved, and the object is drawn as before.
	void StopRig()
	{
		if (mRig == null)
			return;
		mRig.ResetPose();
		mRig.Save(mRigPath);
		RenderView.HiddenObjects.Remove(mRigObject);
		mSceneView.hideRenderers = false;
		DeleteAndNullify!(mRig);
		DeleteAndNullify!(mRigPainter);
		DeleteAndNullify!(mRigRays);
		mRigDragging = false;
		mRigStroke = false;
	}

	/// Turns the Scene camera to look at the model, level, with all of it in view: a person from the front, a
	/// four-legged animal from its left side (where its legs, neck and tail all show).
	void RigFrontView()
	{
		let world = RigWorld;
		let facing = world.TransformDirection(mRig.template == .Quadruped ? -mRig.Right : mRig.facing);
		let flat = Vector3(facing.x, 0, facing.z);
		if (flat.LengthSquared < 1e-8f)
			return;
		let want = -flat.Normalized;
		// The yaw whose forward is closest to looking back along the model's facing.
		var bestYaw = mCamYaw;
		var best = float.MinValue;
		for (int degrees < 360)
		{
			let dot = Vector3.Dot(Quaternion.Euler(0, degrees, 0) * Vector3.Forward, want);
			if (dot > best)
			{
				best = dot;
				bestYaw = degrees;
			}
		}
		mCamYaw = bestYaw;
		mCamPitch = 0;
		let center = world.TransformPoint(mRig.bounds.Center);
		let height = world.TransformDirection(mRig.bounds.Size).Length;
		mCamPosition = center - want * Math.Max((mRig.template == .Quadruped ? Math.Max(mRig.bounds.Size.x, mRig.bounds.Size.z) : height) * 1.15f, 0.5f);
	}

	/// Brings the camera close to a marker, looking the same way: near enough to place fingertips.
	void RigLookAt(int marker)
	{
		let world = RigWorld;
		let at = world.TransformPoint(mRig.markers[marker].position);
		let size = world.TransformDirection(mRig.bounds.Size).Length;
		let distance = Math.Max(size * (RigTemplates.FingerOf(mRig.markers[marker].name) >= 0 ? 0.12f : 0.35f), 0.05f);
		let forward = Quaternion.Euler(mCamPitch, mCamYaw, 0) * Vector3.Forward;
		mCamPosition = at - forward * distance;
	}

	// ---- undo ----

	void PushRigUndo()
	{
		let snapshot = new RigSnapshot();
		Capture(snapshot);
		mRigUndo.Add(snapshot);
		ClearAndDeleteItems!(mRigRedo);
		// Painting a big model keeps a lot: fewer steps back for those.
		let most = mRig.weights.Count > 2000000 ? 8 : 32;
		while (mRigUndo.Count > most)
		{
			delete mRigUndo[0];
			mRigUndo.RemoveAt(0);
		}
	}

	void Capture(RigSnapshot snapshot)
	{
		snapshot.markers.AddRange(mRig.markers);
		for (let bone in mRig.bones)
			snapshot.bones.Add(new RigBone()..CopyFrom(bone));
		snapshot.weights.AddRange(mRig.weights);
		snapshot.template = mRig.template;
		snapshot.settings = mRig.settings;
		snapshot.facing = mRig.facing;
	}

	void Restore(RigSnapshot snapshot)
	{
		mRig.markers.Set(snapshot.markers);
		ClearAndDeleteItems!(mRig.bones);
		for (let bone in snapshot.bones)
			mRig.bones.Add(new RigBone()..CopyFrom(bone));
		mRig.weights.Set(snapshot.weights);
		mRig.template = snapshot.template;
		mRig.settings = snapshot.settings;
		mRig.facing = snapshot.facing;
		mRig.ResetPose();
		mRigPainter.RefreshMirror();
		if (mRigBone >= mRig.bones.Count)
			mRigBone = mRig.bones.IsEmpty ? -1 : 0;
	}

	/// Ctrl+Z while rigging: the rig's last change undone. False when there was nothing to undo.
	bool RigUndo(bool redo)
	{
		if (mRig == null)
			return false;
		let from = redo ? mRigRedo : mRigUndo;
		let to = redo ? mRigUndo : mRigRedo;
		if (from.IsEmpty)
			return true;
		let now = new RigSnapshot();
		Capture(now);
		to.Add(now);
		let last = from.PopBack();
		Restore(last);
		delete last;
		return true;
	}

	// ---- the model as drawn ----

	/// The object's matrix (the rig is in the model's own space).
	Matrix4 RigWorld => RigTarget?.Transform.LocalToWorld ?? .Identity;

	/// Where the model's vertices are drawn this frame: posed (and flexing), or at rest.
	void UpdateRigShown()
	{
		if (mRigFlex && mRig.HasWeights)
		{
			mRigFlexTime += Time.UnscaledDeltaTime;
			// Every bone swings a little, each a beat behind its parent: about the model's right-hand side, or for a
			// bone lying along it (arms held out, fingers), about the up-and-down bend square to the bone, so it bends
			// rather than only twisting about its own length.
			for (int b < mRig.bones.Count)
			{
				let wave = Math.Sin(mRigFlexTime * 2.5f - b * 0.3f) * 25;
				var along = mRig.bones[b].tail - mRig.bones[b].head;
				along = along.LengthSquared > 1e-12f ? along.Normalized : Vector3.Zero;
				var axis = mRig.Right - along * Vector3.Dot(mRig.Right, along);
				if (axis.LengthSquared < 0.25f)
					axis = Vector3.Cross(along, Vector3.Up);
				axis = axis.LengthSquared > 1e-8f ? axis.Normalized : mRig.Right;
				mRig.pose[b] = Quaternion.AngleAxis(wave, axis);
			}
		}
		var posed = false;
		for (let q in mRig.pose)
			posed |= q.x != 0 || q.y != 0 || q.z != 0;
		if (posed)
			mRig.Posed(mRigShown, mRigShownNormals);
		else
		{
			mRigShown.Set(mRig.positions);
			mRigShownNormals.Set(mRig.normals);
		}
	}

	/// A weight as a colour: blue for none, through cyan, green and yellow, to red for all.
	static Color Heat(float w)
	{
		let t = Math.Clamp(w, 0, 1);
		if (t <= 0)
			return .(0.12f, 0.14f, 0.45f, 1);
		Color[5] stops = .(.(0.1f, 0.2f, 0.8f, 1), .(0.1f, 0.75f, 0.85f, 1), .(0.2f, 0.85f, 0.2f, 1), .(0.95f, 0.85f, 0.1f, 1), .(0.95f, 0.15f, 0.1f, 1));
		let x = t * 4;
		let i = Math.Min((int)x, 3);
		return Color.Lerp(stops[i], stops[i + 1], x - i);
	}

	/// A bone's own colour (for showing every bone's share at once).
	static Color BoneColor(int bone)
	{
		let hue = (bone * 0.618034f) % 1;
		let h = hue * 6;
		let i = (int)h;
		let f = h - i;
		Color c;
		switch (i % 6)
		{
		case 0: c = .(1, f, 0, 1);
		case 1: c = .(1 - f, 1, 0, 1);
		case 2: c = .(0, 1, f, 1);
		case 3: c = .(0, 1 - f, 1, 1);
		case 4: c = .(f, 0, 1, 1);
		default: c = .(1, 0, 1 - f, 1);
		}
		return Color.Lerp(c, .White, 0.2f);
	}

	/// Draws the model (as posed and coloured), the bones and the markers into the Scene view.
	void DrawRigModel(Matrix4 world)
	{
		let toCamera = -mSceneCamera.forward;
		let showWeights = mRigStep == .Weights && mRig.HasWeights;
		let colours = showWeights ? mRigColours : 2;
		let count = mRig.bones.Count;
		let vertexColors = scope uint32[mRigShown.Count];
		for (int v < mRigShown.Count)
		{
			var c = EditMesh.ColorFromABGR(mRig.colors[v]);
			c = Color.Lerp(c, .(0.82f, 0.82f, 0.85f, 1), 0.35f);
			if (colours == 0 && mRigBone >= 0 && mRigBone < count)
				c = Heat(mRig.Weight(v, mRigBone));
			else if (colours == 1 && mRig.HasWeights)
			{
				var mix = Color(0, 0, 0, 1);
				let row = mRig.weights.Ptr + v * count;
				for (int b < count)
				{
					if (row[b] > 0)
					{
						let bc = BoneColor(b);
						mix = .(mix.r + bc.r * row[b], mix.g + bc.g * row[b], mix.b + bc.b * row[b], 1);
					}
				}
				c = mix;
			}
			// Lit from the camera, so the shape reads.
			let n = world.TransformDirection(mRigShownNormals[v]).Normalized;
			let light = 0.35f + 0.65f * Math.Abs(Vector3.Dot(n, toCamera));
			vertexColors[v] = Color(c.r * light, c.g * light, c.b * light, 1).ToABGR();
		}
		let triangles = Gizmos.Triangles.Vertices;
		for (int i = 0; i + 2 < mRigTriangles.Count; i += 3)
		{
			for (int k < 3)
			{
				let v = mRigTriangles[i + k];
				LineVertex vertex;
				vertex.position = world.TransformPoint(mRigShown[v]);
				vertex.color = vertexColors[v];
				triangles.Add(vertex);
			}
		}
	}

	/// The bones' joints and ends as drawn (posed), in the model's space.
	void RigJoints(List<Vector3> heads, List<Vector3> ends)
	{
		heads.Clear();
		ends.Clear();
		let matrices = scope List<Matrix4>();
		mRig.PoseMatrices(matrices);
		for (int b < mRig.bones.Count)
		{
			heads.Add(matrices[b].TransformPoint(mRig.bones[b].head));
			ends.Add(matrices[b].TransformPoint(mRig.End(b)));
		}
	}

	void DrawRigBones(Matrix4 world, List<Vector3> heads, List<Vector3> ends)
	{
		let size = Math.Max(mRig.bounds.Size.y, 0.01f) * world.TransformDirection(.(0, 1, 0)).Length;
		let accent = EditorTheme.Accent;
		for (int b < mRig.bones.Count)
		{
			let bone = mRig.bones[b];
			let a = world.TransformPoint(heads[b]);
			let e = world.TransformPoint(ends[b]);
			let selected = b == mRigBone;
			let color = selected ? Color(1, 0.85f, 0.2f, 1) : (bone.deform ? Color(0.35f, 0.75f, 1, 0.95f) : Color(0.6f, 0.6f, 0.65f, 0.6f));
			// No bigger than a quarter of the bone, so fingers' joints do not hide the fingers.
			let radius = Math.Min(size * (selected ? 0.012f : 0.008f), Math.Max((e - a).Length * 0.25f, size * 0.0015f));
			Gizmos.OnTopLines.Sphere(a, radius, color);
			if (bone.deform)
			{
				// A thin diamond along the bone, so its direction shows.
				let dir = e - a;
				let length = dir.Length;
				if (length > 1e-5f)
				{
					var side = Vector3.Cross(dir / length, mSceneCamera.forward);
					if (side.LengthSquared < 1e-6f)
						side = Vector3.Cross(dir / length, .(0, 1, 0));
					side = side.Normalized * Math.Min(length * 0.12f, size * 0.02f);
					let mid = a + dir * 0.2f;
					Gizmos.OnTopLines.Line(a, mid + side, color);
					Gizmos.OnTopLines.Line(a, mid - side, color);
					Gizmos.OnTopLines.Line(mid + side, e, color);
					Gizmos.OnTopLines.Line(mid - side, e, color);
				}
			}
			else
				Gizmos.OnTopLines.Line(a, e, color);
		}
		if (mRigBone >= 0 && mRigBone < mRig.bones.Count && mRigStep != .Markers)
		{
			let at = world.TransformPoint(heads[mRigBone]);
			if (SceneToScreen(at, mSceneOrigin, mSceneSize, let screen))
				ImGui.DrawText(.(screen.x + 10, screen.y - 8), accent, mRig.bones[mRigBone].name.CStr());
		}
	}

	/// The middle across the model, for mirroring markers: the middle markers' (chin, groin, nose...), else the box's.
	float RigMiddle()
	{
		let right = mRig.Right;
		var sum = 0.0f;
		var count = 0;
		for (let marker in mRig.markers)
		{
			if (marker.mirror < 0)
			{
				sum += Vector3.Dot(marker.position, right);
				count++;
			}
		}
		return count > 0 ? sum / count : Vector3.Dot(mRig.bounds.Center, right);
	}

	/// A point put in the middle of the part of the model it is in, along the way the camera looks (what cannot be
	/// told from where it was dropped).
	Vector3 RigCentreInView(Vector3 point)
	{
		let view = RigWorld.Inverse.TransformDirection(mSceneCamera.forward);
		if (view.LengthSquared < 1e-10f)
			return point;
		return mRigRays.Centre(point, view.Normalized, Math.Max(mRig.bounds.Size.Length, 1e-3f) * 2);
	}

	/// The marker's mirror put on the other side of the middle.
	void MirrorMarker(int marker)
	{
		let other = mRig.markers[marker].mirror;
		if (other < 0)
			return;
		let right = mRig.Right;
		let p = mRig.markers[marker].position;
		let lateral = Vector3.Dot(p, right) - RigMiddle();
		mRig.markers[other].position = p - right * (2 * lateral);
	}

	/// Where the pointer's ray meets the model as drawn (in the model's space): the nearest triangle hit.
	bool RigRaycast(Matrix4 toLocal, Ray worldRay, out Vector3 point, out Vector3 normal)
	{
		point = default;
		normal = default;
		let origin = toLocal.TransformPoint(worldRay.origin);
		let dir = (toLocal.TransformPoint(worldRay.origin + worldRay.direction) - origin).Normalized;
		var best = float.MaxValue;
		for (int i = 0; i + 2 < mRigTriangles.Count; i += 3)
		{
			let a = mRigShown[mRigTriangles[i]], b = mRigShown[mRigTriangles[i + 1]], c = mRigShown[mRigTriangles[i + 2]];
			let e1 = b - a, e2 = c - a;
			let pv = Vector3.Cross(dir, e2);
			let det = Vector3.Dot(e1, pv);
			if (Math.Abs(det) < 1e-12f)
				continue;
			let inv = 1 / det;
			let tv = origin - a;
			let u = Vector3.Dot(tv, pv) * inv;
			if (u < 0 || u > 1)
				continue;
			let qv = Vector3.Cross(tv, e1);
			let v = Vector3.Dot(dir, qv) * inv;
			if (v < 0 || u + v > 1)
				continue;
			let t = Vector3.Dot(e2, qv) * inv;
			if (t > 0 && t < best)
			{
				best = t;
				point = origin + dir * t;
				normal = Vector3.Cross(e1, e2).Normalized;
			}
		}
		return best < float.MaxValue;
	}

	/// The joint (or marker) under the pointer, within a few pixels: its index, or -1.
	int32 RigPick(Matrix4 world, List<Vector3> points, ImGui.Vec2 mouse, float pixels = 9)
	{
		var best = (int32) - 1;
		var bestDistance = pixels * pixels;
		for (int32 i < (int32)points.Count)
		{
			if (!SceneToScreen(world.TransformPoint(points[i]), mSceneOrigin, mSceneSize, let screen))
				continue;
			let dx = screen.x - mouse.x, dy = screen.y - mouse.y;
			if (dx * dx + dy * dy < bestDistance)
			{
				bestDistance = dx * dx + dy * dy;
				best = i;
			}
		}
		return best;
	}

	/// A point of the model's space dragged with the pointer: kept at the same depth from the camera.
	Vector3 RigDragPoint(Matrix4 world, Matrix4 toLocal, Vector3 local, ImGui.Vec2 mouse)
	{
		let ray = RigMouseRay(mouse);
		let at = world.TransformPoint(local);
		let normal = mSceneCamera.forward;
		let denom = Vector3.Dot(ray.direction, normal);
		if (Math.Abs(denom) < 1e-6f)
			return local;
		let t = Vector3.Dot(at - ray.origin, normal) / denom;
		return toLocal.TransformPoint(ray.origin + ray.direction * t);
	}

	/// The Scene view while rigging: drawing the rig and handling the pointer. True: the rigger has the mouse (no
	/// picking objects, no transform gizmo).
	bool UpdateRigTools(GameObject selected, ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		if (mRig == null)
			return false;
		let target = RigTarget;
		if (target == null || mPlay != .Edit)
		{
			StopRig();
			return false;
		}
		let world = RigWorld;
		let toLocal = world.Inverse;
		mSceneView.hideRenderers = mRigIsolate;
		UpdateRigShown();
		DrawRigModel(world);
		let heads = scope List<Vector3>();
		let ends = scope List<Vector3>();
		RigJoints(heads, ends);
		if (mRigStep != .Markers || mRig.template == .Custom)
			DrawRigBones(world, heads, ends);
		let mouse = ImGui.GetMousePos();
		let pointerFree = mSceneHovered && !mFlying;
		switch (mRigStep)
		{
		case .Markers:
			if (mRig.template != .Custom)
			{
				// The skeleton as it would be built, faintly, under the markers.
				DrawRigBones(world, heads, ends);
				UpdateRigMarkers(world, toLocal, mouse, pointerFree);
			}
		case .Bones:
			UpdateRigBones(world, toLocal, heads, mouse, pointerFree);
		case .Weights:
			UpdateRigPaint(world, toLocal, heads, mouse, pointerFree);
		case .Pose:
			UpdateRigPose(world, heads, mouse, pointerFree);
		}
		return true;
	}

	void UpdateRigMarkers(Matrix4 world, Matrix4 toLocal, ImGui.Vec2 mouse, bool pointerFree)
	{
		let points = scope List<Vector3>();
		for (let marker in mRig.markers)
			points.Add(marker.position);
		// Markers not used (ears with ears off) are not shown.
		mRigHover = -1;
		if (!mRigDragging && pointerFree)
		{
			mRigHover = RigPick(world, points, mouse, 12);
			if (mRigHover >= 0 && !RigTemplates.Used(mRig, mRig.markers[mRigHover]))
				mRigHover = -1;
		}
		if (pointerFree && ImGui.IsMouseClicked(0) && mRigHover >= 0)
		{
			PushRigUndo();
			mRigMarker = mRigHover;
			mRigDragging = true;
		}
		if (mRigDragging)
		{
			if (ImGui.IsMouseDown(0))
			{
				mRig.markers[mRigMarker].position = RigDragPoint(world, toLocal, mRig.markers[mRigMarker].position, mouse);
				if (mRigSymmetry)
					MirrorMarker(mRigMarker);
				RigTemplates.Build(mRig, mRigRays);
			}
			else
			{
				mRigDragging = false;
				// Into the middle of the body along the view (as Mixamo's markers, placed on a flat front view, are).
				if (mRigCentre && !RigTemplates.OnSurface(mRig.markers[mRigMarker].name))
				{
					mRig.markers[mRigMarker].position = RigCentreInView(mRig.markers[mRigMarker].position);
					if (mRigSymmetry)
						MirrorMarker(mRigMarker);
				}
				RigTemplates.Build(mRig, mRigRays);
				mRigPainter.RefreshMirror();
			}
		}
		// The markers, as discs with their names.
		SceneToScreen(world.TransformPoint(mRig.bounds.Center), mSceneOrigin, mSceneSize, var middle);
		for (int i < mRig.markers.Count)
		{
			let marker = mRig.markers[i];
			if (!RigTemplates.Used(mRig, marker))
				continue;
			if (!SceneToScreen(world.TransformPoint(marker.position), mSceneOrigin, mSceneSize, let screen))
				continue;
			let side = marker.name.StartsWith("Left") ? Color(0.3f, 0.85f, 0.4f, 1) : (marker.name.StartsWith("Right") ? Color(0.95f, 0.55f, 0.2f, 1) : Color(0.95f, 0.85f, 0.2f, 1));
			let active = i == mRigHover || i == mRigMarker;
			// Fingertips are small and named only when pointed at, so a hand is not buried in labels.
			let finger = RigTemplates.FingerOf(marker.name) >= 0;
			let radius = finger ? (active ? 7.0f : 5.0f) : (active ? 9.0f : 7.0f);
			ImGui.DrawCircleFilled(screen, radius, side);
			ImGui.DrawCircle(screen, radius, .(0, 0, 0, 0.8f), finger ? 1.5f : 2);
			if (active || (mRigHover < 0 && !finger))
			{
				// On the outer side, so a pair's names do not run into each other; a pair seen one behind the other (an
				// animal from the side) is named once, by the nearer marker, without its side.
				let label = scope String(marker.name);
				if (marker.mirror >= 0 && SceneToScreen(world.TransformPoint(mRig.markers[marker.mirror].position), mSceneOrigin, mSceneSize, let other))
				{
					let dx = other.x - screen.x, dy = other.y - screen.y;
					if (dx * dx + dy * dy < 30 * 30)
					{
						let mine = (world.TransformPoint(marker.position) - mSceneCamera.position).LengthSquared;
						let theirs = (world.TransformPoint(mRig.markers[marker.mirror].position) - mSceneCamera.position).LengthSquared;
						if (mine > theirs || (mine == theirs && marker.mirror < i))
							continue;
						if (label.StartsWith("Left "))
							label.Remove(0, 5);
						else if (label.StartsWith("Right "))
							label.Remove(0, 6);
					}
				}
				var x = screen.x + 11;
				if (marker.mirror >= 0 && screen.x < middle.x - 30)
					x = screen.x - 11 - ImGui.CalcTextSize(label.CStr()).x;
				ImGui.DrawText(.(x + 1, screen.y - 8), .(0, 0, 0, 0.7f), label.CStr());
				ImGui.DrawText(.(x, screen.y - 9), side, label.CStr());
			}
		}
		if (mRigHover >= 0)
			ImGui.SetTooltip(scope $"{mRig.markers[mRigHover].name}: {RigTemplates.Hint(mRig.markers[mRigHover].name)}" .CStr());
	}

	/// The gizmo on a point of the model (moved: true, with the new point in the model's space).
	bool RigGizmo(Matrix4 world, Matrix4 toLocal, int32 operation, ref Matrix4 matrix)
	{
		ImGui.tn_gizmo_begin(mSceneOrigin.x, mSceneOrigin.y, mSceneSize.x, mSceneSize.y, false);
		var view = mSceneCamera.view;
		var projection = mSceneCamera.projection;
		return ImGui.tn_gizmo_manipulate(&view.m, &projection.m, operation, operation == 1, &matrix.m, null);
	}

	void UpdateRigBones(Matrix4 world, Matrix4 toLocal, List<Vector3> heads, ImGui.Vec2 mouse, bool pointerFree)
	{
		var overGizmo = false;
		if (mRigBone >= 0 && mRigBone < mRig.bones.Count)
		{
			var matrix = Matrix4.Translate(world.TransformPoint(mRig.bones[mRigBone].head));
			let dragging = ImGui.tn_gizmo_is_using();
			if (dragging && !mRigGizmoWasUsing)
				PushRigUndo();
			if (RigGizmo(world, toLocal, 0, ref matrix))
			{
				let now = toLocal.TransformPoint(.(matrix.m[12], matrix.m[13], matrix.m[14]));
				MoveRigJoint(mRigBone, now);
			}
			if (!dragging && mRigGizmoWasUsing)
			{
				// Let go: into the middle of the body along the view, if asked.
				if (mRigCentre)
					MoveRigJoint(mRigBone, RigCentreInView(mRig.bones[mRigBone].head));
				mRigWeightsStale |= mRig.HasWeights;
				mRigPainter.RefreshMirror();
			}
			mRigGizmoWasUsing = ImGui.tn_gizmo_is_using();
			overGizmo = ImGui.tn_gizmo_is_over() || mRigGizmoWasUsing;
		}
		if (!pointerFree || overGizmo || !ImGui.IsMouseClicked(0))
			return;
		let picked = RigPick(world, heads, mouse);
		if (picked >= 0)
		{
			mRigBone = picked;
			return;
		}
		// Shift+click on the model: a new bone from the selected one to there (in the middle of the body as seen).
		if (ImGui.IsKeyDown(ImGui.Key.LeftShift) && RigRaycast(toLocal, RigMouseRay(mouse), let point, ?))
		{
			PushRigUndo();
			let view = toLocal.TransformDirection(mSceneCamera.forward).Normalized;
			let inside = mRigRays.Centre(point, view, Math.Max(mRig.bounds.Size.Length, 1e-3f) * 2);
			let parent = mRigBone;
			let tail = inside + (parent >= 0 ? (inside - mRig.bones[parent].head).Normalized * 0.1f * mRig.bounds.Size.y : Vector3(0, 0.1f * mRig.bounds.Size.y, 0));
			let name = scope $"Bone{mRig.bones.Count}";
			mRigBone = (int32)mRig.AddBone(name, parent, inside, tail);
			if (parent >= 0)
				mRig.bones[parent].tail = inside;
			mRig.ResetPose();
			mRigPainter.RefreshMirror();
			mRigWeightsStale |= mRig.HasWeights;
		}
	}

	/// Moves a joint (its children with it if asked; its mirror too with Symmetry on).
	void MoveRigJoint(int bone, Vector3 to)
	{
		void Move(int b, Vector3 delta)
		{
			mRig.bones[b].head = mRig.bones[b].head + delta;
			mRig.bones[b].tail = mRig.bones[b].tail + delta;
			if (mRigMoveChildren)
			{
				for (int c < mRig.bones.Count)
				{
					if (mRig.bones[c].parent == b)
						Move(c, delta);
				}
			}
		}
		let delta = to - mRig.bones[bone].head;
		Move(bone, delta);
		let mirror = mRig.MirrorBone(bone);
		if (mRigSymmetry && mirror >= 0)
		{
			let right = mRig.Right;
			let mirrored = delta - right * (2 * Vector3.Dot(delta, right));
			Move(mirror, mirrored);
		}
	}

	void UpdateRigPaint(Matrix4 world, Matrix4 toLocal, List<Vector3> heads, ImGui.Vec2 mouse, bool pointerFree)
	{
		mRigBrushHit = false;
		if (!mRig.HasWeights)
			return;
		let radius = mRigRadius * Math.Max(mRig.bounds.Size.y, 1e-3f);
		if (pointerFree && RigRaycast(toLocal, RigMouseRay(mouse), let point, let normal))
		{
			mRigBrushHit = true;
			mRigBrushPoint = point;
			mRigBrushNormal = normal;
			let worldRadius = radius * world.TransformDirection(.(0, 1, 0)).Length;
			Gizmos.OnTopLines.Circle(world.TransformPoint(point), world.TransformDirection(normal).Normalized, worldRadius, .(1, 1, 1, 0.9f));
			// Ctrl+click: the bone that moves this spot most.
			if (ImGui.IsMouseClicked(0) && ImGui.IsKeyDown(ImGui.Key.LeftCtrl))
			{
				let place = mRigPainter.Nearest(point, mRigShown);
				if (place >= 0)
				{
					let v = mRigPainter.verticesAt[place][0];
					var best = 0;
					for (int b < mRig.bones.Count)
					{
						if (mRig.Weight(v, b) > mRig.Weight(v, best))
							best = b;
					}
					mRigBone = (int32)best;
				}
				return;
			}
			if (ImGui.IsMouseDown(0) && !ImGui.IsKeyDown(ImGui.Key.LeftCtrl) && mRigBone >= 0)
			{
				if (!mRigStroke)
				{
					PushRigUndo();
					mRigStroke = true;
				}
				// A steady flow while the button is held (Set goes straight there).
				let amount = mRigBrush == .Set ? mRigStrength : Math.Clamp(mRigStrength * Time.UnscaledDeltaTime * 6, 0, 1);
				mRigPainter.Dab(mRigBrush, mRigBone, point, radius, amount, mRigValue, mRigMirrorPaint, mRigShown);
			}
		}
		else if (pointerFree && ImGui.IsMouseClicked(0))
		{
			// Off the model: a joint picks its bone.
			let picked = RigPick(world, heads, mouse);
			if (picked >= 0)
				mRigBone = picked;
		}
		if (!ImGui.IsMouseDown(0))
			mRigStroke = false;
	}

	void UpdateRigPose(Matrix4 world, List<Vector3> heads, ImGui.Vec2 mouse, bool pointerFree)
	{
		var overGizmo = false;
		if (mRigBone >= 0 && mRigBone < mRig.bones.Count && !mRigFlex)
		{
			// The bone's turn, as a gizmo at its joint: the parent's posed turn times its own.
			let matrices = scope List<Matrix4>();
			mRig.PoseMatrices(matrices);
			let parent = mRig.bones[mRigBone].parent;
			let parentTurn = parent >= 0 ? RotationOf(matrices[parent]) : Quaternion.Identity;
			let worldTurn = RotationOf(world);
			var matrix = Matrix4.TRS(world.TransformPoint(heads[mRigBone]), worldTurn * parentTurn * mRig.pose[mRigBone], .One);
			if (RigGizmo(world, world.Inverse, 1, ref matrix))
			{
				let turned = RotationOf(matrix);
				mRig.pose[mRigBone] = (worldTurn * parentTurn).Conjugate * turned;
			}
			overGizmo = ImGui.tn_gizmo_is_over() || ImGui.tn_gizmo_is_using();
		}
		if (pointerFree && !overGizmo && ImGui.IsMouseClicked(0))
		{
			let picked = RigPick(world, heads, mouse);
			if (picked >= 0)
				mRigBone = picked;
		}
	}

	static Quaternion RotationOf(Matrix4 m)
	{
		m.Decompose(?, let q, ?);
		return q;
	}

	// ---- the window ----

	void DrawRigWindow()
	{
		TickRiggerTest();
		if (!mShowRig)
		{
			if (mRig != null)
				StopRig();
			return;
		}
		if (mDockRig && mInspectorDock != 0)
		{
			ImGui.SetNextWindowDockID(mInspectorDock);
			mDockRig = false;
		}
		if (mFocusRig)
		{
			ImGui.SetNextWindowFocus();
			mFocusRig = false;
		}
		if (ImGui.Begin("Rigging", &mShowRig))
		{
			if (mRig == null)
				DrawRigStart();
			else
				DrawRigPanel();
			if (!mRigMessage.IsEmpty)
				ImGui.TextColored(mRigMessageBad ? EditorTheme.Warning : EditorTheme.Good, mRigMessage.CStr());
		}
		ImGui.End();
	}

	void DrawRigStart()
	{
		ImGui.TextWrapped("Rigs a still model so it can be animated: a person (with Mixamo's bone names, so Mixamo's animations play on it), a four-legged animal, or anything else with bones you place yourself.");
		let selected = Selected;
		let source = selected != null ? RigSourceForDisplay(selected, .. scope .()) : scope String();
		ImGui.BeginDisabled(source.IsEmpty || mPlay != .Edit);
		if (ImGui.Button(source.IsEmpty ? "Select a model to rig" : scope $"Rig {selected.Name}" .CStr(), .(-1, 0)))
			StartRig(selected);
		ImGui.EndDisabled();
		if (!source.IsEmpty)
			ImGui.TextDisabled(scope $"Model: {source}" .CStr());
	}

	/// What RigSourceFor would rig, without writing anything.
	void RigSourceForDisplay(GameObject target, String output)
	{
		let skinned = target.GetComponent<SkinnedMeshRenderer>();
		let renderer = target.GetComponent<MeshRenderer>();
		if (skinned && !skinned.model.IsEmpty)
			output.Set(skinned.model);
		else if (target.GetComponent<ModelMesh>() != null)
			output.Set("its editable model (written as a .glb)");
		else if (renderer && (Assets.IsModelPath(renderer.mesh) && !renderer.mesh.EndsWith(".tmesh", .OrdinalIgnoreCase)))
			output.Set(renderer.mesh);
	}

	void DrawRigPanel()
	{
		let target = RigTarget;
		ImGui.TextDisabled(scope $"{mRig.source}: {mRig.VertexCount} vertices, {mRig.bones.Count} bones" .CStr());
		if (HalfButton(mRig.template == .Quadruped ? "Side View" : "Front View"))
			RigFrontView();
		if (HalfButton("Stop Rigging", true))
		{
			StopRig();
			return;
		}
		ImGui.Checkbox("Show the model on its own", ref mRigIsolate);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Hides the rest of the scene in the Scene view while rigging.");
		// The steps, as tabs.
		for (int i < 4)
		{
			if (i > 0)
				ImGui.SameLine();
			let step = (RigStep)i;
			let disabled = (step == .Weights || step == .Pose) && mRig.bones.IsEmpty;
			ImGui.BeginDisabled(disabled);
			if (mRigStep == step)
				ImGui.PushStyleColor(ImGui.Col.Button, EditorTheme.Accent);
			if (ImGui.Button(scope String(sRigSteps[i]).CStr()))
				SetRigStep(step);
			if (mRigStep == step)
				ImGui.PopStyleColor();
			ImGui.EndDisabled();
		}
		ImGui.Separator();
		switch (mRigStep)
		{
		case .Markers: DrawRigMarkersPanel();
		case .Bones: DrawRigBonesPanel();
		case .Weights: DrawRigWeightsPanel();
		case .Pose: DrawRigPosePanel();
		}
		ImGui.SeparatorText("Save");
		ImGui.SetNextItemWidth(-90);
		ImGui.InputText("Rigged model", mRiggedPath);
		ImGui.BeginDisabled(!mRig.HasWeights);
		if (ImGui.Button("Export Rigged Model", .(-1, 0)))
			ExportRig();
		ImGui.EndDisabled();
		ImGui.BeginDisabled(!mRig.HasWeights || target == null);
		if (ImGui.Button("Export and Use on This Object", .(-1, 0)))
		{
			if (ExportRig())
				UseRigged(target);
		}
		ImGui.EndDisabled();
		ImGui.TextDisabled(scope $"The rig is kept in {mRigPath} (saved when you stop)." .CStr());
	}

	void SetRigStep(RigStep step)
	{
		mRigStep = step;
		mRigFlex = false;
		mRig.ResetPose();
		if ((step == .Weights || step == .Pose) && !mRig.HasWeights && !mRig.bones.IsEmpty)
			MakeRigWeights();
		if (mRigBone < 0 && !mRig.bones.IsEmpty)
			mRigBone = 0;
	}

	void MakeRigWeights()
	{
		PushRigUndo();
		let started = Time.RealTime;
		if (AutoWeights.Make(mRig))
		{
			mRigPainter.Refresh();
			mRigWeightsStale = false;
			RigMessage(scope $"Weights made for {mRig.VertexCount} vertices and {mRig.bones.Count} bones in {Time.RealTime - started:0.00} s.");
		}
		else
			RigMessage("No bones bend the model: add some first.", true);
	}

	void DrawRigMarkersPanel()
	{
		ImGui.TextWrapped("Pick what the model is, then drag the markers in the Scene view onto it. A person is easiest from the front, an animal from the side. The skeleton follows.");
		var template = (int32)mRig.template;
		ImGui.SetNextItemWidth(-90);
		if (RigCombo("Template", ref template, "Humanoid (Mixamo bones);Quadruped (cat, dog, horse...);Custom (place bones yourself)"))
		{
			PushRigUndo();
			mRig.template = (RigTemplate)template;
			ClearAndDeleteItems!(mRig.bones);
			mRig.weights.Clear();
			RigTemplates.GuessMarkers(mRig);
			RigTemplates.CentreMarkers(mRig, mRigRays);
			RigTemplates.Build(mRig, mRigRays);
			mRigPainter.RefreshMirror();
			mRigBone = mRig.bones.IsEmpty ? -1 : 0;
			RigFrontView();
			if (mRig.template == .Custom)
				SetRigStep(.Bones);
		}
		if (mRig.template == .Custom)
		{
			ImGui.TextDisabled("A custom rig has no markers: place its bones in step 2.");
			return;
		}
		// Which way it faces.
		var facing = (int32)(mRig.facing.z < -0.5f ? 0 : (mRig.facing.z > 0.5f ? 1 : (mRig.facing.x < 0 ? 2 : 3)));
		ImGui.SetNextItemWidth(-90);
		if (RigCombo("Faces", ref facing, "-Z (glTF's front);+Z;-X;+X"))
		{
			PushRigUndo();
			Vector3[4] directions = .(.(0, 0, -1), .(0, 0, 1), .(-1, 0, 0), .(1, 0, 0));
			mRig.facing = directions[facing];
			RigTemplates.GuessMarkers(mRig);
			mRig.facing = directions[facing];
			RigTemplates.CentreMarkers(mRig, mRigRays);
			RigTemplates.Build(mRig, mRigRays);
			mRigPainter.RefreshMirror();
		}
		var changed = false;
		ImGui.SetNextItemWidth(-90);
		if (mRig.template == .Humanoid)
		{
			var fingers = (int32)(mRig.settings.fingers >= 5 ? 2 : (mRig.settings.fingers >= 2 ? 1 : 0));
			if (RigCombo("Fingers", ref fingers, "None (25 bones);Thumb and mitten (41);All five (65)"))
			{
				mRig.settings.fingers = fingers == 2 ? 5 : (fingers == 1 ? 2 : 0);
				changed = true;
			}
			ImGui.SetNextItemWidth(-90);
			changed |= RigSlider("Spine", ref mRig.settings.spine, 1, 3);
		}
		else
		{
			changed |= RigSlider("Spine", ref mRig.settings.spine, 1, 6);
			ImGui.SetNextItemWidth(-90);
			changed |= RigSlider("Neck", ref mRig.settings.neck, 1, 6);
			ImGui.SetNextItemWidth(-90);
			changed |= RigSlider("Tail", ref mRig.settings.tail, 0, 16);
			changed |= ImGui.Checkbox("Ears", ref mRig.settings.ears);
			ImGui.SameLine();
			changed |= ImGui.Checkbox("Jaw", ref mRig.settings.jaw);
		}
		if (changed)
		{
			RigTemplates.Build(mRig, mRigRays);
			mRigPainter.RefreshMirror();
		}
		ImGui.Checkbox("Symmetry (move both sides together)", ref mRigSymmetry);
		ImGui.Checkbox("Centre markers in the body when let go", ref mRigCentre);
		if (ImGui.Button("Guess Markers Again", .(-1, 0)))
		{
			PushRigUndo();
			RigTemplates.GuessMarkers(mRig);
			RigTemplates.CentreMarkers(mRig, mRigRays);
			RigTemplates.Build(mRig, mRigRays);
			mRigPainter.RefreshMirror();
		}
		ImGui.PushStyleColor(ImGui.Col.Button, EditorTheme.Accent);
		if (ImGui.Button("Build Skeleton and Weights", .(-1, 0)))
		{
			RigTemplates.Build(mRig, mRigRays);
			mRigPainter.RefreshMirror();
			MakeRigWeights();
			mRigStep = .Weights;
			mRigBone = 0;
		}
		ImGui.PopStyleColor();
		ImGui.SeparatorText("Markers");
		for (int32 i < (int32)mRig.markers.Count)
		{
			let marker = mRig.markers[i];
			if (!RigTemplates.Used(mRig, marker))
				continue;
			// Clicking a name brings the camera to that marker.
			if (ImGui.Selectable(scope $"{marker.name}###marker{i}" .CStr(), i == mRigMarker))
			{
				mRigMarker = i;
				RigLookAt(i);
			}
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip(scope String(RigTemplates.Hint(marker.name)).CStr());
		}
	}

	void DrawRigBonesPanel()
	{
		ImGui.TextWrapped("Click a joint to pick its bone, and move it with the gizmo. Shift+click the model to add a bone there, joined to the picked one.");
		ImGui.Checkbox("Symmetry", ref mRigSymmetry);
		ImGui.SameLine();
		ImGui.Checkbox("Move children", ref mRigMoveChildren);
		ImGui.Checkbox("Centre joints in the body when let go", ref mRigCentre);
		if (mRigWeightsStale)
		{
			ImGui.TextColored(EditorTheme.Warning, "Bones moved since the weights were made.");
			if (ImGui.Button("Make Weights Again", .(-1, 0)))
				MakeRigWeights();
		}
		if (mRigBone >= 0 && mRigBone < mRig.bones.Count)
		{
			let bone = mRig.bones[mRigBone];
			ImGui.SeparatorText("Picked bone");
			let name = scope String(bone.name);
			ImGui.SetNextItemWidth(-90);
			if (ImGui.InputText("Name", name) && !name.IsEmpty && mRig.FindBone(name) < 0)
				bone.name.Set(name);
			var head = bone.head;
			if (ModelVector3("Joint", ref head))
			{
				MoveRigJoint(mRigBone, head);
				mRigWeightsStale |= mRig.HasWeights;
			}
			ImGui.Checkbox("Bends the mesh", ref bone.deform);
			if (HalfButton("Add Child Bone"))
			{
				PushRigUndo();
				let end = mRig.End(mRigBone);
				let dir = (end - bone.head).Length > 1e-5f ? (end - bone.head).Normalized : Vector3(0, 1, 0);
				let length = Math.Max((end - bone.head).Length * 0.5f, mRig.bounds.Size.y * 0.05f);
				mRigBone = (int32)mRig.AddBone(scope $"Bone{mRig.bones.Count}" , mRigBone, end, end + dir * length);
				mRig.ResetPose();
				mRigPainter.RefreshMirror();
			}
			if (HalfButton("Delete Bone", true) && mRig.bones.Count > 1)
			{
				PushRigUndo();
				mRig.RemoveBone(mRigBone);
				mRigBone = Math.Min(mRigBone, (int32)mRig.bones.Count - 1);
				mRig.ResetPose();
				mRigPainter.Refresh();
			}
			if (ImGui.Button("Mirror to the Other Side", .(-1, 0)))
				MirrorRigBones();
		}
		ImGui.SeparatorText("Bones");
		if (ImGui.BeginChild("##rigbones", .(0, 220), 1))
		{
			for (int32 b < (int32)mRig.bones.Count)
			{
				var depth = 0;
				var p = mRig.bones[b].parent;
				while (p >= 0 && depth < 32)
				{
					depth++;
					p = mRig.bones[p].parent;
				}
				let label = scope String();
				label.Append(' ', depth * 2);
				label.Append(mRig.bones[b].name);
				label.AppendF("###bone{}", b);
				if (ImGui.Selectable(label.CStr(), b == mRigBone))
					mRigBone = b;
			}
		}
		ImGui.EndChild();
		if (ImGui.Button("Make Weights", .(-1, 0)))
		{
			MakeRigWeights();
			mRigStep = .Weights;
		}
	}

	/// Makes the bones on the other side of the model match this side's: for each bone named Left.../..._L, its
	/// Right.../..._R is put in the mirrored place (made if it is missing).
	void MirrorRigBones()
	{
		PushRigUndo();
		let right = mRig.Right;
		let middle = mRigPainter.middle;
		Vector3 Mirror(Vector3 p) => p - right * (2 * (Vector3.Dot(p, right) - middle));
		let count = mRig.bones.Count;
		for (int b < count)
		{
			let bone = mRig.bones[b];
			let otherName = Rig.MirrorName(bone.name, .. scope .());
			if (otherName == bone.name)
				continue;
			// The side the picked bone is on is the one copied.
			let pickedName = mRig.bones[mRigBone].name;
			let pickedSide = Rig.MirrorName(pickedName, .. scope .()) != pickedName ? pickedName : "";
			let sameSide = !pickedSide.IsEmpty && ((pickedSide.StartsWith("Left") == bone.name.StartsWith("Left") && (pickedSide.StartsWith("Left") || pickedSide.StartsWith("Right"))) ||
				(pickedSide.Contains("_L") == bone.name.Contains("_L") && (pickedSide.Contains("_L") || pickedSide.Contains("_R"))));
			if (!sameSide)
				continue;
			var other = mRig.FindBone(otherName);
			if (other < 0)
			{
				let parentName = bone.parent >= 0 ? Rig.MirrorName(mRig.bones[bone.parent].name, .. scope .()) : scope String();
				let parent = parentName.IsEmpty ? -1 : mRig.FindBone(parentName);
				other = mRig.AddBone(otherName, parent >= 0 ? parent : bone.parent, Mirror(bone.head), Mirror(bone.tail), bone.deform);
			}
			else
			{
				mRig.bones[other].head = Mirror(bone.head);
				mRig.bones[other].tail = Mirror(bone.tail);
			}
		}
		mRig.SortBones();
		mRig.ResetPose();
		mRigPainter.RefreshMirror();
		mRigWeightsStale |= mRig.HasWeights;
	}

	void DrawRigWeightsPanel()
	{
		if (!mRig.HasWeights)
		{
			if (ImGui.Button("Make Weights", .(-1, 0)))
				MakeRigWeights();
			return;
		}
		ImGui.TextWrapped("Paint how much the picked bone moves the model. Ctrl+click the model to pick the bone that moves it most.");
		ImGui.SetNextItemWidth(-90);
		RigCombo("Show", ref mRigColours, "Picked bone's weights;Every bone's colour;The model");
		var brush = (int32)mRigBrush;
		ImGui.SetNextItemWidth(-90);
		if (RigCombo("Brush", ref brush, "Add;Subtract;Smooth;Set to value"))
			mRigBrush = (WeightTools.Brush)brush;
		ImGui.SetNextItemWidth(-90);
		ImGui.SliderFloat("Size", ref mRigRadius, 0.005f, 0.4f, "%.3f");
		ImGui.SetNextItemWidth(-90);
		ImGui.SliderFloat("Strength", ref mRigStrength, 0.01f, 1);
		if (mRigBrush == .Set)
		{
			ImGui.SetNextItemWidth(-90);
			ImGui.SliderFloat("Value", ref mRigValue, 0, 1);
		}
		ImGui.Checkbox(scope $"Mirror ({mRigPainter.Symmetry * 100:0}% of the model has a mirror)" .CStr(), ref mRigMirrorPaint);
		ImGui.Checkbox("Flex while painting", ref mRigFlex);
		if (!mRigFlex)
			mRig.ResetPose();
		if (HalfButton("Smooth All"))
		{
			PushRigUndo();
			mRigPainter.SmoothAll(2, 0.5f);
			WeightTools.Limit(mRig, AutoWeights.MaxInfluences);
		}
		if (HalfButton("Clean Up", true))
		{
			PushRigUndo();
			WeightTools.Limit(mRig, AutoWeights.MaxInfluences);
			RigMessage("Each vertex keeps its four strongest bones, none under 1%.");
		}
		if (HalfButton("Mirror Left to Right"))
		{
			PushRigUndo();
			mRigPainter.MirrorWeights(false);
		}
		if (HalfButton("Mirror Right to Left", true))
		{
			PushRigUndo();
			mRigPainter.MirrorWeights(true);
		}
		if (ImGui.Button("Make Weights Again (lose painting)", .(-1, 0)))
			MakeRigWeights();
		ImGui.SeparatorText("Bone");
		if (ImGui.BeginChild("##rigweightbones", .(0, 200), 1))
		{
			for (int32 b < (int32)mRig.bones.Count)
			{
				if (!mRig.bones[b].deform)
					continue;
				if (ImGui.Selectable(scope $"{mRig.bones[b].name}###wbone{b}" .CStr(), b == mRigBone))
					mRigBone = b;
			}
		}
		ImGui.EndChild();
	}

	void DrawRigPosePanel()
	{
		ImGui.TextWrapped("Click a joint and turn it with the gizmo to see how the model bends. Posing is only for trying; it is not saved.");
		ImGui.Checkbox("Flex every bone", ref mRigFlex);
		if (ImGui.Button("Reset Pose", .(-1, 0)))
		{
			mRigFlex = false;
			mRig.ResetPose();
		}
		if (mRigBone >= 0 && mRigBone < mRig.bones.Count && !mRigFlex)
		{
			var euler = mRig.pose[mRigBone].EulerAngles;
			if (ModelVector3("Turn", ref euler))
				mRig.pose[mRigBone] = Quaternion.Euler(euler);
		}
	}

	/// Writes the rigged model (and saves the rig). True when it was written.
	bool ExportRig()
	{
		let problem = scope String();
		mRig.ResetPose();
		if (!RigExport.Write(mRig, mRiggedPath, problem))
		{
			RigMessage(problem, true);
			return false;
		}
		mRig.Save(mRigPath);
		SkinnedModel.Forget(mRiggedPath);
		Assets.Forget(mRiggedPath);
		RefreshPalette();
		RigMessage(scope $"Wrote {mRiggedPath} ({mRig.bones.Count} bones) and saved {mRigPath}.");
		return true;
	}

	/// Gives an object the rigged model: a Skinned Mesh Renderer playing it.
	void UseRigged(GameObject target)
	{
		var skinned = target.GetComponent<SkinnedMeshRenderer>();
		if (!skinned)
			skinned = target.AddComponent<SkinnedMeshRenderer>();
		if (!target.HasComponent<MeshRenderer>())
			target.AddComponent<MeshRenderer>();
		// An Animator, so the Animation window, the IK rig and Hand Posing work on it straight away.
		if (target.GetComponent<Animator>() == null)
			target.AddComponent<Animator>();
		skinned.model.Set(mRiggedPath);
		skinned.clip.Clear();
		// Its bones as objects under it, in the Hierarchy and Inspector, ready to pose, key and drive with IK.
		skinned.exposeBones = true;
		SkinnedModel.Forget(mRiggedPath);
		skinned.Refresh();
		MarkDirty();
		RigMessage(scope $"{target.Name} now plays {mRiggedPath}, with its bones under it. Give its Skinned Mesh Renderer a clip (or a Clip Library of animations) to see it move.");
	}

	/// The pointer's ray into the Scene view.
	Ray RigMouseRay(ImGui.Vec2 mouse) => mSceneCamera.ViewportPointToRay((mouse.x - mSceneOrigin.x) / Math.Max(mSceneSize.x, 1), (mouse.y - mSceneOrigin.y) / Math.Max(mSceneSize.y, 1));

	/// A drop-down of choices separated by ';'.
	static bool RigCombo(char8* label, ref int32 value, StringView items)
	{
		let names = scope List<StringView>(items.Split(';'));
		var changed = false;
		if (ImGui.BeginCombo(label, scope String(names[Math.Clamp(value, 0, names.Count - 1)]).CStr()))
		{
			for (int32 i < (int32)names.Count)
			{
				if (ImGui.Selectable(scope String(names[i]).CStr(), i == value))
				{
					value = i;
					changed = true;
				}
			}
			ImGui.EndCombo();
		}
		return changed;
	}

	static bool RigSlider(char8* label, ref int32 value, int32 min, int32 max)
	{
		let changed = ImGui.DragInt(label, ref value, 0.05f, min, max);
		value = Math.Clamp(value, min, max);
		return changed;
	}

	// ---- switches ----

	void ApplyRiggerSwitches()
	{
		let name = scope String();
		if (GetArg("--rigger", name))
			mRiggerStartName.Set(name);
		GetArg("--rigger-step", mRiggerStep);
		GetArg("--rigger-look", mRiggerLook);
		if (HasArg("--rigger-test"))
			mRiggerTestFrames = 1;
	}

	String mRiggerStartName = new .() ~ delete _;
	String mRiggerStep = new .() ~ delete _;
	String mRiggerLook = new .() ~ delete _;

	/// --rig and --rig-test, a few frames in (once the scene is up).
	void TickRiggerTest()
	{
		if (!mRiggerStartName.IsEmpty && Time.FrameCount > 3)
		{
			let target = mScene.Find(mRiggerStartName);
			if (target == null)
				Log.Warning(scope $"RIG: there is no object called '{mRiggerStartName}'.");
			else
			{
				mSelectedId = target.Id;
				FocusSelected();
				StartRig(target);
				// --rigger-look "<marker>": the camera close to a marker.
				if (mRig != null && !mRiggerLook.IsEmpty && mRig.FindMarker(mRiggerLook) >= 0)
					RigLookAt(mRig.FindMarker(mRiggerLook));
				// --rigger-step markers|bones|weights|pose: open on that step (making the weights if needed).
				if (mRig != null)
				{
					for (int i < 4)
					{
						if (mRiggerStep.Equals(sRigSteps[i].Substring(3), .OrdinalIgnoreCase))
							SetRigStep((RigStep)i);
					}
				}
			}
			mRiggerStartName.Clear();
		}
		if (mRiggerTestFrames > 0 && Time.FrameCount > 3)
		{
			mRiggerTestFrames = 0;
			RunRiggerTest();
		}
	}
}
