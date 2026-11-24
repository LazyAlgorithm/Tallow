namespace Tallow.ManagedBuild.Export;

/// <summary>
/// Converts a project's FBX, OBJ, DAE, STL, PLY, 3DS and .blend files to .glb, as the editor does
/// (tallowengine.com/docs/model-import): the same converters in the same order, the same cache
/// (&lt;project&gt;/.cache/models), then the import settings kept beside each file.
/// </summary>
internal static class Models
{
    static readonly string[] Extensions = { ".fbx", ".obj", ".dae", ".stl", ".ply", ".3ds", ".blend" };

    const string BlenderScript = """
        import bpy, sys
        args = sys.argv[sys.argv.index('--') + 1:]
        source, out = args[0], args[1]
        kind = source.lower().rsplit('.', 1)[-1]
        if kind == 'fbx': bpy.ops.import_scene.fbx(filepath=source)
        elif kind == 'obj': bpy.ops.wm.obj_import(filepath=source)
        elif kind == 'stl': bpy.ops.wm.stl_import(filepath=source)
        elif kind == 'ply': bpy.ops.wm.ply_import(filepath=source)
        bpy.ops.export_scene.gltf(filepath=out, export_format='GLB', export_apply=True, export_animations=True)

        """;

    public static bool IsConverted(string name) => Extensions.Any(extension => name.EndsWith(extension, StringComparison.OrdinalIgnoreCase));

    static string NativeFolder(string engine) => Path.Combine(engine, "build", ExportUtil.HostWindows ? "native-win" : "native");

    static string Tool(string engine, string name) => Path.Combine(NativeFolder(engine), ExportUtil.HostWindows ? name + ".exe" : name);

    static string? FindBlender()
    {
        string? fromEnvironment = Environment.GetEnvironmentVariable("TALLOW_BLENDER");
        if (!string.IsNullOrEmpty(fromEnvironment) && File.Exists(fromEnvironment))
            return fromEnvironment;
        string? found = ExportUtil.Which("blender");
        if (found != null)
            return found;
        if (ExportUtil.HostWindows)
        {
            string folder = "C:/Program Files/Blender Foundation";
            if (!Directory.Exists(folder))
                return null;
            return Directory.EnumerateDirectories(folder).Order(StringComparer.Ordinal)
                .Select(version => Path.Combine(version, "blender.exe")).FirstOrDefault(File.Exists);
        }
        const string mac = "/Applications/Blender.app/Contents/MacOS/Blender";
        return File.Exists(mac) ? mac : null;
    }

    /// <summary>As the editor writes it (ModelImport.SourceStamp): .NET ticks of the file's time, and its size.</summary>
    static string SourceStamp(string source)
    {
        var info = new FileInfo(source);
        return $"{info.LastWriteTimeUtc.Ticks}|{info.Length}\n";
    }

    static string ReadOrEmpty(string path) => File.Exists(path) ? ExportUtil.ReadText(path) : "";

    static string? RunConverter(string source, string output, string engine, string? blender, string? assimp)
    {
        string kind = Path.GetExtension(source).ToLowerInvariant();
        string own = Tool(engine, "tallow_modelconv");
        string file;
        List<string> arguments;
        if (kind != ".blend" && File.Exists(own))
        {
            file = own;
            arguments = new() { source, output };
        }
        else if (kind != ".blend" && assimp != null && !(kind == ".fbx" && blender != null))
        {
            file = assimp;
            arguments = new() { "export", source, output, "-fglb2", "-tri", "-jiv", "-gsn", "-lbw", "-embtex" };
        }
        else if (blender != null && kind is not (".dae" or ".3ds"))
        {
            string script = Path.Combine(Path.GetDirectoryName(output)!, "tallow_blender_import.py");
            File.WriteAllText(script, BlenderScript);
            file = blender;
            arguments = new() { "-b" };
            if (kind == ".blend")
                arguments.Add(source);
            else
                arguments.Add("--factory-startup");
            arguments.AddRange(new[] { "--python", script, "--", source, output });
        }
        else
            return kind == ".blend" ? "Blender is needed for .blend files and was not found"
                : "no model converter was found (tallow_modelconv, assimp or Blender)";
        var result = ExportUtil.TryRun(file, arguments);
        if (result.ExitCode != 0 || !File.Exists(output))
        {
            var lines = result.All.Trim().Split('\n', StringSplitOptions.RemoveEmptyEntries);
            return lines.Length > 0 ? lines[^1].Trim() : $"the converter stopped with status {result.ExitCode}";
        }
        return null;
    }

    /// <summary>Brings &lt;project&gt;/.cache/models/&lt;relative&gt;.glb up to date. Returns (path, error).</summary>
    static (string? Path, string? Error) Convert(string project, string relative, string engine, string? blender, string? assimp)
    {
        string source = Path.Combine(project, "src", relative);
        string cache = Path.Combine(project, ".cache", "models");
        string converted = Path.Combine(cache, relative + ".glb");
        string raw = Path.Combine(cache, relative + ".source.glb");
        Directory.CreateDirectory(Path.GetDirectoryName(converted)!);
        string stamp = SourceStamp(source);
        string fullStamp = stamp + ReadOrEmpty(source + ".import");
        string from = converted + ".from";
        if (File.Exists(converted) && File.Exists(from) && ExportUtil.ReadText(from) == fullStamp)
            return (converted, null);
        string rawFrom = raw + ".from";
        if (!File.Exists(raw) || !File.Exists(rawFrom) || ExportUtil.ReadText(rawFrom) != stamp)
        {
            string made = raw + ".part.glb";
            File.Delete(made);
            string? error = RunConverter(source, made, engine, blender, assimp);
            if (error != null)
                return (null, error);
            File.Move(made, raw, true);
            File.WriteAllText(rawFrom, stamp);
        }
        var settings = ExportUtil.ReadSettings(source + ".import", new()
        {
            ["scale"] = "1", ["zUp"] = "0", ["animations"] = "1", ["clips"] = "", ["materials"] = "1"
        });
        string tool = Tool(engine, "tallow_modelsettings");
        string part = converted + ".part";
        if (!File.Exists(tool))
            return (null, $"{Path.GetFileName(tool)} was not found (build the engine native libraries)");
        var applied = ExportUtil.TryRun(tool, new[] { raw, part, settings["scale"], settings["zUp"], settings["animations"],
            settings["clips"], settings["materials"] });
        if (applied.ExitCode != 0)
            return (null, applied.Error.Trim().Length > 0 ? applied.Error.Trim() : "the import settings could not be applied");
        File.Move(part, converted, true);
        File.WriteAllText(from, fullStamp);
        return (converted, null);
    }

    /// <summary>Every converted model in the project, up to date: (relative path, .glb path) pairs and errors.</summary>
    public static (List<(string Relative, string Path)> Done, List<string> Errors) ConvertProject(string project, string engine)
    {
        string? blender = FindBlender();
        string? assimp = ExportUtil.Which("assimp");
        var done = new List<(string, string)>();
        var errors = new List<string>();
        foreach (var (relative, file) in ExportUtil.Files(Path.Combine(project, "src")))
        {
            if (!IsConverted(Path.GetFileName(file)) || ExportUtil.Hidden(relative))
                continue;
            var (path, error) = Convert(project, relative, engine, blender, assimp);
            if (error != null)
                errors.Add($"{relative}: {error}");
            else
                done.Add((relative, path!));
        }
        return (done, errors);
    }
}
