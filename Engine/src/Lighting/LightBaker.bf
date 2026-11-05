using System;
using System.Collections;
using System.Threading;

namespace Tallow;

/// How the light baker works (docs/baked-lighting.md).
class BakeSettings
{
	/// Lightmap texels for each metre of surface.
	public float texelsPerMetre = 8;
	/// The largest a lightmap picture gets, across; more are made when one is full.
	public int32 atlasSize = 1024;
	/// Rays from each texel to gather the light round it. More is smoother and slower.
	public int32 samples = 256;
	/// How many times light bounces off surfaces (0: only the sky and the lights).
	public int32 bounces = 3;
	/// Whether to bake light probes for moving things, and how far apart they are, in metres.
	public bool probes = true;
	public float probeSpacing = 3;
	public int32 probeSamples = 256;
	/// Worker threads (0: all but one of the machine's).
	public int32 threads = 0;

	/// A scene's own settings (SceneEnvironment's bake fields).
	public void FromScene(SceneEnvironment env)
	{
		texelsPerMetre = Math.Clamp(env.bakeTexelsPerMetre, 0.25f, 128);
		samples = Math.Clamp(env.bakeSamples, 4, 4096);
		bounces = Math.Clamp(env.bakeBounces, 0, 16);
		probes = env.bakeProbes;
		probeSpacing = Math.Clamp(env.bakeProbeSpacing, 0.25f, 100);
	}

	public void CopyFrom(BakeSettings other)
	{
		texelsPerMetre = other.texelsPerMetre;
		atlasSize = other.atlasSize;
		samples = other.samples;
		bounces = other.bounces;
		probes = other.probes;
		probeSpacing = other.probeSpacing;
		probeSamples = other.probeSamples;
		threads = other.threads;
	}
}

/// Bakes a scene's lighting (docs/baked-lighting.md): for every Mesh Renderer with Baked Lighting ticked, a lightmap of
/// the light reaching each part of it from the sky, from lights marked Baked Only, and bounced off everything else;
/// and a grid of light probes holding the light bounced round the scene for things that move.
///
/// Make one on the main thread (it copies what it needs from the scene), call Run on any thread (the work, spread over
/// the machine's cores; Cancel stops it), then Apply on the main thread to write the pictures and point the scene at
/// them. Rays are traced in the native library's BVH (native/tallow_bake.cpp).
///
/// Light is kept in the units the shader's ambient term uses: a surface of albedo a lit by ambient A shows a * A. A
/// light's direct share is its colour times its falloff times n.l, as in lighting.sh; the sky sends
/// `ground + (sky - ground) * (0.5 + 0.75 * d.y)` from direction d, which lights an open surface exactly as the scene's
/// two ambient colours do. Each texel's rays are traced once and remembered, so every bounce after the first only
/// looks up what the rays hit.
class LightBaker
{
	/// Lightmaps are RGBM pictures: colour times alpha times this.
	public const float Range = 8;

	public enum Stage
	{
		Preparing,
		Tracing,
		Direct,
		Gathering,
		Bouncing,
		Probes,
		Finishing,
		Done
	}

	struct BakeLight
	{
		public Vector3 position, direction, color;
		public float range, cosOuter, cosInner, shadowStrength;
		public int32 type; // 0 point, 1 spot, 2 directional
		public bool inverseSquare, bakeDirect, castShadows;
	}

	struct Tri
	{
		public int32 object;
		public Vector2 a, b, c; // lightmap pixels
		public Vector3 na, nb, nc, geometric;
		public Vector3 albedo, emission;
		public bool flat;
	}

	struct ProbeVolume
	{
		public Bounds area;
		public int32 x, y, z;
		public float fade;
	}

	struct Texel
	{
		public int32 atlas, x, y, triangle;
		public Vector3 position, normal, geometric;
	}

	public class Atlas
	{
		public int32 width, height;
		public int32[] texelOf ~ delete _;
		public Vector3[] light ~ delete _;
		public uint8[] pixels ~ delete _;
	}

	public class BakeObject
	{
		public MeshRenderer renderer;
		public int32 atlas = -1, x, y, size;
		/// How far apart its texels are in the world, in metres.
		public float texelSize;
		public Vector4 scaleOffset;
	}

	public BakeSettings Settings = new .() ~ delete _;
	public List<BakeObject> Objects = new .() ~ DeleteContainerAndItems!(_);
	public List<Atlas> Atlases = new .() ~ DeleteContainerAndItems!(_);
	public LightProbeSet Probes ~ delete _;
	/// The Light Probe Volumes' boxes, probe counts and blend distances, copied from the scene.
	List<ProbeVolume> mVolumes = new .() ~ delete _;

	public Stage CurrentStage;
	/// How far through the current stage, 0 to 1.
	public float Progress => mWork > 0 ? Math.Min((float)mDone / mWork, 1) : 0;
	public bool Cancel;
	public double Seconds;
	public int64 Rays;
	public int TexelCount => mTexels.Count;
	public int TriangleCount => mTris.Count;

	List<BakeLight> mLights = new .() ~ delete _;
	List<Tri> mTris = new .() ~ delete _;
	List<float> mPositions = new .() ~ delete _;
	List<Texel> mTexels = new .() ~ delete _;
	Vector3 mSky, mGround;
	Bounds mBounds = .Empty;
	void* mBvh;
	int32 mSamples;

	Vector3[] mDirectAll ~ delete _;
	Vector3[] mDirectBaked ~ delete _;
	Vector3[] mSkyGather ~ delete _;
	Vector3[] mGather ~ delete _;
	Vector3[] mRadiance ~ delete _;
	int32[] mHits ~ delete _;
	bool[] mInvalid ~ delete _;

	int32 mNext;
	int32 mDone;
	int32 mWork;
	int32 mThreadCount;

	[CLink] static extern void* tn_bake_create(float* positions, int32 vertexCount, uint32* indices, int32 triangleCount);
	[CLink] static extern void tn_bake_destroy(void* bvh);
	[CLink] static extern void tn_bake_intersect(void* bvh, float* rays, int32 count, int32* triangles, float* hits);
	[CLink] static extern void tn_bake_occluded(void* bvh, float* rays, int32 count, uint8* blocked);

	public ~this()
	{
		if (mBvh != null)
			tn_bake_destroy(mBvh);
	}

	/// Copies the scene's baked renderers, lights and sky (the main thread: it may give meshes lightmap coordinates).
	public this(Scene scene, BakeSettings settings)
	{
		Settings.CopyFrom(settings);
		let env = scene.Environment;
		mSky = Linear(env.ambientSky, env.ambientIntensity);
		mGround = Linear(env.ambientGround, env.ambientIntensity);
		GatherLights(scene);
		for (let volume in scene.FindComponents<LightProbeVolume>(.. scope .()))
		{
			if (!volume.IsActiveAndEnabled || !volume.GameObject.InActiveWorld)
				continue;
			volume.Counts(let x, let y, let z);
			mVolumes.Add(.() { area = volume.WorldBox, x = x, y = y, z = z, fade = Math.Max(volume.blendDistance, 0.01f) });
		}
		for (let renderer in scene.Components<MeshRenderer>(.. scope .()))
		{
			if (!renderer.bakedLighting || !renderer.GameObject.ActiveInHierarchy || !renderer.GameObject.InActiveWorld || renderer.shadowOnly || renderer.color.a < 0.999f)
				continue;
			let meshes = scope List<Mesh>();
			if (!LightmapUV.MeshesFor(renderer, meshes))
				continue;
			AddObject(renderer, meshes);
		}
		PlaceObjects();
	}

	static Vector3 Linear(Color c, float scale = 1)
	{
		return .(Math.Pow(Math.Max(c.r, 0), 2.2f) * scale, Math.Pow(Math.Max(c.g, 0), 2.2f) * scale, Math.Pow(Math.Max(c.b, 0), 2.2f) * scale);
	}

	void GatherLights(Scene scene)
	{
		Light sun = default;
		for (let light in scene.Lights)
		{
			if (!light.IsActiveAndEnabled || !light.GameObject.InActiveWorld || light.type != .Directional)
				continue;
			if (!sun || (!sun.castShadows && light.castShadows))
				sun = light;
		}
		for (let light in scene.Lights)
		{
			if (!light.IsActiveAndEnabled || !light.GameObject.InActiveWorld)
				continue;
			BakeLight baked = default;
			baked.position = light.Transform.Position;
			baked.direction = light.Transform.Forward;
			baked.color = Linear(light.color, light.intensity);
			baked.range = light.range;
			baked.type = light.type == .Directional ? 2 : (light.type == .Spot ? 1 : 0);
			baked.cosOuter = Math.Cos(light.spotAngle * 0.5f * Mathf.Deg2Rad);
			let innerAngle = light.innerSpotAngle < 0 ? light.spotAngle * 0.8f : Math.Clamp(light.innerSpotAngle, 0, light.spotAngle);
			baked.cosInner = Math.Cos(innerAngle * 0.5f * Mathf.Deg2Rad);
			baked.inverseSquare = light.inverseSquare;
			// The sun is always drawn live; other lights marked Baked Only are left out of lightmapped surfaces live
			// (lighting.sh), so their light goes into the lightmap.
			baked.bakeDirect = light.bakedOnly && light != sun;
			baked.castShadows = light.castShadows;
			baked.shadowStrength = Math.Clamp(light.shadowStrength, 0, 1);
			mLights.Add(baked);
		}
	}

	/// The renderer's triangles in the world, with their colour and glow.
	void AddObject(MeshRenderer renderer, List<Mesh> meshes)
	{
		let object = new BakeObject();
		object.renderer = renderer;
		let objectIndex = (int32)Objects.Count;
		let world = renderer.RenderMatrix;
		let mirrored = RenderView.Mirrored(world);
		let parts = renderer.DrawnParts;
		let partCount = (parts != null && parts.Count > 0) ? parts.Count : 1;
		var worldArea = 0.0f, uvArea = 0.0f;
		let first = mTris.Count;
		for (int p < partCount)
		{
			let mesh = meshes[p];
			let material = (parts != null && parts.Count > 0 && parts[p].material != null) ? parts[p].material : renderer.ActiveMaterial;
			let tint = (parts != null && parts.Count > 0) ? parts[p].tint : Color.White;
			var albedo = Linear(renderer.color) * Linear(tint);
			Vector3 emission = default;
			var flat = renderer.flatShading;
			if (material != null)
			{
				albedo = albedo * Linear(material.color) * TextureAverage(material.texture);
				emission = Linear(material.emissive) * material.emissiveIntensity;
				flat = material.flatShading;
				if (material.unlit)
					emission = emission + albedo;
			}
			else
			{
				albedo = albedo * TextureAverage(renderer.texture);
				emission = renderer.emissiveFromColor ? albedo * renderer.emissiveIntensity : Linear(renderer.emissive) * renderer.emissiveIntensity;
				if (renderer.unlit)
					emission = emission + albedo;
			}
			for (int t < mesh.Indices.Count / 3)
			{
				var ia = mesh.Indices[t * 3], ib = mesh.Indices[t * 3 + 1], ic = mesh.Indices[t * 3 + 2];
				// A mirrored object's triangles wind the other way round in the world: turn them back.
				if (mirrored)
					Swap!(ib, ic);
				let va = mesh.Vertices[(int)ia], vb = mesh.Vertices[(int)ib], vc = mesh.Vertices[(int)ic];
				Tri tri = default;
				tri.object = objectIndex;
				let pa = world.TransformPoint(va.position), pb = world.TransformPoint(vb.position), pc = world.TransformPoint(vc.position);
				let cross = Vector3.Cross(pb - pa, pc - pa);
				let length = cross.Length;
				worldArea += length * 0.5f;
				let du = vb.uv2 - va.uv2, dv = vc.uv2 - va.uv2;
				uvArea += Math.Abs(du.x * dv.y - du.y * dv.x) * 0.5f;
				tri.geometric = length > 0 ? cross / length : .(0, 1, 0);
				tri.na = Normal(world, va.normal, tri.geometric);
				tri.nb = Normal(world, vb.normal, tri.geometric);
				tri.nc = Normal(world, vc.normal, tri.geometric);
				tri.a = va.uv2;
				tri.b = vb.uv2;
				tri.c = vc.uv2;
				// Vertex colours are stored sRGB.
				let vertexColor = (VertexColor(va.color) + VertexColor(vb.color) + VertexColor(vc.color)) / 3;
				tri.albedo = Clamp01(albedo * vertexColor);
				tri.emission = emission;
				tri.flat = flat;
				mTris.Add(tri);
				mPositions.Add(pa.x);
				mPositions.Add(pa.y);
				mPositions.Add(pa.z);
				mPositions.Add(pb.x);
				mPositions.Add(pb.y);
				mPositions.Add(pb.z);
				mPositions.Add(pc.x);
				mPositions.Add(pc.y);
				mPositions.Add(pc.z);
				mBounds.Encapsulate(pa);
				mBounds.Encapsulate(pb);
				mBounds.Encapsulate(pc);
			}
		}
		// Enough texels across its square for the wanted density.
		let side = uvArea > 1e-9f ? Math.Sqrt(worldArea / uvArea) : 0;
		object.size = (int32)Math.Clamp(Math.Ceiling(side * Settings.texelsPerMetre), 16, Math.Max(Settings.atlasSize - 4, 16));
		object.texelSize = side / object.size;
		if (worldArea <= 0)
		{
			// Nothing to light: forget its triangles.
			mTris.RemoveRange(first, mTris.Count - first);
			mPositions.RemoveRange(first * 9, mPositions.Count - first * 9);
			delete object;
			return;
		}
		Objects.Add(object);
	}

	static Vector3 VertexColor(uint32 abgr) => Linear(.((abgr & 0xff) / 255.0f, ((abgr >> 8) & 0xff) / 255.0f, ((abgr >> 16) & 0xff) / 255.0f, 1));

	static Vector3 Clamp01(Vector3 v) => .(Math.Clamp(v.x, 0, 1), Math.Clamp(v.y, 0, 1), Math.Clamp(v.z, 0, 1));

	static Vector3 Normal(Matrix4 world, Vector3 normal, Vector3 fallback)
	{
		let n = world.TransformDirection(normal);
		let length = n.Length;
		return length > 1e-8f ? n / length : fallback;
	}

	static Dictionary<String, Vector3> sTextureAverages = new .() ~ { for (let key in _.Keys) delete key; delete _; };

	/// A picture's average colour, in linear light (white without one).
	static Vector3 TextureAverage(StringView path)
	{
		if (path.IsEmpty)
			return .(1, 1, 1);
		if (sTextureAverages.TryGetValueAlt(path, let found))
			return found;
		Vector3 average = .(1, 1, 1);
		let full = Assets.ResolvePath(path, .. scope .());
		int32 w = 0, h = 0;
		let pixels = Native.tn_image_load(full.CStr(), &w, &h);
		if (pixels != null && w > 0 && h > 0)
		{
			Vector3 sum = default;
			let step = Math.Max(1, (w * h) / 65536);
			int count = 0;
			for (int i = 0; i < w * h; i += step)
			{
				sum = sum + Linear(.(pixels[i * 4] / 255.0f, pixels[i * 4 + 1] / 255.0f, pixels[i * 4 + 2] / 255.0f, 1));
				count++;
			}
			average = sum / count;
		}
		if (pixels != null)
			Native.tn_image_free(pixels);
		sTextureAverages[new String(path)] = average;
		return average;
	}

	/// Gives each object a square of texels in a lightmap picture, biggest first, in rows; a new picture when one is
	/// full. Then turns triangles' lightmap coordinates into pixels.
	void PlaceObjects()
	{
		let order = scope List<int32>();
		for (int32 i < (int32)Objects.Count)
			order.Add(i);
		order.Sort(scope (a, b) => Objects[a].size != Objects[b].size ? Objects[b].size <=> Objects[a].size : a <=> b);
		const int32 Pad = 2;
		let size = Math.Max(Settings.atlasSize, 32);
		int32 atlas = -1, x = 0, y = 0, shelf = 0;
		let used = scope List<(int32 w, int32 h)>();
		for (let index in order)
		{
			let object = Objects[index];
			let need = object.size + Pad * 2;
			if (atlas >= 0 && x + need > size)
			{
				x = 0;
				y += shelf;
				shelf = 0;
			}
			if (atlas < 0 || y + need > size)
			{
				atlas++;
				used.Add((0, 0));
				x = 0;
				y = 0;
				shelf = 0;
			}
			object.atlas = atlas;
			object.x = x + Pad;
			object.y = y + Pad;
			x += need;
			shelf = Math.Max(shelf, need);
			used[atlas] = (Math.Max(used[atlas].w, x), Math.Max(used[atlas].h, y + need));
		}
		for (let extent in used)
		{
			let picture = new Atlas();
			picture.width = Math.Min((extent.w + 3) & ~3, size);
			picture.height = Math.Min((extent.h + 3) & ~3, size);
			picture.texelOf = new int32[picture.width * picture.height];
			for (var t in ref picture.texelOf)
				t = -1;
			picture.light = new Vector3[picture.width * picture.height];
			Atlases.Add(picture);
		}
		for (let object in Objects)
		{
			let picture = Atlases[object.atlas];
			object.scaleOffset = .((float)object.size / picture.width, (float)object.size / picture.height, (float)object.x / picture.width, (float)object.y / picture.height);
		}
		for (var tri in ref mTris)
		{
			let object = Objects[tri.object];
			Vector2 Pixel(Vector2 uv) => .(uv.x * object.size + object.x, uv.y * object.size + object.y);
			tri.a = Pixel(tri.a);
			tri.b = Pixel(tri.b);
			tri.c = Pixel(tri.c);
		}
	}

	// ---- the work ----

	/// Bakes. Any thread; nothing in the scene is touched.
	public void Run()
	{
		let start = DateTime.Now;
		mThreadCount = Settings.threads > 0 ? Settings.threads : (int32)Math.Max(1, Platform.BfpSystem_GetNumLogicalCPUs(null) - 1);
		CurrentStage = .Tracing;
		let indices = scope List<uint32>(mTris.Count * 3);
		for (uint32 i < (uint32)mTris.Count * 3)
			indices.Add(i);
		if (mTris.Count > 0)
			mBvh = tn_bake_create(mPositions.Ptr, (int32)mTris.Count * 3, indices.Ptr, (int32)mTris.Count);
		Rasterize();
		let texels = mTexels.Count;
		mDirectAll = new .[texels];
		mDirectBaked = new .[texels];
		mSkyGather = new .[texels];
		mGather = new .[texels];
		mRadiance = new .[texels];
		mInvalid = new .[texels];
		// Square, for the stratified pattern; fewer when the hits would not fit in memory.
		var side = (int32)Math.Max(1, Math.Round(Math.Sqrt((float)Math.Max(Settings.samples, 1))));
		while (side > 2 && (int64)texels * side * side > 48'000'000)
			side--;
		mSamples = side * side;
		mHits = new .[(int)((int64)texels * mSamples)];

		CurrentStage = .Direct;
		ParallelFor(texels, scope => DirectTexel);
		CurrentStage = .Gathering;
		ParallelFor(texels, scope => GatherTexel);
		Rays += (int64)texels * mSamples;
		CurrentStage = .Bouncing;
		for (int bounce < Math.Max(Settings.bounces, 0) + 1)
		{
			if (Cancel)
				break;
			// The light leaving each texel after the last pass, then what every texel gathers of it.
			ParallelFor(texels, scope => RadianceTexel);
			ParallelFor(texels, scope => BounceTexel);
		}
		// Smooth the noise out of the gathered light (never the baked lights' sharp shadows), then the light leaving
		// each texel once more for the probes.
		CurrentStage = .Finishing;
		for (int pass < 2)
		{
			mFilterStep = (int32)(1 << pass);
			ParallelFor(texels, scope => FilterTexel);
			Swap!(mGather, mRadiance);
		}
		ParallelFor(texels, scope => RadianceTexel);
		Finish();
		if (Settings.probes && !Cancel)
		{
			CurrentStage = .Probes;
			BakeProbes();
		}
		CurrentStage = .Done;
		Seconds = (DateTime.Now - start).TotalSeconds;
	}

	/// Runs body for 0 ..< count on the worker threads.
	void ParallelFor(int count, delegate void(int) body)
	{
		mNext = 0;
		mDone = 0;
		mWork = (int32)count;
		if (count == 0)
			return;
#if BF_PLATFORM_WASM
		// No threads in a web page (the baker runs in the editor, but builds everywhere).
		for (int index < count)
			body(index);
		mDone = (int32)count;
		return;
#else
		let threads = scope List<Thread>();
		for (int i < mThreadCount)
		{
			let thread = new Thread(new () =>
				{
					const int32 Chunk = 32;
					while (!Cancel)
					{
						let end = Interlocked.Add(ref mNext, Chunk);
						let first = end - Chunk;
						if (first >= count)
							break;
						for (int index = first; index < Math.Min(end, count); index++)
							body(index);
						Interlocked.Add(ref mDone, Math.Min(end, (int32)count) - first);
					}
				});
			thread.Start(false);
			threads.Add(thread);
		}
		for (let thread in threads)
		{
			thread.Join();
			delete thread;
		}
#endif
	}

	/// Finds the texels each triangle covers: first those whose centre is on it, then those it only touches (their
	/// point moved onto its edge), so that the picture's filtering never reads past a chart.
	void Rasterize()
	{
		for (int pass < 2)
		{
			for (int32 t < (int32)mTris.Count)
			{
				let tri = mTris[t];
				let picture = Atlases[Objects[tri.object].atlas];
				let minX = Math.Max((int32)Math.Floor(Math.Min(tri.a.x, Math.Min(tri.b.x, tri.c.x))) - 1, 0);
				let maxX = Math.Min((int32)Math.Ceiling(Math.Max(tri.a.x, Math.Max(tri.b.x, tri.c.x))) + 1, picture.width - 1);
				let minY = Math.Max((int32)Math.Floor(Math.Min(tri.a.y, Math.Min(tri.b.y, tri.c.y))) - 1, 0);
				let maxY = Math.Min((int32)Math.Ceiling(Math.Max(tri.a.y, Math.Max(tri.b.y, tri.c.y))) + 1, picture.height - 1);
				for (int32 y = minY; y <= maxY; y++)
				{
					for (int32 x = minX; x <= maxX; x++)
					{
						let index = y * picture.width + x;
						if (picture.texelOf[index] >= 0)
							continue;
						let weights = Closest(.(x + 0.5f, y + 0.5f), tri.a, tri.b, tri.c, let distance);
						if (pass == 0 ? distance > 1e-5f : distance > 0.75f)
							continue;
						Texel texel = default;
						texel.atlas = Objects[tri.object].atlas;
						texel.x = x;
						texel.y = y;
						texel.triangle = t;
						texel.position = Corner(t, 0) * weights.x + Corner(t, 1) * weights.y + Corner(t, 2) * weights.z;
						texel.geometric = tri.geometric;
						if (tri.flat)
							texel.normal = tri.geometric;
						else
						{
							let n = tri.na * weights.x + tri.nb * weights.y + tri.nc * weights.z;
							let length = n.Length;
							texel.normal = length > 1e-8f ? n / length : tri.geometric;
						}
						picture.texelOf[index] = (int32)mTexels.Count;
						mTexels.Add(texel);
					}
				}
			}
		}
	}

	Vector3 Corner(int32 t, int k) => .(mPositions[t * 9 + k * 3], mPositions[t * 9 + k * 3 + 1], mPositions[t * 9 + k * 3 + 2]);

	/// The weights of a triangle's corners at its point nearest p, and how far p is from it (0 inside).
	public static Vector3 Closest(Vector2 p, Vector2 a, Vector2 b, Vector2 c, out float distance)
	{
		float Cross(Vector2 u, Vector2 v) => u.x * v.y - u.y * v.x;
		let area = Cross(b - a, c - a);
		if (Math.Abs(area) > 1e-12f)
		{
			let wa = Cross(b - p, c - p) / area;
			let wb = Cross(c - p, a - p) / area;
			let wc = 1 - wa - wb;
			if (wa >= 0 && wb >= 0 && wc >= 0)
			{
				distance = 0;
				return .(wa, wb, wc);
			}
		}
		// Outside (or no area): the nearest point on the three edges.
		var best = float.MaxValue;
		Vector3 weights = .(1, 0, 0);
		void Edge(Vector2 from, Vector2 to, int i, int j)
		{
			let d = to - from;
			let lengthSq = d.x * d.x + d.y * d.y;
			let s = lengthSq > 0 ? Math.Clamp(((p.x - from.x) * d.x + (p.y - from.y) * d.y) / lengthSq, 0, 1) : 0;
			let q = from + d * s;
			let distSq = (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y);
			if (distSq < best)
			{
				best = distSq;
				float[3] w = default;
				w[i] = 1 - s;
				w[j] = s;
				weights = .(w[0], w[1], w[2]);
			}
		}
		Edge(a, b, 0, 1);
		Edge(b, c, 1, 2);
		Edge(c, a, 2, 0);
		distance = Math.Sqrt(best);
		return weights;
	}

	float Bias(Vector3 p) => 0.002f + Math.Max(Math.Abs(p.x), Math.Max(Math.Abs(p.y), Math.Abs(p.z))) * 1e-5f;

	bool Blocked(Vector3 from, Vector3 direction, float distance)
	{
		if (mBvh == null)
			return false;
		float[7] ray = .(from.x, from.y, from.z, direction.x, direction.y, direction.z, distance);
		uint8 blocked = 0;
		tn_bake_occluded(mBvh, &ray[0], 1, &blocked);
		return blocked != 0;
	}

	/// Direct light at a point: from every light (for bouncing), and from those baked into lightmaps.
	void Direct(Vector3 position, Vector3 normal, Vector3 geometric, out Vector3 all, out Vector3 baked)
	{
		all = default;
		baked = default;
		let bias = Bias(position);
		let origin = position + geometric * bias;
		for (let light in mLights)
		{
			Vector3 toLight;
			float distance;
			float atten = 1;
			if (light.type == 2)
			{
				toLight = -light.direction;
				distance = 10000;
			}
			else
			{
				let offset = light.position - position;
				distance = offset.Length;
				if (distance >= light.range || distance < 1e-5f)
					continue;
				toLight = offset / distance;
				if (light.inverseSquare)
				{
					let ratio = distance * distance / Math.Max(light.range * light.range, 1e-8f);
					let fade = Math.Max(1 - ratio * ratio, 0);
					atten = fade * fade / Math.Max(distance * distance, 1e-6f);
				}
				else
				{
					let falloff = Math.Clamp(1 - distance / Math.Max(light.range, 1e-4f), 0, 1);
					atten = falloff * falloff / (1 + distance * distance * 0.1f);
				}
				if (light.type == 1)
					atten *= SmoothStep(light.cosOuter, light.cosInner, Vector3.Dot(-toLight, light.direction));
			}
			let ndotl = Vector3.Dot(normal, toLight);
			if (atten <= 0 || ndotl <= 0 || Vector3.Dot(geometric, toLight) <= 0)
				continue;
			let visible = Blocked(origin, toLight, distance - bias * 2) ? 0.0f : 1.0f;
			let amount = light.color * (atten * ndotl);
			all = all + amount * visible;
			if (light.bakeDirect)
				baked = baked + amount * (light.castShadows ? 1 - light.shadowStrength * (1 - visible) : 1);
		}
	}

	static float SmoothStep(float edge0, float edge1, float x)
	{
		let t = Math.Clamp((x - edge0) / (edge1 - edge0), 0, 1);
		return t * t * (3 - 2 * t);
	}

	/// The sky's light from direction d: lights an open surface just as the scene's ambient colours do.
	Vector3 Sky(Vector3 d) => .(Math.Max(mGround.x + (mSky.x - mGround.x) * (0.5f + 0.75f * d.y), 0),
		Math.Max(mGround.y + (mSky.y - mGround.y) * (0.5f + 0.75f * d.y), 0),
		Math.Max(mGround.z + (mSky.z - mGround.z) * (0.5f + 0.75f * d.y), 0));

	void DirectTexel(int i)
	{
		let texel = mTexels[i];
		Direct(texel.position, texel.normal, texel.geometric, out mDirectAll[i], out mDirectBaked[i]);
	}

	static uint32 Hash(uint32 value)
	{
		var x = value;
		x ^= x >> 16;
		x *= 0x7feb352d;
		x ^= x >> 15;
		x *= 0x846ca68b;
		x ^= x >> 16;
		return x;
	}

	static float Random(ref uint32 state)
	{
		state = state * 747796405 + 2891336453;
		var word = ((state >> ((state >> 28) + 4)) ^ state) * 277803737;
		word = (word >> 22) ^ word;
		return (word >> 8) * (1.0f / 16777216.0f);
	}

	/// Two axes across a normal.
	static void Basis(Vector3 n, out Vector3 t, out Vector3 b)
	{
		let sign = n.z >= 0 ? 1.0f : -1.0f;
		let a = -1.0f / (sign + n.z);
		let c = n.x * n.y * a;
		t = .(1 + sign * n.x * n.x * a, sign * c, -sign * n.x);
		b = .(c, sign + n.y * n.y * a, -n.y);
	}

	/// The texel a triangle's point lies in (by the corners' weights), or one next to it; -1 if none.
	int32 TexelAt(int32 triangle, float u, float v)
	{
		let tri = mTris[triangle];
		let p = tri.a * (1 - u - v) + tri.b * u + tri.c * v;
		let picture = Atlases[Objects[tri.object].atlas];
		let x = (int32)p.x, y = (int32)p.y;
		for (int32 ring < 2)
		{
			for (int32 dy = -ring; dy <= ring; dy++)
			{
				for (int32 dx = -ring; dx <= ring; dx++)
				{
					let px = x + dx, py = y + dy;
					if (px < 0 || py < 0 || px >= picture.width || py >= picture.height)
						continue;
					let found = picture.texelOf[py * picture.width + px];
					if (found >= 0 && mTexels[found].atlas == Objects[tri.object].atlas)
						return found;
				}
			}
		}
		return -1;
	}

	/// Traces the texel's rays once: the sky they see, and the texel each hit (-1 nothing, -2 a back face).
	void GatherTexel(int i)
	{
		let texel = mTexels[i];
		let count = mSamples;
		let side = (int32)Math.Sqrt((float)count);
		let rays = scope float[count * 7];
		let hitTriangles = scope int32[count];
		let hits = scope float[count * 4];
		Basis(texel.normal, let tangent, let bitangent);
		let origin = texel.position + texel.geometric * Bias(texel.position);
		var state = Hash((uint32)i * 9781 + 1);
		for (int s < count)
		{
			// Stratified over the hemisphere, cosine-weighted.
			let u1 = ((s % side) + Random(ref state)) / side;
			let u2 = ((s / side) + Random(ref state)) / side;
			let r = Math.Sqrt(u1);
			let phi = 2 * Math.PI_f * u2;
			var d = tangent * (r * Math.Cos(phi)) + bitangent * (r * Math.Sin(phi)) + texel.normal * Math.Sqrt(Math.Max(1 - u1, 0));
			// Never into the surface itself.
			if (Vector3.Dot(d, texel.geometric) < 0.01f)
				d = d - texel.geometric * (Vector3.Dot(d, texel.geometric) - 0.01f);
			d = d.Normalized;
			rays[s * 7] = origin.x;
			rays[s * 7 + 1] = origin.y;
			rays[s * 7 + 2] = origin.z;
			rays[s * 7 + 3] = d.x;
			rays[s * 7 + 4] = d.y;
			rays[s * 7 + 5] = d.z;
			rays[s * 7 + 6] = 1e30f;
		}
		if (mBvh != null)
			tn_bake_intersect(mBvh, rays.Ptr, count, hitTriangles.Ptr, hits.Ptr);
		else
		{
			for (var h in ref hitTriangles)
				h = -1;
		}
		Vector3 sky = default;
		var backs = 0;
		let start = (int64)i * count;
		for (int s < count)
		{
			let triangle = hitTriangles[s];
			if (triangle < 0)
			{
				sky = sky + Sky(.(rays[s * 7 + 3], rays[s * 7 + 4], rays[s * 7 + 5]));
				mHits[(int)(start + s)] = -1;
			}
			else if (hits[s * 4 + 3] > 0.5f)
			{
				backs++;
				mHits[(int)(start + s)] = -2;
			}
			else
				mHits[(int)(start + s)] = TexelAt(triangle, hits[s * 4 + 1], hits[s * 4 + 2]);
		}
		mSkyGather[i] = sky;
		// Mostly seeing back faces: inside something (under a wall standing on it). Filled from its neighbours.
		mInvalid[i] = backs > count / 5;
	}

	/// The light leaving a texel: its colour times all the light on it, and its own glow.
	void RadianceTexel(int i)
	{
		let tri = mTris[mTexels[i].triangle];
		mRadiance[i] = tri.albedo * (mDirectAll[i] + mGather[i]) + tri.emission;
	}

	void BounceTexel(int i)
	{
		var sum = mSkyGather[i];
		let start = (int64)i * mSamples;
		for (int s < mSamples)
		{
			let hit = mHits[(int)(start + s)];
			if (hit >= 0)
				sum = sum + mRadiance[hit];
		}
		mGather[i] = sum / mSamples;
	}

	int32 mFilterStep;

	/// One pass of an edge-aware blur of the gathered light (into mRadiance): the texels round this one, mStep apart,
	/// on the same object, facing the same way and near it in the world; texels inside things are left out.
	void FilterTexel(int i)
	{
		let texel = mTexels[i];
		if (mInvalid[i])
		{
			mRadiance[i] = mGather[i];
			return;
		}
		let picture = Atlases[texel.atlas];
		let object = mTris[texel.triangle].object;
		let reach = Objects[object].texelSize * mFilterStep * 3;
		var sum = mGather[i] * 2;
		var weight = 2.0f;
		for (int32 dy = -2; dy <= 2; dy++)
		{
			for (int32 dx = -2; dx <= 2; dx++)
			{
				if (dx == 0 && dy == 0)
					continue;
				let x = texel.x + dx * mFilterStep, y = texel.y + dy * mFilterStep;
				if (x < 0 || y < 0 || x >= picture.width || y >= picture.height)
					continue;
				let other = picture.texelOf[y * picture.width + x];
				if (other < 0 || mInvalid[other])
					continue;
				let near = mTexels[other];
				if (mTris[near.triangle].object != object || Vector3.Dot(near.normal, texel.normal) < 0.9f)
					continue;
				let apart = (near.position - texel.position).Length;
				if (apart > reach)
					continue;
				// Nearer counts more.
				let w = 1 - apart / reach * 0.5f - (Math.Abs(dx) + Math.Abs(dy)) * 0.1f;
				sum = sum + mGather[other] * w;
				weight += w;
			}
		}
		mRadiance[i] = sum / weight;
	}

	/// The lightmaps' light (baked lights and everything gathered), texels inside things filled from their
	/// neighbours, a few texels of edge round every chart, and the RGBM pictures.
	void Finish()
	{
		for (int i < mTexels.Count)
		{
			let texel = mTexels[i];
			let picture = Atlases[texel.atlas];
			picture.light[texel.y * picture.width + texel.x] = mDirectBaked[i] + mGather[i];
		}
		for (let picture in Atlases)
		{
			let filled = scope bool[picture.width * picture.height];
			for (int p < filled.Count)
			{
				let texel = picture.texelOf[p];
				filled[p] = texel >= 0 && !mInvalid[texel];
			}
			let next = scope bool[filled.Count];
			for (int pass < 4)
			{
				filled.CopyTo(next);
				for (int32 y < picture.height)
				{
					for (int32 x < picture.width)
					{
						let p = y * picture.width + x;
						if (filled[p])
							continue;
						// Only into gaps and texels inside things: never over another chart's light.
						let own = picture.texelOf[p];
						if (own >= 0 && !mInvalid[own])
							continue;
						Vector3 sum = default;
						int count = 0;
						for (int32 dy = -1; dy <= 1; dy++)
						{
							for (int32 dx = -1; dx <= 1; dx++)
							{
								let nx = x + dx, ny = y + dy;
								if ((dx == 0 && dy == 0) || nx < 0 || ny < 0 || nx >= picture.width || ny >= picture.height)
									continue;
								let q = ny * picture.width + nx;
								if (!filled[q])
									continue;
								// A texel inside something takes only from its own object.
								if (own >= 0 && picture.texelOf[q] >= 0 && mTris[mTexels[picture.texelOf[q]].triangle].object != mTris[mTexels[own].triangle].object)
									continue;
								sum = sum + picture.light[q];
								count++;
							}
						}
						if (count > 0)
						{
							picture.light[p] = sum / count;
							next[p] = true;
						}
					}
				}
				next.CopyTo(filled);
			}
			picture.pixels = new uint8[picture.width * picture.height * 4];
			for (int p < picture.width * picture.height)
				Encode(picture.light[p], &picture.pixels[p * 4]);
		}
	}

	/// RGBM: the colour divided by its brightest channel's share of Range, kept in alpha.
	public static void Encode(Vector3 light, uint8* rgba)
	{
		let brightest = Math.Max(Math.Max(light.x, light.y), Math.Max(light.z, 1e-6f));
		var m = Math.Clamp(brightest / Range, 1.0f / 255.0f, 1.0f);
		m = Math.Ceiling(m * 255) / 255;
		let scale = 1 / (m * Range);
		rgba[0] = (uint8)Math.Clamp(Math.Round(light.x * scale * 255), 0, 255);
		rgba[1] = (uint8)Math.Clamp(Math.Round(light.y * scale * 255), 0, 255);
		rgba[2] = (uint8)Math.Clamp(Math.Round(light.z * scale * 255), 0, 255);
		rgba[3] = (uint8)(m * 255);
	}

	public static Vector3 Decode(uint8* rgba) => Vector3(rgba[0], rgba[1], rgba[2]) * (Range * rgba[3] / (255.0f * 255.0f));

	// ---- light probes ----

	void BakeProbes()
	{
		Probes = new LightProbeSet();
		// The scene's grid, over everything baked.
		let whole = new LightProbeGrid();
		Probes.grids.Add(whole);
		var bounds = mBounds;
		if (mTris.Count == 0)
			bounds = .(.(0, 0, 0), .(1, 1, 1));
		var spacing = Math.Max(Settings.probeSpacing, 0.25f);
		let lo = bounds.min - .(spacing * 0.5f, spacing * 0.5f, spacing * 0.5f);
		let hi = bounds.max + .(spacing * 0.5f, spacing * 0.5f, spacing * 0.5f);
		let size = hi - lo;
		int32 Count(float extent) => (int32)Math.Clamp(Math.Round(extent / spacing) + 1, 2, 48);
		while (Count(size.x) * Count(size.y) * Count(size.z) > 16384)
			spacing *= 1.25f;
		whole.min = lo;
		whole.max = hi;
		whole.countX = Count(size.x);
		whole.countY = Count(size.y);
		whole.countZ = Count(size.z);
		// Then a finer one for each volume.
		for (let volume in mVolumes)
		{
			let grid = new LightProbeGrid();
			grid.min = volume.area.min;
			grid.max = volume.area.max;
			grid.countX = volume.x;
			grid.countY = volume.y;
			grid.countZ = volume.z;
			grid.fade = volume.fade;
			Probes.grids.Add(grid);
		}
		for (let grid in Probes.grids)
		{
			if (Cancel)
				return;
			BakeGrid(grid);
		}
	}

	void BakeGrid(LightProbeGrid grid)
	{
		let total = grid.Count;
		for (int i < total * LightProbeGrid.Coefficients)
			grid.values.Add(0);
		let valid = scope bool[total];
		mProbeValid = valid;
		mProbeGrid = grid;
		ParallelFor(total, scope => ProbeAt);
		Rays += (int64)total * Math.Max(Settings.probeSamples, 16);
		// Probes inside walls: their neighbours' light.
		for (int pass < 8)
		{
			var changed = false;
			let next = scope bool[total];
			valid.CopyTo(next);
			for (int32 z < grid.countZ)
			{
				for (int32 y < grid.countY)
				{
					for (int32 x < grid.countX)
					{
						let p = grid.Index(x, y, z);
						if (valid[p])
							continue;
						float[LightProbeGrid.Coefficients] sum = default;
						int count = 0;
						for (int k < 6)
						{
							let nx = x + (k == 0 ? -1 : (k == 1 ? 1 : 0)), ny = y + (k == 2 ? -1 : (k == 3 ? 1 : 0)), nz = z + (k == 4 ? -1 : (k == 5 ? 1 : 0));
							if (nx < 0 || ny < 0 || nz < 0 || nx >= grid.countX || ny >= grid.countY || nz >= grid.countZ)
								continue;
							let q = grid.Index(nx, ny, nz);
							if (!valid[q])
								continue;
							for (int c < LightProbeGrid.Coefficients)
								sum[c] += grid.values[q * LightProbeGrid.Coefficients + c];
							count++;
						}
						if (count == 0)
							continue;
						for (int c < LightProbeGrid.Coefficients)
							grid.values[p * LightProbeGrid.Coefficients + c] = sum[c] / count;
						next[p] = true;
						changed = true;
					}
				}
			}
			next.CopyTo(valid);
			if (!changed)
				break;
		}
		mProbeValid = null;
		mProbeGrid = null;
	}

	LightProbeGrid mProbeGrid;
	bool[] mProbeValid;

	/// One probe: rays all round (a Fibonacci sphere), what they see, as the constant and direction terms.
	void ProbeAt(int p)
	{
		let x = p % mProbeGrid.countX, y = (p / mProbeGrid.countX) % mProbeGrid.countY, z = p / (mProbeGrid.countX * mProbeGrid.countY);
		let position = mProbeGrid.Position(x, y, z);
		let count = (int32)Math.Max(Settings.probeSamples, 16);
		let rays = scope float[count * 7];
		let hitTriangles = scope int32[count];
		let hits = scope float[count * 4];
		let golden = Math.PI_f * (3 - Math.Sqrt(5.0f));
		for (int s < count)
		{
			let dy = 1 - (s + 0.5f) / count * 2;
			let radius = Math.Sqrt(Math.Max(1 - dy * dy, 0));
			let angle = golden * s;
			rays[s * 7] = position.x;
			rays[s * 7 + 1] = position.y;
			rays[s * 7 + 2] = position.z;
			rays[s * 7 + 3] = Math.Cos(angle) * radius;
			rays[s * 7 + 4] = dy;
			rays[s * 7 + 5] = Math.Sin(angle) * radius;
			rays[s * 7 + 6] = 1e30f;
		}
		if (mBvh != null)
			tn_bake_intersect(mBvh, rays.Ptr, count, hitTriangles.Ptr, hits.Ptr);
		else
		{
			for (var h in ref hitTriangles)
				h = -1;
		}
		Vector3 c0 = default, cx = default, cy = default, cz = default;
		var backs = 0;
		for (int s < count)
		{
			let d = Vector3(rays[s * 7 + 3], rays[s * 7 + 4], rays[s * 7 + 5]);
			Vector3 light;
			let triangle = hitTriangles[s];
			if (triangle < 0)
				light = Sky(d);
			else if (hits[s * 4 + 3] > 0.5f)
			{
				backs++;
				continue;
			}
			else
			{
				let texel = TexelAt(triangle, hits[s * 4 + 1], hits[s * 4 + 2]);
				light = texel >= 0 ? mRadiance[texel] : mTris[triangle].emission;
			}
			c0 = c0 + light;
			cx = cx + light * d.x;
			cy = cy + light * d.y;
			cz = cz + light * d.z;
		}
		// Projected on the first two bands (4 pi / n times the basis 0.282095 and 0.488603 (x, y, z)), then scaled
		// for diffuse light (pi and 2 pi / 3) and divided by pi: a = c0 / n, b = 2 * (sum of light * d) / n.
		let scale0 = 1.0f / count;
		let scale1 = 2.0f / count;
		let start = p * LightProbeGrid.Coefficients;
		for (int channel < 3)
		{
			mProbeGrid.values[start + channel * 4] = c0[channel] * scale0;
			mProbeGrid.values[start + channel * 4 + 1] = cx[channel] * scale1;
			mProbeGrid.values[start + channel * 4 + 2] = cy[channel] * scale1;
			mProbeGrid.values[start + channel * 4 + 3] = cz[channel] * scale1;
		}
		mProbeValid[p] = backs < count / 4;
	}

	// ---- results ----

	/// The baked light (lightmap value, before RGBM) on an object at its lightmap coordinates.
	public Vector3 LightAt(MeshRenderer renderer, Vector2 uv2)
	{
		for (let object in Objects)
		{
			if (object.renderer != renderer)
				continue;
			let picture = Atlases[object.atlas];
			let x = Math.Clamp((int32)(uv2.x * object.size + object.x), 0, picture.width - 1);
			let y = Math.Clamp((int32)(uv2.y * object.size + object.y), 0, picture.height - 1);
			return picture.light[y * picture.width + x];
		}
		return default;
	}

	/// Where a scene's baked lighting is kept: beside the scene, in a folder named after it, relative to the project
	/// (the editor holds a scene's full path), so that the scene file names it the same on every machine.
	public static void FolderFor(Scene scene, String output)
	{
		let relative = Assets.MakeRelative(scene.Path, .. scope .());
		var path = StringView(relative);
		if (path.EndsWith(".tscene"))
			path.RemoveFromEnd(7);
		if (path.IsEmpty)
			path = "Untitled";
		output.AppendF("{}_Baked", path);
	}

	/// Writes the lightmaps and probes into `folder` (relative to the project) and points the scene's renderers and
	/// environment at them. The main thread.
	public bool Apply(Scene scene, StringView folder, String report)
	{
		if (Cancel || CurrentStage != .Done)
			return false;
		let full = Assets.ResolvePath(folder, .. scope .());
		System.IO.Directory.CreateDirectory(full).IgnoreError();
		// Older pictures from a bake that made more.
		for (int i = Atlases.Count; i < 64; i++)
		{
			let old = scope $"{full}/Lightmap-{i}.png";
			if (!System.IO.File.Exists(old))
				break;
			System.IO.File.Delete(old).IgnoreError();
		}
		var good = true;
		for (int i < Atlases.Count)
		{
			let picture = Atlases[i];
			let path = scope $"{folder}/Lightmap-{i}.png";
			if (!Native.tn_image_write_png(scope $"{full}/Lightmap-{i}.png" .CStr(), picture.pixels.Ptr, picture.width, picture.height))
			{
				report.AppendF("Could not write {}\n", path);
				good = false;
			}
			if (Gfx.Initialized)
				Assets.ReplaceTexture(path, picture.pixels.Ptr, picture.width, picture.height);
		}
		// Renderers baked before and not now lose their lightmaps.
		for (let renderer in scene.Components<MeshRenderer>(.. scope .()))
		{
			if (renderer.lightmap.StartsWith(folder))
				ClearLightmap(renderer);
		}
		for (let object in Objects)
		{
			if (!object.renderer)
				continue;
			let renderer = object.renderer;
			renderer.lightmap.Set(scope $"{folder}/Lightmap-{object.atlas}.png");
			renderer.lightmapDirection.Clear();
			renderer.lightmapShadowmask.Clear();
			renderer.lightmapScaleOffset = object.scaleOffset;
			renderer.lightmapDecode = .(Range, 1, 0, 0);
		}
		let probesPath = scope $"{folder}/Probes.tprobes";
		if (Probes != null)
		{
			let text = scope String();
			Probes.Write(text);
			if (System.IO.File.WriteAllText(scope $"{full}/Probes.tprobes" , text) case .Err)
			{
				report.AppendF("Could not write {}\n", probesPath);
				good = false;
			}
			scene.Environment.lightProbes.Set(probesPath);
		}
		else if (scene.Environment.lightProbes.StartsWith(folder))
			scene.Environment.lightProbes.Clear();
		LightProbes.Forget(probesPath);
		report.AppendF("Baked {0} objects into {1} lightmap{2} ({3} texels), {4} light probes{7}, {5:0.0} million rays in {6:0.0} s.", Objects.Count, Atlases.Count, Atlases.Count == 1 ? "" : "s", mTexels.Count, Probes?.Count ?? 0, Rays / 1e6, Seconds, mVolumes.Count > 0 ? scope $" ({mVolumes.Count} volume{mVolumes.Count == 1 ? "" : "s"})" : "");
		return good;
	}

	static void ClearLightmap(MeshRenderer renderer)
	{
		renderer.lightmap.Clear();
		renderer.lightmapDirection.Clear();
		renderer.lightmapShadowmask.Clear();
		renderer.lightmapScaleOffset = .(1, 1, 0, 0);
		renderer.lightmapDecode = .(1, 0, 0, 0);
	}

	/// Takes the scene's baked lighting away (the files stay).
	public static void Clear(Scene scene)
	{
		for (let renderer in scene.Components<MeshRenderer>(.. scope .()))
		{
			if (!renderer.lightmap.IsEmpty && renderer.lightmap.Contains("_Baked/"))
				ClearLightmap(renderer);
		}
		scene.Environment.lightProbes.Clear();
	}
}
