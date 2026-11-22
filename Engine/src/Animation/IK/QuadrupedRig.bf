using System;
using System.Collections;

namespace Tallow;

/// The bones of a four-legged character, found by their names: the four paws, the head and the body bone. The
/// rigger's Quadruped template names them FrontPaw_L, FrontPaw_R, BackPaw_L, BackPaw_R, Root and Head; a model from
/// elsewhere may say Foot, Hoof, Fore, Hind, Rear, and L/R as suffix or prefix. Used by Foot Placement's auto-find,
/// Limb IK's natural bend and the Animation window's IK rig setup.
static class QuadrupedRig
{
	/// How many feet FindFeet fills: front left, front right, back left, back right.
	public const int FootCount = 4;

	/// True for a BoneMap.Simplify core name that is a foot (lower case, with the side words taken out): "frontpaw",
	/// "backhoof", "foot", "ankle".
	public static bool IsFootCore(StringView core) => core.Contains("paw") || core.Contains("hoof") || core.Contains("foot") || core.Contains("ankle");

	/// 1 for a front foot, -1 for a back one, 0 when the name does not say.
	static int Pair(StringView core)
	{
		if (core.Contains("front") || core.Contains("fore"))
			return 1;
		if (core.Contains("back") || core.Contains("hind") || core.Contains("rear"))
			return -1;
		return 0;
	}

	/// The four feet under root, in the order front left, front right, back left, back right: the rigger's
	/// FrontPaw_L and so on, or two plain feet (Foot_L, Foot_R) when the names do not say front or back, which is
	/// what a two-legged character has. Returns 2 for two, 4 for four, 0 when none are named. Feet the character
	/// does not have are null.
	public static int FindFeet(Transform root, ref Transform[FootCount] feet)
	{
		for (int i < FootCount)
			feet[i] = null;
		Transform frontLeft = null, frontRight = null, backLeft = null, backRight = null;
		Transform left = null, right = null;
		let core = scope String();
		void Walk(Transform parent)
		{
			for (let child in parent.Children)
			{
				core.Clear();
				let side = BoneMap.Simplify(child.GameObject.Name, core);
				// A foot needs a leg above it: the two bones Foot Placement turns.
				if ((side == -1 || side == 1) && IsFootCore(core) && child.Parent != null && child.Parent.Parent != null)
				{
					let pair = Pair(core);
					if (pair > 0)
					{
						if (side < 0 && frontLeft == null)
							frontLeft = child;
						else if (side > 0 && frontRight == null)
							frontRight = child;
					}
					else if (pair < 0)
					{
						if (side < 0 && backLeft == null)
							backLeft = child;
						else if (side > 0 && backRight == null)
							backRight = child;
					}
					else if (side < 0 && left == null)
						left = child;
					else if (side > 0 && right == null)
						right = child;
				}
				Walk(child);
			}
		}
		Walk(root);
		if (frontLeft != null && frontRight != null)
		{
			// Plain paws beside a named front pair are the back ones (a rig that says only "Paw_L").
			if (backLeft == null)
				backLeft = left;
			if (backRight == null)
				backRight = right;
			feet[0] = frontLeft;
			feet[1] = frontRight;
			feet[2] = backLeft;
			feet[3] = backRight;
			return backLeft != null && backRight != null ? 4 : 2;
		}
		if (left != null && right != null)
		{
			feet[0] = left;
			feet[1] = right;
			return 2;
		}
		return 0;
	}

	/// The head bone ("Head"): the heads of a four-legged character and a humanoid both answer.
	public static bool FindHead(Transform root, out Transform head)
	{
		Transform found = null;
		Transform close = null;
		let core = scope String();
		void Walk(Transform parent)
		{
			for (let child in parent.Children)
			{
				core.Clear();
				let side = BoneMap.Simplify(child.GameObject.Name, core);
				if (side != 2)
				{
					if (core == "head" && found == null)
						found = child;
					else if (close == null && core.Contains("head"))
						close = child;
				}
				Walk(child);
			}
		}
		Walk(root);
		head = found ?? close;
		return head != null;
	}

	/// The bone the body hangs from, which Foot Placement lowers: the rigger calls it Root, a humanoid Hips or
	/// Pelvis.
	public static bool FindBody(Transform root, out Transform body)
	{
		body = null;
		int best = 0;
		let core = scope String();
		void Walk(Transform parent)
		{
			for (let child in parent.Children)
			{
				core.Clear();
				if (BoneMap.Simplify(child.GameObject.Name, core) != 2)
				{
					let rank = core == "hips" ? 3 : (core == "pelvis" ? 2 : (core == "root" || core == "body" ? 1 : 0));
					if (rank > best)
					{
						best = rank;
						body = child;
					}
				}
				Walk(child);
			}
		}
		Walk(root);
		return body != null;
	}

	/// The way a four-legged character faces, from its left front paw to its right (scene space is left-handed, so
	/// facing +Z its right is +X). Zero when the paws are not both there, or are in the same place.
	public static Vector3 Facing(Transform left, Transform right)
	{
		if (left == null || right == null)
			return .Zero;
		var across = right.Position - left.Position;
		across.y = 0;
		return across.LengthSquared > 1.0e-8f ? Vector3.Cross(across, .Up).Normalized : .Zero;
	}
}
