using System;
using System.Collections;
using System.IO;
using Bgfx;

namespace Tallow;

/// How a material's alpha is used.
enum MaterialBlend : int32
{
	/// Solid.
	Opaque,
	/// Solid, with holes where the texture's alpha is below the cutoff: leaves, fences, grates.
	Cutout,
	/// See-through: blended over what is behind it, and casts no shadow.
	Transparent
}

/// The kinds of value a custom shader can take.
enum ShaderPropertyType : int32 { Float, Color, Vector, Texture }

/// A custom shader: a .tshader file with the properties it declares. The editor compiles it for each graphics
/// backend into Shaders/Compiled next to it; the game only ever loads those compiled files.
///
/// The file says what a surface looks like, not how it is lit:
///     property float speed = 1
///     property color tint = 1 0.5 0.2 1
///     property texture detail
///     surface {
///         albedo *= tint.rgb * (0.5 + 0.5 * sin(time * speed + worldPosition.x));
///     }
///     vertex {
///         position.y += sin(time + position.x) * 0.1;
///     }
/// Lighting, shadows and fog are applied to the result by the engine.
class ShaderAsset
{
	/// One of a shader's properties: its name, kind, slot and default.
	public class Property
	{
		public String name = new .() ~ delete _;
		public ShaderPropertyType type;
		public Vector4 defaultValue;
		/// Which of the eight value slots, or which of the two extra texture slots, the property uses.
		public int32 slot;
	}

	/// The most number, colour and vector properties a shader can have.
	public const int MaxValues = 8;
	/// The most texture properties a shader can have.
	public const int MaxTextures = 2;

	/// The shader's file, relative to the project's assets.
	public String path = new .() ~ delete _;
	/// The properties the shader declares.
	public List<Property> properties = new .() ~ DeleteContainerAndItems!(_);
	/// The code of its surface { } block.
	public String surface = new .() ~ delete _;
	/// The code of its vertex { } block.
	public String vertex = new .() ~ delete _;
	/// A compute shader's code (.tcompute files have this block instead of surface and vertex).
	public String compute = new .() ~ delete _;
	/// A compute shader's "precision high" line: keep values as 16-bit floats instead of 8-bit colours, for
	/// simulations that need numbers outside 0 to 1 or finer steps.
	public bool highPrecision;
	/// Whether it is a compute shader (it has a compute { } block).
	public bool IsCompute => !compute.IsEmpty;
	/// Anything in the file that could not be understood, one message per line. Empty when it is fine.
	public String problems = new .() ~ delete _;
	/// Goes up each time the shader is loaded again, so materials notice.
	public int32 Revision;

	bgfx.ProgramHandle mProgram = .() { idx = uint16.MaxValue };
	bool mProgramTried;
	// For a shader made by FromCompiled: the folder its compiled stages are in.
	String mCompiledFolder ~ delete _;

	static Dictionary<String, ShaderAsset> sCache = new .() ~ DeleteDictionaryAndKeysAndValues!(_);

	/// A property by name, or null.
	public Property Find(StringView name)
	{
		for (let property in properties)
		{
			if (property.name == name)
				return property;
		}
		return null;
	}

	/// The name compiled files are stored under: the shader's path with everything but letters and digits replaced.
	public static void CompiledName(StringView path, String output)
	{
		for (let c in path.RawChars)
			output.Append(c.IsLetterOrDigit ? c : '_');
	}

	/// Reads the properties and the code blocks out of shader source.
	public void Parse(StringView text)
	{
		ClearAndDeleteItems!(properties);
		surface.Clear();
		vertex.Clear();
		compute.Clear();
		highPrecision = false;
		problems.Clear();
		int32 values = 0, textures = 0;
		String block = null;
		int depth = 0;
		int lineNumber = 0;
		for (var line in text.Split('\n'))
		{
			lineNumber++;
			if (block != null)
			{
				// Inside "surface { ... }" or "vertex { ... }": everything up to the brace that closes it is code.
				depth += BraceBalance(line);
				if (depth > 0)
				{
					block..Append(line).Append('\n');
					continue;
				}
				let close = line.LastIndexOf('}');
				if (close > 0)
					block..Append(line.Substring(0, close)).Append('\n');
				block = null;
				continue;
			}
			var trimmed = line;
			trimmed.Trim();
			if (trimmed.IsEmpty || trimmed.StartsWith("//"))
				continue;
			if (trimmed == "precision high")
				highPrecision = true;
			else if (trimmed.StartsWith("surface") || trimmed.StartsWith("vertex") || trimmed.StartsWith("compute"))
				block = StartBlock(trimmed, lineNumber, out depth);
			else if (trimmed.StartsWith("property "))
				ParseProperty(trimmed.Substring(9), lineNumber, ref values, ref textures);
			else
				problems.AppendF("line {}: expected 'property', 'surface {{', 'vertex {{' or 'compute {{'\n", lineNumber);
		}
		if (block != null)
			problems.Append("a block is missing its closing }\n");
	}

	/// How many more braces a line opens than it closes.
	static int BraceBalance(StringView line)
	{
		int balance = 0;
		for (let c in line.RawChars)
		{
			if (c == '{')
				balance++;
			else if (c == '}')
				balance--;
		}
		return balance;
	}

	/// The start of a "surface {", "vertex {" or "compute {" block: returns the block to read code into, or null when
	/// it closed on the same line (or is missing its brace). `depth` is how many braces are left open.
	String StartBlock(StringView line, int lineNumber, out int depth)
	{
		depth = 0;
		let isSurface = line.StartsWith("surface");
		let isCompute = line.StartsWith("compute");
		let open = line.IndexOf('{');
		if (open < 0)
		{
			problems.AppendF("line {}: expected {{ after {}\n", lineNumber, isSurface ? "surface" : (isCompute ? "compute" : "vertex"));
			return null;
		}
		let block = isSurface ? surface : (isCompute ? compute : vertex);
		block.Clear();
		// Code may follow the brace on the same line, and the block may close on it too.
		var rest = line.Substring(open + 1);
		depth = 1 + BraceBalance(rest);
		if (depth <= 0)
		{
			let close = rest.LastIndexOf('}');
			if (close >= 0)
				rest = rest.Substring(0, close);
			block..Append(rest).Append('\n');
			return null;
		}
		if (!rest.IsEmpty)
			block..Append(rest).Append('\n');
		return block;
	}

	/// "property <type> <name> [= values]", the part after "property ".
	void ParseProperty(StringView text, int lineNumber, ref int32 values, ref int32 textures)
	{
		var declaration = text;
		var defaults = StringView();
		let equals = declaration.IndexOf('=');
		if (equals >= 0)
		{
			defaults = declaration.Substring(equals + 1);
			declaration = declaration.Substring(0, equals);
		}
		var words = declaration.Split(' ', .RemoveEmptyEntries);
		StringView typeName = "", name = "";
		if (words.GetNext() case .Ok(let first))
			typeName = first;
		if (words.GetNext() case .Ok(let second))
			name = second;
		ShaderPropertyType type;
		switch (typeName)
		{
		case "float": type = .Float;
		case "color": type = .Color;
		case "vector": type = .Vector;
		case "texture": type = .Texture;
		default:
			problems.AppendF("line {}: unknown property type '{}' (use float, color, vector or texture)\n", lineNumber, typeName);
			return;
		}
		bool validName = !name.IsEmpty && !name[0].IsDigit;
		for (let c in name.RawChars)
			validName &= c.IsLetterOrDigit || c == '_';
		if (!validName || Find(name) != null)
		{
			problems.AppendF("line {}: a property needs a name of its own made of letters, digits and underscores\n", lineNumber);
			return;
		}
		for (let taken in StringView[?]("uv", "worldPosition", "worldNormal", "vertexColor", "time", "tex", "albedo", "alpha", "metallic", "roughness", "specularLevel", "emissive",
			"occlusion", "surfaceNormal", "mainTexture", "texture1", "texture2", "position", "normal", "result", "pixel", "size"))
		{
			if (name == taken)
			{
				problems.AppendF("line {}: '{}' is a name the shader code already uses; give the property another\n", lineNumber, name);
				return;
			}
		}
		if (type == .Texture ? textures >= MaxTextures : values >= MaxValues)
		{
			problems.AppendF("line {}: too many properties (up to {} values and {} textures)\n", lineNumber, MaxValues, MaxTextures);
			return;
		}
		let property = new Property();
		property.name.Set(name);
		property.type = type;
		property.slot = type == .Texture ? textures++ : values++;
		property.defaultValue = type == .Color ? Vector4(1, 1, 1, 1) : Vector4(0, 0, 0, 0);
		float* channels = &property.defaultValue.x;
		int index = 0;
		for (let part in defaults.Split(' ', .RemoveEmptyEntries))
		{
			if (index < 4)
				channels[index++] = SceneSerializer.ParseFloat(part);
		}
		properties.Add(property);
	}

	/// Reads the file again and forgets the compiled program, so that the next draw loads the new one.
	public void Reload()
	{
		let full = scope String();
		Assets.ResolvePath(path, full);
		let text = scope String();
		if (AssetPack.ReadAllText(full, text) case .Err)
		{
			problems.Set("the shader file could not be read\n");
			return;
		}
		Parse(text);
		if (mProgram.idx != uint16.MaxValue)
			bgfx.destroy_program(mProgram);
		mProgram.idx = uint16.MaxValue;
		mProgramTried = false;
		Revision++;
	}

	/// The compiled program, or an invalid handle when the shader has not been compiled for this backend (the
	/// renderer then draws with the standard shader). Needs a graphics device.
	public bgfx.ProgramHandle Program
	{
		get
		{
			if (mProgramTried)
				return mProgram;
			mProgramTried = true;
			let name = scope String();
			CompiledName(path, name);
			let folder = scope String();
			if (mCompiledFolder != null)
				folder.Set(mCompiledFolder);
			else
				Assets.ResolvePath(scope $"Shaders/Compiled/{Gfx.ShaderFolder}" , folder);
			let vs = Gfx.LoadShaderFile(scope $"{folder}/{name}_vs.bin");
			let fs = Gfx.LoadShaderFile(scope $"{folder}/{name}_fs.bin");
			if (vs.idx == uint16.MaxValue || fs.idx == uint16.MaxValue)
			{
				if (vs.idx != uint16.MaxValue)
					bgfx.destroy_shader(vs);
				if (fs.idx != uint16.MaxValue)
					bgfx.destroy_shader(fs);
				Log.Warning(scope $"Shader {path} has not been compiled for this graphics backend ({Gfx.ShaderFolder}); drawing with the standard shader. Open and save it in the editor.");
				return mProgram;
			}
			mProgram = bgfx.create_program(vs, fs, true);
			return mProgram;
		}
	}

	/// A compute shader's compiled program, or an invalid handle when it has not been compiled for this backend.
	public bgfx.ProgramHandle ComputeProgram
	{
		get
		{
			if (mProgramTried)
				return mProgram;
			mProgramTried = true;
			let name = scope String();
			CompiledName(path, name);
			let folder = scope String();
			if (mCompiledFolder != null)
				folder.Set(mCompiledFolder);
			else
				Assets.ResolvePath(scope $"Shaders/Compiled/{Gfx.ShaderFolder}" , folder);
			let cs = Gfx.LoadShaderFile(scope $"{folder}/{name}_cs.bin");
			if (cs.idx == uint16.MaxValue)
			{
				Log.Warning(scope $"Compute shader {path} has not been compiled for this graphics backend ({Gfx.ShaderFolder}). Open and save it in the editor.");
				return mProgram;
			}
			mProgram = bgfx.create_compute_program(cs, true);
			return mProgram;
		}
	}

	/// Loads (and caches) a shader by project path. Returns null if the file is missing.
	public static ShaderAsset Load(StringView path)
	{
		if (path.IsEmpty)
			return null;
		if (sCache.TryGetValueAlt(path, let cached))
			return cached;
		let full = scope String();
		Assets.ResolvePath(path, full);
		if (!AssetPack.Exists(full))
		{
			Log.Warning(scope $"Shader not found: {path}");
			return null;
		}
		let shader = new ShaderAsset();
		shader.path.Set(path);
		shader.Reload();
		sCache[new String(path)] = shader;
		return shader;
	}

	/// A shader from source text whose stages were compiled into a folder of their own, for this backend (the
	/// editor's shader graph previews). It is kept under `name`, which no file has, so a material's Shader can name
	/// it; calling again with the same name replaces it, and materials using it draw with the new program.
	public static ShaderAsset FromCompiled(StringView name, StringView text, StringView folder)
	{
		ShaderAsset shader;
		if (!sCache.TryGetValueAlt(name, out shader))
		{
			shader = new ShaderAsset();
			shader.path.Set(name);
			sCache[new String(name)] = shader;
		}
		shader.Parse(text);
		String.NewOrSet!(shader.mCompiledFolder, folder);
		if (shader.mProgram.idx != uint16.MaxValue)
			bgfx.destroy_program(shader.mProgram);
		shader.mProgram.idx = uint16.MaxValue;
		shader.mProgramTried = false;
		shader.Revision++;
		return shader;
	}

	/// Called by the editor after it has compiled a shader again.
	public static void Reloaded(StringView path)
	{
		if (sCache.TryGetValueAlt(path, let cached))
			cached.Reload();
	}

	/// Releases every compiled program. Called before the graphics device goes away.
	public static void ReleaseAll()
	{
		for (let shader in sCache.Values)
		{
			if (shader.mProgram.idx != uint16.MaxValue)
				bgfx.destroy_program(shader.mProgram);
			shader.mProgram.idx = uint16.MaxValue;
			shader.mProgramTried = false;
		}
	}
}

/// How a surface looks: colour, texture, how shiny, how see-through, and which shader draws it. A .tmat file made
/// in the editor, shared by every Mesh Renderer that names it: change the material and all of them change.
class Material
{
	/// A custom shader (.tshader), or empty for the standard one.
	public String shader = new .() ~ delete _;
	/// The colour the surface is, multiplied by the texture.
	public Color color = .White;
	/// How metal-like the surface is, 0 to 1.
	public float metallic = 0.0f;
	/// How rough the surface is: 0 is a mirror, 1 fully matt.
	public float roughness = 0.85f;
	/// Light the surface gives off itself.
	public Color emissive = .Black;
	/// How strong the emissive light is.
	public float emissiveIntensity = 0.0f;
	/// Lights each triangle evenly, for a faceted look; off, light is smoothed across them.
	public bool flatShading = true;
	/// Draws the colour and texture as they are, with no lighting.
	public bool unlit = false;
	/// The main texture, multiplied by the colour.
	public String texture = new .() ~ delete _;
	/// Bumps and grooves without more triangles: a tangent-space normal map (the blue-purple kind).
	public String normalMap = new .() ~ delete _;
	/// How strong the normal map's bumps are.
	public float normalStrength = 1.0f;
	/// Roughness in the green channel and metallic in the blue, as glTF stores them. Multiplied by the two sliders.
	public String metallicRoughnessMap = new .() ~ delete _;
	/// Darkens creases: ambient occlusion in the red channel.
	public String occlusionMap = new .() ~ delete _;
	/// How much the occlusion map darkens.
	public float occlusionStrength = 1.0f;
	/// Which parts glow. Multiplied by the emissive colour and intensity.
	public String emissiveMap = new .() ~ delete _;
	/// How many times the texture repeats across the mesh, and where it starts.
	public Vector2 tiling = .(1, 1);
	/// Where the texture starts (with tiling, how it repeats).
	public Vector2 offset = .(0, 0);
	/// Opaque, Cutout (holes where the alpha is below cutoff) or Transparent (see-through, blended).
	public MaterialBlend blend = .Opaque;
	/// Cutout: pixels whose alpha is below this are not drawn.
	public float cutoff = 0.5f;
	/// Draw both faces of each triangle: for leaves, cloth and anything seen from behind.
	public bool doubleSided = false;
	/// Palette mode: a palette image (256 colours, usually 16 x 16). Each face then takes everything from its
	/// vertex colour bytes, painted in the modeller: red picks the palette colour, green how strongly it glows,
	/// blue its roughness (top five bits) and metallic (low three), or its opacity on a see-through face, and alpha
	/// its flags (PaletteFlags). Color, Texture and the maps are not used. Empty: an ordinary material.
	public String palette = new .() ~ delete _;
	/// A palette for each world state, by number (Project Settings): what the same faces look like in that state, so
	/// two realities share one mesh. An empty one uses Palette.
	public List<String> statePalettes = new .() ~ DeleteContainerAndItems!(_);
	/// Another material to draw with in a world state, by number (Project Settings): an object shared by every state
	/// keeps one mesh and changes its whole look there. An empty one keeps this material. Not followed further (a
	/// state's material's own state materials are not used).
	public List<String> stateMaterials = new .() ~ DeleteContainerAndItems!(_);
	/// How bright a face's glow is at full green (its emission byte at 255).
	public float paletteEmission = 4;
	/// Dissolve flagged faces: 0 whole, 1 gone (animate it for a shift or a death).
	public float dissolve = 0;
	/// For the editor's shader graph previews: which node of a preview shader the surface shows (0 is the surface
	/// itself). Not saved.
	public int32 previewOutput;

	/// Values for the custom shader's own properties, by name.
	Dictionary<String, Vector4> mValues = new .() ~ DeleteDictionaryAndKeys!(_);
	Dictionary<String, String> mTextures = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	/// Goes up when anything changes, so the renderer regroups its draws.
	public int32 Revision;
	/// The project path it was loaded from; empty for a material made in code.
	public String path = new .() ~ delete _;

	ShaderAsset mShader;
	String mResolvedShader = new .() ~ delete _;
	bgfx.TextureHandle mTexture = .() { idx = uint16.MaxValue };
	String mResolvedTexture = new .("\0") ~ delete _;
	int32 mTextureVersion = -1;

	static Dictionary<String, Material> sCache = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	/// Made with Create, and how many of those there are: only these are ever freed.
	bool mMadeInCode;
	float mLastAsked;
	static int sMadeInCode;
	/// Sweep once this many exist. Doubles past whatever is still in use, so a sweep stays rare.
	static int sSweepAt = MinimumSweep;
	const int MinimumSweep = 256;
	/// How long a material nothing draws with is kept after Create last gave it out.
	const float SweepGrace = 60;
	/// Off in the editor, whose windows hold previews no scene knows about.
	public static bool FreeUnusedMaterials = true;

	/// The custom shader this material uses, or null for the standard one (or when the file is missing).
	public ShaderAsset Shader
	{
		get
		{
			if (mResolvedShader != shader || (mShader == null && !shader.IsEmpty && mResolvedShader.IsEmpty))
			{
				mResolvedShader.Set(shader);
				mShader = ShaderAsset.Load(shader);
			}
			return mShader;
		}
	}

	/// The main texture (white when there is none).
	public bgfx.TextureHandle MainTexture
	{
		get
		{
			if (!mTexture.Valid || mResolvedTexture != texture || mTextureVersion != Assets.TextureVersion)
			{
				mResolvedTexture.Set(texture);
				mTextureVersion = Assets.TextureVersion;
				mTexture = Assets.GetTexture(texture);
			}
			return mTexture;
		}
	}

	/// True when the material is drawn blended over what is behind it.
	public bool IsTransparent => blend == .Transparent;

	/// True in palette mode (Palette set).
	public bool IsPalette => !palette.IsEmpty;

	/// The material drawn in a world state: that state's own (State Materials), or this one.
	public Material ForState(int32 worldState)
	{
		if (worldState < 0 || worldState >= stateMaterials.Count || stateMaterials[worldState].IsEmpty || stateMaterials[worldState] == path)
			return this;
		return Load(stateMaterials[worldState]) ?? this;
	}

	/// The palette used in a world state: that state's own, or Palette.
	public StringView PaletteFor(int32 worldState)
	{
		if (worldState >= 0 && worldState < statePalettes.Count && !statePalettes[worldState].IsEmpty)
			return statePalettes[worldState];
		return palette;
	}

	Material[4] mVariants;
	int32[4] mVariantRevisions = .(-1, -1, -1, -1);

	/// Palette mode: the material for one kind of face (PaletteSection): the same material made double sided,
	/// see-through, or both. Kept in step with this one. Section 0 is this material.
	public Material PaletteVariant(int section)
	{
		if (section <= 0 || section >= 4)
			return this;
		if (mVariants[section] == null || mVariantRevisions[section] != Revision)
		{
			delete mVariants[section];
			let variant = Clone();
			variant.path.Set(path);
			variant.doubleSided = (section & 1) != 0 || doubleSided;
			if ((section & 2) != 0)
				variant.blend = .Transparent;
			mVariants[section] = variant;
			mVariantRevisions[section] = Revision;
		}
		return mVariants[section];
	}

	public ~this()
	{
		for (let variant in mVariants)
			delete variant;
	}

	// ---- the custom shader's properties ----

	/// Sets one of the shader's properties. Names the shader does not declare are kept (the shader may change)
	/// but do nothing.
	public void SetVector(StringView name, Vector4 value)
	{
		if (mValues.TryGetValueAlt(name, let existing) && existing == value)
			return;
		if (mValues.TryGetAlt(name, let key, ?))
			mValues[key] = value;
		else
			mValues[new String(name)] = value;
		Revision++;
	}

	/// Sets a number property of the material's shader.
	public void SetFloat(StringView name, float value) => SetVector(name, .(value, 0, 0, 0));
	/// Sets a colour property of the material's shader.
	public void SetColor(StringView name, Color value) => SetVector(name, .(value.r, value.g, value.b, value.a));

	/// A property's value: what was set, otherwise the shader's default, otherwise zero.
	public Vector4 GetVector(StringView name)
	{
		if (mValues.TryGetValueAlt(name, let value))
			return value;
		let property = Shader?.Find(name);
		return property != null ? property.defaultValue : .(0, 0, 0, 0);
	}

	/// A number property of the material's shader (its default if never set).
	public float GetFloat(StringView name) => GetVector(name).x;
	/// A colour property of the material's shader.
	public Color GetColor(StringView name)
	{
		let value = GetVector(name);
		return .(value.x, value.y, value.z, value.w);
	}

	/// Whether a shader property has been given a value on this material.
	public bool HasValue(StringView name) => mValues.ContainsKeyAlt(name);

	/// Sets a texture property of the shader to an image file in the project.
	public void SetTexture(StringView name, StringView texturePath)
	{
		if (mTextures.TryGetValueAlt(name, let existing))
		{
			if (existing == texturePath)
				return;
			existing.Set(texturePath);
		}
		else
			mTextures[new String(name)] = new String(texturePath);
		Revision++;
	}

	/// The image a texture property of the material's shader names.
	public void GetTexture(StringView name, String output)
	{
		if (mTextures.TryGetValueAlt(name, let existing))
			output.Append(existing);
	}

	/// Fills the eight value slots and the two texture paths the shader's properties map to.
	public void GatherValues(ref Vector4[ShaderAsset.MaxValues] values, ref StringView[ShaderAsset.MaxTextures] textures)
	{
		let custom = Shader;
		if (custom == null)
			return;
		for (let property in custom.properties)
		{
			if (property.type == .Texture)
			{
				if (mTextures.TryGetValueAlt(property.name, let texturePath))
					textures[property.slot] = texturePath;
			}
			else
				values[property.slot] = mValues.TryGetValueAlt(property.name, let value) ? value : property.defaultValue;
		}
	}

	/// Tells the renderer something changed. Call it after setting the plain fields (color, metallic...) from code.
	public void Changed() => Revision++;

	/// A separate copy, for changing one object without changing the others that share the material.
	public Material Clone()
	{
		let copy = new Material();
		copy.shader.Set(shader);
		copy.color = color;
		copy.metallic = metallic;
		copy.roughness = roughness;
		copy.emissive = emissive;
		copy.emissiveIntensity = emissiveIntensity;
		copy.flatShading = flatShading;
		copy.unlit = unlit;
		copy.texture.Set(texture);
		copy.normalMap.Set(normalMap);
		copy.normalStrength = normalStrength;
		copy.metallicRoughnessMap.Set(metallicRoughnessMap);
		copy.occlusionMap.Set(occlusionMap);
		copy.occlusionStrength = occlusionStrength;
		copy.emissiveMap.Set(emissiveMap);
		copy.tiling = tiling;
		copy.offset = offset;
		copy.blend = blend;
		copy.cutoff = cutoff;
		copy.doubleSided = doubleSided;
		copy.palette.Set(palette);
		for (let state in statePalettes)
			copy.statePalettes.Add(new .(state));
		for (let state in stateMaterials)
			copy.stateMaterials.Add(new .(state));
		copy.paletteEmission = paletteEmission;
		copy.dissolve = dissolve;
		for (let (name, value) in mValues)
			copy.mValues[new String(name)] = value;
		for (let (name, texturePath) in mTextures)
			copy.mTextures[new String(name)] = new String(texturePath);
		return copy;
	}

	/// The material as the text of a .tmat file.
	public void Write(String text)
	{
		text.Append("material 1\n");
		text.Append("shader ");
		SceneSerializer.Quote(shader, text);
		text.AppendF("\ncolor {} {} {} {}\nmetallic {}\nroughness {}\nemissive {} {} {} {}\nemissiveIntensity {}\nflatShading {}\nunlit {}\ntexture ",
			color.r, color.g, color.b, color.a, metallic, roughness, emissive.r, emissive.g, emissive.b, emissive.a, emissiveIntensity, flatShading ? 1 : 0, unlit ? 1 : 0);
		SceneSerializer.Quote(texture, text);
		void Map(StringView key, String mapPath)
		{
			text.AppendF("\n{} ", key);
			SceneSerializer.Quote(mapPath, text);
		}
		Map("normalMap", normalMap);
		Map("metallicRoughnessMap", metallicRoughnessMap);
		Map("occlusionMap", occlusionMap);
		Map("emissiveMap", emissiveMap);
		text.AppendF("\nnormalStrength {}\nocclusionStrength {}", normalStrength, occlusionStrength);
		text.AppendF("\ntiling {} {}\noffset {} {}\nblend {}\ncutoff {}\ndoubleSided {}\n", tiling.x, tiling.y, offset.x, offset.y, (int32)blend, cutoff, doubleSided ? 1 : 0);
		// Palette mode only when used, so other materials' files stay as they were.
		if (!palette.IsEmpty)
		{
			text.Append("palette ");
			SceneSerializer.Quote(palette, text);
			text.AppendF("\npaletteEmission {}\n", paletteEmission);
			if (dissolve != 0)
				text.AppendF("dissolve {}\n", dissolve);
		}
		for (int i < statePalettes.Count)
		{
			if (statePalettes[i].IsEmpty)
				continue;
			text.AppendF("statePalette {} ", i);
			SceneSerializer.Quote(statePalettes[i], text);
			text.Append('\n');
		}
		for (int i < stateMaterials.Count)
		{
			if (stateMaterials[i].IsEmpty)
				continue;
			text.AppendF("stateMaterial {} ", i);
			SceneSerializer.Quote(stateMaterials[i], text);
			text.Append('\n');
		}
		// In name order, so that saving the same material twice writes the same file.
		List<String> names = scope .();
		for (let name in mValues.Keys)
			names.Add(name);
		names.Sort(scope (a, b) => a.CompareTo(b));
		for (let name in names)
		{
			let value = mValues[name];
			text.Append("value ");
			SceneSerializer.Quote(name, text);
			text.AppendF(" {} {} {} {}\n", value.x, value.y, value.z, value.w);
		}
		names.Clear();
		for (let name in mTextures.Keys)
			names.Add(name);
		names.Sort(scope (a, b) => a.CompareTo(b));
		for (let name in names)
		{
			text.Append("image ");
			SceneSerializer.Quote(name, text);
			text.Append(' ');
			SceneSerializer.Quote(mTextures[name], text);
			text.Append('\n');
		}
	}

	/// Reads the text of a .tmat file into the material.
	public void Read(StringView text)
	{
		List<StringView> tokens = scope .();
		List<String> storage = scope .();
		defer
		{
			for (let s in storage)
				delete s;
		}
		float F(int index) => index < tokens.Count ? SceneSerializer.ParseFloat(tokens[index]) : 0;
		for (let line in text.Split('\n'))
		{
			tokens.Clear();
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.Count < 2)
				continue;
			switch (tokens[0])
			{
			case "shader": shader.Set(tokens[1]);
			case "color": color = .(F(1), F(2), F(3), tokens.Count > 4 ? F(4) : 1);
			case "metallic": metallic = Mathf.Clamp01(F(1));
			case "roughness": roughness = Mathf.Clamp01(F(1));
			case "emissive": emissive = .(F(1), F(2), F(3), tokens.Count > 4 ? F(4) : 1);
			case "emissiveIntensity": emissiveIntensity = Math.Max(F(1), 0);
			case "flatShading": flatShading = tokens[1] == "1";
			case "unlit": unlit = tokens[1] == "1";
			case "texture": texture.Set(tokens[1]);
			case "normalMap":
				normalMap.Set(tokens[1]);
				Textures.Hint(normalMap, .Normal);
			case "metallicRoughnessMap":
				metallicRoughnessMap.Set(tokens[1]);
				Textures.Hint(metallicRoughnessMap, .Data);
			case "occlusionMap":
				occlusionMap.Set(tokens[1]);
				Textures.Hint(occlusionMap, .Data);
			case "emissiveMap": emissiveMap.Set(tokens[1]);
			case "normalStrength": normalStrength = Math.Max(F(1), 0);
			case "occlusionStrength": occlusionStrength = Mathf.Clamp01(F(1));
			case "tiling": tiling = .(F(1), F(2));
			case "offset": offset = .(F(1), F(2));
			case "blend": blend = (MaterialBlend)Math.Clamp((int32)F(1), 0, 2);
			case "cutoff": cutoff = Mathf.Clamp01(F(1));
			case "doubleSided": doubleSided = tokens[1] == "1";
			case "palette": palette.Set(tokens[1]);
			case "paletteEmission": paletteEmission = Math.Max(F(1), 0);
			case "dissolve": dissolve = Mathf.Clamp01(F(1));
			case "statePalette":
				let index = (int)F(1);
				if (tokens.Count >= 3 && index >= 0 && index < ProjectConfig.MaxWorldStates)
				{
					while (statePalettes.Count <= index)
						statePalettes.Add(new .());
					statePalettes[index].Set(tokens[2]);
				}
			case "stateMaterial":
				let index = (int)F(1);
				if (tokens.Count >= 3 && index >= 0 && index < ProjectConfig.MaxWorldStates)
				{
					while (stateMaterials.Count <= index)
						stateMaterials.Add(new .());
					stateMaterials[index].Set(tokens[2]);
				}
			case "value":
				if (tokens.Count >= 6)
					SetVector(tokens[1], .(F(2), F(3), F(4), F(5)));
			case "image":
				if (tokens.Count >= 3)
					SetTexture(tokens[1], tokens[2]);
			}
		}
		Revision++;
	}

	/// Writes the material to a .tmat file. False if it could not be written.
	public bool Save(StringView fullPath)
	{
		let text = scope String();
		Write(text);
		if (File.WriteAllText(fullPath, text) case .Err)
		{
			Log.Error(scope $"Could not save {fullPath}");
			return false;
		}
		return true;
	}

	/// Loads (and caches) a material by project path. Every renderer naming the same file shares one Material.
	public static Material Load(StringView materialPath)
	{
		if (materialPath.IsEmpty)
			return null;
		if (sCache.TryGetValueAlt(materialPath, let cached))
			return cached;
		let full = scope String();
		Assets.ResolvePath(materialPath, full);
		let text = scope String();
		if (AssetPack.ReadAllText(full, text) case .Err)
		{
			Log.Warning(scope $"Material not found: {materialPath}");
			return null;
		}
		let material = new Material();
		material.path.Set(materialPath);
		material.Read(text);
		sCache[new String(materialPath)] = material;
		return material;
	}

	/// Registers a material made in code under a project path, as if it had been loaded from there.
	///
	/// A game that makes unbounded names (one per spawned object) does not fill memory: past 256 of them, those no
	/// renderer in the scene uses and that Create has not returned for a minute are freed. So give a material to a
	/// renderer by name, or call Create again for it, rather than keeping only the pointer.
	public static Material Create(StringView materialPath)
	{
		if (sCache.TryGetValueAlt(materialPath, let cached))
		{
			cached.mLastAsked = Time.RealTime;
			return cached;
		}
		let material = new Material();
		material.path.Set(materialPath);
		material.mMadeInCode = true;
		material.mLastAsked = Time.RealTime;
		sCache[new String(materialPath)] = material;
		sMadeInCode++;
		return material;
	}

	/// How many materials are held, for tests and the profiler.
	public static int CachedCount => sCache.Count;

	/// Frees what Create made and nothing uses any more. Runs between frames, when no draw list holds a material.
	public static void FreeUnused()
	{
		if (sMadeInCode < sSweepAt || !FreeUnusedMaterials || Scene.Active == null)
			return;
		let used = scope HashSet<Material>();
		for (let renderer in Scene.Active.FindComponents<MeshRenderer>(.. scope .()))
		{
			if (renderer.SharedMaterial != null)
				used.Add(renderer.SharedMaterial);
			if (renderer.RuntimeParts != null)
			{
				for (let part in renderer.RuntimeParts)
				{
					if (part.material != null)
						used.Add(part.material);
				}
			}
		}
		for (let foliage in Scene.Active.FindComponents<Foliage>(.. scope .()))
			used.Add(foliage.ActiveMaterial);
		// A Skinned Mesh Renderer names its materials, and may not have looked them up yet.
		let names = scope String();
		for (let skinned in Scene.Active.FindComponents<SkinnedMeshRenderer>(.. scope .()))
			names.Append(skinned.materials, ";");
		for (var entry in sCache)
		{
			let material = entry.value;
			if (!material.mMadeInCode || used.Contains(material) || Time.RealTime - material.mLastAsked < SweepGrace)
				continue;
			if (names.Contains(entry.key))
				continue;
			delete entry.key;
			delete material;
			@entry.Remove();
			sMadeInCode--;
		}
		sSweepAt = Math.Max(MinimumSweep, sMadeInCode * 2);
	}
}
