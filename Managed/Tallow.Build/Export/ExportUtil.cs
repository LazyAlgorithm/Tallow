using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace Tallow.ManagedBuild.Export;

/// <summary>An export stops: <see cref="Usage"/> for a wrong command line or project (exit 2), else exit 1.</summary>
internal sealed class ExportException(string message, bool usage = false) : Exception(message)
{
    public bool Usage { get; } = usage;
}

/// <summary>The platforms a game is exported for.</summary>
internal enum Target { Linux, Windows, MacOS, Web }

internal static class ExportUtil
{
    public static bool HostWindows => OperatingSystem.IsWindows();
    public static bool HostMac => OperatingSystem.IsMacOS();
    public static bool HostLinux => OperatingSystem.IsLinux();

    /// <summary>A program's output, both streams (standard error after standard output).</summary>
    public sealed record Result(int ExitCode, string Output, string Error)
    {
        public string All => Output + Error;
    }

    /// <summary>Runs a program and waits for it. With <paramref name="capture"/> its output is returned, otherwise
    /// it goes to this program's own.</summary>
    public static Result Run(string file, IEnumerable<string> arguments, bool capture = false, string? directory = null,
        IDictionary<string, string>? environment = null)
    {
        var start = new ProcessStartInfo(file)
        {
            UseShellExecute = false,
            RedirectStandardOutput = capture,
            RedirectStandardError = capture,
        };
        foreach (string argument in arguments)
            start.ArgumentList.Add(argument);
        if (directory != null)
            start.WorkingDirectory = directory;
        if (environment != null)
            foreach (var (key, value) in environment)
                start.Environment[key] = value;
        using Process process = Process.Start(start) ?? throw new ExportException($"Could not start {file}.");
        if (!capture)
        {
            process.WaitForExit();
            return new Result(process.ExitCode, "", "");
        }
        Task<string> output = process.StandardOutput.ReadToEndAsync();
        Task<string> error = process.StandardError.ReadToEndAsync();
        process.WaitForExit();
        return new Result(process.ExitCode, output.Result, error.Result);
    }

    /// <summary>Like <see cref="Run"/>, but a program that cannot be started counts as a failure (exit -1).</summary>
    public static Result TryRun(string file, IEnumerable<string> arguments, bool capture = true, string? directory = null,
        IDictionary<string, string>? environment = null)
    {
        try
        {
            return Run(file, arguments, capture, directory, environment);
        }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or ExportException)
        {
            return new Result(-1, "", exception.Message);
        }
    }

    /// <summary>A program on PATH (with .exe on Windows), or null.</summary>
    public static string? Which(string name)
    {
        string path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (string folder in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            foreach (string candidate in HostWindows ? new[] { name + ".exe", name } : new[] { name })
            {
                string full = Path.Combine(folder, candidate);
                if (File.Exists(full))
                    return full;
            }
        }
        return null;
    }

    /// <summary>Copies a folder's files and folders (links followed), skipping names <paramref name="skip"/> says to.</summary>
    public static void CopyTree(string source, string target, Func<string, bool>? skip = null)
    {
        Directory.CreateDirectory(target);
        foreach (string file in Directory.EnumerateFiles(source))
        {
            string name = Path.GetFileName(file);
            if (skip == null || !skip(name))
                File.Copy(file, Path.Combine(target, name), true);
        }
        foreach (string folder in Directory.EnumerateDirectories(source))
        {
            string name = Path.GetFileName(folder);
            if (skip == null || !skip(name))
                CopyTree(folder, Path.Combine(target, name), skip);
        }
    }

    /// <summary>Every file under a folder, as (path relative to it with forward slashes, full path), in name order.</summary>
    public static List<(string Relative, string Full)> Files(string folder)
    {
        var found = new List<(string, string)>();
        if (!Directory.Exists(folder))
            return found;
        foreach (string file in Directory.EnumerateFiles(folder, "*", SearchOption.AllDirectories))
            found.Add((Path.GetRelativePath(folder, file).Replace('\\', '/'), file));
        found.Sort((a, b) => string.CompareOrdinal(a.Item1, b.Item1));
        return found;
    }

    /// <summary>Whether any part of a relative path starts with a dot (hidden files and folders).</summary>
    public static bool Hidden(string relative) => relative.Split('/').Any(part => part.StartsWith('.'));

    public static long Size(string folder) =>
        Directory.Exists(folder) ? Directory.EnumerateFiles(folder, "*", SearchOption.AllDirectories).Sum(file => new FileInfo(file).Length) : 0;

    /// <summary>Python's os.path.splitext for '/'-separated paths: (root, extension with its dot, or "").</summary>
    public static (string Root, string Extension) SplitExt(string path)
    {
        int slash = path.LastIndexOf('/');
        int dot = path.LastIndexOf('.');
        if (dot <= slash)
            return (path, "");
        // Leading dots of the file name are not an extension (.gitignore).
        int start = slash + 1;
        while (start < dot && path[start] == '.')
            start++;
        if (start == dot)
            return (path, "");
        return (path[..dot], path[dot..]);
    }

    public static string DirName(string path)
    {
        int slash = path.LastIndexOf('/');
        return slash < 0 ? "" : path[..slash];
    }

    public static string BaseName(string path) => path[(path.LastIndexOf('/') + 1)..];

    /// <summary>Python's fnmatch: * and ? match any characters (slashes too), [...] sets, [!...] negated sets.</summary>
    public static bool FnMatch(string name, string pattern, bool ignoreCase = false)
    {
        var regex = new StringBuilder("^");
        for (int i = 0; i < pattern.Length; i++)
        {
            char c = pattern[i];
            if (c == '*')
                regex.Append(".*");
            else if (c == '?')
                regex.Append('.');
            else if (c == '[')
            {
                int j = i + 1;
                if (j < pattern.Length && pattern[j] == '!')
                    j++;
                if (j < pattern.Length && pattern[j] == ']')
                    j++;
                while (j < pattern.Length && pattern[j] != ']')
                    j++;
                if (j >= pattern.Length)
                    regex.Append("\\[");
                else
                {
                    string set = pattern[(i + 1)..j].Replace("\\", "\\\\");
                    if (set.StartsWith('!'))
                        set = "^" + set[1..];
                    else if (set.StartsWith('^'))
                        set = "\\" + set;
                    regex.Append('[').Append(set).Append(']');
                    i = j;
                }
            }
            else
                regex.Append(Regex.Escape(c.ToString()));
        }
        regex.Append('$');
        return Regex.IsMatch(name, regex.ToString(), RegexOptions.Singleline | RegexOptions.CultureInvariant |
            (ignoreCase ? RegexOptions.IgnoreCase : RegexOptions.None));
    }

    /// <summary>Reads key = value lines (project.tallow, .import files).</summary>
    public static Dictionary<string, string> ReadSettings(string path, Dictionary<string, string>? defaults = null)
    {
        var settings = defaults != null ? new Dictionary<string, string>(defaults) : new Dictionary<string, string>();
        if (!File.Exists(path))
            return settings;
        foreach (string line in ReadText(path).Split('\n'))
        {
            int equals = line.IndexOf('=');
            if (equals >= 0)
                settings[line[..equals].Trim()] = line[(equals + 1)..].Trim();
        }
        return settings;
    }

    /// <summary>A text file, invalid UTF-8 replaced (Python's errors='replace'); line ends normalised to \n.</summary>
    public static string ReadText(string path) => File.ReadAllText(path, new UTF8Encoding(false, false)).Replace("\r\n", "\n");

    public static string Get(this Dictionary<string, string> settings, string key, string fallback = "") =>
        settings.TryGetValue(key, out string? value) ? value : fallback;

    static readonly uint[] CrcTable = MakeCrcTable();

    static uint[] MakeCrcTable()
    {
        var table = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            uint c = n;
            for (int k = 0; k < 8; k++)
                c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[n] = c;
        }
        return table;
    }

    /// <summary>zlib's CRC-32.</summary>
    public static uint Crc32(ReadOnlySpan<byte> data)
    {
        uint crc = 0xFFFFFFFFu;
        foreach (byte b in data)
            crc = CrcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
        return crc ^ 0xFFFFFFFFu;
    }

    /// <summary>The cache folder for downloads and build helpers (Python's ~/.cache/tallow on Linux).</summary>
    public static string CacheFolder()
    {
        if (HostWindows)
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Tallow", "cache");
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (HostMac)
            return Path.Combine(home, "Library", "Caches", "tallow");
        string? xdg = Environment.GetEnvironmentVariable("XDG_CACHE_HOME");
        return Path.Combine(string.IsNullOrEmpty(xdg) ? Path.Combine(home, ".cache") : xdg, "tallow");
    }

    public static void MakeExecutable(string path)
    {
        if (!OperatingSystem.IsWindows() && File.Exists(path))
            File.SetUnixFileMode(path, File.GetUnixFileMode(path) | UnixFileMode.UserExecute | UnixFileMode.GroupExecute |
                UnixFileMode.OtherExecute);
    }

    /// <summary>This machine's .NET runtime identifier: linux-x64, win-x64, osx-arm64...</summary>
    public static string HostRid()
    {
        string os = HostWindows ? "win" : HostMac ? "osx" : "linux";
        string arch = RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "arm64" : "x64";
        return $"{os}-{arch}";
    }
}
