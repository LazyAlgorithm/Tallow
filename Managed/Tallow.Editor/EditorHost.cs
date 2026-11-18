using System.Numerics;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Loader;
using System.Text;

namespace Tallow.Editor;

/// <summary>The editor's side of the editor extensions: the functions the editor gives (EditorHostTable, in the
/// order of Editor/src/Scripts/CSharpEditorExtensions.bf) and the ones it calls (ManagedTable). Strings cross as
/// UTF-8 bytes and a length; a string the editor returns stays valid until its next call.</summary>
internal static unsafe class EditorHost
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct HostTable
    {
        public int Version;
        public int Size;
        public delegate* unmanaged[Cdecl]<int, byte*, int, void> Log;
        public delegate* unmanaged[Cdecl]<int, byte*, int, void> Text;
        public delegate* unmanaged[Cdecl]<byte*, int, float, float, int> Button;
        public delegate* unmanaged[Cdecl]<byte*, int, int*, int> Toggle;
        public delegate* unmanaged[Cdecl]<byte*, int, float*, float, float, float, int, int> Float;
        public delegate* unmanaged[Cdecl]<byte*, int, int*, float, int, int, int> Int;
        public delegate* unmanaged[Cdecl]<byte*, int, float*, int, int> Vector;
        public delegate* unmanaged[Cdecl]<byte*, int, byte*, int, int, byte**, int*, int> TextField;
        public delegate* unmanaged[Cdecl]<byte*, int, byte*, int, int*, int> Popup;
        public delegate* unmanaged[Cdecl]<byte*, int, int, int> Foldout;
        public delegate* unmanaged[Cdecl]<int, int, void> Layout;
        public delegate* unmanaged[Cdecl]<float, byte*, int, void> Progress;
        public delegate* unmanaged[Cdecl]<byte*, int, void> Tooltip;
        public delegate* unmanaged[Cdecl]<byte*, int, int> TargetField;
        public delegate* unmanaged[Cdecl]<int> TargetDefault;
        public delegate* unmanaged[Cdecl]<byte*, int, byte**, int*, int> TargetRead;
        public delegate* unmanaged[Cdecl]<byte*, int, byte*, int, int> TargetWrite;
        public delegate* unmanaged[Cdecl]<int, byte**, int*, int> Query;
        public delegate* unmanaged[Cdecl]<uint> SelectedObject;
        public delegate* unmanaged[Cdecl]<uint, void> SelectObject;
        public delegate* unmanaged[Cdecl]<byte*, int, uint> FindObject;
        public delegate* unmanaged[Cdecl]<uint, uint> ObjectParent;
        public delegate* unmanaged[Cdecl]<uint, uint> ObjectChildCount;
        public delegate* unmanaged[Cdecl]<uint, int, uint> ObjectChild;
        public delegate* unmanaged[Cdecl]<uint, byte**, int*, int> ObjectName;
        public delegate* unmanaged[Cdecl]<uint, byte*, int, int> RenameObject;
        public delegate* unmanaged[Cdecl]<byte*, int, uint, uint> CreateObject;
        public delegate* unmanaged[Cdecl]<uint, uint> DuplicateObject;
        public delegate* unmanaged[Cdecl]<uint, void> DeleteObject;
        public delegate* unmanaged[Cdecl]<uint, float*, int> ObjectPosition;
        public delegate* unmanaged[Cdecl]<uint, float, float, float, int> SetObjectPosition;
        public delegate* unmanaged[Cdecl]<uint, float*, int> ObjectRotation;
        public delegate* unmanaged[Cdecl]<uint, float, float, float, int> SetObjectRotation;
        public delegate* unmanaged[Cdecl]<uint, float*, int> ObjectScale;
        public delegate* unmanaged[Cdecl]<uint, float, float, float, int> SetObjectScale;
        public delegate* unmanaged[Cdecl]<uint, int> ComponentCount;
        public delegate* unmanaged[Cdecl]<uint, int, byte**, int*, int> ComponentType;
        public delegate* unmanaged[Cdecl]<uint, byte*, int, int> AddComponent;
        public delegate* unmanaged[Cdecl]<uint, byte*, int, int> RemoveComponent;
        public delegate* unmanaged[Cdecl]<uint, byte*, int, byte**, int*, int> FieldList;
        public delegate* unmanaged[Cdecl]<uint, byte*, int, byte*, int, byte**, int*, int> FieldRead;
        public delegate* unmanaged[Cdecl]<uint, byte*, int, byte*, int, byte*, int, int> FieldWrite;
        public delegate* unmanaged[Cdecl]<void> MarkDirty;
        public delegate* unmanaged[Cdecl]<byte*, int, int> ComponentField;
        public delegate* unmanaged[Cdecl]<int> ComponentDefault;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct ManagedTable
    {
        public delegate* unmanaged[Cdecl]<byte*, int> Load;
        public delegate* unmanaged[Cdecl]<int> Unload;
        public delegate* unmanaged[Cdecl]<int, int, byte*, int, int> Describe;
        public delegate* unmanaged[Cdecl]<byte*, int> FindInspector;
        public delegate* unmanaged[Cdecl]<int, long, int> DrawInspector;
        public delegate* unmanaged[Cdecl]<int, int, int> Window;
        public delegate* unmanaged[Cdecl]<int, int> RunMenu;
        public delegate* unmanaged[Cdecl]<int, int> DrawPage;
        public delegate* unmanaged[Cdecl]<byte*, int, int> FindComponentInspector;
        public delegate* unmanaged[Cdecl]<int, uint, byte*, int, int> DrawComponentInspector;
    }

    internal const int Version = 3;
    internal const int LayoutSameLine = 0, LayoutSeparator = 1, LayoutSpacing = 2, LayoutIndent = 3, LayoutUnindent = 4,
        LayoutBeginDisabled = 5, LayoutEndDisabled = 6, LayoutPushId = 7, LayoutPopId = 8;
    internal const int QueryPlaying = 0, QueryProjectPath = 1, QueryTargetScript = 2, QueryTargetObject = 3,
        QuerySelection = 4, QueryConfigFolder = 5;

    private static HostTable sHost;
    private static bool sBound;

    /// <summary>Called once by Tallow.ManagedRuntime's EditorConfigure (by reflection, so a game never loads this
    /// assembly): keeps the editor's functions and fills in the ones it calls. 1 on success.</summary>
    public static int Configure(nint hostTable, nint managedTable)
    {
        HostTable* host = (HostTable*)hostTable;
        if (host == null || managedTable == 0 || host->Version != Version || host->Size != sizeof(HostTable))
            return 0;
        sHost = *host;
        sBound = true;
        *(ManagedTable*)managedTable = new ManagedTable
        {
            Load = &Load,
            Unload = &Unload,
            Describe = &Describe,
            FindInspector = &FindInspector,
            DrawInspector = &DrawInspector,
            Window = &Window,
            RunMenu = &RunMenu,
            DrawPage = &DrawPage,
            FindComponentInspector = &FindComponentInspector,
            DrawComponentInspector = &DrawComponentInspector
        };
        return 1;
    }

    // ---- Strings ----

    /// <summary>UTF-8 of text in buffer (on the stack when short); the bytes are followed by a NUL.</summary>
    private ref struct Utf8
    {
        private byte[]? mRented;
        public Span<byte> Bytes;

        public Utf8(string? text, Span<byte> stack)
        {
            text ??= "";
            int needed = Encoding.UTF8.GetMaxByteCount(text.Length) + 1;
            Span<byte> buffer = needed <= stack.Length ? stack : (mRented = System.Buffers.ArrayPool<byte>.Shared.Rent(needed));
            int length = Encoding.UTF8.GetBytes(text, buffer);
            buffer[length] = 0;
            Bytes = buffer[..length];
        }

        public void Dispose()
        {
            if (mRented != null)
                System.Buffers.ArrayPool<byte>.Shared.Return(mRented);
        }
    }

    private static string FromUtf8(byte* text, int length) =>
        text == null || length <= 0 ? "" : Encoding.UTF8.GetString(text, length);

    private static void Require()
    {
        if (!sBound || !sDrawing)
            throw new InvalidOperationException("Editor widgets can only be drawn from OnInspectorGUI or OnGUI.");
    }

    // ---- What EditorGUI and the rest call ----

    internal static void Log(int level, string message)
    {
        if (!sBound)
        {
            Console.Error.WriteLine("[Tallow editor C#] " + message);
            return;
        }
        using var text = new Utf8(message, stackalloc byte[512]);
        fixed (byte* bytes = text.Bytes)
            sHost.Log(level, bytes, text.Bytes.Length);
    }

    internal static void Text(int style, string value)
    {
        Require();
        using var text = new Utf8(value, stackalloc byte[512]);
        fixed (byte* bytes = text.Bytes)
            sHost.Text(style, bytes, text.Bytes.Length);
    }

    internal static bool Button(string label, float width, float height)
    {
        Require();
        using var text = new Utf8(label, stackalloc byte[256]);
        fixed (byte* bytes = text.Bytes)
            return sHost.Button(bytes, text.Bytes.Length, width, height) != 0;
    }

    internal static bool Toggle(string label, ref int value)
    {
        Require();
        using var text = new Utf8(label, stackalloc byte[256]);
        fixed (byte* bytes = text.Bytes)
        fixed (int* state = &value)
            return sHost.Toggle(bytes, text.Bytes.Length, state) != 0;
    }

    internal static bool Float(string label, ref float value, float speed, float min, float max, bool slider)
    {
        Require();
        using var text = new Utf8(label, stackalloc byte[256]);
        fixed (byte* bytes = text.Bytes)
        fixed (float* number = &value)
            return sHost.Float(bytes, text.Bytes.Length, number, speed, min, max, slider ? 1 : 0) != 0;
    }

    internal static bool Int(string label, ref int value, float speed, int min, int max)
    {
        Require();
        using var text = new Utf8(label, stackalloc byte[256]);
        fixed (byte* bytes = text.Bytes)
        fixed (int* number = &value)
            return sHost.Int(bytes, text.Bytes.Length, number, speed, min, max) != 0;
    }

    /// <summary>count 2-4: a vector; 5: a colour (4 values).</summary>
    internal static bool Vector(string label, Span<float> values, int count)
    {
        Require();
        using var text = new Utf8(label, stackalloc byte[256]);
        fixed (byte* bytes = text.Bytes)
        fixed (float* numbers = values)
            return sHost.Vector(bytes, text.Bytes.Length, numbers, count) != 0;
    }

    internal static bool TextField(string label, ref string value, bool multiline)
    {
        Require();
        using var name = new Utf8(label, stackalloc byte[256]);
        using var current = new Utf8(value, stackalloc byte[512]);
        byte* result = null;
        int resultLength = 0;
        int changed;
        fixed (byte* labelBytes = name.Bytes)
        fixed (byte* valueBytes = current.Bytes)
            changed = sHost.TextField(labelBytes, name.Bytes.Length, valueBytes, current.Bytes.Length, multiline ? 1 : 0,
                &result, &resultLength);
        if (changed != 0)
            value = FromUtf8(result, resultLength);
        return changed != 0;
    }

    internal static bool Popup(string label, IReadOnlyList<string> options, ref int index)
    {
        Require();
        using var name = new Utf8(label, stackalloc byte[256]);
        using var list = new Utf8(string.Join('\n', options.Select(option => option.Replace('\n', ' '))), stackalloc byte[512]);
        fixed (byte* labelBytes = name.Bytes)
        fixed (byte* listBytes = list.Bytes)
        fixed (int* picked = &index)
            return sHost.Popup(labelBytes, name.Bytes.Length, listBytes, list.Bytes.Length, picked) != 0;
    }

    internal static bool Foldout(string label, bool openAtFirst)
    {
        Require();
        using var text = new Utf8(label, stackalloc byte[256]);
        fixed (byte* bytes = text.Bytes)
            return sHost.Foldout(bytes, text.Bytes.Length, openAtFirst ? 1 : 0) != 0;
    }

    internal static void Progress(float fraction, string overlay)
    {
        Require();
        using var text = new Utf8(overlay, stackalloc byte[256]);
        fixed (byte* bytes = text.Bytes)
            sHost.Progress(fraction, bytes, text.Bytes.Length);
    }

    internal static void Tooltip(string value)
    {
        Require();
        using var text = new Utf8(value, stackalloc byte[512]);
        fixed (byte* bytes = text.Bytes)
            sHost.Tooltip(bytes, text.Bytes.Length);
    }

    internal static void Layout(int op, int value)
    {
        Require();
        sHost.Layout(op, value);
    }

    // Disabled, indented and id scopes still open, innermost last: a widget call that throws or a scope left open
    // must not leave the editor's own widgets greyed out or the window's layout broken.
    private static readonly List<int> sOpen = [];

    internal static EditorGUI.Scope Push(int op, int value)
    {
        Layout(op, value);
        sOpen.Add(op);
        return new EditorGUI.Scope(sOpen.Count);
    }

    internal static void Pop(int depth)
    {
        while (sOpen.Count >= depth && sOpen.Count > 0)
        {
            int op = sOpen[^1];
            sOpen.RemoveAt(sOpen.Count - 1);
            sHost.Layout(op switch
            {
                LayoutBeginDisabled => LayoutEndDisabled,
                LayoutIndent => LayoutUnindent,
                _ => LayoutPopId
            }, 0);
        }
    }

    internal static int Query(int what)
    {
        if (!sBound)
            return 0;
        byte* text = null;
        int length = 0;
        return sHost.Query(what, &text, &length);
    }

    internal static string QueryText(int what)
    {
        if (!sBound)
            return "";
        byte* text = null;
        int length = 0;
        sHost.Query(what, &text, &length);
        return FromUtf8(text, length);
    }

    // ---- The open scene (Tallow.Editor's EditorScene); usable outside drawing, as menu commands do ----

    internal static void RequireScene()
    {
        if (!sBound)
            throw new InvalidOperationException("The editor scene is not available yet.");
    }

    internal static uint SelectedObject()
    {
        RequireScene();
        return sHost.SelectedObject();
    }

    internal static void SelectObject(uint id)
    {
        RequireScene();
        sHost.SelectObject(id);
    }

    internal static uint FindObject(string path)
    {
        RequireScene();
        using var text = new Utf8(path, stackalloc byte[256]);
        fixed (byte* bytes = text.Bytes)
            return sHost.FindObject(bytes, text.Bytes.Length);
    }

    internal static uint ObjectParent(uint id)
    {
        RequireScene();
        return sHost.ObjectParent(id);
    }

    internal static uint ObjectChildCount(uint id)
    {
        RequireScene();
        return sHost.ObjectChildCount(id);
    }

    internal static uint ObjectChild(uint id, int index)
    {
        RequireScene();
        return sHost.ObjectChild(id, index);
    }

    internal static string? ObjectName(uint id)
    {
        RequireScene();
        byte* text = null;
        int length = 0;
        return sHost.ObjectName(id, &text, &length) == 0 ? null : FromUtf8(text, length);
    }

    internal static bool RenameObject(uint id, string name)
    {
        RequireScene();
        using var text = new Utf8(name, stackalloc byte[256]);
        fixed (byte* bytes = text.Bytes)
            return sHost.RenameObject(id, bytes, text.Bytes.Length) > 0;
    }

    internal static uint CreateObject(string kind, uint parent)
    {
        RequireScene();
        using var text = new Utf8(kind, stackalloc byte[256]);
        fixed (byte* bytes = text.Bytes)
            return sHost.CreateObject(bytes, text.Bytes.Length, parent);
    }

    internal static uint DuplicateObject(uint id)
    {
        RequireScene();
        return sHost.DuplicateObject(id);
    }

    internal static void DeleteObject(uint id)
    {
        RequireScene();
        sHost.DeleteObject(id);
    }

    internal static bool ObjectPosition(uint id, Span<float> values)
    {
        RequireScene();
        fixed (float* buffer = values)
            return sHost.ObjectPosition(id, buffer) > 0;
    }

    internal static bool SetObjectPosition(uint id, Vector3 value)
    {
        RequireScene();
        return sHost.SetObjectPosition(id, value.X, value.Y, value.Z) > 0;
    }

    internal static bool ObjectRotation(uint id, Span<float> values)
    {
        RequireScene();
        fixed (float* buffer = values)
            return sHost.ObjectRotation(id, buffer) > 0;
    }

    internal static bool SetObjectRotation(uint id, Vector3 value)
    {
        RequireScene();
        return sHost.SetObjectRotation(id, value.X, value.Y, value.Z) > 0;
    }

    internal static bool ObjectScale(uint id, Span<float> values)
    {
        RequireScene();
        fixed (float* buffer = values)
            return sHost.ObjectScale(id, buffer) > 0;
    }

    internal static bool SetObjectScale(uint id, Vector3 value)
    {
        RequireScene();
        return sHost.SetObjectScale(id, value.X, value.Y, value.Z) > 0;
    }

    internal static int ComponentCount(uint id)
    {
        RequireScene();
        return sHost.ComponentCount(id);
    }

    internal static string? ComponentType(uint id, int index)
    {
        RequireScene();
        byte* text = null;
        int length = 0;
        return sHost.ComponentType(id, index, &text, &length) == 0 ? null : FromUtf8(text, length);
    }

    internal static bool AddComponent(uint id, string fullName)
    {
        RequireScene();
        using var text = new Utf8(fullName, stackalloc byte[256]);
        fixed (byte* bytes = text.Bytes)
            return sHost.AddComponent(id, bytes, text.Bytes.Length) > 0;
    }

    internal static bool RemoveComponent(uint id, string fullName)
    {
        RequireScene();
        using var text = new Utf8(fullName, stackalloc byte[256]);
        fixed (byte* bytes = text.Bytes)
            return sHost.RemoveComponent(id, bytes, text.Bytes.Length) > 0;
    }

    internal static string? FieldList(uint id, string component)
    {
        RequireScene();
        using var name = new Utf8(component, stackalloc byte[256]);
        byte* text = null;
        int length = 0;
        bool found;
        fixed (byte* bytes = name.Bytes)
            found = sHost.FieldList(id, bytes, name.Bytes.Length, &text, &length) > 0;
        return found ? FromUtf8(text, length) : null;
    }

    internal static string? FieldRead(uint id, string component, string field)
    {
        RequireScene();
        using var name = new Utf8(component, stackalloc byte[256]);
        using var text = new Utf8(field, stackalloc byte[256]);
        byte* value = null;
        int length = 0;
        bool found;
        fixed (byte* nameBytes = name.Bytes)
        fixed (byte* fieldBytes = text.Bytes)
            found = sHost.FieldRead(id, nameBytes, name.Bytes.Length, fieldBytes, text.Bytes.Length, &value, &length) > 0;
        return found ? FromUtf8(value, length) : null;
    }

    internal static bool FieldWrite(uint id, string component, string field, string value)
    {
        RequireScene();
        using var name = new Utf8(component, stackalloc byte[256]);
        using var fieldText = new Utf8(field, stackalloc byte[256]);
        using var text = new Utf8(value, stackalloc byte[512]);
        fixed (byte* nameBytes = name.Bytes)
        fixed (byte* fieldBytes = fieldText.Bytes)
        fixed (byte* valueBytes = text.Bytes)
            return sHost.FieldWrite(id, nameBytes, name.Bytes.Length, fieldBytes, fieldText.Bytes.Length,
                valueBytes, text.Bytes.Length) > 0;
    }

    internal static void MarkDirty()
    {
        RequireScene();
        sHost.MarkDirty();
    }

    private static void RequireTarget()
    {
        Require();
        if (sInspecting == null)
            throw new InvalidOperationException("Only an Inspector has a target.");
    }

    internal static bool TargetField(string name)
    {
        RequireTarget();
        using var text = new Utf8(name, stackalloc byte[256]);
        fixed (byte* bytes = text.Bytes)
            return Changed(sHost.TargetField(bytes, text.Bytes.Length) > 0);
    }

    internal static bool TargetDefault()
    {
        RequireTarget();
        return Changed(sHost.TargetDefault() > 0);
    }

    private static bool Changed(bool changed)
    {
        if (changed)
            EditorGUI.Changed = true;
        return changed;
    }

    /// <summary>Draws one field (null: all of them) of the component a C# component Inspector is drawing, with the
    /// editor's own widget. Only while one draws.</summary>
    internal static bool ComponentField(string? name)
    {
        Require();
        if (name == null)
            return Changed(sHost.ComponentDefault() > 0);
        using var text = new Utf8(name, stackalloc byte[256]);
        fixed (byte* bytes = text.Bytes)
            return Changed(sHost.ComponentField(bytes, text.Bytes.Length) > 0);
    }

    internal static string? TargetRead(string name)
    {
        RequireTarget();
        using var text = new Utf8(name, stackalloc byte[256]);
        byte* value = null;
        int length = 0;
        fixed (byte* bytes = text.Bytes)
            if (sHost.TargetRead(bytes, text.Bytes.Length, &value, &length) == 0)
                return null;
        return FromUtf8(value, length);
    }

    internal static bool TargetWrite(string name, string value)
    {
        RequireTarget();
        using var field = new Utf8(name, stackalloc byte[256]);
        using var text = new Utf8(value, stackalloc byte[512]);
        fixed (byte* fieldBytes = field.Bytes)
        fixed (byte* valueBytes = text.Bytes)
            return Changed(sHost.TargetWrite(fieldBytes, field.Bytes.Length, valueBytes, text.Bytes.Length) != 0);
    }

    // ---- The extensions ----

    /// <summary>The game's editor assembly and its own copies of the game assemblies it uses, apart from a running
    /// game's (Play loads its own): Tallow.API and Tallow.Editor are shared, so the types line up.</summary>
    private sealed class ExtensionContext(string root) : AssemblyLoadContext("Tallow.EditorExtensions", isCollectible: true)
    {
        protected override Assembly? Load(AssemblyName name)
        {
            if (name.Name == typeof(Script).Assembly.GetName().Name)
                return typeof(Script).Assembly;
            if (name.Name == typeof(EditorHost).Assembly.GetName().Name)
                return typeof(EditorHost).Assembly;
            if (string.IsNullOrEmpty(name.Name) || name.Name.Contains('/') || name.Name.Contains('\\') ||
                name.Name.Contains("..") || name.Name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
                return null;
            string candidate = Path.Combine(root, name.Name, name.Name + ".dll");
            if (File.Exists(candidate))
                return LoadCopy(candidate);
            if (Directory.Exists(root))
                foreach (string folder in Directory.EnumerateDirectories(root).Order(StringComparer.Ordinal))
                {
                    string library = Path.Combine(folder, name.Name + ".dll");
                    if (File.Exists(library))
                        return LoadCopy(library);
                }
            return null;
        }

        /// <summary>From a copy in memory: the next compile can replace the file (Windows locks mapped files).</summary>
        public Assembly LoadCopy(string path)
        {
            using var image = new MemoryStream(File.ReadAllBytes(path));
            string pdb = Path.ChangeExtension(path, ".pdb");
            using MemoryStream? symbols = File.Exists(pdb) ? new MemoryStream(File.ReadAllBytes(pdb)) : null;
            return LoadFromStream(image, symbols);
        }
    }

    private sealed record InspectorType(Type Inspector, Type Script);
    private sealed record WindowType(Type Window, string MenuPath, string Title);
    private sealed record MenuCommand(MethodInfo Method, string Path);
    private sealed record PageType(Type Type, string Title);
    private sealed record ComponentInspectorType(Type Type, string ComponentName);

    private static ExtensionContext? sContext;
    private static readonly List<InspectorType> sInspectors = [];
    private static readonly List<WindowType> sWindows = [];
    private static readonly List<MenuCommand> sMenus = [];
    private static readonly List<PageType> sPages = [];
    private static readonly List<ComponentInspectorType> sComponentInspectors = [];
    private static readonly Dictionary<string, int> sComponentInspectorFor = new(StringComparer.Ordinal);
    private static readonly Dictionary<(int, uint, string), ComponentInspector> sComponentInspectorObjects = [];
    private static readonly Dictionary<int, PreferencesPage> sPageObjects = [];
    private static readonly Dictionary<(int, long), Inspector> sInspectorObjects = [];
    private static readonly Dictionary<int, EditorWindow> sWindowObjects = [];
    private static readonly Dictionary<string, int> sInspectorFor = new(StringComparer.Ordinal);
    private static readonly HashSet<string> sReported = new(StringComparer.Ordinal);
    private static readonly List<WeakReference> sUnloaded = [];
    private static bool sDrawing;
    private static SerializedScript? sInspecting;
    private static readonly SerializedScript sTarget = new();

    /// <summary>A failure, reported once per distinct text (OnGUI runs every frame).</summary>
    private static int Report(string where, Exception exception)
    {
        if (exception is TargetInvocationException { InnerException: { } inner })
            exception = inner;
        string text = $"{where}: {exception}";
        if (sReported.Count > 256)
            sReported.Clear();
        if (sReported.Add(text))
            Log(2, text);
        return -1;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int Load(byte* binRoot)
    {
        try
        {
            UnloadAll();
            string root = Path.GetFullPath(Marshal.PtrToStringUTF8((nint)binRoot) ?? "");
            string path = Path.Combine(root, "Tallow.Game.Editor", "Tallow.Game.Editor.dll");
            if (!File.Exists(path))
                return 0;
            var context = new ExtensionContext(root);
            sContext = context;
            Assembly assembly = context.LoadCopy(path);
            Type[] types;
            try
            {
                types = assembly.GetTypes();
            }
            catch (ReflectionTypeLoadException partial)
            {
                types = partial.Types.Where(type => type != null).ToArray()!;
            }
            foreach (Type type in types.OrderBy(type => type.FullName, StringComparer.Ordinal))
            {
                if (type.IsClass && !type.IsAbstract && !type.ContainsGenericParameters &&
                    type.GetConstructor(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic, Type.EmptyTypes) != null)
                {
                    if (typeof(Inspector).IsAssignableFrom(type) && type.GetCustomAttribute<CustomInspectorAttribute>() is { } inspector)
                        sInspectors.Add(new InspectorType(type, inspector.Script));
                    else if (typeof(ComponentInspector).IsAssignableFrom(type) &&
                        type.GetCustomAttribute<CustomInspectorAttribute>() is { } component)
                    {
                        if (component.Script.GetCustomAttribute<NativeComponentAttribute>() is { } handle)
                            sComponentInspectors.Add(new ComponentInspectorType(type, handle.TypeName));
                        else
                            Log(1, $"[CustomInspector(typeof({component.Script.Name}))] {type.FullName}: name a built-in " +
                                "component's handle type (Tallow.Light, Tallow.MeshRenderer, ...); a C# script's Inspector derives from Inspector.");
                    }
                    if (type.GetCustomAttribute<PreferencesPageAttribute>() is { } page && page.Title.Length > 0)
                        sPages.Add(new PageType(type, page.Title));
                    if (typeof(EditorWindow).IsAssignableFrom(type) && type.GetCustomAttribute<EditorWindowAttribute>() is { } window)
                    {
                        string menu = window.MenuPath.Trim('/');
                        string title = menu[(menu.LastIndexOf('/') + 1)..];
                        if (title.Length > 0)
                            sWindows.Add(new WindowType(type, menu, title));
                    }
                }
                foreach (MethodInfo method in type.GetMethods(BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.DeclaredOnly))
                {
                    if (method.GetCustomAttribute<MenuItemAttribute>() is not { } item)
                        continue;
                    if (method.GetParameters().Length != 0 || method.ContainsGenericParameters)
                    {
                        Log(1, $"[MenuItem(\"{item.Path}\")] {type.FullName}.{method.Name} needs to be a static method without parameters.");
                        continue;
                    }
                    sMenus.Add(new MenuCommand(method, item.Path.Trim('/')));
                }
            }
            sPages.Sort((a, b) => string.Compare(a.Title, b.Title, StringComparison.CurrentCultureIgnoreCase));
            for (int i = 0; i < sComponentInspectors.Count; i++)
                sComponentInspectorFor[sComponentInspectors[i].ComponentName] = i;
            return sInspectors.Count + sWindows.Count + sMenus.Count + sPages.Count + sComponentInspectors.Count;
        }
        catch (Exception exception)
        {
            UnloadAll();
            return Report("Loading the game's editor scripts", exception);
        }
    }

    private static void UnloadAll()
    {
        foreach ((int index, EditorWindow window) in sWindowObjects)
        {
            try
            {
                window.OnDisable();
            }
            catch (Exception exception)
            {
                Report($"{sWindows[index].Window.FullName}.OnDisable", exception);
            }
        }
        sWindowObjects.Clear();
        sInspectorObjects.Clear();
        sInspectorFor.Clear();
        sInspectors.Clear();
        sComponentInspectorObjects.Clear();
        sComponentInspectorFor.Clear();
        sComponentInspectors.Clear();
        sWindows.Clear();
        sMenus.Clear();
        sPages.Clear();
        sPageObjects.Clear();
        EditorPrefs.Store.Forget();
        ProjectPrefs.Store.Forget();
        sReported.Clear();
        if (sContext != null)
        {
            sUnloaded.Add(new WeakReference(sContext));
            sContext.Unload();
            sContext = null;
        }
        sUnloaded.RemoveAll(weak => !weak.IsAlive);
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int Unload()
    {
        try
        {
            UnloadAll();
            return 1;
        }
        catch (Exception exception)
        {
            return Report("Unloading the game's editor scripts", exception);
        }
    }

    /// <summary>kind 0: an Inspector's script class; 1: a window's "menu path\ttitle"; 2: a menu command's path; 3: a
    /// Preferences tab's title.
    /// Returns the bytes the text needs (written, with a NUL, when they fit), -1 past the end.</summary>
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int Describe(int kind, int index, byte* buffer, int capacity)
    {
        string? text = kind switch
        {
            0 when index >= 0 && index < sInspectors.Count => sInspectors[index].Script.FullName,
            1 when index >= 0 && index < sWindows.Count => sWindows[index].MenuPath + "\t" + sWindows[index].Title,
            2 when index >= 0 && index < sMenus.Count => sMenus[index].Path,
            3 when index >= 0 && index < sPages.Count => sPages[index].Title,
            _ => null
        };
        if (text == null)
            return -1;
        byte[] bytes = Encoding.UTF8.GetBytes(text);
        if (buffer != null && capacity > bytes.Length)
        {
            bytes.CopyTo(new Span<byte>(buffer, capacity));
            buffer[bytes.Length] = 0;
        }
        return bytes.Length;
    }

    /// <summary>The Inspector for a script class (by full name): the one for the class itself, else for its nearest
    /// base class; -1 for none.</summary>
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int FindInspector(byte* scriptName)
    {
        try
        {
            string name = Marshal.PtrToStringUTF8((nint)scriptName) ?? "";
            if (sInspectors.Count == 0 || sContext == null)
                return -1;
            if (sInspectorFor.TryGetValue(name, out int found))
                return found;
            found = -1;
            Type? script = null;
            foreach (Assembly assembly in sContext.Assemblies)
                if ((script = assembly.GetType(name, false)) != null)
                    break;
            for (Type? type = script; type != null && found < 0; type = type.BaseType)
                found = sInspectors.FindIndex(entry => entry.Script == type);
            sInspectorFor[name] = found;
            return found;
        }
        catch (Exception exception)
        {
            return Report("Finding a C# Inspector", exception);
        }
    }

    private static void BeginDrawing()
    {
        sDrawing = true;
        sOpen.Clear();
        EditorGUI.Changed = false;
    }

    private static void EndDrawing(string owner)
    {
        if (sOpen.Count > 0)
        {
            Pop(1);
            if (owner.Length > 0)
                Report(owner, new InvalidOperationException("A Disabled, Indented or Id scope was left open; end each with using."));
        }
        sDrawing = false;
        sInspecting = null;
    }

    /// <summary>Draws Inspector index for the editor's current target (key: which script it is, so each keeps its
    /// own Inspector object). 1 drawn, -1 it threw.</summary>
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int DrawInspector(int index, long key)
    {
        if (index < 0 || index >= sInspectors.Count)
            return -1;
        string owner = sInspectors[index].Inspector.FullName + ".OnInspectorGUI";
        BeginDrawing();
        sInspecting = sTarget;
        Inspector? inspector = null;
        try
        {
            if (!sInspectorObjects.TryGetValue((index, key), out inspector))
            {
                if (sInspectorObjects.Count > 512)
                    sInspectorObjects.Clear();
                inspector = (Inspector)Activator.CreateInstance(sInspectors[index].Inspector, nonPublic: true)!;
                sInspectorObjects[(index, key)] = inspector;
                inspector.Bind(sTarget);
                inspector.OnEnable();
            }
            inspector.Bind(sTarget);
            inspector.OnInspectorGUI();
            EndDrawing(owner);
            return 1;
        }
        catch (Exception exception)
        {
            EndDrawing("");
            return Report(owner, exception);
        }
        finally
        {
            inspector?.Bind(null);
        }
    }

    /// <summary>op 0 draws window index (made and enabled first when it was not open); 1 closes it. Returns 1, 0 when
    /// the window asked to close, -1 when it threw.</summary>
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int Window(int index, int op)
    {
        if (index < 0 || index >= sWindows.Count)
            return -1;
        WindowType type = sWindows[index];
        if (op == 1)
        {
            if (sWindowObjects.Remove(index, out EditorWindow? closing))
            {
                try
                {
                    closing.OnDisable();
                }
                catch (Exception exception)
                {
                    return Report(type.Window.FullName + ".OnDisable", exception);
                }
            }
            return 1;
        }
        string owner = type.Window.FullName + ".OnGUI";
        BeginDrawing();
        try
        {
            if (!sWindowObjects.TryGetValue(index, out EditorWindow? window))
            {
                window = (EditorWindow)Activator.CreateInstance(type.Window, nonPublic: true)!;
                window.Title = type.Title;
                sWindowObjects[index] = window;
                window.OnEnable();
            }
            window.OnGUI();
            EndDrawing(owner);
            return window.CloseRequested ? 0 : 1;
        }
        catch (Exception exception)
        {
            EndDrawing("");
            return Report(owner, exception);
        }
    }

    /// <summary>Draws Preferences tab index: its OnGUI, or a settings class's fields (saved when edited). 1 drawn, -1
    /// it threw.</summary>
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int DrawPage(int index)
    {
        if (index < 0 || index >= sPages.Count)
            return -1;
        PageType page = sPages[index];
        string owner = page.Type.FullName + (typeof(PreferencesPage).IsAssignableFrom(page.Type) ? ".OnGUI" : " (Preferences)");
        BeginDrawing();
        try
        {
            if (typeof(PreferencesPage).IsAssignableFrom(page.Type))
            {
                if (!sPageObjects.TryGetValue(index, out PreferencesPage? drawn))
                    sPageObjects[index] = drawn = (PreferencesPage)Activator.CreateInstance(page.Type, nonPublic: true)!;
                drawn.OnGUI();
            }
            else
            {
                object settings = EditorPrefs.Store.Get(page.Type);
                if (EditorGUI.Fields(settings))
                    EditorPrefs.Store.Save(page.Type, settings);
            }
            EndDrawing(owner);
            return 1;
        }
        catch (Exception exception)
        {
            EndDrawing("");
            return Report(owner, exception);
        }
    }

    /// <summary>The Inspector for a built-in component, by its full type name ("Tallow.Light"): its index, -1 for
    /// none.</summary>
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int FindComponentInspector(byte* typeName, int length)
    {
        try
        {
            if (sComponentInspectorFor.Count == 0 || sContext == null)
                return -1;
            return sComponentInspectorFor.TryGetValue(FromUtf8(typeName, length), out int found) ? found : -1;
        }
        catch (Exception exception)
        {
            return Report("Finding a C# component Inspector", exception);
        }
    }

    /// <summary>Draws component Inspector index for the component of an object (each component on each object keeps
    /// its own Inspector object): 1 drawn and edited, 0 drawn, -1 it threw.</summary>
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int DrawComponentInspector(int index, uint objectId, byte* typeName, int length)
    {
        if (index < 0 || index >= sComponentInspectors.Count)
            return -1;
        string type = FromUtf8(typeName, length);
        string owner = sComponentInspectors[index].Type.FullName + ".OnInspectorGUI";
        BeginDrawing();
        try
        {
            var key = (index, objectId, type);
            if (!sComponentInspectorObjects.TryGetValue(key, out ComponentInspector? inspector))
            {
                if (sComponentInspectorObjects.Count > 512)
                    sComponentInspectorObjects.Clear();
                inspector = (ComponentInspector)Activator.CreateInstance(sComponentInspectors[index].Type, nonPublic: true)!;
                sComponentInspectorObjects[key] = inspector;
                inspector.Bind(new EditorComponent(objectId, type));
                inspector.OnEnable();
            }
            inspector.Bind(new EditorComponent(objectId, type));
            inspector.Edited = false;
            inspector.OnInspectorGUI();
            EndDrawing(owner);
            return inspector.Edited ? 1 : 0;
        }
        catch (Exception exception)
        {
            EndDrawing("");
            return Report(owner, exception);
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int RunMenu(int index)
    {
        if (index < 0 || index >= sMenus.Count)
            return -1;
        try
        {
            sMenus[index].Method.Invoke(null, null);
            return 1;
        }
        catch (Exception exception)
        {
            return Report($"Tools/{sMenus[index].Path}", exception);
        }
    }
}
