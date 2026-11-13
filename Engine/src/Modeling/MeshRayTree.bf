using System;
using System.Collections;

namespace Tallow;

/// The faces of an EditMesh cut into triangles once and sorted into a bounding volume tree, so many rays can be
/// tested against it quickly (the modeller asks what can be seen for every selected element, every frame).
/// It does not follow the mesh: build it again when the mesh changes (Changed tells).
class MeshRayTree
{
	struct Node
	{
		public Vector3 min;
		public Vector3 max;
		/// A leaf's first triangle (in mOrder), or an inner node's first child (the second follows it).
		public int32 start;
		/// Triangles in a leaf; 0 for an inner node.
		public int32 count;
	}

	const int32 LeafSize = 4;

	List<Vector3> mCorners = new .() ~ delete _;
	List<int32> mFaces = new .() ~ delete _;
	List<int32> mOrder = new .() ~ delete _;
	List<Vector3> mCentres = new .() ~ delete _;
	List<Node> mNodes = new .() ~ delete _;
	uint64 mFingerprint;
	bool mSkipHidden;

	public int TriangleCount => mFaces.Count;

	/// A hash of everything a ray test depends on: the positions, each face's corners and whether it is hidden.
	public static uint64 Fingerprint(EditMesh mesh)
	{
		uint64 hash = 14695981039346656037;
		Mix(ref hash, (uint32)mesh.positions.Count);
		for (let p in mesh.positions)
		{
			var copy = p;
			let words = (uint32*)&copy;
			Mix(ref hash, words[0]);
			Mix(ref hash, words[1]);
			Mix(ref hash, words[2]);
		}
		Mix(ref hash, (uint32)mesh.faces.Count);
		for (let face in mesh.faces)
		{
			Mix(ref hash, face.hidden ? 0x80000000 | (uint32)face.Count : (uint32)face.Count);
			for (let v in face.verts)
				Mix(ref hash, (uint32)v);
		}
		return hash;
	}

	[Inline]
	static void Mix(ref uint64 hash, uint32 value)
	{
		hash = (hash ^ value) * 1099511628211;
	}

	/// Whether the mesh is no longer what the tree was built from (or skipHidden differs).
	public bool Changed(EditMesh mesh, bool skipHidden, out uint64 fingerprint)
	{
		fingerprint = Fingerprint(mesh);
		return fingerprint != mFingerprint || skipHidden != mSkipHidden || mNodes.IsEmpty;
	}

	/// Builds it again if the mesh changed since; true when it did.
	public bool Refresh(EditMesh mesh, bool skipHidden = true)
	{
		if (!Changed(mesh, skipHidden, let fingerprint))
			return false;
		Build(mesh, skipHidden, fingerprint);
		return true;
	}

	public void Build(EditMesh mesh, bool skipHidden = true) => Build(mesh, skipHidden, Fingerprint(mesh));

	void Build(EditMesh mesh, bool skipHidden, uint64 fingerprint)
	{
		mSkipHidden = skipHidden;
		mFingerprint = fingerprint;
		mCorners.Clear();
		mFaces.Clear();
		mOrder.Clear();
		mCentres.Clear();
		mNodes.Clear();
		let corners = scope List<int32>();
		for (int32 f < (int32)mesh.faces.Count)
		{
			let face = mesh.faces[f];
			if (skipHidden && face.hidden)
				continue;
			corners.Clear();
			mesh.Triangulate(face, corners);
			for (int i = 0; i + 2 < corners.Count; i += 3)
			{
				let a = mesh.positions[face.verts[corners[i]]];
				let b = mesh.positions[face.verts[corners[i + 1]]];
				let c = mesh.positions[face.verts[corners[i + 2]]];
				mOrder.Add((int32)mFaces.Count);
				mFaces.Add(f);
				mCorners.Add(a);
				mCorners.Add(b);
				mCorners.Add(c);
				mCentres.Add((a + b + c) / 3);
			}
		}
		if (mFaces.IsEmpty)
			return;
		mNodes.Add(default);
		BuildNode(0, 0, (int32)mFaces.Count);
	}

	void BoxOf(int32 start, int32 count, out Vector3 min, out Vector3 max)
	{
		min = .(float.MaxValue, float.MaxValue, float.MaxValue);
		max = .(float.MinValue, float.MinValue, float.MinValue);
		for (int32 i = start; i < start + count; i++)
		{
			let t = mOrder[i] * 3;
			for (int k < 3)
			{
				let p = mCorners[t + k];
				min = .(Math.Min(min.x, p.x), Math.Min(min.y, p.y), Math.Min(min.z, p.z));
				max = .(Math.Max(max.x, p.x), Math.Max(max.y, p.y), Math.Max(max.z, p.z));
			}
		}
	}

	static float Axis(Vector3 v, int axis) => axis == 0 ? v.x : (axis == 1 ? v.y : v.z);

	void BuildNode(int32 node, int32 start, int32 count)
	{
		BoxOf(start, count, let min, let max);
		var n = mNodes[node];
		n.min = min;
		n.max = max;
		if (count <= LeafSize)
		{
			n.start = start;
			n.count = count;
			mNodes[node] = n;
			return;
		}
		// Split at the middle triangle along the longest side of the centres' box.
		var cmin = Vector3(float.MaxValue, float.MaxValue, float.MaxValue);
		var cmax = Vector3(float.MinValue, float.MinValue, float.MinValue);
		for (int32 i = start; i < start + count; i++)
		{
			let c = mCentres[mOrder[i]];
			cmin = .(Math.Min(cmin.x, c.x), Math.Min(cmin.y, c.y), Math.Min(cmin.z, c.z));
			cmax = .(Math.Max(cmax.x, c.x), Math.Max(cmax.y, c.y), Math.Max(cmax.z, c.z));
		}
		let extent = cmax - cmin;
		let axis = extent.x >= extent.y && extent.x >= extent.z ? 0 : (extent.y >= extent.z ? 1 : 2);
		let middle = start + count / 2;
		Select(start, start + count - 1, middle, axis);
		let left = (int32)mNodes.Count;
		mNodes.Add(default);
		mNodes.Add(default);
		n.start = left;
		n.count = 0;
		mNodes[node] = n;
		BuildNode(left, start, middle - start);
		BuildNode(left + 1, middle, start + count - middle);
	}

	/// Puts the triangle whose centre is k-th along the axis at k, smaller ones before it and larger after.
	void Select(int32 low, int32 high, int32 k, int axis)
	{
		var low, high;
		while (low < high)
		{
			let pivot = Axis(mCentres[mOrder[(low + high) / 2]], axis);
			var i = low, j = high;
			while (i <= j)
			{
				while (Axis(mCentres[mOrder[i]], axis) < pivot)
					i++;
				while (Axis(mCentres[mOrder[j]], axis) > pivot)
					j--;
				if (i <= j)
				{
					Swap!(mOrder[i], mOrder[j]);
					i++;
					j--;
				}
			}
			if (k <= j)
				high = j;
			else if (k >= i)
				low = i;
			else
				return;
		}
	}

	[Inline]
	static bool HitsBox(Vector3 origin, Vector3 inverse, Vector3 min, Vector3 max, float limit)
	{
		var t1 = (min.x - origin.x) * inverse.x, t2 = (max.x - origin.x) * inverse.x;
		var near = Math.Min(t1, t2), far = Math.Max(t1, t2);
		t1 = (min.y - origin.y) * inverse.y;
		t2 = (max.y - origin.y) * inverse.y;
		near = Math.Max(near, Math.Min(t1, t2));
		far = Math.Min(far, Math.Max(t1, t2));
		t1 = (min.z - origin.z) * inverse.z;
		t2 = (max.z - origin.z) * inverse.z;
		near = Math.Max(near, Math.Min(t1, t2));
		far = Math.Min(far, Math.Max(t1, t2));
		// NaN (a ray along a box face) compares false and so counts as a hit, which is the safe side.
		return !(far < Math.Max(near, 0)) && !(near > limit);
	}

	static Vector3 Inverse(Vector3 d) => .(1.0f / d.x, 1.0f / d.y, 1.0f / d.z);

	/// The nearest face a ray hits (either side), or -1, as EditMesh.Raycast does.
	public int32 Raycast(Ray ray, out float distance)
	{
		distance = float.MaxValue;
		if (mNodes.IsEmpty)
			return -1;
		int32 best = -1;
		let inverse = Inverse(ray.direction);
		int32[64] stack = ?;
		int depth = 0;
		stack[depth++] = 0;
		while (depth > 0)
		{
			let node = mNodes[stack[--depth]];
			if (!HitsBox(ray.origin, inverse, node.min, node.max, distance))
				continue;
			if (node.count == 0)
			{
				stack[depth++] = node.start;
				stack[depth++] = node.start + 1;
				continue;
			}
			for (int32 i = node.start; i < node.start + node.count; i++)
			{
				let t = mOrder[i];
				let hit = EditMesh.RayTriangle(ray, mCorners[t * 3], mCorners[t * 3 + 1], mCorners[t * 3 + 2]);
				if (hit >= 0 && (hit < distance || (hit == distance && mFaces[t] < best)))
				{
					distance = hit;
					best = mFaces[t];
				}
			}
		}
		return best;
	}

	/// Whether anything lies along a ray closer than `limit`; stops at the first such hit.
	public bool Blocked(Ray ray, float limit)
	{
		if (mNodes.IsEmpty)
			return false;
		let inverse = Inverse(ray.direction);
		int32[64] stack = ?;
		int depth = 0;
		stack[depth++] = 0;
		while (depth > 0)
		{
			let node = mNodes[stack[--depth]];
			if (!HitsBox(ray.origin, inverse, node.min, node.max, limit))
				continue;
			if (node.count == 0)
			{
				stack[depth++] = node.start;
				stack[depth++] = node.start + 1;
				continue;
			}
			for (int32 i = node.start; i < node.start + node.count; i++)
			{
				let t = mOrder[i];
				let hit = EditMesh.RayTriangle(ray, mCorners[t * 3], mCorners[t * 3 + 1], mCorners[t * 3 + 2]);
				if (hit >= 0 && hit < limit)
					return true;
			}
		}
		return false;
	}
}
