using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// The modeller's palette tools (docs/modeling.md, Palette faces): for a model whose material is in palette mode,
/// each picked face is given a palette entry, a glow, a roughness and metallic (or an opacity) and flags, packed into
/// its vertex colour bytes as the palette shader reads them.
extension EditorApp
{
	int32 mPaletteFaceEntry = 0;
	int32 mPaletteFaceGlow = 0;
	int32 mPaletteFaceRoughness = 24;
	int32 mPaletteFaceMetallic = 0;
	int32 mPaletteFaceOpacity = 128;
	uint8 mPaletteFaceFlags = 0;

	/// The vertex colour the palette settings pack to.
	Color PaletteFaceColor
	{
		get
		{
			let transparent = (mPaletteFaceFlags & Mesh.PaletteTransparent) != 0;
			let surface = transparent ? mPaletteFaceOpacity : (Math.Clamp(mPaletteFaceRoughness, 0, 31) << 3) | Math.Clamp(mPaletteFaceMetallic, 0, 7);
			return .FromBytes((uint8)Math.Clamp(mPaletteFaceEntry, 0, 255), (uint8)Math.Clamp(mPaletteFaceGlow, 0, 255), (uint8)Math.Clamp(surface, 0, 255), mPaletteFaceFlags);
		}
	}

	/// Takes the settings from a face's colour (to copy one face's look to others).
	void ReadPaletteFace(Color color)
	{
		let packed = color.ToABGR();
		mPaletteFaceEntry = (int32)(packed & 0xFF);
		mPaletteFaceGlow = (int32)((packed >> 8) & 0xFF);
		let surface = (int32)((packed >> 16) & 0xFF);
		mPaletteFaceFlags = (uint8)(packed >> 24);
		if ((mPaletteFaceFlags & Mesh.PaletteTransparent) != 0)
			mPaletteFaceOpacity = surface;
		else
		{
			mPaletteFaceRoughness = surface >> 3;
			mPaletteFaceMetallic = surface & 7;
		}
	}

	void DrawPaletteFaces(ModelMesh model, EditMesh mesh)
	{
		let renderer = model.GameObject.GetComponent<MeshRenderer>();
		let material = renderer?.SharedMaterial;
		if (material == null || !material.IsPalette)
			return;
		ImGui.SeparatorText("Palette faces");
		// The palette, to pick an entry from.
		Color[Palettes.Size] colors = default;
		Palettes.Colors(material.PaletteFor(mScene.WorldState), ref colors);
		let origin = ImGui.GetCursorScreenPos();
		let cell = Math.Clamp((ImGui.GetContentRegionAvail().x - 4) / Palettes.Side, 8, 16);
		ImGui.InvisibleButton("##facepalette", .(cell * Palettes.Side, cell * Palettes.Side));
		let clicked = ImGui.IsItemHovered() && ImGui.IsMouseClicked(0);
		let mouse = ImGui.GetMousePos();
		for (int32 i < Palettes.Size)
		{
			let x = origin.x + (i % Palettes.Side) * cell;
			let y = origin.y + (i / Palettes.Side) * cell;
			ImGui.DrawRectFilled(.(x, y), .(x + cell - 1, y + cell - 1), colors[i]);
			if (i == mPaletteFaceEntry)
				ImGui.DrawRect(.(x - 1, y - 1), .(x + cell, y + cell), .White, 0, 2);
			if (clicked && mouse.x >= x && mouse.x < x + cell && mouse.y >= y && mouse.y < y + cell)
				mPaletteFaceEntry = i;
		}
		ImGui.SetNextItemWidth(-140);
		ImGui.DragInt("Entry", ref mPaletteFaceEntry, 0.2f, 0, 255);
		ImGui.SetNextItemWidth(-140);
		ImGui.DragInt("Glow", ref mPaletteFaceGlow, 1, 0, 255);
		bool Flag(char8* label, uint8 bit)
		{
			var on = (mPaletteFaceFlags & bit) != 0;
			if (!ImGui.Checkbox(label, ref on))
				return false;
			mPaletteFaceFlags = on ? (mPaletteFaceFlags | bit) : (mPaletteFaceFlags & ~bit);
			return true;
		}
		if ((mPaletteFaceFlags & Mesh.PaletteTransparent) != 0)
		{
			ImGui.SetNextItemWidth(-140);
			ImGui.DragInt("Opacity", ref mPaletteFaceOpacity, 1, 0, 255);
		}
		else
		{
			ImGui.SetNextItemWidth(-140);
			ImGui.DragInt("Roughness (0-31)", ref mPaletteFaceRoughness, 0.1f, 0, 31);
			ImGui.SetNextItemWidth(-140);
			ImGui.DragInt("Metallic (0-7)", ref mPaletteFaceMetallic, 0.05f, 0, 7);
		}
		Flag("Unlit", Mesh.PaletteUnlit);
		ImGui.SameLine();
		Flag("Transparent", Mesh.PaletteTransparent);
		ImGui.SameLine();
		Flag("Double Sided", Mesh.PaletteDoubleSided);
		Flag("Cutout", Mesh.PaletteCutout);
		ImGui.SameLine();
		Flag("Hologram", Mesh.PaletteHologram);
		ImGui.SameLine();
		Flag("Pulse", Mesh.PaletteAnimatedGlow);
		Flag("Dissolve", Mesh.PaletteDissolve);
		if (HalfButton("Paint Faces"))
			ModelFaceAction(model, mesh, .Palette);
		if (HalfButton("Copy From Face", true))
		{
			for (let f in mModelFaces)
			{
				if (f >= 0 && f < mesh.faces.Count && mesh.faces[f].colors.Count > 0)
				{
					ReadPaletteFace(mesh.faces[f].colors[0]);
					break;
				}
			}
		}
	}
}
