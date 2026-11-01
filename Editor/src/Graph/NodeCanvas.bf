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

	public void DrawLink(ImGui.Vec2 a, ImGui.Vec2 b, Color color) => NodeCanvas.DrawLink(a, b, color, zoom);
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

	public static Color CategoryColor(StringView category)
	{
		switch (category)
		{
		case "Events": return .(0.62f, 0.22f, 0.22f, 1);
		case "Flow": return .(0.40f, 0.40f, 0.44f, 1);
		case "Transform","Object": return .(0.20f, 0.42f, 0.66f, 1);
		case "Code": return .(0.50f, 0.34f, 0.66f, 1);
		case "Subgraph","Subgraphs": return .(0.70f, 0.44f, 0.20f, 1);
		case "Input","Time": return .(0.22f, 0.50f, 0.48f, 1);
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

	public static void DrawLink(ImGui.Vec2 a, ImGui.Vec2 b, Color color, float zoom, bool vertical = false)
	{
		let reach = Math.Max(Math.Abs(vertical ? b.y - a.y : b.x - a.x) * 0.5f, 30 * zoom);
		ImDrawList_AddBezierCubic(igGetWindowDrawList(), a, vertical ? .(a.x, a.y + reach) : .(a.x + reach, a.y), vertical ? .(b.x, b.y - reach) : .(b.x - reach, b.y), b, color.ToABGR(), Math.Max(2.2f * zoom, 1), 24);
	}
}
