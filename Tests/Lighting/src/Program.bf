using System;
using System.Collections;
using Tallow;

namespace LightingTests;

/// Lights by cluster and point and spot shadows (docs/lighting.md): which lights a view keeps and in what order,
/// directional lights first, the cap on lights, every pixel's cluster listing every light that reaches it, depth
/// slices, shadow tiles for the nearest shadowed lights (a spot light one, a point light six), the atlas grid, the
/// tiles' matrices and the data the shaders read. Drawing itself needs the graphics card: `python3 run.py` here
/// checks pictures of the Sandbox's Lighting scene.
class Program
{
	static int sFailures;
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		if (!pass)
			sFailures++;
		return pass;
	}

	static uint32 sSeed = 12345;
	static float Random()
	{
		sSeed = sSeed * 1664525 + 1013904223;
		return (sSeed >> 8) / (float)(1 << 24);
	}

	static CameraData Camera(Vector3 position)
	{
		CameraData camera = default;
		camera.position = position;
		camera.forward = .Forward;
		camera.fieldOfView = 60;
		camera.near = 0.1f;
		camera.far = 200;
		camera.aspect = 16 / 9.0f;
		camera.view = Matrix4.LookAt(position, position + .Forward, .Up);
		camera.projection = Matrix4.Perspective(camera.fieldOfView, camera.aspect, camera.near, camera.far, Gfx.HomogeneousDepth);
		return camera;
	}

	static Light AddLight(Scene scene, LightType type, Vector3 position, float range, bool shadows = false)
	{
		let go = scene.CreateGameObject("Light");
		go.Transform.Position = position;
		let light = go.AddComponent<Light>();
		light.type = type;
		light.range = range;
		light.castShadows = shadows;
		return light;
	}

	/// The lights a cluster lists.
	static void ListOf(LightClusters clusters, int32 cluster, List<int32> into)
	{
		into.Clear();
		let start = clusters.ClusterStart[cluster];
		for (int k < clusters.ClusterLength[cluster])
			into.Add((int32)clusters.Data[LightClusters.IndexRow * LightClusters.Width * 4 + start + k]);
	}

	static Vector4 Texel(LightClusters clusters, int texel)
	{
		let i = texel * 4;
		return .(clusters.Data[i], clusters.Data[i + 1], clusters.Data[i + 2], clusters.Data[i + 3]);
	}

	static void Choosing()
	{
		let scene = scope Scene();
		let camera = Camera(.Zero);
		let sun = AddLight(scene, .Directional, .Zero, 0, true);
		AddLight(scene, .Directional, .Zero, 0);
		AddLight(scene, .Directional, .Zero, 0);
		let far = AddLight(scene, .Point, .(0, 0, 50), 3);
		let near = AddLight(scene, .Point, .(0, 0, 5), 2);
		let behind = AddLight(scene, .Point, .(0, 0, -10), 2);
		let aside = AddLight(scene, .Point, .(60, 0, 5), 2);
		let reaching = AddLight(scene, .Point, .(0, 0, -3), 4);
		let dark = AddLight(scene, .Point, .(0, 0, 8), 2);
		dark.intensity = 0;
		let clusters = scope LightClusters();
		clusters.Build(scene, camera, sun, 0, 4096);
		Check(clusters.DirectionalCount == 2 && clusters.Lights[0].type == .Directional && clusters.Lights[1].type == .Directional && !clusters.Lights.Contains(sun), "the other directional lights come first, the sun is left out");
		Check(!clusters.Lights.Contains(behind) && !clusters.Lights.Contains(aside), "lights out of view are left out");
		Check(clusters.Lights.Contains(reaching), "a light behind the camera whose reach is in view is kept");
		Check(!clusters.Lights.Contains(dark), "a light with no intensity is left out");
		Check(clusters.Lights.Count == 5 && clusters.Lights[2] == reaching && clusters.Lights[3] == near && clusters.Lights[4] == far, "nearest first");
		Check(clusters.Tiles.Count == 0, "no shadow tiles when none may cast shadows");

		// The cap: the nearest are kept.
		let crowd = scope Scene();
		for (int i < 300)
			AddLight(crowd, .Point, .(0, 0, 2 + i * 0.5f), 1);
		clusters.Build(crowd, camera, null, 0, 4096);
		Check(clusters.Lights.Count == LightClusters.MaxLights && clusters.Dropped == 300 - LightClusters.MaxLights, scope $"{LightClusters.MaxLights} lights kept, the rest counted as dropped ({clusters.Lights.Count}, {clusters.Dropped})");
		Check(clusters.Lights[0].Transform.Position.z < clusters.Lights[LightClusters.MaxLights - 1].Transform.Position.z, "the farthest are the ones dropped");
	}

	static void Clusters()
	{
		let scene = scope Scene();
		let camera = Camera(.(0, 2, 0));
		// Lights all over the view, some reaching behind the camera and past its sides.
		for (int i < 200)
		{
			let position = Vector3((Random() - 0.5f) * 60, Random() * 6 - 1, Random() * 60 - 5);
			AddLight(scene, (i % 3 == 0) ? LightType.Spot : LightType.Point, position, 0.5f + Random() * 6);
		}
		let clusters = scope LightClusters();
		clusters.Build(scene, camera, null, 0, 4096);
		Check(clusters.Lights.Count > 100, scope $"most lights are in view ({clusters.Lights.Count})");

		// Every point in view: its cluster lists every light that reaches it.
		let list = scope List<int32>();
		let frustum = Frustum(clusters.ViewProj, Gfx.HomogeneousDepth);
		int tried = 0, missing = 0, full = 0;
		for (int i < 4000)
		{
			let point = Vector3((Random() - 0.5f) * 70, Random() * 8 - 2, Random() * 70);
			if (!frustum.IntersectsSphere(point, 0))
				continue;
			tried++;
			let cluster = clusters.ClusterOf(point);
			ListOf(clusters, cluster, list);
			if (list.Count >= LightClusters.MaxPerCluster)
			{
				full++;
				continue;
			}
			for (int32 l < (int32)clusters.Lights.Count)
			{
				let light = clusters.Lights[l];
				if ((light.Transform.Position - point).Length < light.range && !list.Contains(l))
					missing++;
			}
		}
		Check(tried > 1000 && missing == 0, scope $"every light reaching a point is in its cluster's list ({tried} points, {missing} missing, {full} in full clusters)");
		// Lists are not the whole view: a cluster lists far fewer lights than there are.
		int longest = 0, total = 0;
		for (int c < LightClusters.ClusterCount)
		{
			longest = Math.Max(longest, clusters.ClusterLength[c]);
			total += clusters.ClusterLength[c];
		}
		Check(total == clusters.IndexCount && longest <= LightClusters.MaxPerCluster && total / (float)LightClusters.ClusterCount < clusters.Lights.Count * 0.25f, scope $"clusters list only nearby lights (average {total / (float)LightClusters.ClusterCount:0.0} of {clusters.Lights.Count}, longest {longest})");
		Check(clusters.RowsUsed >= LightClusters.IndexRow + 1 && clusters.RowsUsed <= LightClusters.Height, "only the rows in use are sent");

		// Depth slices: from the near distance to the far one, in order.
		var ordered = true;
		var last = 0;
		for (float d = 0.05f; d < 250; d *= 1.1f)
		{
			let slice = clusters.SliceOf(d);
			if (slice < last)
				ordered = false;
			last = slice;
		}
		Check(clusters.SliceOf(0.01f) == 0 && clusters.SliceOf(clusters.Far * 0.999f) == LightClusters.GridZ - 1 && ordered, "depth slices run from near to far");

		// The data the shaders read: a light's place, colour and kind.
		let light = clusters.Lights[5];
		let first = Texel(clusters, 5 * LightClusters.TexelsPerLight);
		let kind = Texel(clusters, 5 * LightClusters.TexelsPerLight + 1);
		let position = light.Transform.Position;
		Check(first.x == position.x && first.y == position.y && first.z == position.z && first.w == light.range && kind.w == (light.type == .Spot ? 1 : 0), "each light's place, reach and kind are written for the shaders");
		let header = Texel(clusters, LightClusters.ClusterRow * LightClusters.Width + 100);
		Check(header.x == clusters.ClusterStart[100] && header.y == clusters.ClusterLength[100], "each cluster's list is written where the shaders look");
	}

	/// The atlas texture coordinates a point lands on through a tile's matrix.
	static Vector3 Lookup(ShadowTile tile, Vector3 point)
	{
		let clip = tile.sampleMtx.Transform(Vector4(point, 1));
		return .(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w);
	}

	static bool InTile(LightClusters clusters, int t, Vector3 point)
	{
		let tile = clusters.Tiles[t];
		let uv = Lookup(tile, point);
		let bounds = Texel(clusters, LightClusters.TileRow * LightClusters.Width + t * 8 + 4);
		return uv.x >= bounds.x && uv.x <= bounds.z && uv.y >= bounds.y && uv.y <= bounds.w && uv.z > 0 && uv.z < 1;
	}

	static void Shadows(StringView conventions)
	{
		Console.WriteLine(scope $"-- shadows, {conventions} --");
		let scene = scope Scene();
		let camera = Camera(.(0, 2, 0));
		let spot = AddLight(scene, .Spot, .(0, 4, 6), 10, true);
		spot.Transform.Rotation = Quaternion.LookRotation(Vector3(0, -1, 0.2f).Normalized, .Forward);
		let lamp = AddLight(scene, .Point, .(3, 1, 9), 8, true);
		let other = AddLight(scene, .Point, .(-3, 1, 12), 8, true);
		let plain = AddLight(scene, .Point, .(0, 1, 7), 5, false);
		let clusters = scope LightClusters();
		clusters.Build(scene, camera, null, 8, 4096);
		Check(clusters.Tiles.Count == 13 && clusters.TileGrid == 4, scope $"a spot light takes one tile and a point light six, on a 4 x 4 grid ({clusters.Tiles.Count} tiles, grid {clusters.TileGrid})");
		var plainHasTile = false;
		for (let tile in clusters.Tiles)
			plainHasTile |= tile.light == plain;
		Check(!plainHasTile, "a light that casts no shadows gets no tile");
		clusters.Build(scene, camera, null, 1, 4096);
		Check(clusters.Tiles.Count == 1 && clusters.Tiles[0].light == spot && clusters.TileGrid == 2, "with one shadowed light allowed, the nearest gets it");
		clusters.Build(scene, camera, null, 2, 4096);
		Check(clusters.Tiles.Count == 7 && clusters.Tiles[0].size == 1024, "two lights: seven tiles of 1024 pixels on a 4 x 4 grid");

		// Lookups: the spot light's axis lands in its tile; a point light's sides land in the matching faces.
		clusters.Build(scene, camera, null, 8, 4096);
		Check(InTile(clusters, 0, spot.Transform.Position + spot.Transform.Forward * 3), "a point in a spot light's cone is inside its tile");
		int firstFace = -1;
		for (int t < clusters.Tiles.Count)
		{
			if (clusters.Tiles[t].light == lamp)
			{
				firstFace = t;
				break;
			}
		}
		let center = lamp.Transform.Position;
		Check(firstFace >= 0 && InTile(clusters, firstFace, center + .(2, 0.3f, -0.2f)) && InTile(clusters, firstFace + 1, center + .(-2, 0.5f, 0.1f)) && InTile(clusters, firstFace + 2, center + .(0.2f, 2, 0.3f)) && InTile(clusters, firstFace + 3, center + .(0.3f, -1, 0)) && InTile(clusters, firstFace + 4, center + .(0, 0.4f, 2)) && InTile(clusters, firstFace + 5, center + .(0.1f, 0.2f, -3)), "each side of a point light lands in its own face's tile (+X, -X, +Y, -Y, +Z, -Z)");
		// Near a face's corner (the most a face covers) the point is still inside, with room to filter.
		Check(InTile(clusters, firstFace, center + .(2, 1.99f, 1.99f)), "a face covers its corner of the cube");
		// The light's data names its tiles.
		let index = clusters.Lights.IndexOf(lamp);
		let shadow = Texel(clusters, index * LightClusters.TexelsPerLight + 4);
		Check(shadow.x == 1 && (int)shadow.y == firstFace && shadow.z == 6, "a shadowed light's data names its first tile and six of them");
		let spotShadow = Texel(clusters, clusters.Lights.IndexOf(spot) * LightClusters.TexelsPerLight + 4);
		let plainShadow = Texel(clusters, clusters.Lights.IndexOf(plain) * LightClusters.TexelsPerLight + 4);
		Check(spotShadow.z == 1 && plainShadow.x == 0, "a spot light has one tile, an unshadowed light none");

		// Drawing: the tile's matrix puts the light's view into its own part of the atlas.
		let tile = clusters.Tiles[firstFace];
		let clip = tile.drawViewProj.Transform(Vector4(center + .(2, 0.3f, -0.2f), 1));
		let n = (float)clusters.TileGrid;
		let column = tile.x / tile.size, row = tile.y / tile.size;
		let ndcX = clip.x / clip.w, ndcY = clip.y / clip.w;
		Check(ndcX > -1 + 2 * column / n && ndcX < -1 + 2 * (column + 1) / n && ndcY < 1 - 2 * row / n && ndcY > 1 - 2 * (row + 1) / n, "drawing lands in the tile's part of the atlas");
		// Where a point is drawn is where it is looked up: the atlas's pixels count from the top left, its texture
		// rows from the bottom where the graphics API says so, and depth is stored 0 to 1.
		var agree = true;
		for (int t < clusters.Tiles.Count)
		{
			let each = clusters.Tiles[t];
			for (int i < 20)
			{
				let point = each.light.Transform.Position + Vector3(Random() * 6 - 3, Random() * 6 - 3, Random() * 6 - 3);
				if (!InTile(clusters, t, point))
					continue;
				let drawn = each.drawViewProj.Transform(Vector4(point, 1));
				let fromTop = 1 - (drawn.y / drawn.w * 0.5f + 0.5f);
				let u = drawn.x / drawn.w * 0.5f + 0.5f;
				let v = Gfx.OriginBottomLeft ? 1 - fromTop : fromTop;
				let depth = Gfx.HomogeneousDepth ? drawn.z / drawn.w * 0.5f + 0.5f : drawn.z / drawn.w;
				let looked = Lookup(each, point);
				if (Math.Abs(looked.x - u) > 1.0e-4f || Math.Abs(looked.y - v) > 1.0e-4f || Math.Abs(looked.z - depth) > 1.0e-5f)
					agree = false;
			}
		}
		Check(agree, "a point is looked up where it was drawn, at the depth it was drawn");

		// Strength and a light that does not cast shadows.
		other.shadowStrength = 0;
		clusters.Build(scene, camera, null, 8, 4096);
		Check(clusters.Tiles.Count == 7, "a light with no shadow strength gets no tiles");
	}

	public static int Main(String[] args)
	{
		Choosing();
		Clusters();
		Shadows("Vulkan, Direct3D and Metal conventions");
		Gfx.HomogeneousDepth = true;
		Gfx.OriginBottomLeft = true;
		Shadows("OpenGL conventions");
		Gfx.HomogeneousDepth = false;
		Gfx.OriginBottomLeft = false;
		Console.WriteLine(sFailures == 0 ? "All lighting checks passed." : scope $"{sFailures} lighting check(s) failed.");
		return sFailures == 0 ? 0 : 1;
	}
}
