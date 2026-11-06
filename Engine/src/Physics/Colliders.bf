using System;
using System.Collections;

namespace Tallow;

/// Collision shape for a GameObject. Without a Rigidbody the object is static scenery.
[Component]
abstract class Collider : Component
{
	/// Where the shape's centre is, relative to the object.
	public Vector3 center = .Zero;

	uint32 mStaticBody = uint32.MaxValue;

	/// The shape the physics world makes for this collider.
	public abstract ShapeDesc GetShape();

	bool mReady;

	// Bodies are created in Start rather than OnEnable so that every component of an object
	// built in code (collider, then rigidbody, ...) exists before the body is set up.
	public override void Start()
	{
		mReady = true;
		CreateStaticBody();
	}

	public override void OnEnable()
	{
		if (mReady)
			CreateStaticBody();
	}

	void CreateStaticBody()
	{
		// A Rigidbody on the same object owns the body; otherwise this collider is static.
		if (mStaticBody == uint32.MaxValue && !HasComponent<Rigidbody>())
			mStaticBody = Scene.Physics.CreateBody(Transform, GetShape(), null);
	}

	/// Rebuilds the static body after the shape changed (for example a re-meshed voxel chunk).
	public void Refresh()
	{
		if (!mReady)
			return;
		OnDisable();
		CreateStaticBody();
	}

	public override void OnDisable()
	{
		if (mStaticBody != uint32.MaxValue)
		{
			Scene.Physics.DestroyBody(mStaticBody);
			mStaticBody = uint32.MaxValue;
		}
	}

	protected Vector3 WorldScale => Transform.WorldScale;
}

/// A box-shaped collider.
[Component]
class BoxCollider : Collider
{
	/// The box's full size on each axis.
	public Vector3 size = .One;

	public override ShapeDesc GetShape()
	{
		let scale = WorldScale;
		ShapeDesc desc = default;
		desc.kind = .Box;
		desc.halfExtents = size * scale * 0.5f;
		desc.center = center * scale;
		return desc;
	}

	public override void OnDrawGizmos(bool selected)
	{
		if (selected)
			Gizmos.Lines.Box(.(center - size * 0.5f, center + size * 0.5f), Transform.LocalToWorld, .(0.5f, 1, 0.5f, 1));
	}
}

/// A ball-shaped collider.
[Component]
class SphereCollider : Collider
{
	/// The ball's radius.
	public float radius = 0.5f;

	public override ShapeDesc GetShape()
	{
		let scale = WorldScale;
		ShapeDesc desc = default;
		desc.kind = .Sphere;
		desc.radius = radius * Math.Max(scale.x, Math.Max(scale.y, scale.z));
		desc.center = center * scale;
		return desc;
	}

	public override void OnDrawGizmos(bool selected)
	{
		if (selected)
			Gizmos.Lines.Sphere(Transform.TransformPoint(center), GetShape().radius, .(0.5f, 1, 0.5f, 1));
	}
}

/// A capsule-shaped collider (a cylinder with rounded ends), standing along Y: the usual shape for characters.
[Component]
class CapsuleCollider : Collider
{
	/// The capsule's radius.
	public float radius = 0.5f;
	/// The capsule's height from end to end, its rounded ends included.
	public float height = 2.0f;

	public override ShapeDesc GetShape()
	{
		let scale = WorldScale;
		ShapeDesc desc = default;
		desc.kind = .Capsule;
		desc.radius = radius * Math.Max(scale.x, scale.z);
		desc.halfHeight = Math.Max(height * scale.y * 0.5f - desc.radius, 0.01f);
		desc.center = center * scale;
		return desc;
	}

	public override void OnDrawGizmos(bool selected)
	{
		if (!selected)
			return;
		let shape = GetShape();
		let c = Transform.TransformPoint(center);
		let up = Transform.Up * shape.halfHeight;
		Gizmos.Lines.Sphere(c + up, shape.radius, .(0.5f, 1, 0.5f, 1));
		Gizmos.Lines.Sphere(c - up, shape.radius, .(0.5f, 1, 0.5f, 1));
	}
}

/// Triangle-accurate static collision using the mesh of the MeshRenderer on the same object.
[Component]
class MeshCollider : Collider
{
	/// A mesh to collide with in place of the renderer's: a terrain gives its full-detail ground here while it draws
	/// fewer triangles far away. Not kept with the scene. Call Refresh after changing it.
	public Mesh CollisionMesh { get; set; }

	public override ShapeDesc GetShape()
	{
		ShapeDesc desc = default;
		desc.kind = .Mesh;
		desc.meshScale = WorldScale;
		if (CollisionMesh != null)
		{
			desc.mesh = CollisionMesh;
			return desc;
		}
		let renderer = GetComponent<MeshRenderer>();
		if (renderer)
			desc.mesh = renderer.ActiveMesh;
		return desc;
	}
}

/// Several boxes acting as one shape, so a whole construction can be a single rigid body.
[Component]
class CompoundCollider : Collider
{
	List<Vector3> mBoxes = new .() ~ delete _;
	List<CompoundCylinder> mCylinders = new .() ~ delete _;
	List<CompoundHull> mHulls = new .() ~ delete _;
	List<List<Vector3>> mHullPoints = new .() ~ DeleteContainerAndItems!(_);
	List<CompoundHull> mScaledHulls = new .() ~ delete _;
	List<List<Vector3>> mScaledHullPoints = new .() ~ DeleteContainerAndItems!(_);
	/// How many convex parts were added with AddHull.
	public int32 HullCount => (int32)mHulls.Count;
	/// Adds a convex part: the hull round some points, placed at center.
	public void AddHull(Vector3 center, Span<Vector3> points, Quaternion rotation, float convexRadius = 0.005f)
	{
		if (points.Length < 4) return;
		let copy = new List<Vector3>();
		copy.AddRange(points);
		mHullPoints.Add(copy);
		mHulls.Add(.() { center = center, rotation = rotation.Normalized, points = copy.Ptr, pointCount = (int32)copy.Count, convexRadius = convexRadius });
	}

	/// How many cylinders were added with AddCylinder.
	public int32 CylinderCount => (int32)mCylinders.Count;
	/// Adds a cylinder part.
	public void AddCylinder(Vector3 center, float radius, float halfHeight, Quaternion rotation)
	{
		mCylinders.Add(.() { center = center, radius = radius, halfHeight = halfHeight, rotation = rotation });
	}

	/// How many boxes the compound has.
	public int32 BoxCount => (int32)(mBoxes.Count / 2);

	/// Removes every box part.
	public void ClearBoxes()
	{
		mBoxes.Clear();
		mCylinders.Clear();
		mHulls.Clear();
		for (let points in mHullPoints)
			delete points;
		mHullPoints.Clear();
	}

	/// Adds a box in the object's local space. Call Rigidbody.RebuildBody (or Refresh) afterwards.
	public void AddBox(Vector3 center, Vector3 size)
	{
		mBoxes.Add(center);
		mBoxes.Add(size * 0.5f);
	}

	public override ShapeDesc GetShape()
	{
		// Scale is baked in here; the stored boxes stay in local units.
		let scale = WorldScale;
		mScaled.Clear();
		for (let v in mBoxes)
			mScaled.Add(v * scale);
		ShapeDesc desc = default;
		desc.kind = .Compound;
		desc.boxes = mScaled.Ptr;
		desc.boxCount = BoxCount;
		desc.cylinders = mCylinders.Ptr;
		desc.cylinderCount = (int32)mCylinders.Count;
		mScaledHulls.Clear();
		for (let points in mScaledHullPoints)
			delete points;
		mScaledHullPoints.Clear();
		for (let hull in mHulls)
		{
			let points = new List<Vector3>();
			for (int i = 0; i < hull.pointCount; i++)
				points.Add((hull.rotation * hull.points[i]) * scale);
			mScaledHullPoints.Add(points);
			mScaledHulls.Add(.() { center = hull.center * scale, rotation = .Identity, points = points.Ptr, pointCount = (int32)points.Count, convexRadius = hull.convexRadius * Math.Min(Math.Abs(scale.x), Math.Min(Math.Abs(scale.y), Math.Abs(scale.z))) });
		}
		desc.hulls = mScaledHulls.Ptr;
		desc.hullCount = (int32)mScaledHulls.Count;
		return desc;
	}

	List<Vector3> mScaled = new .() ~ delete _;
}

/// Convex wrap of the MeshRenderer's mesh. Unlike MeshCollider it works on moving bodies.
[Component]
class ConvexCollider : Collider
{
	/// Wrap the model hierarchy when the body is on a parent rather than the mesh object.
	public bool includeChildren = false;
	/// Points to wrap in place of the renderer's mesh (a dented shell's shape: SoftBody sets it). Not kept with the
	/// scene. Rebuild the Rigidbody's body after changing it.
	public Mesh HullMesh { get; set; }
	Mesh mHierarchyMesh ~ delete _;
	void CollectHull(GameObject object)
	{
		let renderer = object.GetComponent<MeshRenderer>();
		let mesh = renderer ? renderer.ActiveMesh : null;
		if (mesh != null)
		{
			let relative = Transform.WorldToLocal * object.Transform.LocalToWorld;
			let step = Math.Max(1, mesh.Vertices.Count / 256);
			for (int i = 0; i < mesh.Vertices.Count; i += step)
			{
				MeshVertex vertex = default;
				vertex.position = relative.TransformPoint(mesh.Vertices[i].position);
				mHierarchyMesh.Vertices.Add(vertex);
			}
		}
		for (let child in object.Transform.Children)
		{
			let childMesh = child.GameObject.GetComponent<MeshRenderer>();
			if (mesh != null && childMesh && childMesh.mesh.Contains('#')) continue;
			CollectHull(child.GameObject);
		}
	}

	public override ShapeDesc GetShape()
	{
		ShapeDesc desc = default;
		desc.kind = .ConvexHull;
		desc.meshScale = WorldScale;
		if (HullMesh != null)
		{
			desc.mesh = HullMesh;
			return desc;
		}
		if (includeChildren)
		{
			if (mHierarchyMesh == null)
			{
				mHierarchyMesh = new Mesh();
				CollectHull(GameObject);
			}
			desc.mesh = mHierarchyMesh;
			return desc;
		}
		let renderer = GetComponent<MeshRenderer>();
		if (renderer)
			desc.mesh = renderer.ActiveMesh;
		return desc;
	}
}
