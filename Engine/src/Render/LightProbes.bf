using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// A grid of baked light probes (docs/baked-lighting.md): at each point, the light arriving from every direction (the
/// sky and what it bounced off), kept as a constant plus a direction for each of red, green and blue (spherical
/// harmonics to the first band, already scaled for diffuse lighting): the ambient light for a normal n is
/// `max(a + dot(b, n), 0)`. Moving things and surfaces without a lightmap read it per pixel, blended between the
/// eight probes round them. A scene's probes are one grid over everything plus one for each Light Probe Volume
/// (LightProbeSet).
class LightProbeGrid
{
	public const int Coefficients = 12;
	/// The first and last probes' positions; probes are evenly spaced between them.
	public Vector3 min, max;
	public int32 countX = 1, countY = 1, countZ = 1;
	/// A volume's grid: how far inside its box, in metres, it fades in from the scene's grid (0: the scene's own).
	public float fade;
	/// Coefficients for each probe, x fastest then y then z: red a, bx, by, bz, then green, then blue.
	public List<float> values = new .() ~ delete _;
	/// Where its block starts in the set's texture, in texels (LightProbeSet.Texture).
	public int32 offsetX, offsetZ;

	public int32 Count => countX * countY * countZ;
	public int Index(int x, int y, int z) => (z * countY + y) * countX + x;

	/// Whether a point is inside its box.
	public bool Contains(Vector3 p) => p.x >= min.x && p.y >= min.y && p.z >= min.z && p.x <= max.x && p.y <= max.y && p.z <= max.z;

	/// How far inside its box a point is, in metres (less than 0 outside).
	public float Inside(Vector3 p) => Math.Min(Math.Min(Math.Min(p.x - min.x, max.x - p.x), Math.Min(p.y - min.y, max.y - p.y)), Math.Min(p.z - min.z, max.z - p.z));

	public float Volume => Math.Max(max.x - min.x, 0) * Math.Max(max.y - min.y, 0) * Math.Max(max.z - min.z, 0);

	public Vector3 Position(int x, int y, int z)
	{
		Vector3 t = .(countX > 1 ? (float)x / (countX - 1) : 0.5f, countY > 1 ? (float)y / (countY - 1) : 0.5f, countZ > 1 ? (float)z / (countZ - 1) : 0.5f);
		return .(min.x + (max.x - min.x) * t.x, min.y + (max.y - min.y) * t.y, min.z + (max.z - min.z) * t.z);
	}

	/// The ambient light at a point for a surface facing `normal`, blended between the probes round it (as the
	/// shader does).
	public Vector3 Sample(Vector3 position, Vector3 normal)
	{
		float[Coefficients] blended = default;
		float Cell(float p, float lo, float hi, int count, out int first)
		{
			if (count <= 1)
			{
				first = 0;
				return 0;
			}
			let t = Math.Clamp((p - lo) / Math.Max(hi - lo, 1e-6f), 0, 1) * (count - 1);
			first = Math.Min((int)t, count - 2);
			return t - first;
		}
		let fx = Cell(position.x, min.x, max.x, countX, let x0);
		let fy = Cell(position.y, min.y, max.y, countY, let y0);
		let fz = Cell(position.z, min.z, max.z, countZ, let z0);
		for (int corner < 8)
		{
			let dx = corner & 1, dy = (corner >> 1) & 1, dz = (corner >> 2) & 1;
			let x = Math.Min(x0 + dx, countX - 1), y = Math.Min(y0 + dy, countY - 1), z = Math.Min(z0 + dz, countZ - 1);
			let weight = (dx == 1 ? fx : 1 - fx) * (dy == 1 ? fy : 1 - fy) * (dz == 1 ? fz : 1 - fz);
			if (weight <= 0)
				continue;
			let start = Index(x, y, z) * Coefficients;
			for (int i < Coefficients)
				blended[i] += values[start + i] * weight;
		}
		return .(Math.Max(blended[0] + blended[1] * normal.x + blended[2] * normal.y + blended[3] * normal.z, 0),
			Math.Max(blended[4] + blended[5] * normal.x + blended[6] * normal.y + blended[7] * normal.z, 0),
			Math.Max(blended[8] + blended[9] * normal.x + blended[10] * normal.y + blended[11] * normal.z, 0));
	}

	/// Its part of a `.tprobes` file: where it is, then one line of twelve numbers for each probe.
	public void Write(String output)
	{
		output.AppendF("min {} {} {}\n", min.x, min.y, min.z);
		output.AppendF("max {} {} {}\n", max.x, max.y, max.z);
		output.AppendF("count {} {} {}\n", countX, countY, countZ);
		if (fade > 0)
			output.AppendF("fade {}\n", fade);
		for (int p < Count)
		{
			for (int i < Coefficients)
				output.AppendF(i == 0 ? "{0:0.#####}" : " {0:0.#####}", values[p * Coefficients + i]);
			output.Append('\n');
		}
	}

	static float Number(StringView text) => float.Parse(text) case .Ok(let value) ? value : 0;

	/// Reads one line of its part of a file (false: not one of its lines).
	public bool ReadLine(List<StringView> parts)
	{
		switch (parts[0])
		{
		case "min","max","count":
			if (parts.Count < 4)
				return false;
			float[3] v = default;
			for (int i < 3)
				v[i] = Number(parts[i + 1]);
			if (parts[0] == "min")
				min = .(v[0], v[1], v[2]);
			else if (parts[0] == "max")
				max = .(v[0], v[1], v[2]);
			else
			{
				countX = Math.Max((int32)v[0], 1);
				countY = Math.Max((int32)v[1], 1);
				countZ = Math.Max((int32)v[2], 1);
			}
			return true;
		case "fade":
			fade = parts.Count > 1 ? Math.Max(Number(parts[1]), 0) : 0;
			return true;
		}
		if (parts.Count != Coefficients)
			return false;
		for (let part in parts)
			values.Add(Number(part));
		return true;
	}

	public bool Complete => values.Count == Count * Coefficients;

	/// A float as a 16-bit float (rounded to nearest).
	public static uint16 Half(float value)
	{
		var value;
		let bits = *(uint32*)&value;
		let sign = (uint16)((bits >> 16) & 0x8000);
		let exponent = (int32)((bits >> 23) & 0xff) - 127 + 15;
		var mantissa = bits & 0x7fffff;
		if (exponent <= 0)
		{
			if (exponent < -10)
				return sign;
			mantissa |= 0x800000;
			int32 shiftBy = 14 - exponent;
			let shift = (uint32)shiftBy;
			return sign | (uint16)((mantissa + (1u << (shift - 1))) >> shift);
		}
		if (exponent >= 31)
			return sign | 0x7bff;
		let rounded = ((uint32)exponent << 10 | (mantissa >> 13)) + ((mantissa >> 12) & 1);
		return sign | (uint16)Math.Min(rounded, 0x7bffu);
	}
}

/// A scene's baked light probes (SceneEnvironment.lightProbes, a `.tprobes` file): a grid over the whole scene,
/// then a finer one for each Light Probe Volume. A draw is lit by the smallest volume its middle is in, fading into
/// the scene's grid towards that volume's edges, or by the scene's grid alone.
class LightProbeSet
{
	public List<LightProbeGrid> grids = new .() ~ DeleteContainerAndItems!(_);

	bgfx.TextureHandle mTexture = .() { idx = uint16.MaxValue };
	int32 mWidth, mHeight, mDepth;

	public ~this()
	{
		if (mTexture.Valid && Gfx.Initialized)
			bgfx.destroy_texture(mTexture);
	}

	/// How many probes, in every grid.
	public int32 Count
	{
		get
		{
			int32 total = 0;
			for (let grid in grids)
				total += grid.Count;
			return total;
		}
	}

	/// The scene's grid (null if there are no probes).
	public LightProbeGrid SceneGrid => grids.Count > 0 ? grids[0] : null;

	/// The grid that lights a thing whose middle is here: the smallest volume it is in, or 0 for the scene's grid.
	public int32 Pick(Vector3 center)
	{
		int32 best = 0;
		var bestVolume = float.MaxValue;
		for (int32 i = 1; i < grids.Count; i++)
		{
			let grid = grids[i];
			if (!grid.Contains(center))
				continue;
			let volume = grid.Volume;
			if (volume < bestVolume)
			{
				best = i;
				bestVolume = volume;
			}
		}
		return best;
	}

	/// The ambient light at a point for a surface facing `normal`, as the shader works it out for a draw lit by
	/// grid `pick` (-1: the one Pick gives for the point).
	public Vector3 Sample(Vector3 position, Vector3 normal, int32 pick = -1)
	{
		if (grids.Count == 0)
			return default;
		let chosen = pick >= 0 && pick < grids.Count ? pick : Pick(position);
		let inner = grids[chosen].Sample(position, normal);
		if (chosen == 0)
			return inner;
		let grid = grids[chosen];
		let weight = grid.fade > 0 ? Math.Clamp(grid.Inside(position) / grid.fade, 0, 1) : (grid.Contains(position) ? 1 : 0);
		let outer = grids[0].Sample(position, normal);
		return outer + (inner - outer) * weight;
	}

	/// The `.tprobes` file: a header, then each grid (the scene's first).
	public void Write(String output)
	{
		output.Append("tprobes 2\n");
		for (let grid in grids)
		{
			output.Append("grid\n");
			grid.Write(output);
		}
	}

	/// Reads a `.tprobes` file (version 1, one grid with no `grid` line, or version 2).
	public bool Parse(StringView text)
	{
		ClearAndDeleteItems!(grids);
		LightProbeGrid current = null;
		for (var line in text.Split('\n'))
		{
			line.Trim();
			if (line.IsEmpty)
				continue;
			let parts = scope List<StringView>(line.Split(' ', .RemoveEmptyEntries));
			if (parts[0] == "tprobes")
				continue;
			if (parts[0] == "grid" || current == null)
			{
				current = new .();
				grids.Add(current);
				if (parts[0] == "grid")
					continue;
			}
			if (!current.ReadLine(parts))
				return false;
		}
		if (grids.Count == 0)
			return false;
		for (let grid in grids)
		{
			if (!grid.Complete)
				return false;
		}
		return true;
	}

	/// The grids as one 3D texture for the shader. Each grid has a block of countX by countY by three countZ (red,
	/// green, blue); blocks are laid in rows along x, rows one after another along z.
	public bgfx.TextureHandle Texture
	{
		get
		{
			if (!mTexture.Valid && Gfx.Initialized && Count > 0)
			{
				Layout();
				let data = bgfx.alloc((uint32)(mWidth * mHeight * mDepth * 8));
				let halves = (uint16*)data.data;
				Internal.MemSet(halves, 0, mWidth * mHeight * mDepth * 8);
				for (let grid in grids)
				{
					for (int channel < 3)
					{
						for (int z < grid.countZ)
						{
							for (int y < grid.countY)
							{
								for (int x < grid.countX)
								{
									let source = grid.Index(x, y, z) * LightProbeGrid.Coefficients + channel * 4;
									let tz = grid.offsetZ + channel * grid.countZ + z;
									let target = ((tz * mHeight + y) * mWidth + grid.offsetX + x) * 4;
									for (int i < 4)
										halves[target + i] = LightProbeGrid.Half(grid.values[source + i]);
								}
							}
						}
					}
				}
				mTexture = bgfx.create_texture_3d((uint16)mWidth, (uint16)mHeight, (uint16)mDepth, false, .RGBA16F, Gfx.SamplerClamp, data, 0);
			}
			return mTexture;
		}
	}

	/// The texture's size in texels.
	public Vector3 TextureSize => .(mWidth, mHeight, mDepth);

	/// Places each grid's block in the texture.
	public void Layout()
	{
		int32 widest = 1;
		mHeight = 1;
		for (let grid in grids)
		{
			widest = Math.Max(widest, grid.countX);
			mHeight = Math.Max(mHeight, grid.countY);
		}
		let rowWidth = Math.Max(widest, 64);
		int32 x = 0, z = 0, rowDepth = 0;
		mWidth = 1;
		for (let grid in grids)
		{
			if (x + grid.countX > rowWidth)
			{
				z += rowDepth;
				x = 0;
				rowDepth = 0;
			}
			grid.offsetX = x;
			grid.offsetZ = z;
			x += grid.countX;
			mWidth = Math.Max(mWidth, x);
			rowDepth = Math.Max(rowDepth, grid.countZ * 3);
		}
		mDepth = z + rowDepth;
	}
}

/// The light probe grids scenes use (SceneEnvironment.lightProbes), loaded once each, and binding them for drawing.
static class LightProbes
{
	static Dictionary<String, LightProbeSet> sGrids = new .() ~
		{
			for (let pair in _)
			{
				delete pair.key;
				delete pair.value;
			}
			delete _;
		};
	static bgfx.TextureHandle sEmpty = .() { idx = uint16.MaxValue };

	/// The grid in a `.tprobes` file (null if there is none, or it cannot be read).
	public static LightProbeSet Get(StringView path)
	{
		if (path.IsEmpty)
			return null;
		if (sGrids.TryGetValueAlt(path, let found))
			return found;
		LightProbeSet grid = new .();
		let text = scope String();
		if (!Assets.ReadText(path, text) || !grid.Parse(text))
			DeleteAndNullify!(grid);
		sGrids[new String(path)] = grid;
		return grid;
	}

	/// Reads a grid's file again next time (after baking).
	public static void Forget(StringView path)
	{
		if (sGrids.GetAndRemoveAlt(path) case .Ok(let pair))
		{
			delete pair.key;
			delete pair.value;
		}
	}

	/// Sets the shader's probes for the next draw (none: the ambient colours): grid `pick` of the set (Pick), with
	/// the scene's grid round it when that is a volume.
	public static void Bind(LightProbeSet probes, int32 pick = 0)
	{
		bgfx.TextureHandle texture = probes != null ? probes.Texture : .() { idx = uint16.MaxValue };
		Vector4[10] uniforms = default;
		if (probes != null && texture.Valid)
		{
			void Put(LightProbeGrid grid, int at, Vector4[10]* into)
			{
				let size = grid.max - grid.min;
				(*into)[at] = .(grid.min, 1);
				(*into)[at + 1] = .(size.x > 1e-6f ? 1 / size.x : 0, size.y > 1e-6f ? 1 / size.y : 0, size.z > 1e-6f ? 1 / size.z : 0, grid.fade > 0 ? 1 / grid.fade : 1e6f);
				(*into)[at + 2] = .(grid.countX, grid.countY, grid.countZ, 0);
				(*into)[at + 3] = .(grid.offsetX, 0, grid.offsetZ, 0);
			}
			let chosen = pick > 0 && pick < probes.grids.Count ? pick : 0;
			Put(probes.grids[chosen], 0, &uniforms);
			if (chosen > 0)
				Put(probes.grids[0], 4, &uniforms);
			uniforms[8] = .(probes.TextureSize, 0);
			uniforms[9] = .(probes.grids[chosen].max, 0);
		}
		else
		{
			if (!sEmpty.Valid)
			{
				uint16[4] zero = default;
				sEmpty = bgfx.create_texture_3d(1, 1, 1, false, .RGBA16F, Gfx.SamplerClamp, bgfx.copy(&zero, 8), 0);
			}
			texture = sEmpty;
			uniforms[8] = .(1, 1, 1, 0);
		}
		bgfx.set_uniform(RenderResources.uLightProbe, &uniforms, 10);
		bgfx.set_texture(12, RenderResources.sLightProbes, texture, uint32.MaxValue);
	}

	public static void Release()
	{
		for (let pair in sGrids)
		{
			delete pair.key;
			delete pair.value;
		}
		sGrids.Clear();
		if (sEmpty.Valid && Gfx.Initialized)
			bgfx.destroy_texture(sEmpty);
		sEmpty.idx = uint16.MaxValue;
	}
}
