using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// The skeleton of a rigged model, drawn in the Scene view while the model, its Animator's object or one of its
/// bones is selected: a shape for each bone, seen through the mesh, that selects the bone when clicked, and handles
/// for the IK targets and poles that move it. Left bones are blue, right bones red, the spine and head yellow;
/// helper joints (IK targets, roll bones, end points) are left out. Nothing here is saved with the scene. Needs
/// Expose Bones on the Skinned Mesh Renderer.
extension EditorApp
{
	/// The toolbar's Bones button.
	bool mShowBones = true;
	ImGui.Vec2 mSceneOrigin;
	/// What the bone tools drew last frame, for clicks and the mouse-over highlight.
	List<BonePick> mBonePicks = new .() ~ delete _;
	Transform mHoveredBone;

	/// A bone from head to tail, or an IK handle (a point with a radius), and the object it selects.
	struct BonePick
	{
		public Transform transform;
		public Vector3 head, tail;
		public float radius;
		public bool handle;
	}

	static readonly Color BoneSelected = .(1.0f, 0.62f, 0.15f, 1);
	static readonly Color BoneLeft = .(0.35f, 0.62f, 1.0f, 1);
	static readonly Color BoneRight = .(1.0f, 0.42f, 0.4f, 1);
	static readonly Color BoneMiddle = .(0.92f, 0.88f, 0.55f, 1);

	/// The rigged model whose bones are shown for a selection: the selection's own, the one it is a bone or IK
	/// target of, or one just below an Animator.
	SkinnedMeshRenderer BoneOwner(GameObject selected)
	{
		if (selected == null)
			return null;
		for (var t = selected.Transform; t != null; t = t.Parent)
		{
			let skinned = t.GameObject.GetComponent<SkinnedMeshRenderer>();
			if (skinned != null && skinned.BoneCount > 0)
				return skinned;
			if (t.GameObject.GetComponent<Animator>() != null)
			{
				let below = SkinnedBelow(t, 3);
				if (below != null)
					return below;
			}
		}
		return null;
	}

	static SkinnedMeshRenderer SkinnedBelow(Transform parent, int levels)
	{
		if (levels == 0)
			return null;
		for (let child in parent.Children)
		{
			let skinned = child.GameObject.GetComponent<SkinnedMeshRenderer>();
			if (skinned != null && skinned.BoneCount > 0)
				return skinned;
			let below = SkinnedBelow(child, levels - 1);
			if (below != null)
				return below;
		}
		return null;
	}

	/// Draws the shown skeleton and its IK handles, and remembers them for clicks. Called with the other gizmos.
	void BuildBoneGizmos()
	{
		mHoveredBone = mSceneHovered ? NearestBonePick(ImGui.GetMousePos().x - mSceneOrigin.x, ImGui.GetMousePos().y - mSceneOrigin.y) : null;
		mBonePicks.Clear();
		if (!mShowBones)
			return;
		let selected = Selected;
		let skinned = BoneOwner(selected);
		if (skinned == null || skinned.Model == null)
			return;
		let model = skinned.Model;
		let core = scope String();
		for (int j < model.Joints.Count)
		{
			let bone = skinned.BoneAt(j);
			if (bone == null)
				continue;
			core.Clear();
			let side = BoneMap.Simplify(model.Joints[j].name, core);
			// Helper joints (IK targets, roll bones, end points) are not drawn: they would hide the body's bones.
			if (side == 2)
				continue;
			let color = BoneColor(bone, side, selected);
			let head = bone.Position;
			int children = 0;
			for (int c < model.Joints.Count)
			{
				let child = model.Joints[c].parent == j ? skinned.BoneAt(c) : null;
				if (child == null || BoneMap.Simplify(model.Joints[c].name, core..Clear()) == 2)
					continue;
				children++;
				AddBone(bone, head, child.Position, color);
			}
			if (children > 0)
				continue;
			// A tip (a head, a fingertip): a short bone carrying on the way its parent points.
			let parent = skinned.BoneAt(model.Joints[j].parent);
			if (parent != null && (head - parent.Position).Length > 0.0001f)
				AddBone(bone, head, head + (head - parent.Position) * 0.5f, color);
		}
		DrawIKHandles(skinned, selected);
	}

	Color BoneColor(Transform bone, int side, GameObject selected)
	{
		var color = side == -1 ? BoneLeft : (side == 1 ? BoneRight : BoneMiddle);
		if (selected != null && bone.GameObject == selected)
			color = BoneSelected;
		if (bone == mHoveredBone)
			color = .(Math.Min(color.r + 0.25f, 1), Math.Min(color.g + 0.25f, 1), Math.Min(color.b + 0.25f, 1), 1);
		return color;
	}

	/// A bone as Blender draws one: two pyramids meeting a fifth of the way along, filled and outlined.
	void AddBone(Transform bone, Vector3 head, Vector3 tail, Color color)
	{
		let axis = tail - head;
		let length = axis.Length;
		if (length < 0.00001f)
			return;
		let along = axis / length;
		let side = Vector3.Cross(along, Math.Abs(along.y) < 0.9f ? Vector3.Up : Vector3.Right).Normalized;
		let other = Vector3.Cross(along, side);
		let width = length * 0.1f;
		let middle = head + axis * 0.2f;
		Vector3[4] ring = .(middle + side * width, middle + other * width, middle - side * width, middle - other * width);
		let fill = Color(color.r, color.g, color.b, 0.3f);
		for (int i < 4)
		{
			let next = ring[(i + 1) % 4];
			Gizmos.OnTopTriangles.Triangle(head, ring[i], next, fill);
			Gizmos.OnTopTriangles.Triangle(tail, ring[i], next, fill);
			Gizmos.OnTopLines.Line(head, ring[i], color);
			Gizmos.OnTopLines.Line(tail, ring[i], color);
			Gizmos.OnTopLines.Line(ring[i], next, color);
		}
		BonePick pick;
		pick.transform = bone;
		pick.head = head;
		pick.tail = tail;
		pick.radius = width;
		pick.handle = false;
		mBonePicks.Add(pick);
	}

	/// The targets and poles of the IK components working on the shown skeleton: a box turned as the target is (a
	/// hand or foot takes its turn), a diamond for a pole, with a line from the joint it aims.
	void DrawIKHandles(SkinnedMeshRenderer skinned, GameObject selected)
	{
		let root = skinned.Transform;
		for (let component in mScene.Components)
		{
			if (let limb = component as LimbIK)
			{
				if (limb.tip == null || !IsBelow(limb.tip, root))
					continue;
				let size = limb.Middle != null ? Math.Max((limb.tip.Position - limb.Middle.Position).Length * 0.18f, 0.02f) : 0.05f;
				if (limb.target != null)
					AddHandle(limb.target, size, false, .(0.3f, 1, 0.45f, 1), selected);
				if (limb.pole != null)
				{
					AddHandle(limb.pole, size * 0.7f, true, .(0.85f, 0.45f, 1, 1), selected);
					if (limb.Middle != null)
						Gizmos.OnTopLines.Line(limb.Middle.Position, limb.pole.Position, .(0.85f, 0.45f, 1, 0.5f));
				}
			}
			else if (let look = component as LookAtIK)
			{
				if (look.bone == null || look.target == null || !IsBelow(look.bone, root))
					continue;
				AddHandle(look.target, 0.06f, true, .(1, 0.85f, 0.25f, 1), selected);
				Gizmos.OnTopLines.Line(look.bone.Position, look.target.Position, .(1, 0.85f, 0.25f, 0.4f));
			}
		}
	}

	static bool IsBelow(Transform t, Transform root)
	{
		for (var at = t; at != null; at = at.Parent)
		{
			if (at == root)
				return true;
		}
		return false;
	}

	void AddHandle(Transform target, float size, bool diamond, Color baseColor, GameObject selected)
	{
		var color = baseColor;
		if (selected != null && target.GameObject == selected)
			color = BoneSelected;
		else if (target == mHoveredBone)
			color = .(Math.Min(color.r + 0.25f, 1), Math.Min(color.g + 0.25f, 1), Math.Min(color.b + 0.25f, 1), 1);
		let center = target.Position;
		if (diamond)
		{
			Vector3[6] tips = .(center + .(size, 0, 0), center - .(size, 0, 0), center + .(0, size, 0), center - .(0, size, 0), center + .(0, 0, size), center - .(0, 0, size));
			for (int a < 2)
			{
				for (int b = 2; b < 4; b++)
				{
					for (int c = 4; c < 6; c++)
						Gizmos.OnTopTriangles.Triangle(tips[a], tips[b], tips[c], .(color.r, color.g, color.b, 0.35f));
					Gizmos.OnTopLines.Line(tips[a], tips[b], color);
				}
				for (int c = 4; c < 6; c++)
					Gizmos.OnTopLines.Line(tips[a], tips[c], color);
			}
			for (int b = 2; b < 4; b++)
			{
				for (int c = 4; c < 6; c++)
					Gizmos.OnTopLines.Line(tips[b], tips[c], color);
			}
		}
		else
		{
			let cube = Bounds(.(-size), .(size));
			Gizmos.OnTopLines.Box(cube, Matrix4.TRS(center, target.Rotation, .One), color);
			// The target's forward, so that its turn can be seen.
			Gizmos.OnTopLines.Line(center, center + target.Forward * size * 2, color);
		}
		BonePick pick;
		pick.transform = target;
		pick.head = center;
		pick.tail = center;
		pick.radius = size;
		pick.handle = true;
		mBonePicks.Add(pick);
	}

	/// Where a point is in the Scene view, in pixels from its top left corner; false when it is behind the camera.
	bool SceneScreenPoint(Matrix4 viewProjection, Vector3 point, out Vector2 screen)
	{
		screen = default;
		let clip = viewProjection.Transform(.(point, 1));
		if (clip.w <= 0.0001f)
			return false;
		screen = .((clip.x / clip.w + 1) * 0.5f * mSceneSize.x, (1 - clip.y / clip.w) * 0.5f * mSceneSize.y);
		return true;
	}

	/// The bone or handle under a point of the Scene view (pixels from its corner), or null. Handles win over the
	/// bones they sit on (a hand's target over the hand).
	Transform NearestBonePick(float x, float y)
	{
		if (mBonePicks.Count == 0)
			return null;
		let viewProjection = mSceneCamera.projection * mSceneCamera.view;
		let mouse = Vector2(x, y);
		Transform best = null;
		float bestScore = float.MaxValue;
		for (let pick in mBonePicks)
		{
			Vector2 head, tail;
			let headSeen = SceneScreenPoint(viewProjection, pick.head, out head);
			let tailSeen = SceneScreenPoint(viewProjection, pick.tail, out tail);
			if (!headSeen || !tailSeen)
				continue;
			let segment = tail - head;
			let t = segment.LengthSquared > 0.0001f ? Math.Clamp(Vector2.Dot(mouse - head, segment) / segment.LengthSquared, 0, 1) : 0;
			let distance = (mouse - (head + segment * t)).Length;
			let reach = pick.handle ? 14.0f : 9.0f;
			if (distance > reach)
				continue;
			let score = pick.handle ? distance - 100 : distance;
			if (score < bestScore)
			{
				bestScore = score;
				best = pick.transform;
			}
		}
		return best;
	}

	/// A click on a bone or an IK handle selects it ahead of the meshes around it. Picking a bone other than the
	/// skeleton's root switches the Move handle to Rotate, since bones are posed by turning them.
	bool PickBone(float u, float v)
	{
		let hit = NearestBonePick(u * mSceneSize.x, v * mSceneSize.y);
		if (hit == null)
			return false;
		mSelectedId = hit.GameObject.Id;
		bool handle = false;
		for (let pick in mBonePicks)
			handle |= pick.handle && pick.transform == hit;
		let parentIsBone = hit.Parent != null && hit.Parent.GameObject.GetComponent<SkinnedMeshRenderer>() == null && !hit.Parent.GameObject.Name.EndsWith(".Armature");
		if (!handle && parentIsBone && mGizmoOperation == 0)
			mGizmoOperation = 1;
		return true;
	}
}
