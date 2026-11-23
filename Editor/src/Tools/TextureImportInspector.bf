using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// One picture's texture options (tallowengine.com/docs/textures), kept beside it as "<picture>.import" and read by the engine when
/// it loads the picture.
class TextureImportSettings
{
	public TextureFilter filter = .Default;
	public TextureWrap wrap = .Repeat;
	public bool mipmaps = true;
	public bool compression = true;
	public bool fullResolution;

	/// The picture suffixes this applies to (the engine reads these as images).
	public static bool IsPicture(StringView path)
	{
		return path.EndsWith(".png", .OrdinalIgnoreCase) || path.EndsWith(".jpg", .OrdinalIgnoreCase) ||
			path.EndsWith(".jpeg", .OrdinalIgnoreCase) || path.EndsWith(".tga", .OrdinalIgnoreCase) ||
			path.EndsWith(".bmp", .OrdinalIgnoreCase) || path.EndsWith(".hdr", .OrdinalIgnoreCase) ||
			path.EndsWith(".exr", .OrdinalIgnoreCase);
	}

	public static void PathFor(StringView sourceFull, String outPath) => outPath.AppendF("{}.import", sourceFull);

	public void Read(StringView sourceFull)
	{
		let text = scope String();
		if (File.ReadAllText(PathFor(sourceFull, .. scope .()), text) case .Err)
			return;
		let options = TextureOptions.Parse(text);
		filter = options.Filter;
		wrap = options.Wrap;
		mipmaps = options.Mipmaps;
		compression = options.Compression;
		fullResolution = options.FullResolution;
	}

	public void Write(StringView sourceFull)
	{
		let text = scope String();
		text.AppendF("filter = {}\nwrap = {}\nmipmaps = {}\ncompression = {}\nfullResolution = {}\n",
			filter == .Nearest ? "nearest" : "default",
			wrap == .Clamp ? "clamp" : (wrap == .Mirror ? "mirror" : "repeat"),
			mipmaps ? 1 : 0, compression ? 1 : 0, fullResolution ? 1 : 0);
		File.WriteAllText(PathFor(sourceFull, .. scope .()), text).IgnoreError();
	}
}

/// The Inspector for a picture clicked in the Project panel: filtering, wrapping, mip levels, compressed copies and
/// full resolution, saved beside it and read again when the picture is next loaded (tallowengine.com/docs/textures).
extension EditorApp
{
	TextureImportSettings mTextureSettings ~ delete _;
	String mTextureSettingsPath = new .() ~ delete _;
	bool mTextureEdited;

	void LoadTextureSettings(StringView fullPath)
	{
		DeleteAndNullify!(mTextureSettings);
		mTextureSettings = new .();
		mTextureSettings.Read(fullPath);
		mTextureSettingsPath.Set(fullPath);
		mTextureEdited = false;
	}

	void DrawTextureImportInspector(StringView fullPath)
	{
		if (mTextureSettings == null || mTextureSettingsPath != fullPath)
			LoadTextureSettings(fullPath);
		let relative = Assets.MakeRelative(fullPath, .. scope .());
		let name = Path.GetFileName(fullPath, .. scope .());
		ImGui.Text(scope $"{name}  (Texture)");
		ImGui.TextDisabled(relative.CStr());
		ImGui.Separator();

		let settings = mTextureSettings;
		int32 filter = (int32)settings.filter;
		ImGui.SetNextItemWidth(220);
		if (ImGui.BeginCombo("Filtering", filter == (int32)TextureFilter.Nearest ? "Nearest (crisp pixels)" : "Default (smooth, anisotropic)"))
		{
			if (ImGui.Selectable("Default (smooth, anisotropic)", filter == (int32)TextureFilter.Default))
			{
				settings.filter = TextureFilter.Default;
				mTextureEdited = true;
			}
			if (ImGui.Selectable("Nearest (crisp pixels)", filter == (int32)TextureFilter.Nearest))
			{
				settings.filter = TextureFilter.Nearest;
				mTextureEdited = true;
			}
			ImGui.EndCombo();
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Default filters between pixels and keeps slanted surfaces sharp (anisotropic).\nNearest takes each pixel as it is: pixel art stays blocky and crisp instead of blurring.");

		int32 wrap = (int32)settings.wrap;
		ImGui.SetNextItemWidth(220);
		let wrapName = wrap == (int32)TextureWrap.Clamp ? "Clamp" : (wrap == (int32)TextureWrap.Mirror ? "Mirror" : "Repeat");
		if (ImGui.BeginCombo("Wrapping", wrapName))
		{
			if (ImGui.Selectable("Repeat", wrap == (int32)TextureWrap.Repeat))
			{
				settings.wrap = TextureWrap.Repeat;
				mTextureEdited = true;
			}
			if (ImGui.Selectable("Clamp", wrap == (int32)TextureWrap.Clamp))
			{
				settings.wrap = TextureWrap.Clamp;
				mTextureEdited = true;
			}
			if (ImGui.Selectable("Mirror", wrap == (int32)TextureWrap.Mirror))
			{
				settings.wrap = TextureWrap.Mirror;
				mTextureEdited = true;
			}
			ImGui.EndCombo();
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Repeat tiles the picture; Clamp holds its edge colour past 0..1 (decals, UI, atlases that must not bleed); Mirror flips it each time it repeats.");

		if (ImGui.Checkbox("Mip levels", ref settings.mipmaps))
			mTextureEdited = true;
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Smaller copies down to 1 by 1, so far and slanted surfaces stay even.\nOff keeps the picture at full size when drawn small: pixel art stays crisp, but far surfaces may shimmer.");

		if (ImGui.Checkbox("Keep full resolution (quality settings do not shrink it)", ref settings.fullResolution))
			mTextureEdited = true;
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("A low Texture Detail quality setting leaves the largest mip levels out of textures.\nThis picture keeps them: pixel art and UI are always drawn at their full size.");

		if (ImGui.Checkbox("Use a compressed copy in builds", ref settings.compression))
			mTextureEdited = true;
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("A build makes BC1 / BC3 copies of pictures for the video memory.\nOff ships this picture as it is: for one whose pixels must stay exact (pixel art, masks made to be read in code).");

		ImGui.Dummy(.(0, 4));
		if (!mTextureEdited)
			ImGui.BeginDisabled();
		if (ImGui.Button("Apply"))
		{
			settings.Write(fullPath);
			mTextureEdited = false;
			// The picture loads again with the new options (every material naming it draws from the next frame).
			Assets.RemoveTexture(relative);
			AssetPreviews.Invalidate(fullPath);
		}
		ImGui.SameLine();
		if (ImGui.Button("Revert"))
			LoadTextureSettings(fullPath);
		if (!mTextureEdited)
			ImGui.EndDisabled();
		ImGui.Dummy(.(0, 6));
		ImGui.TextDisabled("Kept beside the picture as its .import file and used wherever it is drawn.");
	}
}
