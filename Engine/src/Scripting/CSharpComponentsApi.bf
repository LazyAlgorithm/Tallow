using System;

namespace Tallow;

/// Add trusted C# gameplay components through the same opt-in generated API
/// as other native features. A native CSharpBehaviour owns each managed
/// instance and remains in the standard Scene/Flecs lifecycle.
[CSharpExpose]
static class CSharpComponents
{
    /// Returns a managed instance ID, never a pointer. The native adapter
    /// is attached first, then configured before its managed Awake/OnEnable.
    [CSharpExpose]
    public static int32 Add(uint64 session, uint64 entity, StringView managedType)
    {
        if (managedType.IsEmpty || managedType.Length > 512 ||
            managedType.Contains('\t') || managedType.Contains('\n') ||
            managedType.Contains('\0'))
            return -1;

        let obj = CSharpRuntime.PhysicsObject(session, entity);
        if (obj == null || !CSharpRuntime.Ready || !obj.Scene.IsPlaying)
            return -1;

        let behaviour = obj.AddComponent<CSharpBehaviour>();
        if (behaviour == null)
            return -1;
        let instance = behaviour.Configure(managedType);
        if (instance <= 0)
            obj.RemoveComponent(behaviour);
        return instance;
    }
}
