using System;

namespace Tallow;

/// DebugDraw and Gizmos for C# scripts (generated wrappers in Tallow.API).
/// layer 0: DebugDraw (game and editor, this frame); 1: Gizmos (Scene view only); 2: Gizmos drawn on top.
[CSharpExpose]
static class CSharpDraw
{
	static LineBatch Batch(int32 layer)
	{
		switch (layer)
		{
		case 1: return Gizmos.Lines;
		case 2: return Gizmos.OnTopLines;
		default: return DebugDraw.Lines;
		}
	}

	static Color ToColor(Vector4 color) => .(color.x, color.y, color.z, color.w);

	/// A line from a to b.
	[CSharpExpose]
	public static void Line(int32 layer, Vector3 a, Vector3 b, Vector4 color) => Batch(layer).Line(a, b, ToColor(color));

	/// A sphere's outline.
	[CSharpExpose]
	public static void Sphere(int32 layer, Vector3 center, float radius, Vector4 color) => Batch(layer).Sphere(center, radius, ToColor(color));

	/// A box's edges, by its center and size.
	[CSharpExpose]
	public static void Box(int32 layer, Vector3 center, Vector3 size, Vector4 color) =>
		Batch(layer).Box(.(center - size * 0.5f, center + size * 0.5f), ToColor(color));
}
