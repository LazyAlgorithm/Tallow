using System.Buffers.Binary;

namespace Tallow.ManagedBuild.Export;

/// <summary>
/// Compresses a game's pictures for the graphics card (tallowengine.com/docs/textures): each becomes
/// <c>&lt;picture&gt;.ktx</c> beside it, BC1 (opaque) or BC3 (with transparency) with all its mip levels, made with
/// bgfx's texturec. The engine uses the .ktx in place of the picture; the picture stays for code that reads its pixels.
/// Normal maps are left alone; pictures named as a material's metallicRoughnessMap or occlusionMap are compressed as
/// data, without colour correction.
/// </summary>
internal static class Textures
{
    static readonly string[] Pictures = { ".png", ".jpg", ".jpeg", ".tga", ".bmp" };
    public const string DefaultExclude = "UI/*;Fonts/*";
    // texturec marks colour pictures as sRGB. Tallow's shaders decode sRGB themselves, so the graphics card must not
    // as well: the KTX header's internal format is set to the plain one.
    static readonly Dictionary<uint, uint> PlainFormat = new() { [0x8C4C] = 0x83F0, [0x8C4D] = 0x83F1, [0x8C4E] = 0x83F2, [0x8C4F] = 0x83F3 };

    /// <summary>The texturec built with the engine's native libraries, or null.</summary>
    public static string? TexturecPath(string engine)
    {
        foreach (string folder in ExportUtil.HostWindows ? new[] { "native-win", "native" } : new[] { "native" })
        {
            string candidate = Path.Combine(engine, "build", folder, "bgfx", "cmake", "bimg", ExportUtil.HostWindows ? "texturec.exe" : "texturec");
            if (File.Exists(candidate))
                return candidate;
        }
        return null;
    }

    /// <summary>Whether a picture can be see-through, from its header: PNG with an alpha channel or a tRNS chunk,
    /// TGA with alpha bits. JPEG and BMP pictures are taken as opaque.</summary>
    static bool HasAlpha(string path)
    {
        byte[] data = File.ReadAllBytes(path);
        if (data.Length > 25 && data.AsSpan(0, 8).SequenceEqual(new byte[] { 0x89, (byte)'P', (byte)'N', (byte)'G', 13, 10, 26, 10 }))
        {
            byte colorType = data[25];
            if (colorType is 4 or 6)
                return true;
            int idat = data.AsSpan().IndexOf("IDAT"u8);
            return idat >= 0 && data.AsSpan(0, idat).IndexOf("tRNS"u8) >= 0;
        }
        if (Path.GetExtension(path).Equals(".tga", StringComparison.OrdinalIgnoreCase) && data.Length > 17)
            return (data[17] & 0x0F) > 0;
        return false;
    }

    /// <summary>Pictures the project's materials name as normal maps, and as data (metal / roughness, occlusion).</summary>
    static (HashSet<string> Normal, HashSet<string> Data) KindsFromMaterials(string folder)
    {
        var normal = new HashSet<string>(StringComparer.Ordinal);
        var data = new HashSet<string>(StringComparer.Ordinal);
        foreach (string material in Directory.EnumerateFiles(folder, "*.tmat", SearchOption.AllDirectories))
        {
            foreach (string line in ExportUtil.ReadText(material).Split('\n'))
            {
                string trimmed = line.TrimStart();
                int space = trimmed.IndexOfAny(new[] { ' ', '\t' });
                if (space < 0)
                    continue;
                string key = trimmed[..space];
                string rest = trimmed[space..].Trim();
                if (!rest.StartsWith('"'))
                    continue;
                string value = rest.Trim().Trim('"');
                if (key == "normalMap")
                    normal.Add(value);
                else if (key is "metallicRoughnessMap" or "occlusionMap")
                    data.Add(value);
            }
        }
        return (normal, data);
    }

    /// <summary>The pictures the project's materials name (any slot), as (path relative to the folder, kind: color, data
    /// or normal): the ones the engine can stream, listed for the export's cooking step.</summary>
    public static List<(string Path, string Kind)> MaterialPictures(string folder)
    {
        var (normal, data) = KindsFromMaterials(folder);
        var found = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (string material in Directory.EnumerateFiles(folder, "*.tmat", SearchOption.AllDirectories))
        {
            foreach (string line in ExportUtil.ReadText(material).Split('\n'))
            {
                string trimmed = line.TrimStart();
                int space = trimmed.IndexOfAny(new[] { ' ', '\t' });
                if (space < 0)
                    continue;
                string rest = trimmed[space..].Trim();
                if (!rest.StartsWith('"'))
                    continue;
                string value = rest.Trim('"').Replace('\\', '/');
                if (Pictures.Contains(System.IO.Path.GetExtension(value).ToLowerInvariant()) && File.Exists(System.IO.Path.Combine(folder, value)))
                    found[value] = normal.Contains(value) ? "normal" : data.Contains(value) ? "data" : "color";
            }
        }
        return found.Select(pair => (pair.Key, pair.Value)).ToList();
    }

    /// <summary>Rewrites a KTX file's sRGB internal format to the plain one.</summary>
    static void PlainSrgb(string path)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.ReadWrite);
        var header = new byte[32];
        if (file.Read(header) < 32 || !header.AsSpan(0, 12).SequenceEqual(new byte[] { 0xAB, (byte)'K', (byte)'T', (byte)'X', (byte)' ', (byte)'1', (byte)'1', 0xBB, 13, 10, 26, 10 }))
            return;
        uint format = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(28));
        if (PlainFormat.TryGetValue(format, out uint plain))
        {
            file.Position = 28;
            var bytes = new byte[4];
            BinaryPrimitives.WriteUInt32LittleEndian(bytes, plain);
            file.Write(bytes);
        }
    }

    /// <summary>Makes picture + ".ktx". Returns an error message, or null.</summary>
    static string? Compress(string texturec, string picture, bool linear)
    {
        string output = picture + ".ktx";
        var arguments = new List<string> { "-f", picture, "-o", output, "-t", HasAlpha(picture) ? "BC3" : "BC1", "-m", "--as", "ktx" };
        if (linear)
            arguments.Add("--linear");
        var run = ExportUtil.TryRun(texturec, arguments);
        if (run.ExitCode != 0 || !File.Exists(output))
        {
            File.Delete(output);
            return $"{Path.GetFileName(picture)}: {(run.Error.Length > 0 ? run.Error : run.Output).Trim()}";
        }
        PlainSrgb(output);
        return null;
    }

    /// <summary>Compresses every picture under a folder. Returns (made, skipped, errors).</summary>
    public static (int Made, int Skipped, List<string> Errors) CompressFolder(string folder, string engine, string exclude)
    {
        string? texturec = TexturecPath(engine);
        if (texturec == null)
            return (0, 0, new List<string> { "texturec is not built (cmake --build build/native --target texturec); pictures are left uncompressed" });
        var patterns = exclude.Split(';').Select(pattern => pattern.Trim()).Where(pattern => pattern.Length > 0).ToList();
        var (normal, data) = KindsFromMaterials(folder);
        var jobs = new List<(string Picture, bool Linear)>();
        int skipped = 0;
        foreach (var (relative, picture) in ExportUtil.Files(folder))
        {
            if (!Pictures.Contains(Path.GetExtension(picture).ToLowerInvariant()))
                continue;
            var options = ExportUtil.ReadSettings(picture + ".import");
            string name = Path.GetFileName(picture);
            // Baked lightmaps (tallowengine.com/docs/baked-lighting) are RGBM: block compression would spoil the range
            // in alpha. A picture whose .import turns compressed copies off, or mip levels off (the engine would not
            // use a compressed copy then), is left as it is.
            if (patterns.Any(pattern => ExportUtil.FnMatch(relative, pattern, ExportUtil.HostWindows)) || normal.Contains(relative) ||
                name.Contains("normal", StringComparison.OrdinalIgnoreCase) || name.StartsWith("Lightmap-", StringComparison.Ordinal) ||
                options.Get("compression") == "0" || options.Get("mipmaps") == "0")
            {
                skipped++;
                continue;
            }
            jobs.Add((picture, data.Contains(relative)));
        }
        var results = new string?[jobs.Count];
        Parallel.For(0, jobs.Count, new ParallelOptions { MaxDegreeOfParallelism = Environment.ProcessorCount },
            i => results[i] = Compress(texturec, jobs[i].Picture, jobs[i].Linear));
        var errors = results.Where(error => error != null).Select(error => error!).ToList();
        return (jobs.Count - errors.Count, skipped, errors);
    }
}
