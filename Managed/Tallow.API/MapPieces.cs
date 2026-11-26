using System.Text;

namespace Tallow;

/// <summary>The engine's built-in map-editor pieces: primitives, walls and floors ("builtin:Walls/Wall 4 m").</summary>
public static class MapPieces
{
    /// <summary>Every piece's name, in palette order.</summary>
    public static string[] Names => Read(buffer => CSharpMapPieces.Names(buffer));
    /// <summary>The palette folders ("builtin:Primitives", "builtin:Walls", "builtin:Floors").</summary>
    public static string[] Folders => Read(buffer => CSharpMapPieces.Folders(buffer));

    /// <summary>A folder's name as shown: "builtin:Walls" is "Walls".</summary>
    public static string FolderLabel(string folder) =>
        folder.StartsWith("builtin:", StringComparison.Ordinal) ? folder["builtin:".Length..] : folder;

    /// <summary>Makes a piece in the scene at the origin; null for a name that is not one.</summary>
    public static GameObject? Create(Scene scene, string name)
    {
        ulong id = CSharpMapPieces.Create(scene.SessionId, name ?? "");
        return id == 0 ? null : new GameObject(scene.SessionId, id);
    }

    private static string[] Read(Func<byte[], int> copy)
    {
        byte[] buffer = new byte[4096];
        int length = copy(buffer);
        if (length <= 0)
            return [];
        if (length > buffer.Length)
        {
            buffer = new byte[length];
            length = Math.Min(length, copy(buffer));
        }
        return Encoding.UTF8.GetString(buffer, 0, Math.Max(length, 0)).Split('\x1f');
    }
}
