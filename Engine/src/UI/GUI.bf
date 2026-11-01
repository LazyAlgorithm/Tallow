using System;

namespace Tallow;

/// Immediate-mode interface for games. Call from Component.OnGUI. Coordinates are pixels from
/// the top-left of the game view; use GUI.Width / GUI.Height to anchor to the other edges.
///
///   public override void OnGUI()
///   {
///       GUI.Label(20, 20, scope $"Health {health}");
///       GUI.Bar(20, 44, 200, 14, health / 100.0f, .Red);
///       if (GUI.Button(GUI.Width - 140, 20, 120, 32, "Respawn")) Respawn();
///   }
static class GUI
{
	static ImGui.Vec2 sOrigin;
	static int32 sCounter;

	/// Screen position of the game view's top-left corner.
	public static ImGui.Vec2 Origin => sOrigin;
	public static float Width;
	public static float Height;
	/// Logical UI units (SDL window points), independent of the physical render resolution.
	public static float LogicalWidth => Width;
	public static float LogicalHeight => Height;
	/// Current view aspect ratio; changes naturally on window resize or phone rotation.
	public static float AspectRatio => Height > 0 ? Width / Height : 1;
	public static bool IsPortrait => Height > Width;
	public static bool IsLandscape => Width >= Height;
	/// Physical framebuffer pixels per logical UI point. Do not multiply UI positions by this value.
	public static float PixelRatio => Application.Instance != null && Width > 0 ? (float)Application.Instance.Width / Width : 1;
	/// True while the mouse is over a GUI control, so gameplay can ignore the click.
	public static bool MouseOverControl;

	/// Runs every component's OnGUI inside the ImGui window that is currently open.
	public static void Run(Scene scene, ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		sOrigin = origin;
		Width = size.x;
		Height = size.y;
		sCounter = 0;
		MouseOverControl = false;
		for (int i = 0; i < scene.Components.Count; i++)
		{
			let component = scene.Components[i];
			if (component.IsAwake && component.IsActiveAndEnabled)
				component.OnGUI();
		}
		Subtitles.Draw();
		Achievements.DrawToasts();
	}

	static ImGui.Vec2 At(float x, float y) => .(sOrigin.x + x, sOrigin.y + y);

	public static void Label(float x, float y, StringView text, Color color = .White)
	{
		// A one pixel shadow keeps text readable over bright scenery.
		let cstr = scope String(text).CStr();
		ImGui.DrawText(At(x + 1, y + 1), .(0, 0, 0, color.a * 0.7f), cstr);
		ImGui.DrawText(At(x, y), color, cstr);
	}

	public static void Box(float x, float y, float width, float height, Color color)
	{
		ImGui.DrawRectFilled(At(x, y), At(x + width, y + height), color, 4);
	}

	/// Progress or health bar; fraction is 0..1.
	public static void Bar(float x, float y, float width, float height, float fraction, Color color)
	{
		ImGui.DrawRectFilled(At(x, y), At(x + width, y + height), .(0, 0, 0, 0.55f), 3);
		let fill = Mathf.Clamp01(fraction) * (width - 4);
		if (fill > 0)
			ImGui.DrawRectFilled(At(x + 2, y + 2), At(x + 2 + fill, y + height - 2), color, 2);
	}

	public static bool Button(float x, float y, float width, float height, StringView label)
	{
		ImGui.SetCursorScreenPos(At(x, y));
		ImGui.PushID(sCounter++);
		let pressed = ImGui.Button(scope String(label).CStr(), .(width, height));
		if (ImGui.IsItemHovered())
			MouseOverControl = true;
		ImGui.PopID();
		return pressed;
	}

	/// Single-line text box. Returns true when the text changed.
	public static bool TextField(float x, float y, float width, String text)
	{
		ImGui.SetCursorScreenPos(At(x, y));
		ImGui.PushID(sCounter++);
		ImGui.SetNextItemWidth(width);
		let changed = ImGui.InputText("##field", text);
		if (ImGui.IsItemHovered() || ImGui.IsItemActive())
			MouseOverControl = true;
		ImGui.PopID();
		return changed;
	}

	public static bool Toggle(float x, float y, StringView label, ref bool value)
	{
		ImGui.SetCursorScreenPos(At(x, y));
		ImGui.PushID(sCounter++);
		let changed = ImGui.Checkbox(scope String(label).CStr(), ref value);
		if (ImGui.IsItemHovered())
			MouseOverControl = true;
		ImGui.PopID();
		return changed;
	}

	public static bool Slider(float x, float y, float width, StringView label, ref float value, float min, float max)
	{
		ImGui.SetCursorScreenPos(At(x, y));
		ImGui.PushID(sCounter++);
		ImGui.SetNextItemWidth(width);
		let changed = ImGui.SliderFloat(scope String(label).CStr(), ref value, min, max);
		if (ImGui.IsItemHovered() || ImGui.IsItemActive())
			MouseOverControl = true;
		ImGui.PopID();
		return changed;
	}
}
