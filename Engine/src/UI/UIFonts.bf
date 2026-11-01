using System;
using System.Collections;

namespace Tallow;

/// Fonts for game interfaces: a UI document's `font-family: Fonts/Title.ttf` (inherited like font-size), or from
/// code in a Component's OnGUI:
///
///   UIFonts.Push("Fonts/Title.ttf", 48);
///   GUI.Label(20, 20, "Night 1");
///   ImGui.PopFont();
///
/// A font is read once (a .ttf or .otf file in the project's assets) and kept. A font that cannot be read, or an
/// empty name, is the interface's own font.
static class UIFonts
{
	static Dictionary<String, int> sFonts = new .() ~ DeleteDictionaryAndKeys!(_);

	/// The ImGui font for a file, or null.
	public static void* Find(StringView path)
	{
		if (path.IsEmpty)
			return null;
		if (sFonts.TryGetValueAlt(path, let found))
			return (void*)found;
		let data = scope List<uint8>();
		void* font = null;
		if (Assets.ReadBytes(path, data))
			font = ImGui.tn_imgui_add_font(data.Ptr, (int32)data.Count);
		if (font == null)
			Log.Warning(scope $"Font {path} could not be read; the interface's own font is used.");
		sFonts[new String(path)] = (int)font;
		return font;
	}

	/// Pushes a font at a size (ImGui.PopFont pops it). The interface's own font when path is empty or unreadable.
	public static void Push(StringView path, float size)
	{
		let font = Find(path);
		if (font != null)
			ImGui.tn_imgui_push_font(font, size);
		else
			ImGui.PushFontSize(size);
	}
}
