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

    /// Resolve the particular native CSharpBehaviour adapter on this object,
    /// not just the first attached script of its managed type.
    static CSharpBehaviour Find(uint64 session, uint64 entity, int32 instance)
    {
        if (instance <= 0)
            return null;
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        if (obj == null)
            return null;
        for (let component in obj.Components)
        {
            if (let script = component as CSharpBehaviour)
            {
                if (script.ManagedInstance == instance && script.IsLoaded)
                    return script;
            }
        }
        return null;
    }

    /// -1 means stale/missing, 0 disabled, 1 enabled.
    [CSharpExpose]
    public static int32 EnabledState(uint64 session, uint64 entity, int32 instance)
    {
        let script = Find(session, entity, instance);
        if (script == null)
            return -1;
        return script.Enabled ? 1 : 0;
    }

    /// -1 means stale/missing, 0 inactive/disabled, 1 active and enabled.
    [CSharpExpose]
    public static int32 ActiveState(uint64 session, uint64 entity, int32 instance)
    {
        let script = Find(session, entity, instance);
        if (script == null)
            return -1;
        return script.IsActiveAndEnabled ? 1 : 0;
    }

    /// Uses Component.Enabled: OnEnable/OnDisable and network notifications
    /// remain native Scene responsibilities, including prediction lifecycle.
    [CSharpExpose]
    public static bool SetEnabled(uint64 session, uint64 entity, int32 instance, bool enabled)
    {
        let script = Find(session, entity, instance);
        if (script == null)
            return false;
        script.Enabled = enabled;
        return true;
    }
