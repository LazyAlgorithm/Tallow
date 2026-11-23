using System.Numerics;
using System.Runtime.InteropServices;

namespace Tallow;

/// <summary>The modeller's starting shapes (<see cref="EditMesh.Shape"/>).</summary>
public enum MeshShape
{
    Box,
    Wedge,
    Stairs,
    Cylinder,
    Cone,
    Sphere,
    Torus,
    Arch,
    Plane,
    Prism,
    Pipe,
}

/// <summary>How <see cref="EditMesh.Combine"/> joins two meshes.</summary>
public enum MeshBoolean
{
    /// <summary>Everything inside either.</summary>
    Union,
    /// <summary>The first, with the second cut out of it.</summary>
    Subtract,
    /// <summary>Only what is inside both.</summary>
    Intersect,
}

/// <summary>
/// A model to build in code, with the modeller's shapes and edits (tallowengine.com/docs/modeling), then put on an object:
/// <code>
/// using var stairs = EditMesh.Shape(MeshShape.Stairs, new Vector3(2, 1.5f, 3), steps: 8);
/// stairs.ExtrudeFaces(stairs.FacesFacing(Vector3.UnitY), 0.5f);
/// stairs.ApplyTo(gameObject);         // its Model Mesh (and a Mesh Renderer when it has none)
/// </code>
/// Vertices and faces are numbered from 0; faces wind clockwise seen from the front. A model is scene data, made
/// on each machine for itself: nothing is sent while playing. Dispose it when done; any left are freed when the
/// game stops.
/// </summary>
public sealed class EditMesh : IDisposable
{
    private int id;

    private EditMesh(int id) => this.id = id;

    /// <summary>A mesh the native side already holds (Tallow.Editor's EditorModel hands out objects' models so).</summary>
    internal static EditMesh FromHandle(int handle) => new(handle);

    /// <summary>The native handle the mesh is kept under.</summary>
    internal int Handle => id;

    /// <summary>An empty mesh: add vertices and faces.</summary>
    public EditMesh() : this(CSharpModeling.Create()) { }

    /// <summary>One of the modeller's shapes, standing on its base at 0. Wedge and Stairs climb along the longer side
    /// of size (towards +X when that is X, otherwise towards +Z). sides: round a cylinder, cone, sphere, torus, pipe
    /// or arch; steps: of stairs, rings of a sphere or torus; thickness: of a pipe, arch or torus.</summary>
    public static EditMesh Shape(MeshShape shape, Vector3 size, int sides = 12, int steps = 6, float thickness = 0.2f,
        bool smooth = false) =>
        new(CSharpModeling.Shape((int)shape, size, sides, steps, thickness, smooth));

    /// <summary>A mesh read from .tmesh text (<see cref="ToText"/>, or a Model Mesh's data); null when it is not one.</summary>
    public static EditMesh? FromText(string text)
    {
        int made = CSharpModeling.FromText(text ?? "");
        return made == 0 ? null : new EditMesh(made);
    }

    /// <summary>A copy of an object's Model Mesh; null when it has none.</summary>
    public static EditMesh? From(GameObject gameObject)
    {
        int made = CSharpModeling.ReadFrom(gameObject.SceneId, gameObject.Id);
        return made == 0 ? null : new EditMesh(made);
    }

    /// <summary>A boolean of two meshes: <paramref name="b"/> placed in <paramref name="a"/>'s space by a position,
    /// rotation and scale. A new mesh.</summary>
    public static EditMesh Combine(EditMesh a, EditMesh b, MeshBoolean operation, Vector3 position = default,
        Quaternion? rotation = null, Vector3? scale = null)
    {
        ArgumentNullException.ThrowIfNull(a);
        ArgumentNullException.ThrowIfNull(b);
        int made = CSharpModeling.Combine(a.Live(), b.Live(), position, rotation ?? Quaternion.Identity,
            scale ?? Vector3.One, (int)operation);
        return made != 0 ? new EditMesh(made) : throw new InvalidOperationException("The meshes could not be combined.");
    }

    /// <summary>A copy.</summary>
    public EditMesh Clone() => new(CSharpModeling.Clone(Live()));

    /// <summary>How many vertices.</summary>
    public int VertexCount => CSharpModeling.VertexCount(Live());
    /// <summary>How many faces.</summary>
    public int FaceCount => CSharpModeling.FaceCount(Live());
    /// <summary>The space it encloses (for a closed mesh).</summary>
    public float Volume => CSharpModeling.Volume(Live());

    /// <summary>A vertex's position.</summary>
    public Vector3 GetVertex(int index) => CheckVertex(index) ? CSharpModeling.GetVertex(id, index) : default;

    /// <summary>Moves a vertex.</summary>
    public void SetVertex(int index, Vector3 position)
    {
        CheckVertex(index);
        CSharpModeling.SetVertex(id, index, position);
    }

    /// <summary>Adds a vertex: its index.</summary>
    public int AddVertex(Vector3 position) => CSharpModeling.AddVertex(Live(), position);

    /// <summary>Adds a face through three or more vertices, clockwise seen from the front: its index.</summary>
    public int AddFace(params int[] vertices)
    {
        ArgumentNullException.ThrowIfNull(vertices);
        int face = CSharpModeling.AddFace(Live(), MemoryMarshal.AsBytes(vertices.AsSpan()));
        return face >= 0 ? face : throw new ArgumentException(
            "A face needs three or more different vertices of this mesh.", nameof(vertices));
    }

    /// <summary>A face's vertices, in order.</summary>
    public int[] FaceVertices(int face)
    {
        int count = CSharpModeling.FaceVertices(Live(), face, Span<byte>.Empty);
        if (count < 0)
            throw new ArgumentOutOfRangeException(nameof(face));
        var vertices = new int[count];
        CSharpModeling.FaceVertices(id, face, MemoryMarshal.AsBytes(vertices.AsSpan()));
        return vertices;
    }

    /// <summary>The way a face faces.</summary>
    public Vector3 FaceNormal(int face) => FaceInfo(face).Normal;
    /// <summary>The middle of a face.</summary>
    public Vector3 FaceCenter(int face) => FaceInfo(face).Center;
    /// <summary>A face's area.</summary>
    public float FaceArea(int face) => FaceInfo(face).Area;

    /// <summary>The faces whose normal is within <paramref name="tolerance"/> of a direction (1: exactly), for
    /// picking faces to edit ("the top").</summary>
    public int[] FacesFacing(Vector3 direction, float tolerance = 0.9f)
    {
        Vector3 wanted = Vector3.Normalize(direction);
        var faces = new List<int>();
        for (int face = 0, count = FaceCount; face < count; face++)
        {
            if (Vector3.Dot(FaceNormal(face), wanted) >= tolerance)
                faces.Add(face);
        }
        return [.. faces];
    }

    /// <summary>Paints a face one colour.</summary>
    public void SetFaceColor(int face, Color color) => SetFace(face, color, true, -1, -1);
    /// <summary>Puts a face in a material slot (0: the Mesh Renderer's material; 1 and up: the Model Mesh's).</summary>
    public void SetFaceMaterial(int face, int slot) => SetFace(face, default, false, Math.Max(0, slot), -1);
    /// <summary>Shades a face smooth (true) or flat.</summary>
    public void SetFaceSmooth(int face, bool smooth) => SetFace(face, default, false, -1, smooth ? 1 : 0);

    /// <summary>Pulls faces out along their normals (together, or each on its own): the faces it made.</summary>
    public int[] ExtrudeFaces(int[] faces, float distance, bool individual = false) => Edit(0, faces, distance, individual);
    /// <summary>Makes a smaller face inside each (or one inside them together): the faces it made.</summary>
    public int[] InsetFaces(int[] faces, float amount, bool individual = true) => Edit(1, faces, amount, individual);
    /// <summary>Cuts each face into smaller ones (rounding the shape when smooth): the faces it made.</summary>
    public int[] Subdivide(int[] faces, bool smooth = false) => Edit(2, faces, 0, smooth);
    /// <summary>Cuts faces into triangles: the faces it made.</summary>
    public int[] Triangulate(int[] faces) => Edit(3, faces, 0, false);
    /// <summary>Makes a point in the middle of each face, joined to its corners: the faces it made.</summary>
    public int[] Poke(int[] faces) => Edit(4, faces, 0, false);
    /// <summary>Gives faces a thickness (a back and sides): the faces it made.</summary>
    public int[] Solidify(int[] faces, float thickness) => Edit(5, faces, thickness, false);
    /// <summary>Turns faces to face the other way.</summary>
    public void FlipFaces(int[] faces) => Edit(6, faces, 0, false);
    /// <summary>Removes faces (later faces are numbered down to fill the gaps).</summary>
    public void DeleteFaces(int[] faces) => Edit(7, faces, 0, false);
    /// <summary>Copies faces: the copies.</summary>
    public int[] DuplicateFaces(int[] faces) => Edit(8, faces, 0, false);

    /// <summary>Mirrors it across an axis (0 x, 1 y, 2 z), joining the middle.</summary>
    public void Mirror(int axis, float weld = 0.0001f) => CSharpModeling.Mirror(Live(), axis, weld);
    /// <summary>Copies it <paramref name="count"/> times, each moved by <paramref name="offset"/> (and turned) from the last.</summary>
    public void Repeat(int count, Vector3 offset, Quaternion? turn = null, bool weld = true) =>
        CSharpModeling.Repeat(Live(), count, offset, turn ?? Quaternion.Identity, weld);
    /// <summary>Moves every vertex so that <paramref name="newOrigin"/> is at 0.</summary>
    public void MoveOrigin(Vector3 newOrigin) => CSharpModeling.MoveOrigin(Live(), newOrigin);

    /// <summary>Adds another mesh's faces, placed by a position, rotation and scale.</summary>
    public void Append(EditMesh other, Vector3 position = default, Quaternion? rotation = null, Vector3? scale = null)
    {
        ArgumentNullException.ThrowIfNull(other);
        CSharpModeling.Append(Live(), other.Live(), position, rotation ?? Quaternion.Identity, scale ?? Vector3.One);
    }

    /// <summary>Puts it on an object as its Model Mesh (adding a Mesh Renderer and Model Mesh when it has none),
    /// replacing the model it had. The object keeps its own copy.</summary>
    public void ApplyTo(GameObject gameObject)
    {
        if (!CSharpModeling.ApplyTo(Live(), gameObject.SceneId, gameObject.Id))
            throw new InvalidOperationException($"{gameObject} could not take the model.");
    }

    /// <summary>The .tmesh text (what a Model Mesh keeps, and what <see cref="FromText"/> reads).</summary>
    public string ToText()
    {
        int handle = Live();
        return NativeText.Read(buffer => CSharpModeling.ToText(handle, buffer)) ?? "";
    }

    /// <summary>Frees it.</summary>
    public void Dispose()
    {
        if (id != 0)
            CSharpModeling.Release(id);
        id = 0;
    }

    private int[] Edit(int op, int[] faces, float amount, bool flag)
    {
        ArgumentNullException.ThrowIfNull(faces);
        int handle = Live();
        // Each face can make several (a cube's extrude: four sides and a cap each).
        var added = new int[Math.Max(16, faces.Length * 32)];
        int count = CSharpModeling.EditFaces(handle, op, MemoryMarshal.AsBytes(faces.AsSpan()), amount, flag,
            MemoryMarshal.AsBytes(added.AsSpan()));
        if (count > added.Length)
        {
            // Not room for every made face: they are the last faces of the mesh.
            int total = FaceCount;
            return Enumerable.Range(total - count, count).ToArray();
        }
        return added[..Math.Max(0, count)];
    }

    private void SetFace(int face, Color color, bool setColor, int material, int smooth)
    {
        if (!CSharpModeling.SetFace(Live(), face, color.R, color.G, color.B, color.A, setColor, material, smooth))
            throw new ArgumentOutOfRangeException(nameof(face));
    }

    private (Vector3 Normal, Vector3 Center, float Area) FaceInfo(int face)
    {
        Span<float> values = stackalloc float[7];
        if (!CSharpModeling.FaceInfo(Live(), face, values))
            throw new ArgumentOutOfRangeException(nameof(face));
        return (new Vector3(values[0], values[1], values[2]), new Vector3(values[3], values[4], values[5]), values[6]);
    }

    private bool CheckVertex(int index) =>
        (uint)index < (uint)VertexCount ? true : throw new ArgumentOutOfRangeException(nameof(index));

    private int Live() => id != 0 ? id : throw new ObjectDisposedException(nameof(EditMesh));
}
