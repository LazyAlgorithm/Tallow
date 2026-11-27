using System.Security.Cryptography;
using System.Text;

namespace Tallow.ManagedBuild.Export;

/// <summary>
/// What an export has already made, so a build only does the work whose inputs changed: assets copied into a fresh
/// staging folder are hard links to the project's files, and the costly steps (NativeAOT, compressed textures,
/// cooked streaming data, the asset pack) each keep their output in <c>&lt;project&gt;/build/export-cache</c>, keyed
/// by a signature of their inputs. A change to any input makes the next build redo that step; nothing else is redone.
///
/// Signatures are hashes of file paths, sizes and modification times (plus content hashes where a file is small and
/// rewritten every build, such as game.tallow). File timestamps survive <see cref="ExportUtil.LinkFile"/> and
/// <see cref="File.Copy"/> on the platforms the build runs on, so a file that did not change keeps its stamp.
/// </summary>
internal static class ExportCache
{
    /// <summary>Bumped when the cached formats or the steps that make them change, so old caches are not trusted.</summary>
    public const string Version = "1";

    /// <summary>How much one step's cached output may take, in bytes: 4 GB unless TALLOW_BUILD_CACHE_MB says otherwise.
    /// Big steps (a project of very high-poly models can cook tens of gigabytes) are not kept: the next build makes
    /// them again rather than fill the disk.</summary>
    public static long LimitBytes => long.TryParse(Environment.GetEnvironmentVariable("TALLOW_BUILD_CACHE_MB"), out long mb) && mb > 0
        ? mb * 1024L * 1024
        : 4L * 1024 * 1024 * 1024;

    /// <summary>How many bytes the files under a folder take (hard links count their full size).</summary>
    public static long Size(string folder)
    {
        if (!Directory.Exists(folder))
            return 0;
        long total = 0;
        foreach (var (_, full) in ExportUtil.Files(folder))
            total += new FileInfo(full).Length;
        return total;
    }

    public static string Gigabytes(long bytes) => $"{bytes / (1024.0 * 1024 * 1024):0.0} GB";

    public static string Root(string project, Target target, string config) =>
        Path.Combine(project, "build", "export-cache", target.ToString().ToLowerInvariant() + "-" + config.ToLowerInvariant());

    public static string SignatureFile(string folder) => Path.Combine(folder, "signature.txt");

    public static string Hash(params string[] parts)
    {
        using var hash = SHA256.Create();
        return Convert.ToHexString(hash.ComputeHash(Encoding.UTF8.GetBytes(string.Join('\n', parts)))).ToLowerInvariant();
    }

    /// <summary>A file's path, size and timestamp; "missing" when there is none. Web, Android and iOS exports have no
    /// player of their own (<see cref="Exporter"/> passes an empty path), which <see cref="FileInfo"/> rejects.</summary>
    public static string FileStamp(string path)
    {
        if (string.IsNullOrEmpty(path))
            return "missing";
        var info = new FileInfo(path);
        return info.Exists ? $"{path}|{info.Length}|{info.LastWriteTimeUtc.Ticks}" : path + "|missing";
    }

    /// <summary>A file's content, hashed: for small files written fresh each build.</summary>
    public static string ContentStamp(string path) =>
        File.Exists(path) ? path + "|" + ContentHash(path) : path + "|missing";

    static string ContentHash(string path)
    {
        using var hash = SHA256.Create();
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(hash.ComputeHash(stream)).ToLowerInvariant();
    }

    /// <summary>Every file under a folder by path, size and timestamp, in name order. Files whose extension is in
    /// <paramref name="ignore"/> are left out (a step's outputs that another step makes in the same folder).</summary>
    public static string TreeStamp(string folder, params string[] ignore)
    {
        if (!Directory.Exists(folder))
            return folder + "|missing";
        var skipped = ignore.Length == 0 ? null : new HashSet<string>(ignore, StringComparer.OrdinalIgnoreCase);
        var text = new StringBuilder();
        foreach (var (relative, full) in ExportUtil.Files(folder))
        {
            if (skipped != null && skipped.Contains(Path.GetExtension(full)))
                continue;
            var info = new FileInfo(full);
            text.Append(relative).Append('|').Append(info.Length).Append('|');
            if (info.Length <= InlineHash)
                text.Append(ContentHash(full));
            else
                text.Append(info.LastWriteTimeUtc.Ticks);
            text.Append('\n');
        }
        return Hash(text.ToString());
    }

    /// <summary>A folder of build inputs (assemblies) whose contents decide a cached step: hashed by content.</summary>
    public static string ContentTreeStamp(string folder, params string[] extensions)
    {
        if (!Directory.Exists(folder))
            return folder + "|missing";
        var wanted = new HashSet<string>(extensions, StringComparer.OrdinalIgnoreCase);
        var text = new StringBuilder();
        foreach (var (relative, full) in ExportUtil.Files(folder))
            if (wanted.Count == 0 || wanted.Contains(Path.GetExtension(full)))
                text.Append(relative).Append('|').Append(ContentHash(full)).Append('\n');
        return Hash(text.ToString());
    }

    /// <summary>Files up to this size are hashed by content in a tree stamp; bigger ones by size and timestamp. A
    /// scene the editor rewrites unchanged, or a material saved again, must not make a build think its inputs changed,
    /// while hashing a multi-gigabyte model on every build would cost more than the step it guards.</summary>
    const long InlineHash = 1L * 1024 * 1024;

    public static bool Matches(string folder, string signature)
    {
        string file = SignatureFile(folder);
        return Directory.Exists(folder) && File.Exists(file) && ExportUtil.ReadText(file).Trim() == signature;
    }

    public static void Save(string folder, string signature)
    {
        Directory.CreateDirectory(folder);
        File.WriteAllText(SignatureFile(folder), signature + "\n");
    }

    /// <summary>Removes a cached step's files (its signature file stays until the new one is written).</summary>
    public static void Clear(string folder)
    {
        if (!Directory.Exists(folder))
            return;
        foreach (string entry in Directory.EnumerateFileSystemEntries(folder))
            if (Path.GetFileName(entry) != Path.GetFileName(SignatureFile(folder)))
            {
                if (Directory.Exists(entry))
                    Directory.Delete(entry, true);
                else
                    File.Delete(entry);
            }
    }
}
