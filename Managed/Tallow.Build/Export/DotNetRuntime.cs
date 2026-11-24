using System.Formats.Tar;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;

namespace Tallow.ManagedBuild.Export;

/// <summary>The .NET runtime a JIT export ships (dotnet/ beside the game), for whichever platform it is for: copied
/// from this machine's .NET when that is the same platform, otherwise Microsoft's download of the same version,
/// checked against the SHA-512 in Microsoft's release list and kept in a per-user cache.</summary>
internal static class DotNetRuntime
{
    public const int Major = 11;

    /// <summary>The .NET that runs this tool: its folder holding host/ and shared/.</summary>
    public static string? HostRoot()
    {
        string? fromEnvironment = Environment.GetEnvironmentVariable("DOTNET_ROOT");
        if (!string.IsNullOrEmpty(fromEnvironment) && Directory.Exists(Path.Combine(fromEnvironment, "host", "fxr")))
            return fromEnvironment;
        // .../shared/Microsoft.NETCore.App/<version>/System.Private.CoreLib.dll
        string? core = Path.GetDirectoryName(typeof(object).Assembly.Location);
        string? root = core == null ? null : Path.GetFullPath(Path.Combine(core, "..", "..", ".."));
        return root != null && Directory.Exists(Path.Combine(root, "host", "fxr")) ? root : null;
    }

    /// <summary>The newest folder of a .NET version of <paramref name="major"/> in a folder (releases before previews).</summary>
    public static string? Newest(string folder, int major)
    {
        if (!Directory.Exists(folder))
            return null;
        string? best = null;
        (int[] Numbers, bool Release, string Pre) bestKey = default;
        foreach (string entry in Directory.EnumerateDirectories(folder))
        {
            string name = Path.GetFileName(entry);
            if (name.Split('.')[0] != major.ToString())
                continue;
            int dash = name.IndexOf('-');
            string core = dash < 0 ? name : name[..dash];
            string pre = dash < 0 ? "" : name[(dash + 1)..];
            var key = (core.Split('.').Select(part => int.TryParse(part, out int value) ? value : 0).ToArray(), pre.Length == 0, pre);
            if (best == null || Compare(key, bestKey) > 0)
            {
                best = entry;
                bestKey = key;
            }
        }
        return best;
    }

    static int Compare((int[] Numbers, bool Release, string Pre) a, (int[] Numbers, bool Release, string Pre) b)
    {
        for (int i = 0; i < Math.Max(a.Numbers.Length, b.Numbers.Length); i++)
        {
            int x = i < a.Numbers.Length ? a.Numbers[i] : -1, y = i < b.Numbers.Length ? b.Numbers[i] : -1;
            if (x != y)
                return x.CompareTo(y);
        }
        if (a.Release != b.Release)
            return a.Release ? 1 : -1;
        return string.CompareOrdinal(a.Pre, b.Pre);
    }

    /// <summary>Puts the runtime for <paramref name="rid"/> into staging/dotnet. Returns its version.</summary>
    public static string Bundle(string staging, string rid)
    {
        string? hostRoot = HostRoot();
        string? framework = hostRoot == null ? null : Newest(Path.Combine(hostRoot, "shared", "Microsoft.NETCore.App"), Major);
        if (framework == null)
            throw new ExportException($"The .NET {Major} runtime to bundle was not found beside dotnet; install it or pass --no-bundle-dotnet.");
        string version = Path.GetFileName(framework);
        string root = rid == ExportUtil.HostRid() ? hostRoot! : Download(version, rid);
        framework = Newest(Path.Combine(root, "shared", "Microsoft.NETCore.App"), Major);
        string? fxr = Newest(Path.Combine(root, "host", "fxr"), Major);
        if (fxr == null || framework == null)
            throw new ExportException($"The .NET {Major} runtime for {rid} is incomplete in {root}; pass --no-bundle-dotnet.");
        string bundled = Path.Combine(staging, "dotnet");
        ExportUtil.CopyTree(fxr, Path.Combine(bundled, "host", "fxr", Path.GetFileName(fxr)));
        ExportUtil.CopyTree(framework, Path.Combine(bundled, "shared", "Microsoft.NETCore.App", Path.GetFileName(framework)));
        foreach (string notice in new[] { "LICENSE.txt", "ThirdPartyNotices.txt" })
            if (File.Exists(Path.Combine(root, notice)))
                File.Copy(Path.Combine(root, notice), Path.Combine(bundled, notice), true);
        Console.WriteLine($".NET {Path.GetFileName(framework)} bundled ({ExportUtil.Size(bundled) / (1024 * 1024)} MB)");
        return version;
    }

    /// <summary>Microsoft's .NET runtime <paramref name="version"/> for <paramref name="rid"/>, unpacked into the
    /// cache (downloaded once). Returns the folder holding its host/ and shared/.</summary>
    static string Download(string version, string rid)
    {
        string cacheRoot = Path.Combine(ExportUtil.CacheFolder(), "dotnet-runtime");
        string cache = Path.Combine(cacheRoot, $"{version}-{rid}");
        if (Directory.Exists(Path.Combine(cache, "host", "fxr")) && Directory.Exists(Path.Combine(cache, "shared", "Microsoft.NETCore.App", version)))
            return cache;
        string majorMinor = string.Join('.', version.Split('-')[0].Split('.').Take(2));
        string index = $"https://builds.dotnet.microsoft.com/dotnet/release-metadata/{majorMinor}/releases.json";
        string archiveName = $"dotnet-runtime-{rid}.{(rid.StartsWith("win", StringComparison.Ordinal) ? "zip" : "tar.gz")}";
        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        string url, expected;
        try
        {
            using JsonDocument releases = JsonDocument.Parse(http.GetStringAsync(index).GetAwaiter().GetResult());
            JsonElement? file = null;
            foreach (JsonElement release in releases.RootElement.GetProperty("releases").EnumerateArray())
            {
                if (!release.TryGetProperty("runtime", out JsonElement runtime) || runtime.ValueKind != JsonValueKind.Object ||
                    !runtime.TryGetProperty("version", out JsonElement runtimeVersion) || runtimeVersion.GetString() != version)
                    continue;
                foreach (JsonElement candidate in runtime.GetProperty("files").EnumerateArray())
                    if (candidate.TryGetProperty("rid", out var fileRid) && fileRid.GetString() == rid &&
                        candidate.TryGetProperty("name", out var name) && name.GetString() == archiveName)
                        file = candidate;
            }
            if (file == null)
                throw new ExportException($"Microsoft lists no {rid} .NET runtime {version}; pass --no-bundle-dotnet.");
            url = file.Value.GetProperty("url").GetString()!;
            expected = file.Value.GetProperty("hash").GetString()!.ToLowerInvariant();
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or JsonException or KeyNotFoundException or InvalidOperationException)
        {
            throw new ExportException($"Could not read the list of .NET releases ({index}): {exception.Message}. Pass --no-bundle-dotnet " +
                $"to build without the runtime (players then install .NET {Major}).");
        }
        Console.WriteLine($"Downloading the {rid} .NET runtime {version} (once; kept in {cacheRoot})...");
        Directory.CreateDirectory(cacheRoot);
        string temporary = Path.Combine(cacheRoot, $".download-{rid}-{Environment.ProcessId}");
        if (Directory.Exists(temporary))
            Directory.Delete(temporary, true);
        Directory.CreateDirectory(temporary);
        try
        {
            string archive = Path.Combine(temporary, archiveName);
            try
            {
                using var response = http.GetStreamAsync(url).GetAwaiter().GetResult();
                using var output = File.Create(archive);
                response.CopyTo(output);
            }
            catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or IOException)
            {
                throw new ExportException($"Could not download {url}: {exception.Message}");
            }
            string digest;
            using (var stream = File.OpenRead(archive))
                digest = Convert.ToHexStringLower(SHA512.HashData(stream));
            if (digest != expected)
                throw new ExportException($"The download of {url} does not match the SHA-512 Microsoft lists for it; not used.");
            string unpacked = Path.Combine(temporary, "runtime");
            Directory.CreateDirectory(unpacked);
            if (archiveName.EndsWith(".zip", StringComparison.Ordinal))
            {
                using ZipArchive zip = ZipFile.OpenRead(archive);
                foreach (ZipArchiveEntry entry in zip.Entries)
                    if (entry.FullName.StartsWith('/') || entry.FullName.StartsWith('\\') || entry.FullName.Replace('\\', '/').Split('/').Contains(".."))
                        throw new ExportException($"{url} holds an unsafe path ({entry.FullName}); not used.");
                zip.ExtractToDirectory(unpacked);
            }
            else
            {
                using var file = File.OpenRead(archive);
                using var gzip = new GZipStream(file, CompressionMode.Decompress);
                // Refuses entries that would land outside the folder.
                TarFile.ExtractToDirectory(gzip, unpacked, true);
            }
            if (Directory.Exists(cache))
                Directory.Delete(cache, true);
            Directory.Move(unpacked, cache);
        }
        finally
        {
            if (Directory.Exists(temporary))
                Directory.Delete(temporary, true);
        }
        return cache;
    }
}
