using System;
using Tallow;

namespace Tallow.Editor;

/// A pannable, zoomable canvas filling the rest of a window (the graph, animator and behaviour tree editors): where
/// it is on screen this frame and how its space maps onto the screen.
struct CanvasView
{
	[CLink] static extern void* igGetWindowDrawList();

	public ImGui.Vec2 origin;
	public ImGui.Vec2 size;
	public ImGui.Vec2 mouse;
	public Vector2 pan;
	public float zoom;
	public bool hovered;
	public void* drawList;

	/// Lays the canvas out over the rest of the window (an invisible button that takes the mouse), lets the wheel
	/// zoom it and the middle button pan it, and draws its grid.
	public static CanvasView Begin(char8* id, ref Vector2 pan, ref float zoom)
	{
		var view = Layout(id);
		view.Update(ref pan, ref zoom);
		return view;
	}

	/// The first half of Begin: lays the canvas out, without touching the view yet.
	public static CanvasView Layout(char8* id)
	{
		CanvasView view = default;
		view.origin = ImGui.GetCursorScreenPos();
		view.size = ImGui.GetContentRegionAvail();
		ImGui.InvisibleButton(id, .(Math.Max(view.size.x, 1), Math.Max(view.size.y, 1)));
		view.hovered = ImGui.IsItemHovered();
		view.mouse = ImGui.GetMousePos();
		view.drawList = igGetWindowDrawList();
		return view;
	}

	/// The second half of Begin: zooms and pans the view with the mouse, and draws the grid.
	public void Update(ref Vector2 pan, ref float zoom) mut
	{
		NodeCanvas.UpdateView(ref pan, ref zoom, origin, mouse, hovered);
		this.pan = pan;
		this.zoom = zoom;
		NodeCanvas.DrawGrid(origin, size, pan, zoom);
	}

	public ImGui.Vec2 ToScreen(Vector2 p) => .(origin.x + pan.x + p.x * zoom, origin.y + pan.y + p.y * zoom);

	public Vector2 ToGraph(ImGui.Vec2 p) => .((p.x - origin.x - pan.x) / zoom, (p.y - origin.y - pan.y) / zoom);

	public Vector2 GraphMouse => ToGraph(mouse);

	public void DrawLink(ImGui.Vec2 a, ImGui.Vec2 b, Color color, float thickness = 2.2f) => NodeCanvas.DrawLink(a, b, color, zoom, false, thickness);
}

/// Shared visual language and view transforms for script graphs.
static class NodeCanvas
{
	[CLink] static extern void* igGetWindowDrawList();
	[CLink] static extern void ImDrawList_AddBezierCubic(void* list, ImGui.Vec2 a, ImGui.Vec2 b, ImGui.Vec2 c, ImGui.Vec2 d, uint32 color, float thickness, int32 segments);
	[CLink] static extern void igPushFont(void* font, float size);
	public static ImGui.Vec2 ToScreen(Vector2 p, ImGui.Vec2 origin, Vector2 pan, float zoom) => .(origin.x + pan.x + p.x * zoom, origin.y + pan.y + p.y * zoom);
	public static Vector2 ToGraph(ImGui.Vec2 p, ImGui.Vec2 origin, Vector2 pan, float zoom) => .((p.x - origin.x - pan.x) / zoom, (p.y - origin.y - pan.y) / zoom);
	public static Vector2 CenterNode(ImGui.Vec2 size, Vector2 pan, float zoom) => .((size.x * 0.5f - pan.x) / zoom - 95, (size.y * 0.5f - pan.y) / zoom - 30);
	public static void ZoomAt(ref Vector2 pan, ref float zoom, ImGui.Vec2 origin, ImGui.Vec2 mouse, float wheel)
	{
		let under = ToGraph(mouse, origin, pan, zoom);
		zoom = Mathf.Clamp(zoom * Math.Pow(1.12f, wheel), 0.25f, 2.5f);
		pan = .(mouse.x - origin.x - under.x * zoom, mouse.y - origin.y - under.y * zoom);
	}

	public static void UpdateView(ref Vector2 pan, ref float zoom, ImGui.Vec2 origin, ImGui.Vec2 mouse, bool hovered)
	{
		if (!hovered) return;
		if (Input.MouseWheel != 0)
			ZoomAt(ref pan, ref zoom, origin, mouse, Input.MouseWheel);
		if (ImGui.IsMouseDown(2))
			pan += Input.MouseDelta;
	}

	public static void DrawGrid(ImGui.Vec2 origin, ImGui.Vec2 size, Vector2 pan, float zoom)
	{
		ImGui.DrawRectFilled(origin, .(origin.x + size.x, origin.y + size.y), .(0.13f, 0.13f, 0.14f, 1));
		for (int level < 2)
		{
			let step = (level == 0 ? 32.0f : 160.0f) * zoom;
			if (step < 8) continue;
			let color = level == 0 ? Color(1, 1, 1, 0.045f) : Color(1, 1, 1, 0.10f);
			for (float x = pan.x % step; x < size.x; x += step)
				ImGui.DrawLine(.(origin.x + x, origin.y), .(origin.x + x, origin.y + size.y), color);
			for (float y = pan.y % step; y < size.y; y += step)
				ImGui.DrawLine(.(origin.x, origin.y + y), .(origin.x + size.x, origin.y + y), color);
		}
	}

	public static Color CategoryColor(StringView categoryPath)
	{
		// By top-level category ("Math" for "Math|Float").
		let bar = categoryPath.IndexOf('|');
		let category = bar < 0 ? categoryPath : categoryPath.Substring(0, bar);
		switch (category)
		{
		case "Events","Add Event": return .(0.62f, 0.22f, 0.22f, 1);
		case "Flow","Flow Control": return .(0.40f, 0.40f, 0.44f, 1);
		case "Transform","Object","Transformation","Game","Physics","Collision","Audio": return .(0.20f, 0.42f, 0.66f, 1);
		case "Code","My Scripts": return .(0.50f, 0.34f, 0.66f, 1);
		case "Subgraph","Subgraphs": return .(0.70f, 0.44f, 0.20f, 1);
		case "Input","Time","Networking": return .(0.22f, 0.50f, 0.48f, 1);
		default: return .(0.26f, 0.48f, 0.30f, 1);
		}
	}

	public static void BeginFont(float zoom)
	{
		// Stable integer font sizes avoid baking a different atlas size for every fractional wheel step.
		igPushFont(null, Math.Max((float)Math.Round(15 * zoom), 4));
	}

	public static void EndFont() => ImGui.PopFont();
	public static void DrawNode(ImGui.Vec2 min, ImGui.Vec2 max, Color header, bool selected, float zoom, Color border = .(0, 0, 0, 0.8f))
	{
		ImGui.DrawRectFilled(.(min.x + 3, min.y + 4), .(max.x + 3, max.y + 4), .(0, 0, 0, 0.35f), 6 * zoom);
		ImGui.DrawRectFilled(min, max, .(0.20f, 0.20f, 0.22f, 0.98f), 6 * zoom);
		ImGui.DrawRectFilled(min, .(max.x, min.y + 26 * zoom), header, 6 * zoom);
		ImGui.DrawRect(min, max, selected ? Color(1, 0.70f, 0.20f, 1) : border, 6 * zoom, selected ? 2 : 1);
		if (selected && border != Color(0, 0, 0, 0.8f))
			ImGui.DrawRect(.(min.x - 3, min.y - 3), .(max.x + 3, max.y + 3), border, 6 * zoom, 2);
	}

	public static void DrawLink(ImGui.Vec2 a, ImGui.Vec2 b, Color color, float zoom, bool vertical = false, float thickness = 2.2f)
	{
		LinkControls(a, b, zoom, vertical, let c1, let c2);
		ImDrawList_AddBezierCubic(igGetWindowDrawList(), a, c1, c2, b, color.ToABGR(), Math.Max(thickness * zoom, 1), 24);
	}

	/// The curve's two middle control points, as DrawLink draws it.
	static void LinkControls(ImGui.Vec2 a, ImGui.Vec2 b, float zoom, bool vertical, out ImGui.Vec2 c1, out ImGui.Vec2 c2)
	{
		let reach = Math.Max(Math.Abs(vertical ? b.y - a.y : b.x - a.x) * 0.5f, 30 * zoom);
		c1 = vertical ? .(a.x, a.y + reach) : .(a.x + reach, a.y);
		c2 = vertical ? .(b.x, b.y - reach) : .(b.x - reach, b.y);
	}

	/// How far a point is from a link's curve, in pixels.
	public static float LinkDistance(ImGui.Vec2 a, ImGui.Vec2 b, ImGui.Vec2 point, float zoom, bool vertical = false)
	{
		LinkControls(a, b, zoom, vertical, let c1, let c2);
		ImGui.Vec2 At(float t)
		{
			let u = 1 - t;
			let w0 = u * u * u, w1 = 3 * u * u * t, w2 = 3 * u * t * t, w3 = t * t * t;
			return .(a.x * w0 + c1.x * w1 + c2.x * w2 + b.x * w3, a.y * w0 + c1.y * w1 + c2.y * w2 + b.y * w3);
		}
		var best = float.MaxValue;
		var previous = a;
		for (int i = 1; i <= 24; i++)
		{
			let next = At(i / 24.0f);
			let dx = next.x - previous.x, dy = next.y - previous.y;
			let length = dx * dx + dy * dy;
			let t = length > 0 ? Math.Clamp(((point.x - previous.x) * dx + (point.y - previous.y) * dy) / length, 0, 1) : 0;
			let x = previous.x + dx * t - point.x, y = previous.y + dy * t - point.y;
			best = Math.Min(best, x * x + y * y);
			previous = next;
		}
		return Math.Sqrt(best);
	}
}
