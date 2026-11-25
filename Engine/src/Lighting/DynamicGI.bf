using System;
using System.Collections;
using System.Diagnostics;
using System.Threading;
using Bgfx;

namespace Tallow;

/// A whole number position in the probe grid, in cells of DynamicGI.Spacing metres.
struct GiCell : IHashable
{
	public int32 x, y, z;

	public this(int32 x, int32 y, int32 z)
	{
		this.x = x;
		this.y = y;
		this.z = z;
	}

	public static bool operator==(GiCell a, GiCell b) => a.x == b.x && a.y == b.y && a.z == b.z;
	public static bool operator!=(GiCell a, GiCell b) => !(a == b);
	public int GetHashCode() => (int)((uint32)x * 73856093 ^ (uint32)y * 19349663 ^ (uint32)z * 83492791);
}

/// The static triangles the probe grid traces against: world-space positions with each triangle's albedo and glow,
/// and the BVH over them (built on the worker thread).
class GiGeometry
{
	/// Nine floats a triangle.
	public List<float> positions = new .() ~ delete _;
	/// Three floats a triangle each.
	public List<float> albedo = new .() ~ delete _;
	public List<float> emission = new .() ~ delete _;
	public void* bvh;
	public double buildMilliseconds;

	public int32 TriangleCount => (int32)(positions.Count / 9);

	public void Build()
	{
		let start = Stopwatch.StartNew();
		let count = TriangleCount;
		if (count <= 0)
			return;
		// On the heap: this runs on the probe worker, whose stack is small, and a big scene has millions of triangles.
		let indices = new uint32[count * 3];
		defer delete indices;
		for (int i < indices.Count)
			indices[i] = (uint32)i;
		bvh = LightBaker.tn_bake_create(positions.Ptr, count * 3, indices.Ptr, count);
		buildMilliseconds = start.Elapsed.TotalMilliseconds;
	}

	public ~this()
	{
		if (bvh != null)
			LightBaker.tn_bake_destroy(bvh);
	}
}

/// The probe grid's worker: a thread that keeps tracing rays from the probes round the camera against the static
/// geometry, and keeps their light (first-band spherical harmonics, as the baked probes hold) and how far the probes
/// see (for stopping light leaking through walls) in a staging array the main thread uploads. It never touches the
/// scene: the main thread hands it the camera, the lights and the sky each frame, and new geometry when that changes.
///
/// The probes sit at whole cells of the world (cell * spacing). Their values live in a fixed box of countX by countY
/// by countZ slots, a probe's slot being its cell wrapped into the box, so scrolling with the camera only retraces
/// the probes that came into view and moves nothing.
class GiWorker
{
	public const int32 VisibilityBlocks = 3;
	public const int32 Blocks = 3 + VisibilityBlocks;
	/// Rays never go further than this: what is beyond is treated as sky.
	const float RayLength = 60;

	public readonly int32 nx, ny, nz;
	public readonly float spacing;
	readonly int32 mRays, mBudget;
	readonly float mHysteresis;
	readonly int32 mPeriodMs;
	int32 N => nx * ny * nz;

	Monitor mLock = new .() ~ delete _;
	Thread mThread;
	bool mStop;

	// What the main thread hands over (under the lock).
	Vector3 mInCamera, mInSky, mInGround;
	List<LightBaker.BakeLight> mInLights = new .() ~ delete _;
	GiGeometry mInGeometry;
	bool mHasInput;

	// What the main thread takes (under the lock).
	public uint16[] outTexels ~ delete _;
	public int64 outVersion;
	public GiCell outOrigin;

	// Statistics, written by the worker, read by anybody.
	public float stepMilliseconds;
	public int64 raysTraced;
	public int32 probesUpdated;
	public int32 activeProbes;
	public int32 steps;
	public int32 triangles;

	// The worker's own state.
	GiGeometry mGeometry;
	List<LightBaker.BakeLight> mLights = new .() ~ delete _;
	GiCell mOrigin;
	bool mHasOrigin;
	GiCell[] mCell ~ delete _;
	float[] mSh ~ delete _;
	float[] mVis ~ delete _;
	bool[] mValid ~ delete _;
	bool[] mFresh ~ delete _;
	bool[] mPicked ~ delete _;
	int32[] mOrder ~ delete _;
	int32 mCursorAll, mCursorNear;
	List<int32> mChosen = new .() ~ delete _;
	List<int32> mTouched = new .() ~ delete _;
	uint32 mRandom = 12345;
	Vector3[] mDirections ~ delete _;
	Vector3 mSky, mGround;
	int32 mOutWidth, mOutHeight, mOutDepth;

	// Scratch for one probe's rays.
	float[] mRayData ~ delete _;
	int32[] mRayTriangles ~ delete _;
	float[] mRayHits ~ delete _;
	Vector3[] mRayRadiance ~ delete _;
	float[] mRayDistance ~ delete _;
	List<int32> mShade = new .() ~ delete _;
	Vector3[] mPosition ~ delete _;
	Vector3[] mNormal ~ delete _;
	Vector3[] mDirect ~ delete _;
	float[] mShadowRays ~ delete _;
	uint8[] mBlocked ~ delete _;
	List<int32> mShadowFor = new .() ~ delete _;
	List<Vector3> mShadowAmount = new .() ~ delete _;

	static ProfilerMarker sStepMarker = .("DynamicGI worker step", .Rendering);

	public this(int32 nx, int32 ny, int32 nz, float spacing, int32 rays, int32 budget, float hysteresis, int32 periodMs)
	{
		this.nx = nx;
		this.ny = ny;
		this.nz = nz;
		this.spacing = spacing;
		mRays = rays;
		mBudget = budget;
		mHysteresis = hysteresis;
		mPeriodMs = periodMs;
		let count = N;
		mCell = new .[count];
		mSh = new .[count * 12];
		mVis = new .[count * 12];
		mValid = new .[count];
		mFresh = new .[count];
		mPicked = new .[count];
		mOrder = new .[count];
		mOutWidth = nx;
		mOutHeight = ny;
		mOutDepth = nz * Blocks;
		outTexels = new .[mOutWidth * mOutHeight * mOutDepth * 4];
		mRayData = new .[rays * 7];
		mRayTriangles = new .[rays];
		mRayHits = new .[rays * 4];
		mRayRadiance = new .[rays];
		mRayDistance = new .[rays];
		mPosition = new .[rays];
		mNormal = new .[rays];
		mDirect = new .[rays];
		mShadowRays = new .[rays * 7];
		mBlocked = new .[rays];
		mDirections = new .[rays];
		for (int i < count)
		{
			mFresh[i] = true;
			SetInvalid(i);
		}
		// Every slot starts as a probe that sees nothing: no weight in the shader.
		for (int i < count)
			Publish(i);
	}

	public ~this()
	{
		Stop();
		delete mGeometry;
		delete mInGeometry;
	}

	public void Start()
	{
#if !BF_PLATFORM_WASM
		mStop = false;
		mThread = new Thread(new => Run);
		mThread.Start(false);
#endif
	}

	public void Stop()
	{
#if !BF_PLATFORM_WASM
		if (mThread != null)
		{
			mStop = true;
			mThread.Join();
			delete mThread;
			mThread = null;
		}
#endif
	}

	/// The main thread's frame: where the camera is, the lights near it, the sky, and (when it changed) the scene's
	/// static triangles, which now belong to the worker.
	public void Hand(Vector3 camera, List<LightBaker.BakeLight> lights, Vector3 sky, Vector3 ground, GiGeometry geometry)
	{
		using (mLock.Enter())
		{
			mInCamera = camera;
			mInSky = sky;
			mInGround = ground;
			mInLights.Clear();
			mInLights.AddRange(lights);
			if (geometry != null)
			{
				delete mInGeometry;
				mInGeometry = geometry;
			}
			mHasInput = true;
		}
	}

	/// Copies the published probes if there are newer ones than `version`; false when there are not.
	public bool Take(int64 version, uint16[] into, out int64 newVersion, out GiCell origin)
	{
		using (mLock.Enter())
		{
			newVersion = outVersion;
			origin = outOrigin;
			if (outVersion == version)
				return false;
			outTexels.CopyTo(into);
			return true;
		}
	}

	public int32 TextureWidth => mOutWidth;
	public int32 TextureHeight => mOutHeight;
	public int32 TextureDepth => mOutDepth;

	void Run()
	{
		while (!mStop)
		{
			let start = Stopwatch.StartNew();
			Step();
			let took = (int32)start.Elapsed.TotalMilliseconds;
			stepMilliseconds = stepMilliseconds * 0.9f + (float)start.Elapsed.TotalMilliseconds * 0.1f;
			Thread.Sleep(Math.Max(2, mPeriodMs - took));
		}
	}

	static int32 Wrap(int32 value, int32 count)
	{
		let r = value % count;
		return r < 0 ? r + count : r;
	}

	int32 SlotOf(GiCell cell) => (Wrap(cell.z, nz) * ny + Wrap(cell.y, ny)) * nx + Wrap(cell.x, nx);

	void Step()
	{
		using (sStepMarker.Sample())
		{
			Vector3 camera;
			GiGeometry fresh = null;
			using (mLock.Enter())
			{
				if (!mHasInput)
					return;
				camera = mInCamera;
				mSky = mInSky;
				mGround = mInGround;
				mLights.Clear();
				mLights.AddRange(mInLights);
				fresh = mInGeometry;
				mInGeometry = null;
			}
			if (fresh != null)
			{
				fresh.Build();
				let old = mGeometry;
				mGeometry = fresh;
				delete old;
				triangles = mGeometry.TriangleCount;
				Log.Info(scope $"Dynamic GI: {triangles} triangles in the scene's BVH ({fresh.buildMilliseconds:0.0} ms)");
				// The light of everything changed: refresh the whole grid, nearest probes first.
				mCursorAll = 0;
				mCursorNear = 0;
			}

			let origin = GiCell((int32)Math.Floor(camera.x / spacing) - nx / 2, (int32)Math.Floor(camera.y / spacing) - ny / 2, (int32)Math.Floor(camera.z / spacing) - nz / 2);
			mTouched.Clear();
			if (!mHasOrigin || origin != mOrigin)
				Reorigin(origin, camera);
			else if ((mOrderCamera - camera).Length > spacing)
				SortOrder(camera); // the order only matters for which probes come first

			Pick();
			RandomDirections();
			for (let slot in mChosen)
				Trace(slot);
			mChosen.Clear();
			for (let slot in mTouched)
				mPicked[slot] = false;
			int32 active = 0;
			for (int i < N)
			{
				if (mValid[i])
					active++;
			}
			activeProbes = active;
			steps++;
			PublishAll();
		}
	}

	Vector3 mOrderCamera;

	/// The camera moved to another cell: slots whose cell came into the box start again as unseen.
	void Reorigin(GiCell origin, Vector3 camera)
	{
		mOrigin = origin;
		mHasOrigin = true;
		for (int32 sz < nz)
		{
			for (int32 sy < ny)
			{
				for (int32 sx < nx)
				{
					let slot = (sz * ny + sy) * nx + sx;
					let cell = GiCell(origin.x + Wrap(sx - origin.x, nx), origin.y + Wrap(sy - origin.y, ny), origin.z + Wrap(sz - origin.z, nz));
					if (mCell[slot] != cell)
					{
						mCell[slot] = cell;
						mFresh[slot] = true;
						SetInvalid(slot);
						mTouched.Add(slot);
					}
				}
			}
		}
		SortOrder(camera);
	}

	void SortOrder(Vector3 camera)
	{
		mOrderCamera = camera;
		let distance = scope float[N];
		for (int32 i < N)
		{
			mOrder[i] = i;
			let p = ProbePosition(mCell[i]);
			distance[i] = (p - camera).LengthSquared;
		}
		let order = scope List<int32>(N);
		for (let i in mOrder)
			order.Add(i);
		order.Sort(scope (a, b) => distance[a] <=> distance[b]);
		for (int i < N)
			mOrder[i] = order[i];
	}

	Vector3 ProbePosition(GiCell cell) => .(cell.x * spacing, cell.y * spacing, cell.z * spacing);

	void SetInvalid(int slot)
	{
		mValid[slot] = false;
		for (int i < 12)
		{
			mSh[slot * 12 + i] = 0;
			mVis[slot * 12 + i] = (i & 1) == 0 ? -1 : 0;
		}
	}

	/// This step's probes: those never traced first (nearest first), then the next ones round the whole grid and
	/// round the nearest quarter, which are kept fresher.
	void Pick()
	{
		mChosen.Clear();
		let count = N;
		for (let slot in mOrder)
		{
			if (mChosen.Count >= mBudget)
				break;
			if (mFresh[slot])
			{
				mChosen.Add(slot);
				mPicked[slot] = true;
			}
		}
		let rest = mBudget - mChosen.Count;
		let nearCount = Math.Max(count / 4, 1);
		for (int k < rest)
		{
			let near = (k & 1) == 0;
			int32 slot;
			if (near)
			{
				slot = mOrder[mCursorNear % nearCount];
				mCursorNear++;
			}
			else
			{
				slot = mOrder[mCursorAll % count];
				mCursorAll++;
			}
			if (mPicked[slot])
				continue;
			mPicked[slot] = true;
			mChosen.Add(slot);
		}
		// Remember them to clear the marks afterwards.
		for (let slot in mChosen)
			mTouched.Add(slot);
	}

	/// A fresh Fibonacci sphere of directions, turned randomly (the same for every probe of the step).
	void RandomDirections()
	{
		// A random rotation from two random vectors.
		Vector3 Random3()
		{
			Vector3 v;
			repeat
			{
				v = .(LightBaker.Random(ref mRandom) * 2 - 1, LightBaker.Random(ref mRandom) * 2 - 1, LightBaker.Random(ref mRandom) * 2 - 1);
			}
			while (v.LengthSquared > 1 || v.LengthSquared < 0.01f);
			return v.Normalized;
		}
		let ax = Random3();
		var ay = Random3();
		ay = (ay - ax * Vector3.Dot(ay, ax));
		if (ay.LengthSquared < 1e-4f)
			LightBaker.Basis(ax, out ay, let unused);
		ay = ay.Normalized;
		let az = Vector3.Cross(ax, ay);
		let golden = Math.PI_f * (3 - Math.Sqrt(5.0f));
		for (int s < mRays)
		{
			let dy = 1 - (s + 0.5f) / mRays * 2;
			let radius = Math.Sqrt(Math.Max(1 - dy * dy, 0));
			let angle = golden * s;
			let d = Vector3(Math.Cos(angle) * radius, dy, Math.Sin(angle) * radius);
			mDirections[s] = ax * d.x + ay * d.y + az * d.z;
		}
	}

	/// The light from what the grid knew at the last step, at a point facing n: the eight probes round it blended
	/// by distance, those that are inside geometry or not yet traced left out. The sky's light when there are none.
	Vector3 Irradiance(Vector3 p, Vector3 n)
	{
		let gx = p.x / spacing, gy = p.y / spacing, gz = p.z / spacing;
		let bx = (int32)Math.Floor(gx), by = (int32)Math.Floor(gy), bz = (int32)Math.Floor(gz);
		let fx = gx - bx, fy = gy - by, fz = gz - bz;
		float[12] sum = default;
		var total = 0.0f;
		for (int corner < 8)
		{
			let dx = corner & 1, dy = (corner >> 1) & 1, dz = (corner >> 2) & 1;
			let cx = bx + dx, cy = by + dy, cz = bz + dz;
			if (cx < mOrigin.x || cy < mOrigin.y || cz < mOrigin.z || cx >= mOrigin.x + nx || cy >= mOrigin.y + ny || cz >= mOrigin.z + nz)
				continue;
			let slot = SlotOf(GiCell((int32)cx, (int32)cy, (int32)cz));
			if (!mValid[slot])
				continue;
			var w = (dx == 1 ? fx : 1 - fx) * (dy == 1 ? fy : 1 - fy) * (dz == 1 ? fz : 1 - fz);
			// Probes behind the surface count for less.
			let toProbe = Vector3(cx * spacing - p.x, cy * spacing - p.y, cz * spacing - p.z);
			let length = toProbe.Length;
			if (length > 1e-4f)
			{
				let facing = Math.Clamp((Vector3.Dot(toProbe / length, n) + 0.25f) / 1.25f, 0, 1);
				w *= facing * facing + 0.01f;
			}
			// And by how far the probe sees towards the point (as the shader does), so light does not bounce
			// through walls into rooms that should be dark.
			let from = Vector3(p.x - cx * spacing, p.y - cy * spacing, p.z - cz * spacing);
			let dist = Math.Max(from.Length, 1e-4f);
			let dir = from / dist;
			let vb = slot * 12;
			let mx = dir.x > 0 ? Vector2(mVis[vb], mVis[vb + 1]) : Vector2(mVis[vb + 2], mVis[vb + 3]);
			let my = dir.y > 0 ? Vector2(mVis[vb + 4], mVis[vb + 5]) : Vector2(mVis[vb + 6], mVis[vb + 7]);
			let mz = dir.z > 0 ? Vector2(mVis[vb + 8], mVis[vb + 9]) : Vector2(mVis[vb + 10], mVis[vb + 11]);
			let m = mx * (dir.x * dir.x) + my * (dir.y * dir.y) + mz * (dir.z * dir.z);
			if (dist > m.x)
			{
				let variance = Math.Max(Math.Abs(m.y - m.x * m.x), 0.01f);
				let gap = dist - m.x;
				let chebyshev = variance / (variance + gap * gap);
				w *= chebyshev * chebyshev * chebyshev;
			}
			if (w <= 1e-5f)
				continue;
			total += w;
			for (int i < 12)
				sum[i] += mSh[slot * 12 + i] * w;
		}
		if (total < 1e-4f)
			return LightBaker.SkyLight(mSky, mGround, n);
		let inv = 1 / total;
		return .(Math.Max((sum[0] + sum[1] * n.x + sum[2] * n.y + sum[3] * n.z) * inv, 0),
			Math.Max((sum[4] + sum[5] * n.x + sum[6] * n.y + sum[7] * n.z) * inv, 0),
			Math.Max((sum[8] + sum[9] * n.x + sum[10] * n.y + sum[11] * n.z) * inv, 0));
	}

	/// Traces one probe's rays, shades what they hit, and blends the result into its values.
	void Trace(int32 slot)
	{
		let rays = mRays;
		let position = ProbePosition(mCell[slot]);
		let bvh = mGeometry != null ? mGeometry.bvh : null;
		for (int s < rays)
		{
			let d = mDirections[s];
			mRayData[s * 7] = position.x;
			mRayData[s * 7 + 1] = position.y;
			mRayData[s * 7 + 2] = position.z;
			mRayData[s * 7 + 3] = d.x;
			mRayData[s * 7 + 4] = d.y;
			mRayData[s * 7 + 5] = d.z;
			mRayData[s * 7 + 6] = RayLength;
		}
		if (bvh != null)
			LightBaker.tn_bake_intersect(bvh, mRayData.Ptr, rays, mRayTriangles.Ptr, mRayHits.Ptr);
		else
		{
			for (var t in ref mRayTriangles)
				t = -1;
		}
		raysTraced += rays;
		let visibleRange = spacing * 3;
		var backs = 0;
		mShade.Clear();
		for (int s < rays)
		{
			let d = mDirections[s];
			let triangle = mRayTriangles[s];
			mRayRadiance[s] = default;
			if (triangle < 0)
			{
				mRayDistance[s] = visibleRange;
				mRayRadiance[s] = LightBaker.SkyLight(mSky, mGround, d);
				continue;
			}
			let t = mRayHits[s * 4];
			if (mRayHits[s * 4 + 3] > 0.5f)
			{
				backs++;
				mRayDistance[s] = Math.Min(t * 0.2f, visibleRange);
				continue;
			}
			mRayDistance[s] = Math.Min(t, visibleRange);
			let u = mRayHits[s * 4 + 1], v = mRayHits[s * 4 + 2];
			let tri = (mGeometry.positions.Ptr + triangle * 9);
			let a = Vector3(tri[0], tri[1], tri[2]);
			let e1 = Vector3(tri[3], tri[4], tri[5]) - a, e2 = Vector3(tri[6], tri[7], tri[8]) - a;
			var n = Vector3.Cross(e1, e2);
			let length = n.Length;
			n = length > 1e-12f ? n / length : -d;
			mPosition[s] = a + e1 * u + e2 * v;
			mNormal[s] = n;
			mDirect[s] = default;
			mShade.Add((int32)s);
		}
		// A probe mostly inside geometry (its sphere seeing back faces): off.
		if (backs > rays / 4)
		{
			mFresh[slot] = false;
			SetInvalid(slot);
			probesUpdated++;
			return;
		}
		if (mShade.Count > 0)
		{
			DirectLight(position);
			for (let s in mShade)
			{
				let triangle = mRayTriangles[s];
				let albedo = Vector3(mGeometry.albedo[triangle * 3], mGeometry.albedo[triangle * 3 + 1], mGeometry.albedo[triangle * 3 + 2]);
				let emission = Vector3(mGeometry.emission[triangle * 3], mGeometry.emission[triangle * 3 + 1], mGeometry.emission[triangle * 3 + 2]);
				let n = mNormal[s];
				let indirect = Irradiance(mPosition[s] + n * 0.05f, n);
				mRayRadiance[s] = emission + .(albedo.x * (mDirect[s].x + indirect.x), albedo.y * (mDirect[s].y + indirect.y), albedo.z * (mDirect[s].z + indirect.z));
			}
		}
		// Projected on the first two bands, as the baked probes are (LightBaker.BakeGrid).
		Vector3 c0 = default, cx = default, cy = default, cz = default;
		for (int s < rays)
		{
			if (mRayTriangles[s] >= 0 && mRayHits[s * 4 + 3] > 0.5f)
				continue;
			let d = mDirections[s];
			let light = mRayRadiance[s];
			c0 = c0 + light;
			cx = cx + light * d.x;
			cy = cy + light * d.y;
			cz = cz + light * d.z;
		}
		float[12] sh = default;
		let scale0 = 1.0f / rays;
		let scale1 = 2.0f / rays;
		for (int channel < 3)
		{
			sh[channel * 4] = c0[channel] * scale0;
			sh[channel * 4 + 1] = cx[channel] * scale1;
			sh[channel * 4 + 2] = cy[channel] * scale1;
			sh[channel * 4 + 3] = cz[channel] * scale1;
		}
		// How far each of the six axis directions sees: the mean distance and mean squared distance, weighted by how
		// much a ray points that way.
		float[12] vis = default;
		float[6] weight = default;
		for (int s < rays)
		{
			let d = mDirections[s];
			let distance = mRayDistance[s];
			for (int axis < 3)
			{
				let component = axis == 0 ? d.x : (axis == 1 ? d.y : d.z);
				for (int side < 2)
				{
					let c = side == 0 ? component : -component;
					if (c <= 0)
						continue;
					let nearness = 1 / (distance + 0.25f); let w = c * c * nearness * nearness;
					let k = axis * 2 + side;
					weight[k] += w;
					vis[axis * 4 + side * 2] += w * distance;
					vis[axis * 4 + side * 2 + 1] += w * distance * distance;
				}
			}
		}
		for (int k < 6)
		{
			let axis = k / 2, side = k % 2;
			if (weight[k] > 1e-4f)
			{
				vis[axis * 4 + side * 2] /= weight[k];
				vis[axis * 4 + side * 2 + 1] /= weight[k];
			}
			else
			{
				vis[axis * 4 + side * 2] = visibleRange;
				vis[axis * 4 + side * 2 + 1] = visibleRange * visibleRange;
			}
		}
		// Blend into what the probe held: slowly, but quickly when the light changed a lot.
		var hysteresis = mHysteresis;
		if (mFresh[slot] || !mValid[slot])
			hysteresis = 0;
		else
		{
			let before = mSh[slot * 12] + mSh[slot * 12 + 4] + mSh[slot * 12 + 8];
			let after = sh[0] + sh[4] + sh[8];
			let change = Math.Abs(after - before) / Math.Max(Math.Max(before, after), 0.1f);
			if (change > 0.25f)
				hysteresis = Math.Max(hysteresis - 0.35f, 0.3f);
		}
		for (int i < 12)
		{
			mSh[slot * 12 + i] = mSh[slot * 12 + i] * hysteresis + sh[i] * (1 - hysteresis);
			// A hit pulls the distances faster than they relax (a wall appearing counts at once).
			mVis[slot * 12 + i] = mVis[slot * 12 + i] * hysteresis + vis[i] * (1 - hysteresis);
		}
		mValid[slot] = true;
		mFresh[slot] = false;
		probesUpdated++;
	}

	/// The scene's lights at the shaded hits (mShade) of a probe, with a shadow ray each, sent all at once.
	void DirectLight(Vector3 probe)
	{
		for (let light in mLights)
		{
			// Only lights that can reach round the probe.
			if (light.type != 2 && (light.position - probe).Length > light.range + RayLength)
				continue;
			mShadowFor.Clear();
			mShadowAmount.Clear();
			for (let s in mShade)
			{
				let position = mPosition[s];
				let n = mNormal[s];
				if (!LightBaker.LightShare(light, position, n, n, let toLight, let distance, let amount))
					continue;
				let bias = LightBaker.Bias(position);
				let origin = position + n * bias;
				let k = mShadowFor.Count;
				mShadowRays[k * 7] = origin.x;
				mShadowRays[k * 7 + 1] = origin.y;
				mShadowRays[k * 7 + 2] = origin.z;
				mShadowRays[k * 7 + 3] = toLight.x;
				mShadowRays[k * 7 + 4] = toLight.y;
				mShadowRays[k * 7 + 5] = toLight.z;
				mShadowRays[k * 7 + 6] = distance - bias * 2;
				mShadowFor.Add(s);
				mShadowAmount.Add(amount);
			}
			if (mShadowFor.Count == 0)
				continue;
			let bvh = mGeometry != null ? mGeometry.bvh : null;
			for (var b in ref mBlocked)
				b = 0;
			if (bvh != null)
				LightBaker.tn_bake_occluded(bvh, mShadowRays.Ptr, (int32)mShadowFor.Count, mBlocked.Ptr);
			raysTraced += mShadowFor.Count;
			for (int k < mShadowFor.Count)
			{
				if (mBlocked[k] == 0)
					mDirect[mShadowFor[k]] = mDirect[mShadowFor[k]] + mShadowAmount[k];
			}
		}
	}

	/// Writes a slot's values into the staging texels: red, green and blue (a, b.n) in the first three blocks of
	/// depth, then the three pairs of axis directions' distances.
	void Publish(int slot)
	{
		let sx = slot % nx, sy = (slot / nx) % ny, sz = slot / (nx * ny);
		for (int block < Blocks)
		{
			let texel = ((((block * nz) + sz) * mOutHeight + sy) * mOutWidth + sx) * 4;
			for (int i < 4)
				outTexels[texel + i] = LightProbeGrid.Half(block < 3 ? mSh[slot * 12 + block * 4 + i] : mVis[slot * 12 + (block - 3) * 4 + i]);
		}
	}

	void PublishAll()
	{
		using (mLock.Enter())
		{
			for (let slot in mTouched)
				Publish(slot);
			outOrigin = mOrigin;
			outVersion++;
		}
	}
}

/// Probe-grid global illumination (ScreenEffects.GlobalIllumination = ProbeGrid, SceneEnvironment.globalIllumination
/// above 0): light bounced round the scene, kept in a camera-centred grid of probes (the same first-band spherical
/// harmonics the baked light probes hold) that a worker thread keeps tracing rays from against the scene's static
/// triangles, so moving lights, the sun turning and doors opening change it as the game runs. Each ray's hit is lit by
/// the scene's lights (with shadow rays) plus what the grid itself held a moment ago there, which makes the light
/// bounce as many times as it has time for. Surfaces without a lightmap take their ambient light from it
/// (lighting.sh dynamicGridAmbient): the eight probes round the point, weighted by distance, by whether the probe
/// faces the surface and by how far the probe sees towards the point (so light does not leak through walls).
///
/// Moving things (Rigidbodies, skinned models, anything whose transform changes) are not in the traced geometry, so
/// they do not block or bounce light, but they are lit by the grid. Where the scene has baked light probes, those are used
/// instead. Costs nothing while off: no thread, no memory. Not on the web, where there are no threads.
static class DynamicGI
{
	// What the grid is made of; changed only while it is off (they apply when its worker starts).
	public static float Spacing = 2.5f;
	public static int32 CountX = 16, CountY = 8, CountZ = 16;
	public static int32 RaysPerProbe = 96;
	public static int32 ProbesPerStep = 192;
	public static float Hysteresis = 0.92f;
	/// The worker's pause between steps, in milliseconds.
	public static int32 StepPeriod = 20;
	/// Triangles the traced scene may hold (the rest is left out).
	public static int32 MaxTriangles = 2000000;

	static GiWorker sWorker;
	static Scene sScene;
	static bgfx.TextureHandle sTexture = .() { idx = uint16.MaxValue };
	static uint16[] sUpload ~ delete _;
	static int64 sUploaded = -1;
	static GiCell sOrigin;
	static float sStrength = 1;
	static int64 sUpdatedFrame = -1;
	static bool sLoggedWeb;
	static bool sReady;
	static List<LightBaker.BakeLight> sLights = new .() ~ delete _;
	static List<LightBaker.BakeLight> sNearLights = new .() ~ delete _;

	static ProfilerMarker sUpdateMarker = .("DynamicGI.Update", .Rendering);
	static ProfilerCounter sStepCounter = .("GI worker step", .Rendering, "ms");
	static ProfilerCounter sProbeCounter = .("GI probes updated", .Rendering);
	static ProfilerCounter sRayCounter = .("GI rays", .Rendering);

	/// Whether the grid is on: the setting, a scene strength above 0, and a platform that can run its worker.
	public static bool Wanted(SceneEnvironment env)
	{
		if (!ScreenEffects.UsesProbeGrid || env == null || env.globalIllumination <= 0.001f || !Gfx.Initialized)
			return false;
#if BF_PLATFORM_WASM
		if (!sLoggedWeb)
		{
			sLoggedWeb = true;
			Log.Info("Dynamic GI: the probe grid needs a worker thread, which web pages do not have; surfaces keep their ambient light");
		}
		return false;
#else
		return true;
#endif
	}

	/// Whether the shader has probes to use.
	public static bool Ready => sReady && sTexture.Valid;

	/// The grid's worker thread is running.
	public static bool Running => sWorker != null;
	public static int32 TriangleCount => sWorker != null ? sWorker.triangles : 0;
	public static int32 ActiveProbes => sWorker != null ? sWorker.activeProbes : 0;
	public static float StepMilliseconds => sWorker != null ? sWorker.stepMilliseconds : 0;
	public static int64 RaysTraced => sWorker != null ? sWorker.raysTraced : 0;
	public static int32 Steps => sWorker != null ? sWorker.steps : 0;

	/// Once a frame from a view that advances the scene: starts, feeds and stops the worker, and uploads what it made.
	public static void Update(Scene scene, SceneEnvironment env, Vector3 camera, bool advance)
	{
		if (!advance || sUpdatedFrame == Time.FrameCount)
			return;
		sUpdatedFrame = Time.FrameCount;
		if (!Wanted(env))
		{
			if (sWorker != null || sTexture.Valid)
				Shutdown();
			return;
		}
		using (sUpdateMarker.Sample())
		{
			if (sScene != scene)
			{
				Shutdown();
				sScene = scene;
			}
			sStrength = env.globalIllumination;
			if (sWorker == null)
				Start();
			Feed(scene, env, camera);
			Upload();
		}
	}

	static void Start()
	{
		var spacing = Spacing;
		var nx = CountX, ny = CountY, nz = CountZ;
		var rays = RaysPerProbe;
		var budget = ProbesPerStep;
		var period = StepPeriod;
#if BF_PLATFORM_ANDROID || BF_PLATFORM_IOS
		// Phones: a smaller grid, fewer rays, a slower worker.
		nx = Math.Min(nx, 12);
		ny = Math.Min(ny, 6);
		nz = Math.Min(nz, 12);
		rays = Math.Min(rays, 48);
		budget = Math.Min(budget, 48);
		period = Math.Max(period, 50);
		spacing = Math.Max(spacing, 3);
#endif
		sWorker = new GiWorker(Math.Max(nx, 2), Math.Max(ny, 2), Math.Max(nz, 2), Math.Max(spacing, 0.5f), Math.Max(rays, 16), Math.Max(budget, 8), Math.Clamp(Hysteresis, 0, 0.99f), period);
		sWorker.Start();
		sUploaded = -1;
		sReady = false;
		sNextCheck = 0;
		sBuiltSignature = 0;
		sGathering = false;
		Log.Info(scope $"Dynamic GI: probe grid {sWorker.nx}x{sWorker.ny}x{sWorker.nz}, {sWorker.spacing} m apart, {rays} rays a probe");
	}

	/// Stops the worker and frees everything the grid held.
	public static void Shutdown()
	{
		if (sWorker != null)
		{
			Log.Info(scope $"Dynamic GI: stopped after {sWorker.steps} steps, {sWorker.raysTraced} rays");
			delete sWorker;
			sWorker = null;
		}
		if (sTexture.Valid && Gfx.Initialized)
			bgfx.destroy_texture(sTexture);
		sTexture.idx = uint16.MaxValue;
		DeleteAndNullify!(sUpload);
		DeleteAndNullify!(sBuilding);
		sTracks.Clear();
		sGatherList.Clear();
		sGathering = false;
		sReady = false;
		sScene = null;
		sUploaded = -1;
	}

	/// Sends the camera, the lights and (when it changed) the static geometry to the worker.
	static void Feed(Scene scene, SceneEnvironment env, Vector3 camera)
	{
		sLights.Clear();
		LightBaker.CollectLights(scene, sLights);
		// The lights that matter near the camera: directional ones, and those whose reach touches the grid.
		sNearLights.Clear();
		let reach = Math.Max(sWorker.nx, Math.Max(sWorker.ny, sWorker.nz)) * sWorker.spacing * 0.5f + 20;
		for (let light in sLights)
		{
			if (light.type != 2 && ((light.position - camera).Length > reach + light.range || light.color.x + light.color.y + light.color.z <= 0))
				continue;
			sNearLights.Add(light);
		}
		if (sNearLights.Count > 24)
		{
			sNearLights.Sort(scope (a, b) =>
				{
					let ka = a.type == 2 ? 0.0f : (a.position - camera).LengthSquared;
					let kb = b.type == 2 ? 0.0f : (b.position - camera).LengthSquared;
					return ka <=> kb;
				});
			sNearLights.RemoveRange(24, sNearLights.Count - 24);
		}
		GiGeometry finished = null;
		MaintainGeometry(scene, ref finished);
		sWorker.Hand(camera, sNearLights, LightBaker.Linear(env.ambientSky, env.ambientIntensity), LightBaker.Linear(env.ambientGround, env.ambientIntensity), finished);
	}

	// ---- the traced scene ----

	class Track
	{
		public uint32 matrix;
		public double changed = -1000;
		public int64 seen;
	}

	static Dictionary<uint64, Track> sTracks = new .() ~ DeleteDictionaryAndValues!(_);
	static List<MeshRenderer> sGatherList = new .() ~ delete _;
	static int32 sGatherIndex;
	static GiGeometry sBuilding;
	static bool sGathering;
	static double sNextCheck;
	static uint64 sBuiltSignature, sGatherSignature;
	static int64 sCheck;
	static bool sWarnedTriangles;
	static ProfilerMarker sGatherMarker = .("DynamicGI.Gather", .Rendering);

	/// A world matrix as a number, to notice a renderer that moved (to a thousandth of a metre).
	static uint32 MatrixHash(Matrix4 matrix)
	{
		uint32 hash = 2166136261;
		for (int i < 16)
		{
			let quantized = (int32)Math.Round(matrix.m[i] * 1000);
			hash = (hash ^ (uint32)quantized) * 16777619;
		}
		return hash;
	}

	static bool Eligible(MeshRenderer renderer)
	{
		if (!renderer.GameObject.ActiveInHierarchy || !renderer.GameObject.InActiveWorld || renderer.shadowOnly || renderer.color.a < 0.999f || renderer.IsMoving)
			return false;
		return true;
	}

	/// Every second or so looks for changes to the scene's static renderers, and then gathers their triangles over
	/// a few frames (never more than a millisecond or two each) before handing them over.
	static void MaintainGeometry(Scene scene, ref GiGeometry finished)
	{
		double now = Time.RealTime;
		if (sGathering)
		{
			using (sGatherMarker.Sample())
				GatherSome(ref finished);
			return;
		}
		if (now < sNextCheck)
			return;
		sNextCheck = now + 1.0;
		sCheck++;
		let renderers = scope List<MeshRenderer>();
		scene.Components<MeshRenderer>(renderers);
		uint64 signature = 0;
		sGatherList.Clear();
		for (let renderer in renderers)
		{
			if (!Eligible(renderer))
				continue;
			let id = renderer.GameObject.Entity.id;
			let matrix = MatrixHash(renderer.RenderMatrix);
			Track track;
			if (!sTracks.TryGetValue(id, out track))
			{
				track = new Track();
				track.matrix = matrix;
				sTracks[id] = track;
			}
			track.seen = sCheck;
			// Something that moves is left out, and back in once it has stayed still for a few seconds.
			if (track.matrix != matrix)
			{
				track.matrix = matrix;
				track.changed = now;
			}
			if (now - track.changed < 3)
				continue;
			let mesh = renderer.ActiveMesh;
			let parts = renderer.DrawnParts;
			if ((parts == null || parts.Count == 0) && mesh == null)
				continue;
			sGatherList.Add(renderer);
			signature += ((uint64)id * 0x9E3779B97F4A7C15 + matrix) * 0xBF58476D1CE4E5B9 + (uint64)(int)Internal.UnsafeCastToPtr(mesh);
		}
		// Forget renderers that are gone.
		var gone = scope List<uint64>();
		for (let pair in sTracks)
		{
			if (pair.value.seen != sCheck)
				gone.Add(pair.key);
		}
		for (let key in gone)
		{
			delete sTracks[key];
			sTracks.Remove(key);
		}
		signature = signature * 31 + (uint64)sGatherList.Count;
		if (signature == sBuiltSignature && sBuiltOnce)
		{
			sGatherList.Clear();
			return;
		}
		// Something changed: gather again.
		sGatherSignature = signature;
		sGatherIndex = 0;
		delete sBuilding;
		sBuilding = new GiGeometry();
		sGathering = true;
		using (sGatherMarker.Sample())
			GatherSome(ref finished);
	}

	static bool sBuiltOnce;

	static void GatherSome(ref GiGeometry finished)
	{
		let start = Stopwatch.StartNew();
		while (sGatherIndex < sGatherList.Count)
		{
			let renderer = sGatherList[sGatherIndex++];
			if (renderer.GameObject.IsDestroyed)
				continue;
			AddRenderer(renderer);
			if (start.Elapsed.TotalMilliseconds > 1.5)
				break;
		}
		if (sGatherIndex >= sGatherList.Count)
		{
			sGathering = false;
			sBuiltSignature = sGatherSignature;
			sBuiltOnce = true;
			sGatherList.Clear();
			finished = sBuilding;
			sBuilding = null;
		}
	}

	static void AddRenderer(MeshRenderer renderer)
	{
		if (sBuilding.TriangleCount >= MaxTriangles)
		{
			if (!sWarnedTriangles)
			{
				sWarnedTriangles = true;
				Log.Warning(scope $"Dynamic GI: the scene has more than {MaxTriangles} static triangles; the rest do not bounce light");
			}
			return;
		}
		let world = renderer.RenderMatrix;
		let mirrored = RenderView.Mirrored(world);
		let parts = renderer.DrawnParts;
		let partCount = (parts != null && parts.Count > 0) ? parts.Count : 1;
		for (int p < partCount)
		{
			Mesh mesh;
			if (parts != null && parts.Count > 0)
			{
				if (parts[p].hidden || parts[p].shadowOnly)
					continue;
				mesh = parts[p].mesh;
			}
			else
				mesh = renderer.ActiveMesh;
			if (mesh == null || mesh.IsDynamic || mesh.VertexSource != null || mesh.Indices.Count < 3)
				continue;
			LightBaker.PartColors(renderer, parts, p, let albedo, let emission, let flat);
			for (int t < mesh.Indices.Count / 3)
			{
				var ia = mesh.Indices[t * 3], ib = mesh.Indices[t * 3 + 1], ic = mesh.Indices[t * 3 + 2];
				if (mirrored)
					Swap!(ib, ic);
				let va = mesh.Vertices[(int)ia], vb = mesh.Vertices[(int)ib], vc = mesh.Vertices[(int)ic];
				let pa = world.TransformPoint(va.position), pb = world.TransformPoint(vb.position), pc = world.TransformPoint(vc.position);
				if (Vector3.Cross(pb - pa, pc - pa).LengthSquared < 1e-14f)
					continue;
				let vertexColor = (LightBaker.VertexColor(va.color) + LightBaker.VertexColor(vb.color) + LightBaker.VertexColor(vc.color)) / 3;
				let color = LightBaker.Clamp01(.(albedo.x * vertexColor.x, albedo.y * vertexColor.y, albedo.z * vertexColor.z));
				sBuilding.positions.Add(pa.x); sBuilding.positions.Add(pa.y); sBuilding.positions.Add(pa.z);
				sBuilding.positions.Add(pb.x); sBuilding.positions.Add(pb.y); sBuilding.positions.Add(pb.z);
				sBuilding.positions.Add(pc.x); sBuilding.positions.Add(pc.y); sBuilding.positions.Add(pc.z);
				sBuilding.albedo.Add(color.x); sBuilding.albedo.Add(color.y); sBuilding.albedo.Add(color.z);
				sBuilding.emission.Add(emission.x); sBuilding.emission.Add(emission.y); sBuilding.emission.Add(emission.z);
			}
		}
	}

	// ---- the texture ----

	/// Sends the worker's newest probes to the 3D texture (creating it the first time).
	static void Upload()
	{
		let w = sWorker.TextureWidth, h = sWorker.TextureHeight, d = sWorker.TextureDepth;
		if (!sTexture.Valid)
		{
			sTexture = bgfx.create_texture_3d((uint16)w, (uint16)h, (uint16)d, false, .RGBA16F, Gfx.SamplerClamp, null, 0);
			sUpload = new uint16[w * h * d * 4];
		}
		if (!sWorker.Take(sUploaded, sUpload, let version, let origin))
			return;
		sUploaded = version;
		sOrigin = origin;
		bgfx.update_texture_3d(sTexture, 0, 0, 0, 0, (uint16)w, (uint16)h, (uint16)d, bgfx.copy(sUpload.Ptr, (uint32)(sUpload.Count * 2)));
		sReady = true;
		sStepCounter.Set(sWorker.stepMilliseconds);
		sProbeCounter.Set(sWorker.probesUpdated);
		sRayCounter.Set((double)sWorker.raysTraced);
		sWorker.probesUpdated = 0;
	}

	/// Fills the shader's probe uniforms (LightProbes.Bind's ten vectors) with the grid, for lighting.sh's
	/// dynamicGridAmbient: [0] the first probe's position and 2; [1] 1 / spacing, the scene's strength, spacing;
	/// [2] probes along each axis; [3] the first probe's cell; [8] the texture's size. Returns the texture.
	public static bgfx.TextureHandle Fill(Vector4* uniforms)
	{
		let w = sWorker;
		uniforms[0] = .(sOrigin.x * w.spacing, sOrigin.y * w.spacing, sOrigin.z * w.spacing, 2);
		uniforms[1] = .(1 / w.spacing, sStrength, w.spacing, 0);
		uniforms[2] = .(w.nx, w.ny, w.nz, 0);
		uniforms[3] = .(sOrigin.x, sOrigin.y, sOrigin.z, 0);
		uniforms[8] = .(w.TextureWidth, w.TextureHeight, w.TextureDepth, 0);
		return sTexture;
	}
}
