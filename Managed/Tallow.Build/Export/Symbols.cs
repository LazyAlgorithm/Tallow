using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace Tallow.ManagedBuild.Export;

/// <summary>
/// Private symbols and build identifiers for release exports. A Release export ships a player with no debug
/// information; the matching symbols (Linux .dbg, Windows .pdb), a map file and a build record naming every module's
/// exact identifier go to &lt;output&gt;-symbols/ beside the build, never inside it. Identifiers are read from the
/// files themselves: the ELF GNU build ID, the PE CodeView GUID and age, the Mach-O UUID.
/// </summary>
internal static class Symbols
{
    public static string Folder(string output) => output.TrimEnd('/', '\\') + "-symbols";

    static string Digest(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexStringLower(SHA256.HashData(stream));
    }

    /// <summary>The GNU build ID of a 64-bit little-endian ELF file, or "".</summary>
    public static string ElfBuildId(string path)
    {
        try
        {
            byte[] data = File.ReadAllBytes(path);
            if (data.Length < 64 || data[0] != 0x7F || data[1] != 'E' || data[2] != 'L' || data[3] != 'F' || data[4] != 2 || data[5] != 1)
                return "";
            long sectionOffset = (long)BinaryPrimitives.ReadUInt64LittleEndian(data.AsSpan(0x28));
            int sectionSize = BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(0x3A));
            int sectionCount = BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(0x3C));
            for (int i = 0; i < sectionCount; i++)
            {
                var header = data.AsSpan((int)(sectionOffset + (long)i * sectionSize));
                if (BinaryPrimitives.ReadUInt32LittleEndian(header[4..]) != 7) // SHT_NOTE
                    continue;
                long offset = (long)BinaryPrimitives.ReadUInt64LittleEndian(header[0x18..]);
                long size = (long)BinaryPrimitives.ReadUInt64LittleEndian(header[0x20..]);
                long at = offset;
                while (at + 12 <= offset + size)
                {
                    int nameSize = (int)BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan((int)at));
                    int descSize = (int)BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan((int)at + 4));
                    uint type = BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan((int)at + 8));
                    long name = at + 12;
                    long desc = name + ((nameSize + 3) & ~3);
                    if (type == 3 && nameSize == 4 && data.AsSpan((int)name, 3).SequenceEqual("GNU"u8))
                        return Convert.ToHexStringLower(data, (int)desc, descSize);
                    at = desc + ((descSize + 3) & ~3);
                }
            }
        }
        catch (Exception exception) when (exception is IOException or ArgumentOutOfRangeException or IndexOutOfRangeException)
        {
        }
        return "";
    }

    /// <summary>The PE debug identifier a .pdb is matched by: the CodeView GUID and age, as "guid age", or "".</summary>
    public static string PeDebugId(string path)
    {
        try
        {
            byte[] data = File.ReadAllBytes(path);
            if (data.Length < 0x40 || data[0] != 'M' || data[1] != 'Z')
                return "";
            int pe = BinaryPrimitives.ReadInt32LittleEndian(data.AsSpan(0x3C));
            if (!data.AsSpan(pe, 4).SequenceEqual("PE\0\0"u8))
                return "";
            int sections = BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(pe + 6));
            int optionalSize = BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(pe + 20));
            int optional = pe + 24;
            bool plus = BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(optional)) == 0x20B;
            int directories = optional + (plus ? 112 : 96);
            uint debugRva = BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(directories + 6 * 8));
            uint debugSize = BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(directories + 6 * 8 + 4));
            int table = optional + optionalSize;
            long FileOffset(uint rva)
            {
                for (int i = 0; i < sections; i++)
                {
                    var section = data.AsSpan(table + i * 40);
                    uint virtualSize = BinaryPrimitives.ReadUInt32LittleEndian(section[8..]);
                    uint address = BinaryPrimitives.ReadUInt32LittleEndian(section[12..]);
                    uint raw = BinaryPrimitives.ReadUInt32LittleEndian(section[20..]);
                    if (rva >= address && rva < address + Math.Max(virtualSize, BinaryPrimitives.ReadUInt32LittleEndian(section[16..])))
                        return raw + (rva - address);
                }
                return -1;
            }
            long directory = FileOffset(debugRva);
            for (long entry = directory; directory >= 0 && entry + 28 <= directory + debugSize; entry += 28)
            {
                if (BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan((int)entry + 12)) != 2) // CODEVIEW
                    continue;
                int pointer = (int)BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan((int)entry + 24));
                if (!data.AsSpan(pointer, 4).SequenceEqual("RSDS"u8))
                    continue;
                var guid = new Guid(data.AsSpan(pointer + 4, 16));
                uint age = BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(pointer + 20));
                return $"{guid.ToString("D")} {age}";
            }
        }
        catch (Exception exception) when (exception is IOException or ArgumentOutOfRangeException or IndexOutOfRangeException)
        {
        }
        return "";
    }

    /// <summary>A 64-bit Mach-O file's LC_UUID, or "".</summary>
    public static string MachOUuid(string path)
    {
        try
        {
            byte[] data = File.ReadAllBytes(path);
            if (data.Length < 32 || BinaryPrimitives.ReadUInt32LittleEndian(data) != 0xFEEDFACF)
                return "";
            int commands = (int)BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(16));
            int at = 32;
            for (int i = 0; i < commands; i++)
            {
                uint command = BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(at));
                int size = (int)BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(at + 4));
                if (command == 0x1B)
                    return Convert.ToHexStringLower(data, at + 8, 16);
                at += size;
            }
        }
        catch (Exception exception) when (exception is IOException or ArgumentOutOfRangeException or IndexOutOfRangeException)
        {
        }
        return "";
    }

    /// <summary>The processor a Mach-O program is for: "arm64", "x64", or null when it is not one.</summary>
    public static string? MachOArch(string path)
    {
        using var stream = File.OpenRead(path);
        var header = new byte[8];
        if (stream.Read(header) < 8 || BinaryPrimitives.ReadUInt32LittleEndian(header) != 0xFEEDFACF)
            return null;
        return BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4)) switch
        {
            0x0100000C => "arm64",
            0x01000007 => "x64",
            _ => null
        };
    }

    /// <summary>Takes a Release player's debug information out of the package and keeps it (and a Windows .pdb) in
    /// <paramref name="symbols"/>. A missing objcopy only warns: the export carries on.</summary>
    public static void StripReleasePlayer(string executable, string symbols, Target target, string? source)
    {
        Directory.CreateDirectory(symbols);
        if (target == Target.Windows)
        {
            // A COFF image keeps nothing itself; the linker's .pdb is the symbols. It sits beside the player Beef built.
            if (source == null)
            {
                Console.WriteLine("note: the Windows player's source folder is unknown, so no .pdb was kept.");
                return;
            }
            string folder = Path.GetDirectoryName(source)!;
            var candidates = new List<string> { Path.Combine(folder, Path.GetFileNameWithoutExtension(source) + "_lld.pdb") };
            candidates.AddRange(Directory.EnumerateFiles(folder, "*.pdb").Order(StringComparer.Ordinal));
            string? found = candidates.FirstOrDefault(File.Exists);
            if (found != null)
                File.Copy(found, Path.Combine(symbols, Path.GetFileName(found)), true);
            else
                Console.WriteLine($"note: no .pdb was found beside {source}; a crash of this build cannot be read.");
            return;
        }
        if (target == Target.MacOS)
            return; // A Mac player's symbols stay in a .dSYM the engine build makes; nothing is split off here.
        string? objcopy = ExportUtil.Which("objcopy") ?? ExportUtil.Which("llvm-objcopy");
        if (objcopy == null)
        {
            Console.WriteLine("note: objcopy (binutils) is missing; the player keeps its debug information in the package.");
            return;
        }
        string debugFile = Path.Combine(symbols, Path.GetFileName(executable) + ".dbg");
        Check(ExportUtil.Run(objcopy, new[] { "--only-keep-debug", executable, debugFile }), "objcopy --only-keep-debug");
        if (new FileInfo(debugFile).Length < 4096)
        {
            // The player was already stripped (a packaged engine can ship one): there is nothing to keep.
            File.Delete(debugFile);
            Console.WriteLine($"note: {Path.GetFileName(executable)} carries no debug information, so no .dbg was kept for it. " +
                "Build Player/ with debug info to get crash symbols.");
            return;
        }
        long before = new FileInfo(executable).Length;
        Check(ExportUtil.Run(objcopy, new[] { "--strip-debug", executable }), "objcopy --strip-debug");
        // What a debugger follows from the shipped file to the private one (the CRC is of the .dbg).
        Check(ExportUtil.Run(objcopy, new[] { "--add-gnu-debuglink=" + debugFile, executable }), "objcopy --add-gnu-debuglink");
        long after = new FileInfo(executable).Length;
        Console.WriteLine($"Player: stripped of debug information ({before / (1024 * 1024)} MB -> {after / (1024 * 1024)} MB); symbols in {debugFile}");
    }

    static void Check(ExportUtil.Result result, string what)
    {
        if (result.ExitCode != 0)
            throw new ExportException($"{what} failed (exit {result.ExitCode}).");
    }

    /// <summary>A name map for crash addresses read without a debugger: code symbols only, address sorted,
    /// demangled, in the nm BSD format.</summary>
    public static string? WriteMap(string symbols, string binary)
    {
        string? nm = ExportUtil.Which("llvm-nm") ?? ExportUtil.Which("nm");
        if (nm == null)
            return null;
        var result = ExportUtil.TryRun(nm, new[] { "--defined-only", "--numeric-sort", "--demangle", binary });
        if (result.ExitCode != 0 || result.Output.Trim().Length == 0)
            return null;
        var kept = result.Output.Split('\n').Where(line => line.Length > 0).Where(line =>
        {
            // t/T: code, w/W: weak code (a line of another shape is kept too).
            var parts = line.Split((char[]?)null, 3, StringSplitOptions.RemoveEmptyEntries);
            return parts.Length < 2 || parts[1].Length != 1 || "tTwW".Contains(parts[1][0]);
        }).ToList();
        if (kept.Count == 0)
            return null;
        string target = Path.Combine(symbols, Path.GetFileName(binary) + ".map");
        File.WriteAllText(target, string.Join('\n', kept) + "\n", new UTF8Encoding(false));
        return target;
    }

    static string EngineCommit(string engine)
    {
        var commit = ExportUtil.TryRun("git", new[] { "-C", engine, "rev-parse", "--short=12", "HEAD" });
        var branch = ExportUtil.TryRun("git", new[] { "-C", engine, "rev-parse", "--abbrev-ref", "HEAD" });
        string id = commit.Output.Trim();
        return commit.ExitCode == 0 && id.Length > 0 ? $"{branch.Output.Trim()} @ {id}" : "(not a git checkout)";
    }

    /// <summary>The private record of a build: each shipped module's exact identifier and the symbol files kept for
    /// it. Matches a crash to these files; never shipped.</summary>
    public static string WriteBuildInfo(string symbols, string engine, string project, string config, Target target,
        string runtime, string? codeId, string? library, string player)
    {
        var lines = new List<string>
        {
            "# Tallow build information. Private: kept beside the build, never shipped in it.",
            $"project: {project}",
            $"config: {config}",
            $"platform: {target.ToString().ToLowerInvariant()}",
            $"runtime: {runtime}",
            $"engine commit: {EngineCommit(engine)}",
            $"game code id: {codeId ?? "(none)"}",
        };
        void Module(string title, string path)
        {
            lines.Add($"{title}: {Path.GetFileName(path)}");
            lines.Add($"{title} sha256: {Digest(path)}");
            lines.Add($"{title} size: {new FileInfo(path).Length}");
            string identifier = target switch { Target.Windows => PeDebugId(path), Target.MacOS => MachOUuid(path), _ => ElfBuildId(path) };
            string kind = target switch { Target.Windows => "pdb id", Target.MacOS => "uuid", _ => "build id" };
            if (identifier.Length > 0)
                lines.Add($"{title} {kind}: {identifier}");
        }
        Module("player", player);
        if (library != null && File.Exists(library))
            Module("game library", library);
        lines.Add("");
        lines.Add("symbols kept here (private):");
        foreach (string file in Directory.EnumerateFiles(symbols).Order(StringComparer.Ordinal))
        {
            string name = Path.GetFileName(file);
            if (name != "build-info.txt" && Path.GetExtension(name) is ".dbg" or ".pdb" or ".map")
                lines.Add($"  {name} sha256 {Digest(file)} ({new FileInfo(file).Length} bytes)");
        }
        string info = Path.Combine(symbols, "build-info.txt");
        File.WriteAllText(info, string.Join('\n', lines) + "\n", new UTF8Encoding(false));
        return info;
    }
}
