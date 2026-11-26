using System;

namespace Tallow;

/// Immediate-mode canvas drawing for C# games: the pieces a menu's `ondraw` handler (or a script's OnGUI) needs to
/// paint the game's own artwork, custom fonts and HUD into the interface. Window pixels, from the top left.
/// Together with Tallow.API's UIElement.ScreenX/Y/Width/Height/Scale a document's canvas can be drawn exactly.
[CSharpExpose]
static class CSharpCanvas
{
	static Color ToColor(Vector4 color) => .(color.x, color.y, color.z, color.w);

	/// The game view's origin (x, y) and size (width, height) in window pixels.
	[CSharpExpose]
	public static void ScreenRect(Span<float> values)
	{
		if (values.Length < 4)
			return;
		let origin = GUI.Origin;
		values[0] = origin.x;
		values[1] = origin.y;
		values[2] = GUI.Width;
		values[3] = GUI.Height;
	}

	/// Paints an image (a project path, or "builtin:white") into a rectangle.
	[CSharpExpose]
	public static void DrawImage(StringView path, float minX, float minY, float maxX, float maxY, Vector4 tint, bool opaque)
	{
		let texture = Assets.GetTexture(path);
		ImGui.DrawImage(texture.idx, .(minX, minY), .(maxX, maxY), ToColor(tint), opaque);
	}

	/// Paints an image turned about its middle; angle in radians.
	[CSharpExpose]
	public static void DrawImageRotated(StringView path, float centerX, float centerY, float width, float height, float angle)
	{
		let texture = Assets.GetTexture(path);
		ImGui.DrawImageRotated(texture.idx, .(centerX, centerY), .(width, height), angle);
	}

	[CSharpExpose]
	public static void DrawRectFilled(float minX, float minY, float maxX, float maxY, Vector4 color, float rounding) =>
		ImGui.DrawRectFilled(.(minX, minY), .(maxX, maxY), ToColor(color), rounding);

	[CSharpExpose]
	public static void DrawRect(float minX, float minY, float maxX, float maxY, Vector4 color, float rounding, float thickness) =>
		ImGui.DrawRect(.(minX, minY), .(maxX, maxY), ToColor(color), rounding, thickness);

	[CSharpExpose]
	public static void DrawLine(float ax, float ay, float bx, float by, Vector4 color, float thickness) =>
		ImGui.DrawLine(.(ax, ay), .(bx, by), ToColor(color), thickness);

	[CSharpExpose]
	public static void DrawTriangle(float ax, float ay, float bx, float by, float cx, float cy, Vector4 color) =>
		ImGui.DrawTriangleFilled(.(ax, ay), .(bx, by), .(cx, cy), ToColor(color));

	/// Limits what is drawn next to a rectangle until PopClip.
	[CSharpExpose]
	public static void PushClip(float minX, float minY, float maxX, float maxY) =>
		ImGui.PushClipRect(.(minX, minY), .(maxX, maxY));

	[CSharpExpose]
	public static void PopClip() => ImGui.PopClipRect();

	/// Switches to the interface's font at a pixel size until PopFont.
	[CSharpExpose]
	public static void PushFontSize(float size) => ImGui.PushFontSize(size);

	[CSharpExpose]
	public static void PopFont() => ImGui.PopFont();

	/// The width and height a line of text takes in the current font.
	[CSharpExpose]
	public static void TextSize(StringView text, Span<float> values)
	{
		if (values.Length < 2)
			return;
		let size = ImGui.CalcStringSize(text);
		values[0] = size.x;
		values[1] = size.y;
	}

	[CSharpExpose]
	public static void DrawText(float x, float y, Vector4 color, StringView text)
	{
		let copy = scope String(text);
		ImGui.DrawText(.(x, y), ToColor(color), copy.CStr());
	}

	/// ImGui's input capture flags: bit 2 (4) is set while a text box has the keyboard.
	[CSharpExpose]
	public static int32 CaptureFlags() => ImGui.tn_imgui_capture_flags();

	/// Whether any interface item is being worked (a text box mostly).
	[CSharpExpose]
	public static bool AnyItemActive() => ImGui.IsAnyItemActive();

	/// The editor's move/turn/size handles over a rectangle of the window.
	[CSharpExpose]
	public static void GizmoBegin(float x, float y, float width, float height, bool orthographic) =>
		ImGui.tn_gizmo_begin(x, y, width, height, orthographic);

	/// Works the handles. data holds the camera view (16), its projection (16), and the object's world matrix
	/// (16, written back), then a snap step for each axis (3; all zero turns snapping off). True on a change.
	[CSharpExpose]
	public static bool GizmoManipulate(Span<float> data, int32 operation, bool local)
	{
		if (data.Length < 51)
			return false;
		float* matrix = (float*)data.Ptr + 32;
		float* snap = (float*)data.Ptr + 48;
		bool snapping = data[48] > 0 || data[49] > 0 || data[50] > 0;
		return ImGui.tn_gizmo_manipulate((float*)data.Ptr, (float*)data.Ptr + 16, operation, local, matrix,
			snapping ? snap : null);
	}

	[CSharpExpose]
	public static bool GizmoUsing() => ImGui.tn_gizmo_is_using();

	[CSharpExpose]
	public static bool GizmoOver() => ImGui.tn_gizmo_is_over();

	/// The camera's view and projection (16 + 16 floats) for a picture's width-to-height ratio.
	[CSharpExpose]
	public static bool CameraViewProjection(uint64 session, uint64 entity, float aspect, Span<float> values)
	{
		if (values.Length < 32)
			return false;
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		if (obj == null || !obj.HasComponent<Camera>())
			return false;
		let data = obj.GetComponent<Camera>().GetCameraData(aspect);
		for (int i < 16)
		{
			values[i] = data.view.m[i];
			values[16 + i] = data.projection.m[i];
		}
		return true;
	}
}
