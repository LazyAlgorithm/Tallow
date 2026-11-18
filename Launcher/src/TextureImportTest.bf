using System;
using Bgfx;
using Tallow;

namespace Tallow.Launcher;

/// --texture-import-test: a picture's own texture options (docs/textures.md) parse, default and become the sampler
/// flags they should, without a window or a project.
static class TextureImportTest
{
	public static int Run()
	{
		int failures = 0;
		void Expect(bool ok, StringView what)
		{
			if (ok)
				Console.WriteLine(scope $"PASS {what}");
			else
			{
				Console.WriteLine(scope $"FAIL {what}");
				failures++;
			}
		}

		let defaults = TextureOptions.Parse("");
		Expect(defaults.Filter == .Default && defaults.Wrap == .Repeat && defaults.Mipmaps && defaults.Compression &&
			!defaults.FullResolution, "no .import: engine defaults");
		let defaultFlags = defaults.SamplerFlags(true);
		Expect((defaultFlags & (uint64)bgfx.SamplerFlags.MinAnisotropic) != 0 &&
			(defaultFlags & (uint64)bgfx.SamplerFlags.MagAnisotropic) != 0, "default filtering is anisotropic");
		Expect((defaultFlags & ((uint64)bgfx.SamplerFlags.UClamp | (uint64)bgfx.SamplerFlags.VClamp |
			(uint64)bgfx.SamplerFlags.WClamp)) == 0, "default wrapping repeats");

		let pixel = TextureOptions.Parse("filter = nearest\nwrap = clamp\nmipmaps = 0\ncompression = 0\nfullResolution = 1\n");
		Expect(pixel.Filter == .Nearest && pixel.Wrap == .Clamp && !pixel.Mipmaps && !pixel.Compression &&
			pixel.FullResolution, "every key is read");
		let pixelFlags = pixel.SamplerFlags(true);
		Expect((pixelFlags & (uint64)bgfx.SamplerFlags.MinPoint) != 0 &&
			(pixelFlags & (uint64)bgfx.SamplerFlags.MagPoint) != 0 &&
			(pixelFlags & (uint64)bgfx.SamplerFlags.MipPoint) != 0, "nearest filtering takes each pixel");
		Expect((pixelFlags & (uint64)bgfx.SamplerFlags.UClamp) != 0 &&
			(pixelFlags & (uint64)bgfx.SamplerFlags.VClamp) != 0, "clamp wrapping");
		Expect((pixel.SamplerFlags(false) & (uint64)bgfx.SamplerFlags.MipPoint) == 0,
			"without mip levels there is no mip sampling mode");

		let mirror = TextureOptions.Parse("wrap = mirror\n");
		Expect(mirror.Wrap == .Mirror && (mirror.SamplerFlags(true) & (uint64)bgfx.SamplerFlags.UMirror) != 0,
			"mirror wrapping");
		let unknown = TextureOptions.Parse("filter = nearest\nsomething = 3\n");
		Expect(unknown.Filter == .Nearest && unknown.Mipmaps && unknown.Compression, "unknown keys are ignored");

		if (failures == 0)
		{
			Console.WriteLine("Texture import test passed.");
			return 0;
		}
		Console.WriteLine(scope $"Texture import test failed ({failures}).");
		return 1;
	}
}
