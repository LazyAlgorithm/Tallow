using System.Numerics;
using System.Reflection;
using System.Runtime.Loader;
using Tallow;

namespace Tallow.ManagedHost;

/// <summary>
/// Developer smoke-test host: deliberately loads only the trusted game assembly.
/// Not wired into the native editor yet. This is NOT a third-party mod loader.
/// </summary>
internal static class Program
{
    private sealed class TestBridge : IEngineBridge
    {
        private readonly Dictionary<GameObject, Vector3> _positions = [];
        private readonly Dictionary<(GameObject, TransformChannel), Vector4> _transform = [];

        public bool IsAlive(GameObject gameObject) => _positions.ContainsKey(gameObject);
        public Vector3 GetPosition(GameObject gameObject) => _positions[gameObject];
        public void SetPosition(GameObject gameObject, Vector3 position) => _positions[gameObject] = position;
        public Vector4 GetTransform(GameObject gameObject, TransformChannel channel)
        {
            if (!IsAlive(gameObject))
                throw new ObjectDisposedException(nameof(GameObject));
            if (_transform.TryGetValue((gameObject, channel), out Vector4 value))
                return value;
            return channel switch
            {
                TransformChannel.LocalPosition => new Vector4(GetPosition(gameObject), 0),
                TransformChannel.LocalScale or TransformChannel.WorldScale => new Vector4(1, 1, 1, 0),
                TransformChannel.Rotation or TransformChannel.LocalRotation => new Vector4(0, 0, 0, 1),
                TransformChannel.Forward => new Vector4(0, 0, 1, 0),
                TransformChannel.Right => new Vector4(1, 0, 0, 0),
                TransformChannel.Up => new Vector4(0, 1, 0, 0),
                _ => Vector4.Zero
            };
        }
        public void SetTransform(GameObject gameObject, TransformChannel channel, Vector4 value)
        {
            if (!IsAlive(gameObject))
                throw new ObjectDisposedException(nameof(GameObject));
            _transform[(gameObject, channel)] = value;
            if (channel == TransformChannel.LocalPosition)
                SetPosition(gameObject, new Vector3(value.X, value.Y, value.Z));
        }
        // The smoke host has no hierarchy or rotation; model only translation.
        // Production calls delegate to Beef Transform via the native bridge.
        public Vector3 TransformPoint(GameObject gameObject, Vector3 point, bool inverse)
        {
            if (!IsAlive(gameObject))
                throw new ObjectDisposedException(nameof(GameObject));
            Vector3 position = GetPosition(gameObject);
            return inverse ? point - position : point + position;
        }
        public Script? GetManagedComponent(GameObject gameObject, Type scriptType) => null;
        public void Destroy(GameObject gameObject)
        {
            _positions.Remove(gameObject);
            foreach (var key in _transform.Keys.Where(key => key.Item1 == gameObject).ToArray())
                _transform.Remove(key);
        }
        public bool IsMine(GameObject gameObject) => IsAlive(gameObject);
        public ulong CreateSceneObject(ulong sceneSession, string name) =>
            throw new NotSupportedException("This managed smoke host has no native scene.");
        public ulong FindSceneObject(ulong sceneSession, string name) =>
            throw new NotSupportedException("This managed smoke host has no native scene.");
        public ulong InstantiatePrefab(ulong sceneSession, string path) =>
            throw new NotSupportedException("This managed smoke host has no native scene.");
        public GameObject Create(ulong id)
        {
            GameObject gameObject = new(1, id);
            _positions.Add(gameObject, Vector3.Zero);
            return gameObject;
        }
    }

    public static int Main(string[] args)
    {
        if (args.Length != 1 || !File.Exists(args[0]) ||
            !string.Equals(Path.GetFileName(args[0]), "Tallow.Game.dll", StringComparison.Ordinal))
        {
            Console.Error.WriteLine("Usage: Tallow.ManagedHost <trusted-project-output>/Tallow.Game.dll");
            return 2;
        }

        string path = Path.GetFullPath(args[0]);
        string bin = Path.GetDirectoryName(path)!;
        string assemblies = Directory.GetParent(bin)!.FullName;
        AssemblyLoadContext.Default.Resolving += (context, name) =>
        {
            // Resolve only trusted assembly-definition builds generated for this game.
            string candidate = Path.Combine(assemblies, name.Name!, name.Name! + ".dll");
            return File.Exists(candidate) ? context.LoadFromAssemblyPath(candidate) : null;
        };

        Assembly game = AssemblyLoadContext.Default.LoadFromAssemblyPath(path);
        foreach (AssemblyName reference in game.GetReferencedAssemblies())
        {
            if (File.Exists(Path.Combine(assemblies, reference.Name!, reference.Name! + ".dll")))
                Assembly.Load(reference);
        }

        TestBridge bridge = new();
        Engine.Bind(bridge);
        int tested = 0;
        foreach (Assembly assembly in AppDomain.CurrentDomain.GetAssemblies())
        {
            // The API itself and the runtime are not gameplay assemblies.
            if (assembly != game && !assembly.GetName().Name!.StartsWith("Gameplay", StringComparison.Ordinal))
                continue;

            foreach (Type type in assembly.GetTypes())
            {
                // This scripted probe exercises compiler-generated native
                // exports and requires the in-process hostfxr bridge. The
                // managed-only host has no Beef function-pointer resolver.
                if (type.FullName is "Gameplay.GeneratedBindingSmoke" or
                    "Gameplay.SceneApiSmoke")
                    continue;
                if (type.IsAbstract || !typeof(Script).IsAssignableFrom(type) ||
                    !Attribute.IsDefined(type, typeof(ComponentAttribute)))
                    continue;

                Script script = (Script)Activator.CreateInstance(type)!;
                GameObject gameObject = bridge.Create((ulong)++tested);
                script.Attach(gameObject);
                script.Awake();
                script.OnEnable();
                script.Start();
                script.Update(new TickInput(Vector2.Zero, Vector2.Zero, 0), 1f / 60);
                script.OnLocalUpdate();
                script.LateUpdate(1f / 60);
                script.OnDisable();
                script.OnDestroy();
                if (!gameObject.IsValid)
                    throw new InvalidOperationException($"{type.Name} invalidated its test entity.");
                Console.WriteLine($"PASS {type.FullName} position={gameObject.Transform.Position}");
            }
        }

        if (tested == 0)
        {
            Console.Error.WriteLine("No [Component] gameplay scripts were discovered.");
            return 1;
        }
        Console.WriteLine($"Passed {tested} trusted C# component smoke test(s).");
        return 0;
    }
}
