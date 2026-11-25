using System;

namespace Tallow;

/// The GPU-driven renderer's settings and statistics for C# scripts (GpuDriven in Tallow.API). Stat ids match the
/// GpuDrivenStat enum there.
[CSharpExpose]
static class CSharpGpuDriven
{
	/// Whether this device and renderer can draw clusters on the graphics card at all.
	[CSharpExpose]
	public static bool Available() => GpuDriven.Available;

	/// Whether big meshes are being drawn that way now (available and not switched off).
	[CSharpExpose]
	public static bool Enabled() => GpuDriven.Enabled;

	/// The debug view in use (GpuDriven.DebugView), and which level of the occlusion pyramid the Hzb view shows.
	[CSharpExpose]
	public static int32 DebugView() => (int32)GpuDriven.View;

	[CSharpExpose]
	public static bool SetDebugView(int32 view, int32 mip)
	{
		if (view < 0 || view > (int32)GpuDriven.DebugView.VtPages)
			return false;
		GpuDriven.View = (GpuDriven.DebugView)view;
		GpuDriven.DebugMip = Math.Max(0, mip);
		return true;
	}

	[CSharpExpose]
	public static int32 DebugMip() => GpuDriven.DebugMip;

	/// One statistic: 0 clusters drawn, 1 triangles drawn, 2 instances (this frame), 3 draws (bins), 4 clusters lost to a
	/// full budget, 5 resident geometry MB, 6 resident texture MB, 7 resident virtual texture MB, 8 pool MB in use.
	/// Cluster and triangle counts are read back from the graphics card a few frames late.
	[CSharpExpose]
	public static double Stat(int32 id)
	{
		switch (id)
		{
		case 0: return (double)GpuDriven.Clusters;
		case 1: return (double)GpuDriven.Triangles;
		case 2: return (double)GpuDriven.FrameInstances;
		case 3: return (double)GpuDriven.FrameBins;
		case 4: return (double)GpuDriven.ClustersLost;
		case 5: return ResidentMB(.GeoPage);
		case 6: return ResidentMB(.TextureMip);
		case 7: return ResidentMB(.VtTile);
		case 8: return (double)GpuDriven.PoolWordsInUse * 4 / 1048576.0;
		default: return 0;
		}
	}

	static double ResidentMB(StreamKind kind)
	{
		let pool = StreamingCore.Pool(kind);
		return pool == null ? 0 : (double)pool.Resident / 1048576.0;
	}
}
