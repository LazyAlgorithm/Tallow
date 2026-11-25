using System.Text.RegularExpressions;

namespace Tallow.ManagedBuild.Export;

/// <summary>
/// Custom skyboxes (tallowengine.com/docs/skybox): each one a scene draws is converted once, at export, to the cube the
/// game loads, <c>&lt;skybox&gt;.sky.ktx</c> beside it (Engine/src/Render/Skybox.bf reads it from the pack). The
/// engine's player imports it with no window (<c>TallowPlayer --cook-skyboxes</c>, the editor's own import: RGBA16F
/// with mips), then texturec compresses it to BC6H with its mips on desktop builds; the web, Android and iOS keep the
/// RGBA16F cube. The source pictures are then left out of the game. Never fails the build: a skybox that was not
/// cooked keeps its source, and the game imports it when it first draws it.
/// </summary>
internal static class SkyboxCook
{
    // Pictures that are only ever skyboxes, whatever their .tmeta says.
    static readonly string[] SkyOnly = { ".hdr", ".exr", ".dds" };
    static readonly Regex SkyboxLine = new("^env (?:skybox|nightSkybox) \"((?:[^\"\\\\]|\\\\.)*)\"", RegexOptions.Multiline | RegexOptions.CultureInvariant);

    /// <summary>The skyboxes the game's scenes name, as project paths.</summary>
    public static SortedSet<string> Used(string assets)
    {
        var found = new SortedSet<string>(StringComparer.Ordinal);
        foreach (var (_, file) in ExportUtil.Files(assets))
        {
            if (!file.EndsWith(".tscene", StringComparison.Ordinal) && !file.EndsWith(".tcell", StringComparison.Ordinal))
                continue;
            foreach (Match match in SkyboxLine.Matches(File.ReadAllText(file)))
            {
                string path = Unquote(match.Groups[1].Value);
                if (path.Length > 0 && (File.Exists(Path.Combine(assets, path)) || Directory.Exists(Path.Combine(assets, path))))
                    found.Add(path);
            }
        }
        return found;
    }

    // The inside of a quoted string as SceneSerializer.Quote writes it (\" \\ \n).
    static string Unquote(string quoted)
    {
        var text = new System.Text.StringBuilder();
        for (int i = 0; i < quoted.Length; i++)
        {
            char c = quoted[i];
            if (c == '\\' && i + 1 < quoted.Length)
            {
                c = quoted[++i];
                if (c == 'n')
                    c = '\n';
            }
            text.Append(c);
        }
        return text.ToString().Replace('\\', '/');
    }

    /// <summary>Cooks into the staging folder. Returns a message to print, or null when there was nothing to do.</summary>
    public static string? Run(string player, string staging, string engine, bool compress)
    {
        string assets = Path.Combine(staging, "Assets");
        if (!Directory.Exists(assets))
            return null;
        var used = Used(assets);
        if (used.Count == 0)
            return null;
        string list = Path.Combine(staging, "cook-skyboxes.txt");
        File.WriteAllText(list, string.Concat(used.Select(path => path + "\n")));
        ExportUtil.Result run;
        try
        {
            run = ExportUtil.TryRun(player, new[] { "--cook-skyboxes", staging, "--cook-list", list });
        }
        finally
        {
            File.Delete(list);
        }
        string? texturec = compress ? Textures.TexturecPath(engine) : null;
        var notes = new List<string>();
        int compressed = 0, plain = 0;
        foreach (string path in used)
        {
            string source = Path.Combine(assets, path);
            string raw = source + ".sky16.ktx", cooked = source + ".sky.ktx";
            if (!File.Exists(raw))
            {
                notes.Add($"{path} was not cooked; the game imports it when it first draws it");
                continue;
            }
            bool made = false;
            if (texturec != null)
            {
                var convert = ExportUtil.TryRun(texturec, new[] { "-f", raw, "-o", cooked, "-t", "BC6H", "-m", "--as", "ktx", "--linear" });
                made = convert.ExitCode == 0 && File.Exists(cooked);
                if (!made)
                    notes.Add($"{path}: BC6H failed ({(convert.Error.Length > 0 ? convert.Error : convert.Output).Trim()}); shipped uncompressed");
            }
            if (made)
            {
                File.Delete(raw);
                compressed++;
            }
            else
            {
                File.Move(raw, cooked, true);
                plain++;
            }
            // The source stays out of the game when it can only be a skybox (a folder of faces, an HDR picture, or a
            // picture the editor marked as one); a picture also used as a texture stays.
            string meta = source + ".tmeta";
            bool skyOnly = Directory.Exists(source) || SkyOnly.Any(ext => source.EndsWith(ext, StringComparison.OrdinalIgnoreCase))
                || (File.Exists(meta) && File.ReadAllLines(meta).Any(line => line.Trim() == "kind skybox"));
            if (!skyOnly)
                continue;
            if (Directory.Exists(source))
                Directory.Delete(source, true);
            else
                File.Delete(source);
            File.Delete(meta);
        }
        string summary = $"Skyboxes: {compressed} compressed to BC6H, {plain} uncompressed";
        if (run.ExitCode != 0)
            notes.Add($"the player's cooking step said: {(run.Output + run.Error).Trim().Split('\n').LastOrDefault()}");
        return summary + string.Concat(notes.Select(note => "\n  note: " + note));
    }
}
