using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Turns .tshader and .tcompute files into programs the graphics card runs. A shader file only says what a surface
/// looks like (or what a compute step does); this puts that code into the engine's own shader, which adds
/// lighting, shadows and fog, and compiles the result with bgfx's shaderc for every graphics backend it can.
/// Compiled files go to Shaders/Compiled/<backend>/ in the project, and ship with the game; the game itself never
/// compiles anything.
static class ShaderCompiler
{
	/// Backends compiled for: folder, shaderc profile, shaderc platform. The first is the one this machine runs,
	/// and the only one whose failure counts as the shader failing.
	static (StringView folder, StringView profile, StringView platform)[?] sTargets = .(("spirv", "spirv", "linux"), ("glsl", "430", "linux"), ("essl", "310_es", "android"), ("webgl", "300_es", "asm.js"), ("metal", "metal", "osx"));

	static void Defines(ShaderAsset shader, bool withTextures, String output)
	{
		for (let property in shader.properties)
		{
			if (property.type == .Texture)
			{
				if (withTextures)
					output.AppendF("#define {} s_texture{}\n", property.name, property.slot + 1);
			}
			else if (property.type == .Float)
				output.AppendF("#define {} u_params[{}].x\n", property.name, property.slot);
			else
				output.AppendF("#define {} u_params[{}]\n", property.name, property.slot);
		}
	}

	/// Forgets the properties' names after the shader's own code, so the engine's code that follows can use any name.
	static void Undefines(ShaderAsset shader, bool withTextures, String output)
	{
		for (let property in shader.properties)
		{
			if (withTextures || property.type != .Texture)
				output.AppendF("#undef {}\n", property.name);
		}
	}

	static bool Template(StringView engineRoot, StringView name, String text)
	{
		return File.ReadAllText(scope $"{engineRoot}/Engine/shaders/{name}" , text, true) case .Ok;
	}

	/// Writes the full shader source a shader file becomes. For a surface shader: the fragment and vertex stages.
	/// For a compute shader: the compute stage. Returns false if the engine's templates could not be read.
	public static bool Generate(ShaderAsset shader, StringView engineRoot, String fragment, String vertex, String compute)
	{
		if (shader.IsCompute)
		{
			if (!Template(engineRoot, "cs_template.sc", compute))
				return false;
			let defines = scope String();
			Defines(shader, false, defines);
			compute.Replace("@FORMAT", shader.highPrecision ? "rgba16f" : "rgba8");
			compute.Replace("//@PROPERTIES", defines);
			compute.Replace("//@COMPUTE", shader.compute);
			return true;
		}
		if (!Template(engineRoot, "fs_mesh.sc", fragment) || !Template(engineRoot, "vs_mesh.sc", vertex))
			return false;
		let withTextures = scope String();
		Defines(shader, true, withTextures);
		let valuesOnly = scope String();
		Defines(shader, false, valuesOnly);
		fragment.Replace("//@PROPERTIES", withTextures);
		fragment.Replace("//@SURFACE", shader.surface);
		fragment.Replace("//@UNDEFINE", Undefines(shader, true, .. scope String()));
		vertex.Replace("//@PROPERTIES", valuesOnly);
		vertex.Replace("//@VERTEX", shader.vertex);
		vertex.Replace("//@UNDEFINE", Undefines(shader, false, .. scope String()));
		return true;
	}

	static void ShadercPath(StringView engineRoot, String output)
	{
		let custom = scope String();
		if (Environment.GetEnvironmentVariable("SHADERC", custom) case .Ok && !custom.IsEmpty)
			output.Set(custom);
		else
#if BF_PLATFORM_WINDOWS
			output.AppendF("{}/build/native-win/bgfx/cmake/bgfx/shaderc.exe", engineRoot);
#else
			output.AppendF("{}/build/native/bgfx/cmake/bgfx/shaderc", engineRoot);
#endif
	}

	/// What compiling a shader's stages needs: where things are, and where messages go.
	struct StageJob
	{
		public StringView engineRoot;
		public StringView shaderPath;
		/// The shader compiler (bgfx's shaderc).
		public StringView shaderc;
		/// A temporary folder for the generated source and the compiler's messages.
		public StringView work;
		/// The shader's compiled name.
		public StringView name;
		public StringView outputRoot;
		public String log;
	}

	/// Compiles one stage (vertex, fragment or compute) for every backend, or only the one the editor draws with.
	/// False when it fails for the backend this machine draws with.
	static bool CompileStage(StageJob stage, StringView source, StringView suffix, StringView type, bool thisBackendOnly = false)
	{
		bool usable = true;
		let sourcePath = scope $"{stage.work}/{stage.name}_{suffix}.sc";
		File.WriteAllText(sourcePath, source).IgnoreError();
		for (int t < sTargets.Count)
		{
			let target = sTargets[t];
			if (thisBackendOnly && target.folder != Gfx.ShaderFolder)
				continue;
			let folder = scope $"{stage.outputRoot}/{target.folder}";
			Directory.CreateDirectory(folder).IgnoreError();
			let output = scope $"{folder}/{stage.name}_{suffix}.bin";
			let messages = scope $"{stage.work}/{stage.name}_{suffix}_{target.folder}.log";
			let command = scope String();
			ShadercCommand(stage, target, type, sourcePath, output, messages, command);
			if (Terminal.Run(command) == 0)
				continue;
			File.Delete(output).IgnoreError();
			// Only the backend this machine draws with decides whether the shader works here; the others
			// are extras for other platforms, and say so once.
			if (t == 0 || thisBackendOnly)
			{
				usable = false;
				let said = scope String();
				File.ReadAllText(messages, said, true).IgnoreError();
				int shown = 0;
				for (let line in said.Split('\n', .RemoveEmptyEntries))
				{
					// shaderc echoes the whole source around an error; the lines that say what is wrong are these.
					if ((line.Contains("rror") || line.Contains("ERROR")) && shown++ < 8)
						stage.log.AppendF("{} ({} stage): {}\n", stage.shaderPath, type, line);
				}
				if (shown == 0)
					stage.log.AppendF("{} ({} stage): the shader compiler failed without saying why\n", stage.shaderPath, type);
			}
			else
				stage.log.AppendF("{}: not compiled for {} (other backends are unaffected)\n", stage.shaderPath, target.folder);
		}
		return usable;
	}

	/// The shaderc command line for one stage and backend, its messages sent to `messages`.
	static void ShadercCommand(StageJob stage, (StringView folder, StringView profile, StringView platform) target, StringView type, StringView sourcePath, StringView output, StringView messages, String command)
	{
		Terminal.Quote(stage.shaderc, command);
		command.Append(" -f ");
		Terminal.Quote(sourcePath, command);
		command.Append(" -o ");
		Terminal.Quote(output, command);
		command.AppendF(" --type {} --platform {} -p {} -i ", type, target.platform, target.profile);
		Terminal.Quote(scope $"{stage.engineRoot}/Engine/shaders/include" , command);
		command.Append(" --varyingdef ");
		Terminal.Quote(scope $"{stage.engineRoot}/Engine/shaders/varying.def.sc" , command);
		command.Append(" -O 3 > ");
		Terminal.Quote(messages, command);
		command.Append(" 2>&1");
	}

	/// Compiles one shader file (a project path) for every backend. Messages from the compiler are added to log.
	/// Returns true when the shader can be used on this machine.
	public static bool Compile(StringView engineRoot, StringView shaderPath, String log)
	{
		let full = scope String();
		Assets.ResolvePath(shaderPath, full);
		let text = scope String();
		if (File.ReadAllText(full, text, true) case .Err)
		{
			log.AppendF("{}: the file could not be read\n", shaderPath);
			return false;
		}
		let shader = scope ShaderAsset();
		shader.path.Set(shaderPath);
		shader.Parse(text);
		if (!shader.problems.IsEmpty)
		{
			for (let problem in shader.problems.Split('\n', .RemoveEmptyEntries))
				log.AppendF("{}: {}\n", shaderPath, problem);
			return false;
		}
		let isCompute = shaderPath.EndsWith(".tcompute");
		if (isCompute != shader.IsCompute)
		{
			log.AppendF("{}: {}\n", shaderPath, isCompute ? "a compute shader needs a compute { } block" : "a compute { } block belongs in a .tcompute file");
			return false;
		}
		let fragment = scope String(), vertex = scope String(), compute = scope String();
		if (!Generate(shader, engineRoot, fragment, vertex, compute))
		{
			log.AppendF("{}: the engine's shader templates were not found under {}/Engine/shaders\n", shaderPath, engineRoot);
			return false;
		}
		let shaderc = scope String();
		ShadercPath(engineRoot, shaderc);
		if (!File.Exists(shaderc))
		{
			log.AppendF("{}: the shader compiler was not found at {} (run build.sh)\n", shaderPath, shaderc);
			return false;
		}
		let name = scope String();
		ShaderAsset.CompiledName(shaderPath, name);
		let work = scope String();
		Path.GetTempPath(work);
		work.AppendF("/tallow-shaders-{}", (int)Platform.BfpProcess_GetCurrentId());
		Directory.CreateDirectory(work).IgnoreError();
		// Compiled files live beside the project's other shaders, wherever the shader itself is.
		let outputRoot = scope String();
		outputRoot.AppendF("{}/Shaders/Compiled", Assets.ProjectPath);

		StageJob stage;
		stage.engineRoot = engineRoot;
		stage.shaderPath = shaderPath;
		stage.shaderc = shaderc;
		stage.work = work;
		stage.name = name;
		stage.outputRoot = outputRoot;
		stage.log = log;
		bool usable = true;
		if (shader.IsCompute)
			usable &= CompileStage(stage, compute, "cs", "compute");
		else
		{
			usable &= CompileStage(stage, vertex, "vs", "vertex");
			usable &= CompileStage(stage, fragment, "fs", "fragment");
		}
		// Running materials pick the new program up on their next draw.
		ShaderAsset.Reloaded(shaderPath);
		return usable;
	}

	/// Compiles shader source (a .tshader's or .tcompute's text) for the backend the editor draws with only, into
	/// <outputRoot>/<backend>/<name>_vs.bin and _fs.bin, or _cs.bin: the shader graph's live previews, which load
	/// it with ShaderAsset.FromCompiled. Uses its own work folder, so it can run on another thread. Messages go to
	/// log.
	public static bool CompilePreview(StringView engineRoot, StringView text, StringView name, StringView outputRoot, String log)
	{
		let shader = scope ShaderAsset();
		shader.path.Set(name);
		shader.Parse(text);
		if (!shader.problems.IsEmpty)
		{
			log.Append(shader.problems);
			return false;
		}
		let fragment = scope String(), vertex = scope String(), compute = scope String();
		let shaderc = scope String();
		ShadercPath(engineRoot, shaderc);
		if (!Generate(shader, engineRoot, fragment, vertex, compute) || !File.Exists(shaderc))
		{
			log.Append("the engine's shader templates or the shader compiler were not found\n");
			return false;
		}
		let work = scope $"{outputRoot}/work";
		Directory.CreateDirectory(work).IgnoreError();
		StageJob stage;
		stage.engineRoot = engineRoot;
		stage.shaderPath = name;
		stage.shaderc = shaderc;
		stage.work = work;
		stage.name = name;
		stage.outputRoot = outputRoot;
		stage.log = log;
		if (shader.IsCompute)
			return CompileStage(stage, compute, "cs", "compute", true);
		return CompileStage(stage, vertex, "vs", "vertex", true) && CompileStage(stage, fragment, "fs", "fragment", true);
	}

	static void Collect(StringView folder, StringView root, List<String> output, int depth)
	{
		if (depth > 12 || !Directory.Exists(folder))
			return;
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (name.EndsWith(".tshader") || name.EndsWith(".tcompute"))
				output.Add(new String(scope $"{folder}/{name}" .Substring(root.Length + 1)));
		}
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (!name.StartsWith('.') && name != "Compiled" && name != "build")
				Collect(scope $"{folder}/{name}" , root, output, depth + 1);
		}
	}

	/// The newest of the engine's shader templates and the files they include: a shader compiled before then is
	/// out of date (a change to the lighting reaches custom shaders only when they are compiled again).
	static DateTime NewestTemplate(StringView engineRoot)
	{
		var newest = DateTime.MinValue;
		for (let name in StringView[?]("fs_mesh.sc", "vs_mesh.sc", "cs_template.sc", "include/lighting.sh", "include/wind.sh", "include/shadergraph.sh", "include/palette.sh", "include/bgfx_shader.sh"))
		{
			if (File.GetLastWriteTimeUtc(scope $"{engineRoot}/Engine/shaders/{name}") case .Ok(let time) && time > newest)
				newest = time;
		}
		return newest;
	}

	/// Compiles every shader in the project whose compiled file is missing or older than its source or the engine's
	/// templates (all of them with `everything`). Returns how many failed.
	public static int CompileProject(StringView engineRoot, String log, bool everything = false)
	{
		List<String> shaders = scope .();
		defer
		{
			for (let s in shaders)
				delete s;
		}
		Collect(Assets.ProjectPath, Assets.ProjectPath, shaders, 0);
		int failed = 0;
		let templates = NewestTemplate(engineRoot);
		for (let shaderPath in shaders)
		{
			if (!everything)
			{
				let name = scope String();
				ShaderAsset.CompiledName(shaderPath, name);
				let compiled = scope $"{Assets.ProjectPath}/Shaders/Compiled/{sTargets[0].folder}/{name}_{shaderPath.EndsWith(".tcompute") ? "cs" : "fs"}.bin";
				if (File.GetLastWriteTimeUtc(compiled) case .Ok(let built))
				{
					if (File.GetLastWriteTimeUtc(scope $"{Assets.ProjectPath}/{shaderPath}") case .Ok(let written))
					{
						if (built >= written && built >= templates)
							continue;
					}
				}
			}
			if (!Compile(engineRoot, shaderPath, log))
				failed++;
		}
		return failed;
	}
}
