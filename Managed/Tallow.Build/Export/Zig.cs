using System.Text;

namespace Tallow.ManagedBuild.Export;

/// <summary>
/// Zig as the C toolchain of a Linux NativeAOT build, on any machine. Zig is one download per system (Tallow's
/// project selector installs it: Editor/src/Project/ZigToolchain.bf), and every one of them links for Linux with its
/// own copy of glibc's interface, so neither a Linux machine nor a Linux sysroot is needed. The library is linked
/// against <see cref="Glibc"/>: it runs on every distribution the engine's Linux player runs on.
///
/// .NET's NativeAOT build drives a GCC-like compiler driver and objcopy. Two small commands of this tool stand in
/// for them (scripts named in CppCompilerAndLinker and ObjCopyName start them): <c>zig-cc</c> passes the link to
/// <c>zig cc</c>, dropping the few options Zig's linker does not take, and <c>zig-objcopy</c> stands in for the
/// symbol split, which Zig's objcopy cannot do for a shared library: zig-cc links twice instead, once with the
/// debug information (the private symbols) and once without it (what ships), with the same build ID.
/// </summary>
internal static class Zig
{
    /// <summary>The Zig Tallow installs (ZigToolchain.PinnedVersion in the editor).</summary>
    public const string Version = "0.17.1";
    /// <summary>The oldest glibc the library runs with: Ubuntu 22.04's, which the engine's Linux player needs too.</summary>
    public const string Glibc = "2.35";
    const string Triple = "x86_64-linux-gnu." + Glibc;
    /// <summary>Beside the shipped library while the build runs: the same library with its debug information.</summary>
    const string DebugSuffix = ".tallow-debug";

    /// <summary>Where Tallow installs Zig versions: TALLOW_ZIG_HOME, or &lt;data&gt;/Tallow/zig beside Tallow's .NET
    /// (data being ~/.local/share, %LOCALAPPDATA% or ~/Library/Application Support).</summary>
    public static string Home()
    {
        string? chosen = Environment.GetEnvironmentVariable("TALLOW_ZIG_HOME");
        if (!string.IsNullOrEmpty(chosen))
            return chosen;
        if (ExportUtil.HostLinux)
        {
            string? xdg = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
            return Path.Combine(string.IsNullOrEmpty(xdg) ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "share") : xdg,
                "Tallow", "zig");
        }
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Tallow", "zig");
    }

    /// <summary>The zig program: TALLOW_ZIG, else the pinned version in <see cref="Home"/>; null when neither is there.</summary>
    public static string? Find()
    {
        string? chosen = Environment.GetEnvironmentVariable("TALLOW_ZIG");
        if (!string.IsNullOrEmpty(chosen))
            return File.Exists(chosen) ? Path.GetFullPath(chosen) : null;
        string zig = Path.Combine(Home(), Version, ExportUtil.HostWindows ? "zig.exe" : "zig");
        return File.Exists(zig) ? zig : null;
    }

    /// <summary>Environment and MSBuild properties that make a linux-x64 NativeAOT publish link with Zig: the two
    /// stand-in commands are written to <paramref name="work"/>/zig-bin, put first on PATH.</summary>
    public static (Dictionary<string, string> Environment, List<string> Properties) LinkSetup(string zig, string work)
    {
        string bin = Path.Combine(work, "zig-bin");
        Directory.CreateDirectory(bin);
        // This tool, started again for each command: by the program running it (dotnet, or its own launcher).
        string host = Environment.ProcessPath ?? "dotnet";
        string self = typeof(Zig).Assembly.Location;
        bool viaDotNet = Path.GetFileNameWithoutExtension(host).Equals("dotnet", StringComparison.OrdinalIgnoreCase);
        foreach (string command in new[] { "zig-cc", "zig-objcopy" })
        {
            string name = "tallow-" + command;
            if (ExportUtil.HostWindows)
            {
                string start = viaDotNet ? $"\"{host}\" \"{self}\"" : $"\"{host}\"";
                File.WriteAllText(Path.Combine(bin, name + ".cmd"), $"@echo off\r\n{start} {command} %*\r\nexit /b %ERRORLEVEL%\r\n");
            }
            else
            {
                string Q(string text) => "'" + text.Replace("'", "'\\''") + "'";
                string start = viaDotNet ? $"{Q(host)} {Q(self)}" : Q(host);
                string script = Path.Combine(bin, name);
                File.WriteAllText(script, $"#!/bin/sh\nexec {start} {command} \"$@\"\n");
                ExportUtil.MakeExecutable(script);
            }
        }
        var environment = new Dictionary<string, string>
        {
            ["PATH"] = bin + Path.PathSeparator + (Environment.GetEnvironmentVariable("PATH") ?? ""),
            ["TALLOW_ZIG"] = zig,
            // Zig's own cache of what it builds for the target (glibc's stubs, compiler-rt): once per machine.
            ["ZIG_GLOBAL_CACHE_DIR"] = Path.Combine(ExportUtil.CacheFolder(), "zig"),
        };
        var properties = new List<string>
        {
            // .NET does not support linking for another system; with Zig it works.
            "-p:DisableUnsupportedError=true",
            "-p:CppCompilerAndLinker=tallow-zig-cc", "-p:ObjCopyName=tallow-zig-objcopy",
            // Zig picks its own linker and target (-fuse-ld, --target, -gz are not passed: empty values leave them out).
            "-p:LinkerFlavor=", "-p:TargetTriple=", "-p:CompressSymbols=false",
        };
        return (environment, properties);
    }

    /// <summary>Arguments as a response file (@file) gives them: one per line or separated by spaces, with quotes.</summary>
    static IEnumerable<string> Expand(IEnumerable<string> args)
    {
        foreach (string arg in args)
        {
            if (!arg.StartsWith('@') || !File.Exists(arg[1..]))
            {
                yield return arg;
                continue;
            }
            var current = new StringBuilder();
            bool quoted = false, any = false;
            foreach (char c in File.ReadAllText(arg[1..]))
            {
                if (c == '"')
                {
                    quoted = !quoted;
                    any = true;
                }
                else if (!quoted && char.IsWhiteSpace(c))
                {
                    if (any)
                        yield return current.ToString();
                    current.Clear();
                    any = false;
                }
                else
                {
                    current.Append(c);
                    any = true;
                }
            }
            if (any)
                yield return current.ToString();
        }
    }

    static string ZigPath() => Environment.GetEnvironmentVariable("TALLOW_ZIG") is { Length: > 0 } zig ? zig
        : Find() ?? throw new ExportException("Zig is not installed (the project selector installs it).");

    /// <summary><c>zig-cc</c>: the compiler driver NativeAOT links with. Options Zig's linker does not take are left out:
    /// --icf (identical code folding), and --gc-sections, with which Zig's linker drops the section whose start and
    /// end symbols (__start___modules) the .NET runtime finds its modules by. A link with debug information (-g) to
    /// an output is done twice, the second time without it and with the first one's build ID.</summary>
    public static int Cc(string[] args)
    {
        try
        {
            var kept = Expand(args).Where(arg => !arg.StartsWith("-Wl,--icf=", StringComparison.Ordinal) && arg != "-Wl,--gc-sections" &&
                !arg.StartsWith("-fuse-ld=", StringComparison.Ordinal) && !arg.StartsWith("--target=", StringComparison.Ordinal) &&
                !arg.StartsWith("-gz", StringComparison.Ordinal)).ToList();
            string zig = ZigPath();
            var prefix = new List<string> { "cc", "-target", Triple };
            int outputAt = kept.IndexOf("-o");
            if (!kept.Contains("-g") || outputAt < 0 || outputAt + 1 >= kept.Count)
                return ExportUtil.Run(zig, prefix.Concat(kept)).ExitCode;
            string output = kept[outputAt + 1];
            var debug = new List<string>(kept);
            debug[outputAt + 1] = output + DebugSuffix;
            int code = ExportUtil.Run(zig, prefix.Concat(debug)).ExitCode;
            if (code != 0)
                return code;
            string id = Symbols.ElfBuildId(output + DebugSuffix);
            var shipped = kept.Where(arg => arg != "-g" && !arg.StartsWith("-Wl,--build-id", StringComparison.Ordinal)).ToList();
            shipped.Add("-Wl,--strip-debug");
            if (id.Length > 0)
                shipped.Add("-Wl,--build-id=0x" + id);
            return ExportUtil.Run(zig, prefix.Concat(shipped)).ExitCode;
        }
        catch (ExportException exception)
        {
            Console.Error.WriteLine(exception.Message);
            return 1;
        }
    }

    /// <summary><c>zig-objcopy</c>: what NativeAOT asks objcopy for after linking. --only-keep-debug IN OUT keeps the
    /// library zig-cc linked with debug information as OUT (a whole library serves as its own symbols file); the
    /// strip and the debug link are already done (the shipped library was linked without debug information, and the
    /// private symbols are found by build ID).</summary>
    public static int ObjCopy(string[] args)
    {
        if (args.Length == 3 && args[0] == "--only-keep-debug")
        {
            string debug = args[1] + DebugSuffix;
            File.Copy(File.Exists(debug) ? debug : args[1], args[2], true);
            File.Delete(debug);
            return 0;
        }
        if (args.Length >= 2 && args[..^1].All(arg => arg is "--strip-debug" or "--strip-unneeded" || arg.StartsWith("--add-gnu-debuglink=", StringComparison.Ordinal)))
            return 0;
        Console.Error.WriteLine("tallow-zig-objcopy: unexpected arguments: " + string.Join(' ', args));
        return 1;
    }
}
