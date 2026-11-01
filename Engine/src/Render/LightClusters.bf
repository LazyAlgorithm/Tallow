using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// One shadow tile of the local shadow atlas: a spot light's view, or one face of a point light's cube.
struct ShadowTile
{
	public Light light;
	/// From the world to the tile's part of the atlas, for drawing into it (clip space of the whole atlas).
	public Matrix4 drawViewProj;
	/// From the world to the atlas's texture coordinates and depth, for looking the shadow up.
	public Matrix4 sampleMtx;
	/// The light's own view of the tile, for picking what casts into it.
	public Frustum frustum;
	/// Where the tile is in the atlas, in pixels from the top left.
	public int32 x, y, size;
}

/// The point, spot and extra directional lights of one view, sorted into clusters (docs/lighting.md). The view is
/// cut into a grid of 16 x 9 cells across the screen and 24 slices in depth; each cluster lists the lights whose
/// reach touches it, so a pixel only works through the lights near it, however many the scene has. The lights,
/// their shadow tiles and the lists go to the shaders in one float texture per view.
class LightClusters
{
	public const int32 GridX = 16;
	public const int32 GridY = 9;
	public const int32 GridZ = 24;
	public const int32 ClusterCount = GridX * GridY * GridZ;
	/// The most lights one view draws (the nearest are kept).
	public const int32 MaxLights = 256;
	/// The most directional lights besides the sun (they light every pixel).
	public const int32 MaxDirectional = 8;
	/// The most lights one cluster lists (a pixel lit by more drops the farthest).
	public const int32 MaxPerCluster = 32;
	/// Tiles of the local shadow atlas (a spot light takes one, a point light six).
	public const int32 MaxTiles = 64;

	// The texture: Width texels a row, RGBA32F. Lights are 8 texels each, then the shadow tiles (8 texels each), the
	// clusters (one texel each: where its list starts, how long it is), and the lists, four light numbers a texel.
	// lighting.sh reads it with the same numbers.
	public const int32 Width = 64;
	public const int32 TexelsPerLight = 8;
	public const int32 TileRow = MaxLights * TexelsPerLight / Width;
	public const int32 ClusterRow = TileRow + MaxTiles * 8 / Width;
	public const int32 IndexRow = ClusterRow + ClusterCount / Width;
	public const int32 Height = 256;
	public const int32 MaxIndices = (Height - IndexRow) * Width * 4;

	/// The lights drawn, directional ones first.
	public List<Light> Lights = new .() ~ delete _;
	/// How many of Lights are directional (they light every pixel, not by cluster).
	public int32 DirectionalCount;
	public List<ShadowTile> Tiles = new .() ~ delete _;
	/// The shadow atlas's grid this frame: 2, 4 or 8 tiles across (fewer tiles in use, bigger tiles).
	public int32 TileGrid = 4;
	/// Lights left out because the view had MaxLights already.
	public int32 Dropped;
	/// Light numbers in the cluster lists.
	public int32 IndexCount;
	/// Clusters that had more lights than MaxPerCluster.
	public int32 FullClusters;

	public float[] Data = new float[Width * Height * 4] ~ delete _;
	/// How many rows of Data are in use this frame.
	public int32 RowsUsed;
	/// Each cluster's list: where it starts among the light numbers, and how many.
	public int32[] ClusterStart = new int32[ClusterCount] ~ delete _;
	public int32[] ClusterLength = new int32[ClusterCount] ~ delete _;

	// The camera the clusters were made for.
	public Matrix4 ViewProj;
	public Vector3 CameraPosition, CameraForward;
	public float Near, Far;
	/// Which depth slice a distance in front of the camera is in: floor(log(distance) * SliceScale + SliceOffset).
	public float SliceScale, SliceOffset;

	List<(Light light, float key)> mSorted = new .() ~ delete _;
	List<(int32 x0, int32 x1, int32 y0, int32 y1, int32 z0, int32 z1)> mBoxes = new .() ~ delete _;
	int32[] mFill = new int32[ClusterCount] ~ delete _;
	bgfx.TextureHandle mTexture = .() { idx = uint16.MaxValue };

	public ~this()
	{
		if (mTexture.idx != uint16.MaxValue && Gfx.Initialized)
			bgfx.destroy_texture(mTexture);
	}

	/// The texture the shaders read (made the first time it is asked for).
	public bgfx.TextureHandle Texture
	{
		get
		{
			if (mTexture.idx == uint16.MaxValue)
				mTexture = bgfx.create_texture_2d((uint16)Width, (uint16)Height, false, 1, .RGBA32F, Gfx.SamplerPoint | Gfx.SamplerClamp, null, 0);
			return mTexture;
		}
	}

	/// Picks the view's lights (all but the sun), the shadowed ones and their tiles, and sorts them into clusters.
	/// `shadowedLights` is how many point and spot lights may cast shadows (0: none).
	public void Build(Scene scene, CameraData camera, Light sun, int32 shadowedLights, int32 atlasSize)
	{
		Lights.Clear();
		Tiles.Clear();
		mSorted.Clear();
		DirectionalCount = 0;
		Dropped = 0;
		SetCamera(camera);
		let frustum = Frustum(ViewProj, Gfx.HomogeneousDepth);
		for (let light in scene.Lights)
		{
			if (!light.IsActiveAndEnabled || !light.GameObject.InActiveWorld || light == sun)
				continue;
			if (light.type == .Directional)
			{
				if (DirectionalCount < MaxDirectional)
				{
					Lights.Add(light);
					DirectionalCount++;
				}
				continue;
			}
			if (light.intensity <= 0 || light.range <= 0)
				continue;
			let position = light.Transform.Position;
			if (!frustum.IntersectsSphere(position, light.range))
				continue;
			// Nearest first, by how far the edge of their reach is from the camera (inside it counts as less than
			// nothing, so the light the camera is deepest in comes first).
			mSorted.Add((light, (position - CameraPosition).Length - light.range));
		}
		mSorted.Sort((a, b) => a.key <=> b.key);
		for (let entry in mSorted)
		{
			if (Lights.Count >= MaxLights)
			{
				Dropped++;
				continue;
			}
			Lights.Add(entry.light);
		}
		PlaceShadows(shadowedLights, atlasSize);
		Assign();
		Write();
	}

	void SetCamera(CameraData camera)
	{
		ViewProj = camera.projection * camera.view;
		CameraPosition = camera.position;
		let v = camera.view.m;
		CameraForward = Vector3(v[2], v[6], v[10]).Normalized;
		Near = Math.Max(camera.near, 0.05f);
		Far = Math.Max(camera.far, Near * 2);
		SliceScale = GridZ / Math.Log(Far / Near);
		SliceOffset = -Math.Log(Near) * SliceScale;
	}

	/// The depth slice of a distance in front of the camera.
	public int32 SliceOf(float depth)
	{
		if (depth <= Near)
			return 0;
		return (int32)Math.Clamp(Math.Floor(Math.Log(depth) * SliceScale + SliceOffset), 0, GridZ - 1);
	}

	/// The cluster a point of the world is in (as lighting.sh finds it).
	public int32 ClusterOf(Vector3 point)
	{
		let clip = ViewProj.Transform(Vector4(point, 1));
		let w = Math.Max(clip.w, 1.0e-6f);
		let x = (int32)Math.Clamp(Math.Floor((clip.x / w * 0.5f + 0.5f) * GridX), 0, GridX - 1);
		let y = (int32)Math.Clamp(Math.Floor((clip.y / w * 0.5f + 0.5f) * GridY), 0, GridY - 1);
		let z = SliceOf(Vector3.Dot(point - CameraPosition, CameraForward));
		return x + y * GridX + z * GridX * GridY;
	}

	/// Shadow tiles for the nearest lights that cast shadows: a spot light one, a point light six (a cube).
	void PlaceShadows(int32 shadowedLights, int32 atlasSize)
	{
		let wanted = scope List<Light>();
		int32 tiles = 0;
		for (int i = DirectionalCount; i < Lights.Count; i++)
		{
			let light = Lights[i];
			if (wanted.Count >= shadowedLights)
				break;
			if (!light.castShadows || light.shadowStrength <= 0 || light.range <= 0.05f)
				continue;
			let needs = light.type == .Point ? 6 : 1;
			if (tiles + needs > MaxTiles)
				continue;
			wanted.Add(light);
			tiles += (int32)needs;
		}
		if (tiles == 0)
			return;
		TileGrid = tiles <= 4 ? 2 : (tiles <= 16 ? 4 : 8);
		let size = atlasSize / TileGrid;
		for (let light in wanted)
		{
			let position = light.Transform.Position;
			// Close by stays sharp; a point light's near plane can be further out than a spot light's.
			let near = Math.Clamp(light.range * 0.002f, 0.02f, 0.1f);
			if (light.type == .Spot)
			{
				let view = Matrix4.LookAt(position, position + light.Transform.Forward, light.Transform.Rotation * Vector3.Up);
				let projection = Matrix4.Perspective(Math.Clamp(light.spotAngle, 1, 170), 1, near, light.range, Gfx.HomogeneousDepth);
				AddTile(light, projection * view, size);
				continue;
			}
			// A point light's six faces, each a little wider than 90 degrees, so that the shadow's filtering never
			// reads past a face's edge.
			let margin = 2.5f;
			let fov = 2 * Math.Atan(size / (size - 2 * margin)) * Mathf.Rad2Deg;
			let projection = Matrix4.Perspective(fov, 1, near, light.range, Gfx.HomogeneousDepth);
			for (int face < 6)
			{
				let view = Matrix4.LookAt(position, position + sFaceForward[face], sFaceUp[face]);
				AddTile(light, projection * view, size);
			}
		}
	}

	// The faces of a point light's cube, in the order lighting.sh picks them: +X, -X, +Y, -Y, +Z, -Z.
	static Vector3[6] sFaceForward = .(.(1, 0, 0), .(-1, 0, 0), .(0, 1, 0), .(0, -1, 0), .(0, 0, 1), .(0, 0, -1));
	static Vector3[6] sFaceUp = .(.(0, 1, 0), .(0, 1, 0), .(0, 0, -1), .(0, 0, 1), .(0, 1, 0), .(0, 1, 0));

	void AddTile(Light light, Matrix4 viewProj, int32 size)
	{
		let index = (int32)Tiles.Count;
		let column = index % TileGrid;
		let row = index / TileGrid;
		let n = (float)TileGrid;
		ShadowTile tile = default;
		tile.light = light;
		tile.x = column * size;
		tile.y = row * size;
		tile.size = size;
		tile.frustum = Frustum(viewProj, Gfx.HomogeneousDepth);
		// Drawing: the light's clip space squeezed into the tile's part of the atlas (top row at the top).
		Matrix4 squeeze = default;
		squeeze.m[0] = 1 / n;
		squeeze.m[12] = -1 + (2 * column + 1) / n;
		squeeze.m[5] = 1 / n;
		squeeze.m[13] = 1 - (2 * row + 1) / n;
		squeeze.m[10] = 1;
		squeeze.m[15] = 1;
		tile.drawViewProj = squeeze * viewProj;
		// Looking up: the light's clip space to the tile's texture coordinates and a 0 to 1 depth.
		Matrix4 bias = default;
		bias.m[0] = 0.5f / n;
		bias.m[12] = (column + 0.5f) / n;
		bias.m[5] = Gfx.OriginBottomLeft ? 0.5f / n : -0.5f / n;
		bias.m[13] = Gfx.OriginBottomLeft ? 1 - (row + 0.5f) / n : (row + 0.5f) / n;
		bias.m[10] = Gfx.HomogeneousDepth ? 0.5f : 1;
		bias.m[14] = Gfx.HomogeneousDepth ? 0.5f : 0;
		bias.m[15] = 1;
		tile.sampleMtx = bias * viewProj;
		Tiles.Add(tile);
	}

	/// Which clusters each light reaches, then each cluster's list.
	void Assign()
	{
		mBoxes.Clear();
		for (int c < ClusterCount)
			ClusterLength[c] = 0;
		for (int i < Lights.Count)
		{
			let light = Lights[i];
			if (i < DirectionalCount)
			{
				mBoxes.Add((0, -1, 0, -1, 0, -1));
				continue;
			}
			mBoxes.Add(Reach(light.Transform.Position, light.range));
		}
		// How long each list is (lights in order of nearness, so the cap drops the far ones), then where they start.
		FullClusters = 0;
		for (let reach in mBoxes)
		{
			for (int32 z = reach.z0; z <= reach.z1; z++)
			{
				for (int32 y = reach.y0; y <= reach.y1; y++)
				{
					for (int32 x = reach.x0; x <= reach.x1; x++)
						ClusterLength[x + y * GridX + z * GridX * GridY]++;
				}
			}
		}
		int32 next = 0;
		for (int c < ClusterCount)
		{
			if (ClusterLength[c] > MaxPerCluster)
			{
				ClusterLength[c] = MaxPerCluster;
				FullClusters++;
			}
			if (next + ClusterLength[c] > MaxIndices)
				ClusterLength[c] = Math.Max(MaxIndices - next, 0);
			ClusterStart[c] = next;
			next += ClusterLength[c];
			mFill[c] = 0;
		}
		IndexCount = next;
		let indexBase = IndexRow * Width * 4;
		for (int32 i < (int32)mBoxes.Count)
		{
			let reach = mBoxes[i];
			for (int32 z = reach.z0; z <= reach.z1; z++)
			{
				for (int32 y = reach.y0; y <= reach.y1; y++)
				{
					for (int32 x = reach.x0; x <= reach.x1; x++)
					{
						let c = x + y * GridX + z * GridX * GridY;
						if (mFill[c] >= ClusterLength[c])
							continue;
						Data[indexBase + ClusterStart[c] + mFill[c]] = i;
						mFill[c]++;
					}
				}
			}
		}
	}

	/// The clusters a sphere may touch: its depth slices, and the screen rectangle round its box (the whole
	/// screen when the box reaches behind the camera).
	(int32 x0, int32 x1, int32 y0, int32 y1, int32 z0, int32 z1) Reach(Vector3 center, float radius)
	{
		let depth = Vector3.Dot(center - CameraPosition, CameraForward);
		if (depth + radius < Near || depth - radius > Far)
			return (0, -1, 0, -1, 0, -1);
		let z0 = SliceOf(depth - radius);
		let z1 = SliceOf(depth + radius);
		float minX = 1, minY = 1, maxX = -1, maxY = -1;
		bool whole = false;
		for (int corner < 8)
		{
			let p = center + Vector3((corner & 1) != 0 ? radius : -radius, (corner & 2) != 0 ? radius : -radius, (corner & 4) != 0 ? radius : -radius);
			let clip = ViewProj.Transform(Vector4(p, 1));
			if (clip.w < 1.0e-4f)
			{
				whole = true;
				break;
			}
			minX = Math.Min(minX, clip.x / clip.w);
			maxX = Math.Max(maxX, clip.x / clip.w);
			minY = Math.Min(minY, clip.y / clip.w);
			maxY = Math.Max(maxY, clip.y / clip.w);
		}
		if (whole)
			return (0, GridX - 1, 0, GridY - 1, z0, z1);
		if (maxX < -1 || minX > 1 || maxY < -1 || minY > 1)
			return (0, -1, 0, -1, 0, -1);
		int32 Cell(float ndc, int32 count) => (int32)Math.Clamp(Math.Floor((ndc * 0.5f + 0.5f) * count), 0, count - 1);
		return (Cell(minX, GridX), Cell(maxX, GridX), Cell(minY, GridY), Cell(maxY, GridY), z0, z1);
	}

	void Set(int texel, float x, float y, float z, float w)
	{
		let i = texel * 4;
		Data[i] = x;
		Data[i + 1] = y;
		Data[i + 2] = z;
		Data[i + 3] = w;
	}

	void SetColumns(int texel, Matrix4 m)
	{
		for (int c < 4)
			Set(texel + c, m.m[c * 4], m.m[c * 4 + 1], m.m[c * 4 + 2], m.m[c * 4 + 3]);
	}

	/// Lights, tiles and cluster lists into Data, as lighting.sh reads them.
	void Write()
	{
		for (int i < Lights.Count)
		{
			let light = Lights[i];
			let texel = i * TexelsPerLight;
			let position = light.Transform.Position;
			let color = LinearColor(light.color, light.intensity);
			let type = light.type == .Directional ? 2 : (light.type == .Spot ? 1 : 0);
			let outer = Math.Cos(light.spotAngle * 0.5f * Mathf.Deg2Rad);
			let innerAngle = light.innerSpotAngle < 0 ? light.spotAngle * 0.8f : Math.Clamp(light.innerSpotAngle, 0, light.spotAngle);
			let inner = Math.Cos(innerAngle * 0.5f * Mathf.Deg2Rad);
			let forward = light.Transform.Forward;
			Set(texel, position.x, position.y, position.z, light.range);
			Set(texel + 1, color.x, color.y, color.z, type);
			Set(texel + 2, forward.x, forward.y, forward.z, outer);
			Set(texel + 3, inner, light.inverseSquare ? 1 : 0, light.shadowMaskChannel + 1, light.bakedOnly ? 1 : 0);
			Set(texel + 4, 0, 0, 0, 0);
		}
		// Each shadowed light's first tile and how many it has (tiles of one light are next to each other).
		for (int t < Tiles.Count)
		{
			let tile = Tiles[t];
			let lightIndex = Lights.IndexOf(tile.light);
			let lightTexel = (lightIndex * TexelsPerLight + 4) * 4;
			if (Data[lightTexel] <= 0)
				Set(lightIndex * TexelsPerLight + 4, Math.Clamp(tile.light.shadowStrength, 0, 1), t, tile.light.type == .Point ? 6 : 1, 0);
			let texel = TileRow * Width + t * 8;
			SetColumns(texel, tile.sampleMtx);
			// The tile's bounds in texture coordinates, kept a texel and a half in for filtering.
			let n = (float)TileGrid;
			let column = (float)(tile.x / tile.size), row = (float)(tile.y / tile.size);
			let texelSize = 1.0f / (tile.size * TileGrid);
			let v0 = Gfx.OriginBottomLeft ? 1 - (row + 1) / n : row / n;
			Set(texel + 4, column / n + texelSize * 1.5f, v0 + texelSize * 1.5f, (column + 1) / n - texelSize * 1.5f, v0 + 1 / n - texelSize * 1.5f);
			// Texel size; depth bias; how wide a texel is a metre from the light (for pushing the test off the surface).
			let fovTan = tile.light.type == .Point ? 1.0f : Math.Tan(Math.Clamp(tile.light.spotAngle, 1, 170) * 0.5f * Mathf.Deg2Rad);
			Set(texel + 5, texelSize, 0.000002f, 2 * fovTan / tile.size, 0);
		}
		let clusterBase = ClusterRow * Width;
		for (int c < ClusterCount)
			Set(clusterBase + c, ClusterStart[c], ClusterLength[c], 0, 0);
		RowsUsed = IndexRow + (IndexCount + Width * 4 - 1) / (Width * 4);
		RowsUsed = Math.Clamp(RowsUsed, IndexRow + 1, Height);
	}

	static Vector3 LinearColor(Color c, float scale)
	{
		return .(Math.Pow(Math.Max(c.r, 0), 2.2f) * scale, Math.Pow(Math.Max(c.g, 0), 2.2f) * scale, Math.Pow(Math.Max(c.b, 0), 2.2f) * scale);
	}

	/// Sends this frame's rows to the texture.
	public void Upload()
	{
		let texture = Texture;
		let bytes = (uint32)(RowsUsed * Width * 4 * sizeof(float));
		bgfx.update_texture_2d(texture, 0, 0, 0, 0, (uint16)Width, (uint16)RowsUsed, bgfx.copy(Data.Ptr, bytes), (uint16)(Width * 4 * sizeof(float)));
	}
}
