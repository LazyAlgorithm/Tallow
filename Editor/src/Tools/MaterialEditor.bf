using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Materials in the editor: creating them, compiling shaders, and the material's settings as the Inspector shows
/// them. Click a .tmat file in the Project panel, or select an object whose Mesh Renderer has a material.
extension EditorApp
{
	Material mMaterial;
	String mMaterialPath = new .() ~ delete _;
	bool mMaterialDirty;
	/// True when the Inspector shows the asset clicked in the Project panel rather than the selected object.
	bool mInspectAsset;
	uint32 mInspectedObject;
	List<String> mImageChoices = new .() ~ DeleteContainerAndItems!(_);
	List<String> mShaderChoices = new .() ~ DeleteContainerAndItems!(_);
	int mMaterialChoicesFrame = -1000;

	/// Shows a material in the Inspector. The path is a file on disk.
	public void OpenMaterial(StringView fullPath)
	{
		let relative = scope String();
		Assets.MakeRelative(fullPath, relative);
		let material = Material.Load(relative);
		if (material == null)
			return;
		// Shown in the Inspector, as if it had been clicked in the Project panel.
		mSelectedAsset.Set(fullPath);
		mInspectAsset = true;
	}

	bool ValidAssetName(StringView name, StringView what)
	{
		if (ProjectGenerator.IsValidName(name))
			return true;
		Log.Error(scope $"{what} names use letters, digits and underscores, and start with a letter.");
		return false;
	}

	void CreateMaterialAsset(StringView name)
	{
		let path = scope $"{mBrowsePath}/{name}.tmat";
		if (!ValidAssetName(name, "Material"))
			return;
		if (File.Exists(path))
		{
			Log.Error(scope $"{path} already exists.");
			return;
		}
		let relative = scope String();
		Assets.MakeRelative(path, relative);
		// Smooth shading suits most textured, shaped surfaces; the flat look is one tick away.
		let material = Material.Create(relative);
		material.Save(path);
		OpenMaterial(path);
	}

	void CreateShaderAsset(StringView name, bool compute)
	{
		if (!ValidAssetName(name, "Shader"))
			return;
		let path = scope $"{mBrowsePath}/{name}.{compute ? "tcompute" : "tshader"}";
		if (File.Exists(path))
		{
			Log.Error(scope $"{path} already exists.");
			return;
		}
		// Something that visibly works, to change from there.
		if (compute)
			File.WriteAllText(path, """
				// A compute shader: this code runs for every pixel of a texture, every step.
				// Read: pixel, size, uv (0 to 1), time, previous(uv) (the texture before this step).
				// Write: result (starts as this pixel's previous value).
				// Add a Compute Effect component to an object with a Mesh Renderer and pick this file.
				property float speed = 1
				property color ink = 0.2 0.6 1 1

				compute {
					// Fade what was there, and draw a ring that grows from the middle.
					float ring = abs(distance(uv, vec2(0.5, 0.5)) - fract(time * speed * 0.2) * 0.7);
					result = result * 0.96 + ink * smoothstep(0.02, 0.0, ring);
					result.a = 1.0;
				}

				""").IgnoreError();
		else
			File.WriteAllText(path, """
				// A surface shader: it says what the surface looks like; lighting, shadows and fog are added for you.
				// Read: uv, worldPosition, worldNormal, vertexColor, time, and texture2D(mainTexture, uv).
				// Change: albedo, alpha, metallic, roughness, emissive.
				// Properties appear in the Material window of every material that uses this shader.
				property float speed = 2
				property color glow = 1 0.5 0.2 1

				surface {
					float pulse = 0.5 + 0.5 * sin(time * speed + worldPosition.y * 4.0);
					emissive += glow.rgb * pulse;
				}

				// Optional: move the mesh's points. position is in the mesh's own space.
				vertex {
				}

				""").IgnoreError();
		let relative = scope String();
		Assets.MakeRelative(path, relative);
		CompileShader(relative);
		OpenScript(path);
	}

	/// Compiles a shader file and reports the outcome in the Console.
	bool CompileShader(StringView relativePath)
	{
		let log = scope String();
		let fine = ShaderCompiler.Compile(Project.Current.EngineRoot, relativePath, log);
		for (let line in log.Split('\n', .RemoveEmptyEntries))
		{
			if (line.Contains("other backends are unaffected"))
				Log.Warning(line);
			else
				Log.Error(line);
		}
		if (fine)
			Log.Info(scope $"Compiled {relativePath}.");
		AssetPreviews.InvalidateMaterials();
		return fine;
	}

	/// Compiles the shaders whose source is newer than what was built: at start-up and before a game is built.
	void CompileStaleShaders()
	{
		let log = scope String();
		let failed = ShaderCompiler.CompileProject(Project.Current.EngineRoot, log);
		for (let line in log.Split('\n', .RemoveEmptyEntries))
		{
			if (line.Contains("other backends are unaffected"))
				Log.Warning(line);
			else
				Log.Error(line);
		}
		if (failed > 0)
			Log.Error(scope $"{failed} shader(s) did not compile; objects using them are drawn with the standard shader.");
	}

	void RefreshMaterialChoices()
	{
		if (Time.FrameCount - mMaterialChoicesFrame < 240)
			return;
		mMaterialChoicesFrame = Time.FrameCount;
		ClearAndDeleteItems!(mImageChoices);
		ClearAndDeleteItems!(mShaderChoices);
		void Scan(StringView folder, int depth)
		{
			if (depth > 8 || !Directory.Exists(folder))
				return;
			for (let entry in Directory.EnumerateFiles(folder))
			{
				let name = scope String();
				entry.GetFileName(name);
				let isImage = IsImageFile(name);
				if (!isImage && !name.EndsWith(".tshader"))
					continue;
				let relative = new String();
				Assets.MakeRelative(scope $"{folder}/{name}" , relative);
				(isImage ? mImageChoices : mShaderChoices).Add(relative);
			}
			for (let entry in Directory.EnumerateDirectories(folder))
			{
				let name = scope String();
				entry.GetFileName(name);
				if (!name.StartsWith('.') && name != "build" && name != "Compiled")
					Scan(scope $"{folder}/{name}" , depth + 1);
			}
		}
		Scan(Assets.ProjectPath, 0);
		mImageChoices.Sort(scope (a, b) => a.CompareTo(b));
		mShaderChoices.Sort(scope (a, b) => a.CompareTo(b));
	}

	/// A row that picks an image file (or none). Returns true when it changed.
	bool ImageRow(char8* label, String path)
	{
		bool changed = false;
		ImGui.SetNextItemWidth(-130);
		if (ImGui.BeginCombo(label, path.IsEmpty ? (char8*)"(none)" : path.CStr()))
		{
			RefreshMaterialChoices();
			if (ImGui.Selectable("(none)", path.IsEmpty))
			{
				path.Clear();
				changed = true;
			}
			for (let choice in mImageChoices)
			{
				if (ImGui.Selectable(choice.CStr(), choice == path))
				{
					path.Set(choice);
					changed = true;
				}
			}
			ImGui.EndCombo();
		}
		return changed;
	}

	/// The settings of a material, drawn in the Inspector: for a .tmat file selected in the Project panel, and
	/// under the components of an object whose Mesh Renderer uses one. Everything using the material changes as
	/// it is edited, and changes are saved as they are made.
	void DrawMaterialInspector(StringView relativePath)
	{
		let loaded = Material.Load(relativePath);
		if (loaded == null)
		{
			ImGui.TextDisabled("This material could not be read.");
			return;
		}
		if (loaded != mMaterial)
		{
			if (mMaterialDirty)
				SaveMaterial();
			mMaterial = loaded;
			mMaterialPath.Set(relativePath);
			mMaterialSavedRevision = loaded.Revision;
		}
		ImGui.PushID("material");
		let material = mMaterial;
		bool changed = false;
		changed |= DrawMaterialShaderChoice(material);
		let custom = material.Shader;
		if (custom != null && !custom.problems.IsEmpty)
			ImGui.TextDisabled("This shader has mistakes; see the Console.");
		changed |= DrawMaterialPalette(material);
		changed |= DrawMaterialSurface(material);
		changed |= DrawMaterialPlacement(material);
		// The custom shader's own properties (they mark the material changed themselves).
		if (custom != null && custom.properties.Count > 0)
			DrawShaderProperties(material, custom);
		ImGui.PopID();
		if (changed)
			material.Changed();
		// Shader property edits bump the material's revision themselves; either way it is written once the mouse is up.
		mMaterialDirty |= changed || material.Revision != mMaterialSavedRevision;
		if (mMaterialDirty && !ImGui.IsMouseDown(0))
			SaveMaterial();
	}

	/// Which shader the material uses: Standard, or one of the project's.
	bool DrawMaterialShaderChoice(Material material)
	{
		bool changed = false;
		ImGui.SeparatorText("Shader");
		ImGui.SetNextItemWidth(-130);
		if (ImGui.BeginCombo("Shader", material.shader.IsEmpty ? (char8*)"Standard" : material.shader.CStr()))
		{
			RefreshMaterialChoices();
			if (ImGui.Selectable("Standard", material.shader.IsEmpty))
			{
				material.shader.Clear();
				changed = true;
			}
			for (let choice in mShaderChoices)
			{
				if (ImGui.Selectable(choice.CStr(), choice == material.shader))
				{
					material.shader.Set(choice);
					changed = true;
				}
			}
			ImGui.EndCombo();
		}
		return changed;
	}

	/// The palette entry being edited in the Material Inspector (-1: none), and the colours being edited, written to
	/// the image when the mouse is let go.
	int32 mPaletteEntry = -1;
	String mPaletteEditPath = new .() ~ delete _;
	Color[Palettes.Size] mPaletteEdit;
	bool mPaletteEditDirty;

	/// A new palette image for a material, beside the project's textures: a copy of `from`, or the starter colours.
	String NewPaletteFile(Material material, StringView suffix, StringView from)
	{
		let name = scope String();
		System.IO.Path.GetFileNameWithoutExtension(material.path.IsEmpty ? "Material" : material.path, name);
		let path = new String()..AppendF("Textures/{}_{}.png", name, suffix);
		Color[Palettes.Size] colors = default;
		if (from.IsEmpty || !Palettes.Colors(from, ref colors))
			Palettes.Starter(ref colors);
		if (!Palettes.Save(path, colors))
			Log.Error(scope $"Could not write {path}");
		return path;
	}

	/// Palette mode, optional: a palette image (made and edited here), one per world state, and how faces glow and
	/// dissolve.
	bool DrawMaterialPalette(Material material)
	{
		bool changed = false;
		ImGui.SeparatorText("Palette (optional)");
		changed |= ImageRow("Palette", material.palette);
		if (!material.IsPalette)
		{
			if (ImGui.Button("New Palette", .(-1, 0)))
			{
				let path = NewPaletteFile(material, "palette", "");
				material.palette.Set(path);
				delete path;
				changed = true;
			}
			ImGui.TextDisabled("Optional: colour faces from a 256-colour palette painted in the modeller (a low-poly look).");
			return changed;
		}
		ImGui.TextDisabled("Each face's colour, glow, roughness, metallic and flags come from its painted vertex colour; Color, Texture and the maps below are not used.");
		changed |= ImGui.SliderFloat("Glow Strength", ref material.paletteEmission, 0, 20);
		changed |= ImGui.SliderFloat("Dissolve", ref material.dissolve, 0, 1);
		let states = ProjectConfig.WorldStates;
		if (states.Count > 1)
		{
			while (material.statePalettes.Count < states.Count)
				material.statePalettes.Add(new .());
			for (int i < states.Count)
			{
				ImGui.PushID((int32)i);
				changed |= ImageRow(scope String()..AppendF("In {}", states[i]).CStr(), material.statePalettes[i]);
				if (material.statePalettes[i].IsEmpty && ImGui.Button(scope String()..AppendF("New palette for {}", states[i]).CStr(), .(-1, 0)))
				{
					let path = NewPaletteFile(material, states[i], material.palette);
					material.statePalettes[i].Set(path);
					delete path;
					changed = true;
				}
				ImGui.PopID();
			}
			ImGui.TextDisabled("A world state's palette recolours the same faces there; empty uses Palette.");
		}
		DrawPaletteEditor(material.palette);
		for (int i < Math.Min(states.Count, material.statePalettes.Count))
		{
			if (!material.statePalettes[i].IsEmpty)
			{
				ImGui.PushID((int32)(100 + i));
				ImGui.TextDisabled(scope String()..AppendF("{}:", states[i]).CStr());
				DrawPaletteEditor(material.statePalettes[i]);
				ImGui.PopID();
			}
		}
		return changed;
	}

	/// A palette's 256 colours in its 16 x 16 layout: click one to change it. The image is written when the mouse is
	/// let go, and everything using it changes at once.
	void DrawPaletteEditor(String path)
	{
		if (mPaletteEditPath != path)
		{
			if (mPaletteEditDirty)
				Palettes.Save(mPaletteEditPath, mPaletteEdit);
			mPaletteEditDirty = false;
			mPaletteEntry = -1;
			mPaletteEditPath.Set(path);
			Palettes.Colors(path, ref mPaletteEdit);
		}
		let origin = ImGui.GetCursorScreenPos();
		let cell = Math.Clamp((ImGui.GetContentRegionAvail().x - 4) / Palettes.Side, 8, 18);
		ImGui.InvisibleButton("##palette", .(cell * Palettes.Side, cell * Palettes.Side));
		let clicked = ImGui.IsItemHovered() && ImGui.IsMouseClicked(0);
		let mouse = ImGui.GetMousePos();
		for (int32 i < Palettes.Size)
		{
			let x = origin.x + (i % Palettes.Side) * cell;
			let y = origin.y + (i / Palettes.Side) * cell;
			ImGui.DrawRectFilled(.(x, y), .(x + cell - 1, y + cell - 1), mPaletteEdit[i]);
			if (i == mPaletteEntry)
				ImGui.DrawRect(.(x - 1, y - 1), .(x + cell, y + cell), .White, 0, 2);
			if (clicked && mouse.x >= x && mouse.x < x + cell && mouse.y >= y && mouse.y < y + cell)
				mPaletteEntry = i;
		}
		if (mPaletteEntry >= 0)
		{
			ImGui.SetNextItemWidth(-130);
			if (ImGui.ColorEdit4(scope String()..AppendF("Entry {}", mPaletteEntry).CStr(), ref mPaletteEdit[mPaletteEntry]))
				mPaletteEditDirty = true;
		}
		else
			ImGui.TextDisabled("Click a colour to change it.");
		if (mPaletteEditDirty && !ImGui.IsMouseDown(0))
		{
			if (!Palettes.Save(path, mPaletteEdit))
				Log.Error(scope $"Could not write {path}");
			mPaletteEditDirty = false;
		}
	}

	/// Colour, the PBR settings and maps.
	bool DrawMaterialSurface(Material material)
	{
		bool changed = false;
		ImGui.SeparatorText("Surface");
		changed |= ImGui.ColorEdit4("Color", ref material.color);
		changed |= ImageRow("Texture", material.texture);
		changed |= ImGui.SliderFloat("Metallic", ref material.metallic, 0, 1);
		changed |= ImGui.SliderFloat("Roughness", ref material.roughness, 0, 1);
		changed |= ImGui.ColorEdit4("Emissive", ref material.emissive);
		changed |= ImGui.DragFloat("Emissive Intensity", ref material.emissiveIntensity, 0.05f, 0, 100);
		changed |= ImGui.Checkbox("Flat Shading", ref material.flatShading);
		ImGui.SameLine();
		changed |= ImGui.Checkbox("Unlit", ref material.unlit);
		ImGui.SameLine();
		changed |= ImGui.Checkbox("Double Sided", ref material.doubleSided);

		ImGui.SeparatorText("PBR maps");
		changed |= ImageRow("Normal Map", material.normalMap);
		if (!material.normalMap.IsEmpty)
			changed |= ImGui.SliderFloat("Normal Strength", ref material.normalStrength, 0, 2);
		changed |= ImageRow("Metallic-Roughness", material.metallicRoughnessMap);
		changed |= ImageRow("Occlusion", material.occlusionMap);
		if (!material.occlusionMap.IsEmpty)
			changed |= ImGui.SliderFloat("Occlusion Strength", ref material.occlusionStrength, 0, 1);
		changed |= ImageRow("Emissive Map", material.emissiveMap);
		return changed;
	}

	/// Texture tiling and offset, and how see-through the material is.
	bool DrawMaterialPlacement(Material material)
	{
		bool changed = false;
		ImGui.SeparatorText("Texture placement");
		float[2] tiling = .(material.tiling.x, material.tiling.y), offset = .(material.offset.x, material.offset.y);
		ImGui.SetNextItemWidth(-130);
		if (ImGui.DragFloat2("Tiling", &tiling, 0.01f))
		{
			material.tiling = .(tiling[0], tiling[1]);
			changed = true;
		}
		ImGui.SetNextItemWidth(-130);
		if (ImGui.DragFloat2("Offset", &offset, 0.01f))
		{
			material.offset = .(offset[0], offset[1]);
			changed = true;
		}

		ImGui.SeparatorText("Transparency");
		let blendLabel = scope String();
		material.blend.ToString(blendLabel);
		ImGui.SetNextItemWidth(-130);
		if (ImGui.BeginCombo("Blend", blendLabel.CStr()))
		{
			for (let mode in MaterialBlend[?](.Opaque, .Cutout, .Transparent))
			{
				let label = scope String();
				mode.ToString(label);
				if (ImGui.Selectable(label.CStr(), mode == material.blend))
				{
					material.blend = mode;
					changed = true;
				}
			}
			ImGui.EndCombo();
		}
		if (material.blend == .Cutout)
			changed |= ImGui.SliderFloat("Cutoff", ref material.cutoff, 0, 1);
		return changed;
	}

	/// A custom shader's own properties, each with the field its type needs.
	void DrawShaderProperties(Material material, ShaderAsset custom)
	{
		ImGui.SeparatorText("Shader properties");
		for (let property in custom.properties)
		{
			ImGui.PushID(property.name.CStr());
			let label = scope String();
			NodeLibrary.Spaced(property.name, label);
			switch (property.type)
			{
			case .Float:
				var value = material.GetFloat(property.name);
				if (ImGui.DragFloat(label.CStr(), ref value, 0.01f))
					material.SetFloat(property.name, value);
			case .Color:
				var color = material.GetColor(property.name);
				if (ImGui.ColorEdit4(label.CStr(), ref color))
					material.SetColor(property.name, color);
			case .Vector:
				var vector = material.GetVector(property.name);
				ImGui.SetNextItemWidth(-130);
				if (ImGui.DragFloat4(label.CStr(), &vector.x, 0.01f))
					material.SetVector(property.name, vector);
			case .Texture:
				let image = scope String();
				material.GetTexture(property.name, image);
				if (ImageRow(label.CStr(), image))
					material.SetTexture(property.name, image);
			}
			ImGui.PopID();
		}
	}

	int32 mMaterialSavedRevision;

	void SaveMaterial()
	{
		if (mMaterial == null || mMaterialPath.IsEmpty)
			return;
		let full = scope String();
		Assets.ResolvePath(mMaterialPath, full);
		mMaterial.Save(full);
		AssetPreviews.Invalidate(full);
		mMaterialSavedRevision = mMaterial.Revision;
		mMaterialDirty = false;
	}
}
