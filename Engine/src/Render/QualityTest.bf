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
			Console.WriteLine(scope $"{Quality.Names[i]}: gpuDriven={GpuDriven.QualitySetting} pixelError={GpuDriven.PixelError} occlusion={GpuDriven.Occlusion} streamGeometry={GpuDriven.StreamGeometry} budgets MB geo/tex/vt={StreamingCore.Pool(.GeoPage).Budget >> 20}/{StreamingCore.Pool(.TextureMip).Budget >> 20}/{StreamingCore.Pool(.VtTile).Budget >> 20} fog on={RenderView.FogEnabled} tile={RenderView.FogTileSize} slices={RenderView.FogSlices} temporal={RenderView.FogTemporalAllowed} lights={RenderView.FogLocalLights}");
			Check(Quality.Level == level, "level is kept after Apply");
			Check(GpuDriven.QualitySetting == (i > 0), "GPU path off only on Low");
			Check(StreamingCore.Pool(.GeoPage).Budget == (int64)Quality.Current.geometryBudgetMB << 20, "geometry budget applied");
			Check(RenderView.FogEnabled == (i > 0), "volumetric fog off only on Low");
			Check(RenderView.FogTileSize == Quality.Current.fogTileSize && RenderView.FogSlices == Quality.Current.fogSlices
				&& RenderView.FogLocalLights == Quality.Current.fogLocalLights && RenderView.FogTemporalAllowed == Quality.Current.fogTemporal,
				"fog quality applied");
		}
		Quality.Set(.Ultra);
		Check(GpuDriven.PixelError == 0.75f && StreamingCore.Pool(.TextureMip).Budget == 2048L << 20, "Ultra: 0.75 px, 2048 MB textures");
		Check(RenderView.FogTileSize == 8 && RenderView.FogSlices == 128 && RenderView.FogLocalLights == 128 && RenderView.FogTemporalAllowed, "Ultra: finest fog grid, 128 lights, temporal");
		Check(RenderView.FogHistoryBlend == 0.95f, "Ultra: fog history blend 0.95");
		Quality.Set(.Low);
		Check(StreamingCore.Pool(.VtTile).Budget == 256L << 20, "Low: 256 MB virtual textures");
		Check(PhysicalSky.Quality == 0, "Low: smallest sky table");
		Check(!RenderView.FogEnabled && RenderView.FogTileSize == 16 && RenderView.FogSlices == 32 && RenderView.FogLocalLights == 0
			&& !RenderView.FogTemporalAllowed, "Low: volumetric fog off (the fallback's height fog and shafts)");
		Quality.Set(.Medium);
		Check(RenderView.FogEnabled && RenderView.FogTileSize == 16 && RenderView.FogSlices == 48 && RenderView.FogLocalLights == 16
			&& RenderView.FogTemporalAllowed, "Medium: 16 px, 48 slices, 16 lights, temporal");
		Quality.Set(.High);
		Check(RenderView.FogEnabled && RenderView.FogTileSize == 12 && RenderView.FogSlices == 64 && RenderView.FogLocalLights == 64
			&& RenderView.FogTemporalAllowed && RenderView.FogHistoryBlend == 0.9f, "High: 12 px, 64 slices, 64 lights, temporal");

		// Round trip: a changed value comes back, and Custom is reported.
		var v = Quality.Preset(.High);
		v.pixelError = 1.5f;
		v.gpuOcclusion = false;
		v.streamGeometry = false;
		v.geometryBudgetMB = 300;
		v.textureBudgetMB = 700;
		v.vtBudgetMB = 200;
		v.skyQuality = 2;
		v.volumetricFog = false;
		v.fogTileSize = 8;
		v.fogSlices = 128;
		v.fogTemporal = false;
		v.fogLocalLights = 24;
		let text = scope String();
		Quality.Write(v, text);
		let back = Quality.Read(text, .());
		Check(back == v, "quality file round trip");
		Check(Quality.LevelOf(back) == .Custom, "changed values are Custom");
		Check(back.fogTileSize == 8 && back.fogSlices == 128 && !back.fogTemporal && back.fogLocalLights == 24 && !back.volumetricFog,
			"fog settings round trip");

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
