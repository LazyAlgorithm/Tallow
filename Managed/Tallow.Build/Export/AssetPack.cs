using System.Buffers.Binary;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Tallow.ManagedBuild.Export;

/// <summary>
/// Tallow asset packs (.tpak): a game's assets in one file. The format is described at the top of
/// native/tallow_pack.c, which reads it. Files are deflated when that makes them smaller and then scrambled, so they
/// cannot be opened or edited with ordinary tools, and each carries a checksum so that a changed file is refused. It is
/// not encryption.
/// </summary>
internal static class AssetPack
{
    const uint Key = 0x7E55E2A5;
    const int Block = 4096;
    static readonly byte[] Magic = "TPAK1\0\0\0"u8.ToArray();
    // Already compressed: deflating again gains nothing.
    // Page files (.tmips, .tvt, .tclodp, .tpages) are stored whole so that the engine reads one page with one seek
    // (their pages are deflated one by one where that helps); the others are already compressed.
    static readonly HashSet<string> Stored = new(StringComparer.Ordinal) { ".png", ".jpg", ".jpeg", ".ogg", ".mp3", ".flac", ".tpak", ".tpages", ".tmips", ".tvt", ".tclodp" };

    static byte[] MakeBlock(uint seed, uint salt)
    {
        uint state = seed ^ Key ^ unchecked(salt * 2654435761u);
        if (state == 0)
            state = Key;
        var output = new byte[Block];
        for (int i = 0; i < Block; i++)
        {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            output[i] = (byte)(state >> 11);
        }
        return output;
    }

    /// <summary>XOR with the repeating block; the same call undoes it.</summary>
    static void Scramble(Span<byte> data, uint seed, uint salt)
    {
        if (data.IsEmpty)
            return;
        byte[] block = MakeBlock(seed, salt);
        for (int i = 0; i < data.Length; i++)
            data[i] ^= block[i % Block];
    }

    static byte[] Deflate(byte[] plain)
    {
        using var memory = new MemoryStream();
        using (var zlib = new ZLibStream(memory, CompressionLevel.SmallestSize, true))
            zlib.Write(plain);
        return memory.ToArray();
    }

    /// <summary>Files larger than this are streamed into the pack instead of being held in memory (and are not
    /// deflated): a 2 GB asset is a normal thing in a high-poly project, and a byte array cannot hold it.</summary>
    const long LargeFile = 64L * 1024 * 1024;
    const int CopyBlock = 1024 * 1024;

    /// <summary>Writes a file's bytes scrambled, a block at a time, without holding it all in memory.</summary>
    static void CopyScrambled(string source, Stream output, uint seed, uint crc, long length)
    {
        byte[] block = MakeBlock(seed, crc);
        var buffer = new byte[CopyBlock];
        using var input = File.OpenRead(source);
        long position = 0;
        while (position < length)
        {
            int read = input.Read(buffer, 0, (int)Math.Min(buffer.Length, length - position));
            if (read <= 0)
                throw new InvalidDataException($"{source} ended {length - position} bytes before its length said it would.");
            for (int i = 0; i < read; i++)
                buffer[i] ^= block[(int)((position + i) % Block)];
            output.Write(buffer, 0, read);
            position += read;
        }
    }

    /// <summary>Writes a pack of (name inside the pack, path on disk) pairs; names use forward slashes.
    /// <paramref name="compress"/> false stores every file at its full size (still scrambled and checksummed).
    /// <paramref name="name"/> (the game's name) fixes the scrambling, so that a file that has not changed comes out
    /// the same in every build: a store such as Steam then sends players only what did change.</summary>
    public static int Write(string path, IEnumerable<(string Name, string Source)> files, bool compress, string? name)
    {
        uint seed = name != null ? ExportUtil.Crc32(Encoding.UTF8.GetBytes("tallow-pack:" + name))
            : BinaryPrimitives.ReadUInt32LittleEndian(RandomNumberGenerator.GetBytes(4));
        var sorted = files.ToList();
        sorted.Sort((a, b) =>
        {
            int order = string.CompareOrdinal(a.Name, b.Name);
            return order != 0 ? order : string.CompareOrdinal(a.Source, b.Source);
        });
        using var index = new MemoryStream();
        using (var output = new FileStream(path, FileMode.Create, FileAccess.ReadWrite))
        {
            output.Write(new byte[32]);
            Span<byte> number = stackalloc byte[8];
            foreach (var (entryName, source) in sorted)
            {
                var info = new FileInfo(source);
                if (info.Length > uint.MaxValue)
                    throw new InvalidDataException($"{entryName} is {info.Length / (1024.0 * 1024 * 1024):0.0} GB; a pack entry holds less than 4 GB.");
                byte[] encoded = Encoding.UTF8.GetBytes(entryName);
                if (info.Length > LargeFile)
                {
                    // Too big for one byte array: checksum it first (the scramble uses the checksum), then copy it a
                    // block at a time, stored as it is (deflating would mean holding the whole file).
                    uint crc;
                    using (var stream = File.OpenRead(source))
                        crc = ExportUtil.Crc32(stream);
                    BinaryPrimitives.WriteUInt16LittleEndian(number, (ushort)encoded.Length);
                    index.Write(number[..2]);
                    index.Write(encoded);
                    BinaryPrimitives.WriteUInt64LittleEndian(number, (ulong)output.Position);
                    index.Write(number);
                    BinaryPrimitives.WriteUInt32LittleEndian(number, (uint)info.Length);
                    index.Write(number[..4]);
                    BinaryPrimitives.WriteUInt32LittleEndian(number, (uint)info.Length);
                    index.Write(number[..4]);
                    BinaryPrimitives.WriteUInt32LittleEndian(number, crc);
                    index.Write(number[..4]);
                    index.WriteByte(0);
                    CopyScrambled(source, output, seed, crc, info.Length);
                    continue;
                }
                byte[] plain = File.ReadAllBytes(source);
                uint checksum = ExportUtil.Crc32(plain);
                byte[] stored = plain;
                byte flags = 0;
                if (compress && !Stored.Contains(Path.GetExtension(entryName).ToLowerInvariant()))
                {
                    byte[] deflated = Deflate(plain);
                    if (deflated.Length < plain.Length)
                    {
                        stored = deflated;
                        flags = 1;
                    }
                }
                BinaryPrimitives.WriteUInt16LittleEndian(number, (ushort)encoded.Length);
                index.Write(number[..2]);
                index.Write(encoded);
                BinaryPrimitives.WriteUInt64LittleEndian(number, (ulong)output.Position);
                index.Write(number);
                BinaryPrimitives.WriteUInt32LittleEndian(number, (uint)stored.Length);
                index.Write(number[..4]);
                BinaryPrimitives.WriteUInt32LittleEndian(number, (uint)plain.Length);
                index.Write(number[..4]);
                BinaryPrimitives.WriteUInt32LittleEndian(number, checksum);
                index.Write(number[..4]);
                index.WriteByte(flags);
                byte[] scrambled = stored == plain ? (byte[])plain.Clone() : stored;
                Scramble(scrambled, seed, checksum);
                output.Write(scrambled);
            }
            long indexOffset = output.Position;
            byte[] indexBytes = index.ToArray();
            Scramble(indexBytes, seed, 0xFFFFFFFF);
            output.Write(indexBytes);
            output.Position = 0;
            var header = new byte[32];
            Magic.CopyTo(header, 0);
            BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(8), 1);
            BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(12), (uint)sorted.Count);
            BinaryPrimitives.WriteUInt64LittleEndian(header.AsSpan(16), (ulong)indexOffset);
            BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(24), (uint)indexBytes.Length);
            BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(28), seed);
            output.Write(header);
        }
        return sorted.Count;
    }

    /// <summary>A pack's files, read back and checked: (name, contents). Throws on a damaged file.</summary>
    public static List<(string Name, byte[] Data)> Read(string path)
    {
        using var input = File.OpenRead(path);
        var header = new byte[32];
        input.ReadExactly(header);
        if (!header.AsSpan(0, 8).SequenceEqual(Magic))
            throw new InvalidDataException("not a Tallow asset pack");
        uint version = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(8));
        if (version != 1)
            throw new InvalidDataException($"pack version {version} is not supported");
        int count = (int)BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(12));
        long indexOffset = (long)BinaryPrimitives.ReadUInt64LittleEndian(header.AsSpan(16));
        int indexSize = (int)BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(24));
        uint seed = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(28));
        input.Position = indexOffset;
        var index = new byte[indexSize];
        input.ReadExactly(index);
        Scramble(index, seed, 0xFFFFFFFF);
        var result = new List<(string, byte[])>();
        int at = 0;
        for (int i = 0; i < count; i++)
        {
            int length = BinaryPrimitives.ReadUInt16LittleEndian(index.AsSpan(at));
            string name = Encoding.UTF8.GetString(index, at + 2, length);
            int field = at + 2 + length;
            long offset = (long)BinaryPrimitives.ReadUInt64LittleEndian(index.AsSpan(field));
            int stored = (int)BinaryPrimitives.ReadUInt32LittleEndian(index.AsSpan(field + 8));
            int size = (int)BinaryPrimitives.ReadUInt32LittleEndian(index.AsSpan(field + 12));
            uint crc = BinaryPrimitives.ReadUInt32LittleEndian(index.AsSpan(field + 16));
            byte flags = index[field + 20];
            at = field + 21;
            input.Position = offset;
            var data = new byte[stored];
            input.ReadExactly(data);
            Scramble(data, seed, crc);
            if ((flags & 1) != 0)
            {
                using var inflate = new ZLibStream(new MemoryStream(data), CompressionMode.Decompress);
                using var plain = new MemoryStream();
                inflate.CopyTo(plain);
                data = plain.ToArray();
            }
            if (data.Length != size || ExportUtil.Crc32(data) != crc)
                throw new InvalidDataException($"{name} is damaged");
            result.Add((name, data));
        }
        return result;
    }

    // Text formats whose contents may name other assets.
    static readonly HashSet<string> TextFormats = new(StringComparer.Ordinal)
    {
        ".tscene", ".tcell", ".tprefab", ".tmat", ".tui", ".tcss", ".tcontroller", ".tanim", ".tmask", ".tshader", ".tcompute",
        ".tinput", ".tbt", ".gltf", ".json", ".txt", ".tallow"
    };
    static readonly Regex PathLike = new(@"[A-Za-z0-9_./\\-]+\.[A-Za-z0-9]+", RegexOptions.CultureInvariant);
    // A scene's own pack is only worth its own file above this size; smaller ones stay in the shared pack.
    const long SplitMinimum = 64 * 1024;

    /// <summary>The assets a text file names: as an asset path, or relative to the file's own folder.</summary>
    static HashSet<string> References(string text, string folder, Dictionary<string, string> assets)
    {
        var found = new HashSet<string>(StringComparer.Ordinal);
        foreach (Match match in PathLike.Matches(text))
        {
            string token = match.Value.Replace('\\', '/').TrimStart('.', '/');
            if (token.StartsWith("Assets/", StringComparison.Ordinal))
                token = token[7..];
            foreach (string candidate in new[] { token, folder.Length > 0 ? folder + "/" + token : token })
            {
                if (assets.ContainsKey(candidate))
                    found.Add(candidate);
                else if (assets.ContainsKey(candidate + ".glb"))
                    // A converted model (tallowengine.com/docs/model-import): named as the FBX, OBJ, ... and built as <file>.glb.
                    found.Add(candidate + ".glb");
                else if (assets.ContainsKey(candidate + ".sky.ktx"))
                    // A skybox the export cooked (SkyboxCook): named as its picture or folder, shipped as <skybox>.sky.ktx.
                    found.Add(candidate + ".sky.ktx");
                else if (candidate.EndsWith(".terrain", StringComparison.Ordinal))
                    // A terrain's sculpting folder: every tile's file in it.
                    found.UnionWith(assets.Keys.Where(path => path.StartsWith(candidate + "/", StringComparison.Ordinal)));
            }
        }
        return found;
    }

    /// <summary>
    /// Shares a game's assets out among packs: one per scene for what only that scene uses, and the shared pack
    /// (game.tpak) for everything else. A file goes into a scene's pack only when that scene is the one thing that
    /// reaches it: not the start scene, not another scene, not the scripts (whose string literals name assets they
    /// load), and not a file that something else reaches. Files matching a shared pattern always stay shared.
    /// Returns the scene packs (file name -> asset paths) and the scene each serves.
    /// </summary>
    public static (SortedDictionary<string, List<string>> Packs, Dictionary<string, string> Served) PlanSplit(
        Dictionary<string, string> assets, IEnumerable<string> codeTexts, string startScene, IEnumerable<string> sharedPatterns)
    {
        // Files with the same name in another format (a terrain's .voxels beside its scene, and so on).
        var byStem = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (string path in assets.Keys)
        {
            string stem = ExportUtil.SplitExt(path).Root;
            if (!byStem.TryGetValue(stem, out var list))
                byStem[stem] = list = new List<string>();
            list.Add(path);
        }

        HashSet<string> Reach(IEnumerable<string> roots)
        {
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var todo = new Stack<string>(roots);
            while (todo.Count > 0)
            {
                string path = todo.Pop();
                if (seen.Contains(path) || !assets.ContainsKey(path))
                    continue;
                seen.Add(path);
                var (stem, extension) = ExportUtil.SplitExt(path);
                // A picture's streamed copies (cooked beside it).
                foreach (string cooked in new[] { path + ".tmips", path + ".tvt" })
                    if (assets.ContainsKey(cooked))
                        todo.Push(cooked);
                foreach (string other in byStem[stem])
                    if (other != path)
                        todo.Push(other);
                if (path.EndsWith(".tscene", StringComparison.Ordinal))
                    // A streamed world (tallowengine.com/docs/world-streaming): its cells, in the folder beside it.
                    foreach (string other in assets.Keys.Where(other => other.StartsWith(stem + ".cells/", StringComparison.Ordinal)))
                        todo.Push(other);
                if (TextFormats.Contains(extension.ToLowerInvariant()))
                {
                    string text;
                    try
                    {
                        text = File.ReadAllText(assets[path], new UTF8Encoding(false, true));
                    }
                    catch (Exception exception) when (exception is DecoderFallbackException or IOException)
                    {
                        continue;
                    }
                    foreach (string found in References(text, ExportUtil.DirName(path), assets))
                        todo.Push(found);
                }
            }
            return seen;
        }

        var scenes = assets.Keys.Where(path => path.EndsWith(".tscene", StringComparison.Ordinal)).ToList();
        scenes.Sort(string.CompareOrdinal);
        var sharedRoots = new HashSet<string>(StringComparer.Ordinal);
        // A scene named in the scripts is a map to load, not something every scene needs.
        foreach (string text in codeTexts)
            sharedRoots.UnionWith(References(text, "", assets).Where(path => !path.EndsWith(".tscene", StringComparison.Ordinal)));
        sharedRoots.Add(startScene);
        var patterns = sharedPatterns.Where(pattern => pattern.Length > 0).ToList();
        sharedRoots.UnionWith(assets.Keys.Where(path => patterns.Any(pattern => ExportUtil.FnMatch(path, pattern))));
        var shared = Reach(sharedRoots);
        var users = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);
        foreach (string scene in scenes)
        {
            if (shared.Contains(scene))
                continue;
            foreach (string path in Reach(new[] { scene }))
            {
                if (!users.TryGetValue(path, out var by))
                    users[path] = by = new HashSet<string>(StringComparer.Ordinal);
                by.Add(scene);
            }
        }
        var packs = new SortedDictionary<string, List<string>>(StringComparer.Ordinal);
        var served = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (string scene in scenes)
        {
            var own = users.Where(pair => pair.Value.Count == 1 && pair.Value.Contains(scene) && !shared.Contains(pair.Key))
                .Select(pair => pair.Key).ToList();
            own.Sort(string.CompareOrdinal);
            if (!own.Contains(scene) || own.Sum(path => new FileInfo(assets[path]).Length) < SplitMinimum)
                continue;
            string name = "scene-" + Slug(ExportUtil.SplitExt(ExportUtil.BaseName(scene)).Root) + ".tpak";
            if (packs.ContainsKey(name))
                name = "scene-" + Slug(ExportUtil.SplitExt(scene).Root) + ".tpak";
            packs[name] = own;
            served[name] = scene;
        }
        return (packs, served);
    }

    static string Slug(string text) => Regex.Replace(text.ToLowerInvariant(), "[^a-z0-9]+", "-").Trim('-');
}
