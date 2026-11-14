using System;

namespace Tallow;

/// Native GameObject activation through generated, session-scoped C# wrappers.
/// SetActive keeps the existing Flecs InactiveSelf, hierarchy notifications
/// and network authority bookkeeping in GameObject instead of a C# shadow.
[CSharpExpose]
static class CSharpSceneObjects
{
    /// -1 invalid scene/object, 0 inactive, 1 active.
    [CSharpExpose]
    public static int32 ActiveSelfState(uint64 session, uint64 entity)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        if (obj == null)
            return -1;
        return obj.ActiveSelf ? 1 : 0;
    }

    /// Native hierarchy check includes all ancestors, not just this object.
    [CSharpExpose]
    public static int32 ActiveHierarchyState(uint64 session, uint64 entity)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        if (obj == null)
            return -1;
        return obj.ActiveInHierarchy ? 1 : 0;
    }

    /// The normal native setter handles active tags, OnEnable/OnDisable,
    /// physics synchronization and NetworkSync.ActiveChanged callbacks.
    [CSharpExpose]
    public static bool SetActive(uint64 session, uint64 entity, bool active)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        if (obj == null)
            return false;
        obj.SetActive(active);
        return true;
    }
}
