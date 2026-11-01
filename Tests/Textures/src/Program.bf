using System;
using Tallow;
using Bgfx;

namespace TexturesTests;

/// Textures (docs/textures.md): mip levels made on the CPU (sizes, odd sizes, leaving out the largest, averaging colour
/// in linear light, data as stored and normal maps as directions), what a texture holds from hints and names, and the
/// quality settings that set them. Compressed copies and drawing need tools and a graphics card: `python3 run.py`.
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

	static uint8[] Image(int32 width, int32 height, delegate void(int32 x, int32 y, uint8* pixel) paint)
	{
		let pixels = new uint8[width * height * 4];
		for (int32 y < height)
		{
			for (int32 x < width)
				paint(x, y, &pixels[(y * width + x) * 4]);
		}
		return pixels;
	}

	public static int Main(String[] args)
	{
		int32 w, h, levels;

		// ---- the chain ----
		let flat = Image(8, 4, scope (x, y, p) =>
			{
				p[0] = 200;
				p[1] = 100;
				p[2] = 50;
				p[3] = 255;
			}
			);
		defer delete flat;
		var mips = Textures.MakeMips(flat, 8, 4, .Color, 0, out w, out h, out levels);
		Check(mips != null && w == 8 && h == 4 && levels == 4, scope $"8 x 4 has four levels: 8x4, 4x2, 2x1, 1x1 ({levels})");
		Check(mips.Count == (32 + 8 + 2 + 1) * 4, scope $"one after another, largest first ({mips.Count} bytes)");
		Check(mips[mips.Count - 4] == 200 && mips[mips.Count - 3] == 100 && mips[mips.Count - 2] == 50 && mips[mips.Count - 1] == 255, "a flat colour stays the same colour down to 1 x 1");
		delete mips;

		let odd = Image(5, 3, scope (x, y, p) =>
			{
				p[0] = p[1] = p[2] = 128;
				p[3] = 255;
			}
			);
		defer delete odd;
		mips = Textures.MakeMips(odd, 5, 3, .Data, 0, out w, out h, out levels);
		Check(levels == 3 && mips.Count == (15 + 2 + 1) * 4, scope $"odd sizes halve rounding down: 5x3, 2x1, 1x1 ({levels} levels)");
		delete mips;

		mips = Textures.MakeMips(flat, 8, 4, .Color, 1, out w, out h, out levels);
		Check(w == 4 && h == 2 && levels == 3 && mips.Count == (8 + 2 + 1) * 4, scope $"leaving out the largest level starts at 4 x 2 ({w} x {h}, {levels} levels)");
		delete mips;
		mips = Textures.MakeMips(flat, 8, 4, .Color, 9, out w, out h, out levels);
		Check(w == 1 && h == 1 && levels == 1, "leaving out more than there are keeps the last level");
		delete mips;

		// ---- averaging ----
		let checker = Image(2, 2, scope (x, y, p) =>
			{
				let on = (x + y) % 2 == 0;
				p[0] = p[1] = p[2] = on ? 255 : 0;
				p[3] = on ? 255 : 0;
			}
			);
		defer delete checker;
		mips = Textures.MakeMips(checker, 2, 2, .Color, 0, out w, out h, out levels);
		// The 2 x 2 level is the first 16 bytes; the 1 x 1 one follows.
		let colour = mips[16];
		Check(colour >= 186 && colour <= 189, scope $"a black and white colour checker shrinks to the grey the eye sees, averaged in linear light ({colour}, not 128)");
		Check(mips[19] == 128, scope $"alpha is averaged as it is ({mips[19]})");
		delete mips;
		mips = Textures.MakeMips(checker, 2, 2, .Data, 0, out w, out h, out levels);
		Check(mips[16] == 128, scope $"data is averaged as it is stored ({mips[16]})");
		delete mips;

		// Two normals a right angle apart (x and z): their average, made unit length, points between them.
		let normals = Image(2, 1, scope (x, y, p) =>
			{
				p[0] = x == 0 ? 255 : 128;
				p[1] = 128;
				p[2] = x == 0 ? 128 : 255;
				p[3] = 255;
			}
			);
		defer delete normals;
		mips = Textures.MakeMips(normals, 2, 1, .Normal, 0, out w, out h, out levels);
		let nx = mips[8] / 127.5f - 1, ny = mips[9] / 127.5f - 1, nz = mips[10] / 127.5f - 1;
		let length = Math.Sqrt(nx * nx + ny * ny + nz * nz);
		Check(Math.Abs(length - 1) < 0.02f && Math.Abs(nx - nz) < 0.02f && nx > 0.68f, scope $"normal maps average directions and keep them unit length ({nx:0.00} {ny:0.00} {nz:0.00}, length {length:0.000})");
		delete mips;

		// ---- what a texture holds ----
		Check(Textures.KindOf("Textures/rock.png") == .Color, "a picture is a colour by default");
		Check(Textures.KindOf("Textures/rock_Normal.png") == .Normal && Textures.KindOf("Packs/NormalMaps/a.png") == .Color, "a file named as a normal map is one (the file's name, not its folder)");
		Textures.Hint("Textures/rock_orm.png", .Data);
		Check(Textures.KindOf("Textures/rock_orm.png") == .Data, "a material's metal / roughness map is data, as hinted");
		let material = scope Material();
		material.Read("material 1\nnormalMap \"Textures/bumps.png\"\nocclusionMap \"Textures/dirt.png\"\n");
		Check(Textures.KindOf("Textures/bumps.png") == .Normal && Textures.KindOf("Textures/dirt.png") == .Data, "a material's normal map is a normal map whatever its name, its occlusion map data");

		// ---- quality ----
		Check(Textures.SkipLevels == 0 && (Gfx.ResetFlags & (uint32)bgfx.ResetFlags.Maxanisotropy) != 0, "the engine starts at full texture detail with anisotropic filtering");
		Quality.Set(.Low);
		Check(Textures.SkipLevels == 1 && (Gfx.ResetFlags & (uint32)bgfx.ResetFlags.Maxanisotropy) == 0, "Low halves textures and turns anisotropic filtering off");
		Quality.Set(.High);
		Check(Textures.SkipLevels == 0 && (Gfx.ResetFlags & (uint32)bgfx.ResetFlags.Maxanisotropy) != 0, "High puts them back");
		let text = scope String();
		var custom = Quality.Preset(.High);
		custom.textureDetail = 2;
		custom.anisotropic = false;
		Quality.Write(custom, text);
		Check(Quality.Read(text, .()) == custom, "texture detail and anisotropic filtering are saved with the other settings");

		Console.WriteLine(scope $"\n{sFailures} failure(s)");
		return sFailures == 0 ? 0 : 1;
	}
}
