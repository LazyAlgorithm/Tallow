using System;
using System.Collections.Generic;
using System.Globalization;
using System.Numerics;

namespace Tallow.Editor;

/// <summary>The kind of a component field, as the scene serializer and the Inspector see it.</summary>
public enum EditorFieldKind
{
    /// <summary>A kind this version does not know.</summary>
    Unknown,
    /// <summary>A float.</summary>
    Float,
    /// <summary>A double.</summary>
    Double,
    /// <summary>A char (written as its number).</summary>
    Char,
    /// <summary>A Vector4: "x y z w".</summary>
    Vector4,
    /// <summary>An Int3: "x y z".</summary>
    Int3,
    /// <summary>A Matrix4: sixteen numbers, row by row.</summary>
    Matrix4,
    /// <summary>An int.</summary>
    Int,
    /// <summary>A bool: "1" or "0".</summary>
    Bool,
    /// <summary>A Vector2: "x y".</summary>
    Vector2,
    /// <summary>A Vector3: "x y z".</summary>
    Vector3,
    /// <summary>A Quaternion: "x y z w".</summary>
    Quaternion,
    /// <summary>A color: "r g b a".</summary>
    Color,
    /// <summary>A string: its text.</summary>
    String,
    /// <summary>An enum: the value's name.</summary>
    Enum,
    /// <summary>A reference to an object or component: "objectId componentIndex".</summary>
    ObjectReference,
    /// <summary>A List of one of the kinds above (the text is the scene file's own).</summary>
    List,
    /// <summary>An array of one of the kinds above (the text is the scene file's own).</summary>
    Array,
}

/// <summary>One serialized field of a built-in component.</summary>
public readonly record struct EditorField(string Name, EditorFieldKind Kind);

/// <summary>
/// An object in the scene the editor has open, for editor scripts that work in Edit mode: a Tools menu command can
/// find, create, move and delete objects, add and remove components and read or write their fields. Ids are the
/// editor's own; an object that was deleted (or another scene opened) stops existing. Mutations are refused during
/// Play, and each command that changes the scene is one undo step.
/// </summary>
public readonly struct EditorObject : IEquatable<EditorObject>
{
    internal EditorObject(uint id) => Id = id;

    internal uint Id { get; }

    /// <summary>An object that is none.</summary>
    public static EditorObject None => default;

    /// <summary>Whether the object is still in the open scene.</summary>
    public bool Exists => Id != 0 && EditorHost.ObjectName(Id) is not null;

    /// <summary>The object's name; setting it renames the object (edit mode only).</summary>
    public string Name
    {
        get => EditorHost.ObjectName(Id) ?? "";
        set
        {
            if (!EditorHost.RenameObject(Id, value))
                throw new InvalidOperationException("The object cannot be renamed (it is gone, or this is Play mode).");
        }
    }

    /// <summary>The object it is under, or null at the scene root.</summary>
    public EditorObject? Parent
    {
        get
        {
            uint parent = Id != 0 ? EditorHost.ObjectParent(Id) : 0;
            return parent != 0 ? new EditorObject(parent) : null;
        }
    }

    /// <summary>The objects directly under this one, in Hierarchy order.</summary>
    public IReadOnlyList<EditorObject> Children
    {
        get
        {
            int count = Id != 0 ? (int)EditorHost.ObjectChildCount(Id) : 0;
            var children = new EditorObject[count];
            for (int i = 0; i < count; i++)
                children[i] = new EditorObject(EditorHost.ObjectChild(Id, i));
            return children;
        }
    }

    /// <summary>World position.</summary>
    public Vector3 Position
    {
        get => ReadVector3(EditorHost.ObjectPosition);
        set
        {
            if (!EditorHost.SetObjectPosition(Id, value))
                throw new EditorMutationException();
        }
    }

    /// <summary>Rotation in Euler degrees.</summary>
    public Vector3 Rotation
    {
        get => ReadVector3(EditorHost.ObjectRotation);
        set
        {
            if (!EditorHost.SetObjectRotation(Id, value))
                throw new EditorMutationException();
        }
    }

    /// <summary>Local scale.</summary>
    public Vector3 Scale
    {
        get => ReadVector3(EditorHost.ObjectScale);
        set
        {
            if (!EditorHost.SetObjectScale(Id, value))
                throw new EditorMutationException();
        }
    }

    /// <summary>How many built-in components the object has (Transform is not one of them).</summary>
    public int ComponentCount => EditorHost.ComponentCount(Id);

    /// <summary>The components on the object, as the Inspector lists them: class components and scripts first, then
    /// the built-in handles (Light, MeshRenderer, ...). Transform is separate: use <see cref="Position"/> and the
    /// other transform properties.</summary>
    public IReadOnlyList<EditorComponent> Components
    {
        get
        {
            int count = Math.Max(ComponentCount, 0);
            var components = new EditorComponent[count];
            for (int i = 0; i < count; i++)
                components[i] = new EditorComponent(Id, EditorHost.ComponentType(Id, i) ?? "");
            return components;
        }
    }

    /// <summary>The component of that full type name ("Tallow.Light"), or null when the object has none.</summary>
    public EditorComponent? Component(string fullName) => HasComponent(fullName) ? new EditorComponent(Id, fullName) : null;

    /// <summary>Whether the object has a component of that full type name.</summary>
    public bool HasComponent(string fullName)
    {
        int count = Math.Max(ComponentCount, 0);
        for (int i = 0; i < count; i++)
            if (EditorHost.ComponentType(Id, i) == fullName)
                return true;
        return false;
    }

    /// <summary>Adds a component by full type name ("Tallow.Light", a script class name, ...); null when there is no
    /// such component or the object has it already.</summary>
    public EditorComponent? AddComponent(string fullName) =>
        EditorHost.AddComponent(Id, fullName) ? new EditorComponent(Id, fullName) : null;

    /// <summary>Removes the component of that type; false when the object has none.</summary>
    public bool RemoveComponent(string fullName) => EditorHost.RemoveComponent(Id, fullName);

    /// <summary>Makes one of the editor's built-in objects ("Cube", "Point Light", "Create Empty", ...) under this
    /// one, selected; returns the object that is none when the kind is not one of them.</summary>
    public EditorObject Create(string kind) =>
        Id != 0 ? new EditorObject(EditorHost.CreateObject(kind, Id)) : EditorObject.None;

    /// <summary>A copy of the object (and everything under it) beside it; the object that is none when it cannot be
    /// copied.</summary>
    public EditorObject Duplicate() => new(EditorHost.DuplicateObject(Id));

    /// <summary>Deletes the object and everything under it.</summary>
    public void Delete() => EditorHost.DeleteObject(Id);

    /// <summary>Selects the object in the editor.</summary>
    public void Select() => EditorHost.SelectObject(Id);

    private delegate bool ReadFloats(uint id, Span<float> values);

    private Vector3 ReadVector3(ReadFloats read)
    {
        if (Id == 0)
            return Vector3.Zero;
        Span<float> values = stackalloc float[3];
        return read(Id, values) ? new Vector3(values[0], values[1], values[2]) : Vector3.Zero;
    }

    /// <summary>Whether both name the same object.</summary>
    public bool Equals(EditorObject other) => Id == other.Id;
    /// <inheritdoc/>
    public override bool Equals(object? obj) => obj is EditorObject other && Equals(other);
    /// <inheritdoc/>
    public override int GetHashCode() => (int)Id;
    /// <summary>Whether both name the same object.</summary>
    public static bool operator ==(EditorObject left, EditorObject right) => left.Id == right.Id;
    /// <summary>Whether they name different objects.</summary>
    public static bool operator !=(EditorObject left, EditorObject right) => left.Id != right.Id;
    /// <summary>The object's name, or its id when it is gone.</summary>
    public override string ToString() => Exists ? Name : $"<object {Id}>";
}

/// <summary>One component on an object of the open scene, as <see cref="EditorObject.Components"/> lists them.</summary>
public readonly struct EditorComponent
{
    internal EditorComponent(uint owner, string typeName)
    {
        Object = new EditorObject(owner);
        TypeName = typeName;
    }

    /// <summary>The object the component is on.</summary>
    public EditorObject Object { get; }

    /// <summary>The component's full type name ("Tallow.Light").</summary>
    public string TypeName { get; }

    /// <summary>Whether the object still has the component.</summary>
    public bool Exists => Object.HasComponent(TypeName);

    /// <summary>The component's serialized fields, as the Inspector lists them.</summary>
    public IReadOnlyList<EditorField> Fields
    {
        get
        {
            string? list = EditorHost.FieldList(Object.Id, TypeName);
            if (list == null)
                return [];
            var fields = new List<EditorField>();
            foreach (string line in list.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                int tab = line.IndexOf('\t');
                if (tab <= 0)
                    continue;
                fields.Add(new EditorField(line[..tab],
                    Enum.TryParse(line[(tab + 1)..], out EditorFieldKind kind) ? kind : EditorFieldKind.Unknown));
            }
            return fields;
        }
    }

    /// <summary>A field's value as text, the way scene files write it: numbers as "1.5", vectors as "1 2 3", a
    /// string as its text, an enum by name, a reference as "objectId componentIndex". Null when there is no such
    /// field.</summary>
    public string? Get(string field) => EditorHost.FieldRead(Object.Id, TypeName, field);

    /// <summary>Sets a field from the same text <see cref="Get"/> returns; false when there is no such field (or
    /// this is Play mode).</summary>
    public bool Set(string field, string value) => EditorHost.FieldWrite(Object.Id, TypeName, field, value);

    /// <summary>A float field, or the fallback when it is missing or not a number.</summary>
    public float GetFloat(string field, float fallback = 0) =>
        float.TryParse(Get(field), NumberStyles.Float, CultureInfo.InvariantCulture, out float value) ? value : fallback;

    /// <summary>An int field, or the fallback when it is missing or not a number.</summary>
    public int GetInt(string field, int fallback = 0) =>
        int.TryParse(Get(field), NumberStyles.Integer, CultureInfo.InvariantCulture, out int value) ? value : fallback;

    /// <summary>A bool field, or the fallback when it is missing.</summary>
    public bool GetBool(string field, bool fallback = false) => Get(field) switch
    {
        "1" or "true" => true,
        "0" or "false" => false,
        _ => fallback,
    };

    /// <summary>A string field's text ("" when it is missing).</summary>
    public string GetString(string field) => Get(field) ?? "";

    /// <summary>An enum field's value name ("" when it is missing).</summary>
    public string GetEnum(string field) => Get(field) ?? "";

    /// <summary>A Vector3 field ("x y z"), or zero when it is missing.</summary>
    public Vector3 GetVector3(string field)
    {
        float[] values = ParseNumbers(Get(field), 3);
        return values.Length == 3 ? new Vector3(values[0], values[1], values[2]) : Vector3.Zero;
    }

    /// <summary>Sets a float field; false when there is no such field (or this is Play mode).</summary>
    public bool SetFloat(string field, float value) => Set(field, value.ToString("R", CultureInfo.InvariantCulture));

    /// <summary>Sets an int field; false when there is no such field (or this is Play mode).</summary>
    public bool SetInt(string field, int value) => Set(field, value.ToString(CultureInfo.InvariantCulture));

    /// <summary>Sets a bool field; false when there is no such field (or this is Play mode).</summary>
    public bool SetBool(string field, bool value) => Set(field, value ? "1" : "0");

    /// <summary>Sets a string field; false when there is no such field (or this is Play mode).</summary>
    public bool SetString(string field, string value) => Set(field, value);

    /// <summary>Sets an enum field by value name; false when there is no such field (or this is Play mode).</summary>
    public bool SetEnum(string field, string name) => Set(field, name);

    /// <summary>Sets a Vector3 field ("x y z"); false when there is no such field (or this is Play mode).</summary>
    public bool SetVector3(string field, Vector3 value) => Set(field,
        $"{value.X.ToString("R", CultureInfo.InvariantCulture)} {value.Y.ToString("R", CultureInfo.InvariantCulture)} {value.Z.ToString("R", CultureInfo.InvariantCulture)}");

    internal static float[] ParseNumbers(string? text, int count)
    {
        if (text == null)
            return [];
        string[] parts = text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != count)
            return [];
        var values = new float[count];
        for (int i = 0; i < count; i++)
            if (!float.TryParse(parts[i], NumberStyles.Float, CultureInfo.InvariantCulture, out values[i]))
                return [];
        return values;
    }
}

/// <summary>The scene the editor has open, for editor scripts: find what the user selected, make and remove objects,
/// and edit their components. Works in Edit mode; during Play the mutating calls refuse.</summary>
public static class EditorScene
{
    /// <summary>Whether the editor is playing the game (the scene is the play session's then).</summary>
    public static bool IsPlaying => EditorHost.Query(EditorHost.QueryPlaying) != 0;

    /// <summary>Whether objects and components can be changed (Edit mode).</summary>
    public static bool IsEditable => !IsPlaying;

    /// <summary>The object selected in the Hierarchy or the Scene view, or null.</summary>
    public static EditorObject? Selection
    {
        get
        {
            uint id = EditorHost.SelectedObject();
            return id != 0 ? new EditorObject(id) : null;
        }
        set => EditorHost.SelectObject(value?.Id ?? 0);
    }

    /// <summary>The objects at the scene root, in Hierarchy order.</summary>
    public static IReadOnlyList<EditorObject> Roots
    {
        get
        {
            int count = (int)EditorHost.ObjectChildCount(0);
            var roots = new EditorObject[count];
            for (int i = 0; i < count; i++)
                roots[i] = new EditorObject(EditorHost.ObjectChild(0, i));
            return roots;
        }
    }

    /// <summary>An object by its path from the scene root ("Level/Walls/Wall 1", a leading '/' is allowed), or by
    /// name anywhere in the scene; the object that is none when there is none.</summary>
    public static EditorObject Find(string path) => new(EditorHost.FindObject(path));

    /// <summary>Makes one of the editor's built-in objects ("Cube", "Point Light", "Create Empty", ...) where the
    /// editor puts a new object (under the selected folder, or in front of the Scene view camera), selected.</summary>
    public static EditorObject Create(string kind) => new(EditorHost.CreateObject(kind, uint.MaxValue));

    /// <summary>Makes one of the built-in objects under a parent (or at the scene root for the object that is
    /// none).</summary>
    public static EditorObject Create(string kind, EditorObject parent) =>
        new(EditorHost.CreateObject(kind, parent.Id));

    /// <summary>Records the scene as changed (the editor marks it unsaved and makes an undo step of this frame's
    /// edits). The field, transform and lifecycle calls do this themselves; batch edits through it when writing to
    /// something the editor does not see, such as a component handle held between frames.</summary>
    public static void MarkDirty() => EditorHost.MarkDirty();
}

/// <summary>A scene change was refused: the object is gone, or the editor is in Play mode.</summary>
public sealed class EditorMutationException()
    : InvalidOperationException("The scene cannot be changed now (an object that is gone, or Play mode).");
