using System;
using System.IO;

namespace Tallow;

/// `--quality-test`: switches each preset headless, prints the applied GPU-path and streaming values, and checks the
/// quality file round-trip.
static class QualityTest
{
	static int sFailed;

	static void Check(bool ok, StringView what)
	{
		if (!ok)
		{
			sFailed++;
			Console.WriteLine(scope $"FAIL: {what}");
		}
	}

	public static int Run()
	{
		StreamingCore.Start(0);
		for (int i < 4)
		{
			let level = (QualityLevel)i;
			Quality.Set(level);
			Console.WriteLine(scope $"{Quality.Names[i]}: gpuDriven={GpuDriven.QualitySetting} pixelError={GpuDriven.PixelError} occlusion={GpuDriven.Occlusion} streamGeometry={GpuDriven.StreamGeometry} budgets MB geo/tex/vt={StreamingCore.Pool(.GeoPage).Budget >> 20}/{StreamingCore.Pool(.TextureMip).Budget >> 20}/{StreamingCore.Pool(.VtTile).Budget >> 20}");
			Check(Quality.Level == level, "level is kept after Apply");
			Check(GpuDriven.QualitySetting == (i > 0), "GPU path off only on Low");
			Check(StreamingCore.Pool(.GeoPage).Budget == (int64)Quality.Current.geometryBudgetMB << 20, "geometry budget applied");
		}
		Quality.Set(.Ultra);
		Check(GpuDriven.PixelError == 0.75f && StreamingCore.Pool(.TextureMip).Budget == 2048L << 20, "Ultra: 0.75 px, 2048 MB textures");
		Quality.Set(.Low);
		Check(StreamingCore.Pool(.VtTile).Budget == 256L << 20, "Low: 256 MB virtual textures");
		Check(PhysicalSky.Quality == 0, "Low: smallest sky table");

		// Round trip: a changed value comes back, and Custom is reported.
		var v = Quality.Preset(.High);
		v.pixelError = 1.5f;
		v.gpuOcclusion = false;
		v.streamGeometry = false;
		v.geometryBudgetMB = 300;
		v.textureBudgetMB = 700;
		v.vtBudgetMB = 200;
		v.skyQuality = 2;
		let text = scope String();
		Quality.Write(v, text);
		let back = Quality.Read(text, .());
		Check(back == v, "quality file round trip");
		Check(Quality.LevelOf(back) == .Custom, "changed values are Custom");

		// The command line wins.
		GpuDriven.PixelErrorFromArgs = true;
		GpuDriven.PixelError = 3;
		Quality.Set(.Ultra);
		Check(GpuDriven.PixelError == 3, "--gpu-pixel-error wins over the preset");
		GpuDriven.PixelErrorFromArgs = false;
		StreamingCore.Stop();
		Console.WriteLine(sFailed == 0 ? "quality-test: passed" : scope $"quality-test: {sFailed} failed");
		return sFailed == 0 ? 0 : 1;
	}
}
