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

    /// Copies the object's name as UTF-8 and returns its full byte length,
    /// which may exceed the buffer (call again with a larger one). -1 = stale.
    [CSharpExpose]
    public static int32 CopyName(uint64 session, uint64 entity, Span<uint8> buffer)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        if (obj == null)
            return -1;
        let count = Math.Min(obj.Name.Length, buffer.Length);
        for (int i < count)
            buffer[i] = (uint8)obj.Name[i];
        return (int32)obj.Name.Length;
    }

    [CSharpExpose]
    public static bool SetName(uint64 session, uint64 entity, StringView name)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        if (obj == null || name.IsEmpty || name.Length > 256 ||
            name.Contains('\n') || name.Contains('\0'))
            return false;
        obj.Name.Set(name);
        return true;
    }

    /// 0 = at the top of the scene (or stale).
    [CSharpExpose]
    public static uint64 GetParent(uint64 session, uint64 entity)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        let parent = obj?.Transform.Parent;
        return parent != null ? (uint64)parent.GameObject.Id : 0;
    }

    /// parent 0 moves the object to the top of the scene. Refuses to make
    /// an object a child of itself or of one of its own descendants.
    [CSharpExpose]
    public static bool SetParent(uint64 session, uint64 entity, uint64 parent, bool keepWorldPose)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        if (obj == null)
            return false;
        if (parent == 0)
        {
            obj.Transform.SetParent(null, keepWorldPose);
            return true;
        }
        let target = CSharpRuntime.PhysicsObject(session, parent);
        if (target == null || target == obj || target.Transform.IsChildOf(obj.Transform))
            return false;
        obj.Transform.SetParent(target.Transform, keepWorldPose);
        return true;
    }

    [CSharpExpose]
    public static int32 GetChildCount(uint64 session, uint64 entity)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        return obj != null ? (int32)obj.Transform.Children.Count : -1;
    }

    /// 0 when the index is out of range or the object is stale.
    [CSharpExpose]
    public static uint64 GetChild(uint64 session, uint64 entity, int32 index)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        if (obj == null || index < 0 || index >= obj.Transform.Children.Count)
            return 0;
        return (uint64)obj.Transform.Children[index].GameObject.Id;
    }

    static bool ValidTag(StringView tag) =>
        !tag.IsEmpty && tag.Length <= 128 && !tag.Contains('\n') && !tag.Contains('\0');

    [CSharpExpose]
    public static bool HasTag(uint64 session, uint64 entity, StringView tag)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        return obj != null && ValidTag(tag) && obj.HasTag(tag);
    }

    [CSharpExpose]
    public static bool AddTag(uint64 session, uint64 entity, StringView tag)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        if (obj == null || !ValidTag(tag))
            return false;
        obj.AddTag(tag);
        return true;
    }

    [CSharpExpose]
    public static bool RemoveTag(uint64 session, uint64 entity, StringView tag)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        if (obj == null || !ValidTag(tag))
            return false;
        obj.RemoveTag(tag);
        return true;
    }

    /// The first active object with that tag; 0 when there is none.
    [CSharpExpose]
    public static uint64 FindWithTag(uint64 session, StringView tag)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        if (scene == null || !ValidTag(tag))
            return 0;
        let found = scene.FindWithTag(tag);
        return found != null ? (uint64)found.Id : 0;
    }

    /// Fills ids with every object carrying the tag (active or not) and
    /// returns how many there are, which may exceed the buffer.
    [CSharpExpose]
    public static int32 FindAllWithTag(uint64 session, StringView tag, Span<uint64> ids)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        if (scene == null || !ValidTag(tag))
            return 0;
        let found = scope System.Collections.List<GameObject>();
        scene.FindAllWithTag(tag, found);
        for (int i < Math.Min(found.Count, ids.Length))
            ids[i] = (uint64)found[i].Id;
        return (int32)found.Count;
    }

    /// The physics layer, 0 to 31; -1 when stale.
    [CSharpExpose]
    public static int32 GetLayer(uint64 session, uint64 entity)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        return obj != null ? obj.Layer : -1;
    }

    [CSharpExpose]
    public static bool SetLayer(uint64 session, uint64 entity, int32 layer)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        if (obj == null || layer < 0 || layer >= ProjectConfig.MaxLayers)
            return false;
        obj.Layer = layer;
        return true;
    }

    /// Prefab.Instantiate enforces network authority and ownership itself.
    [CSharpExpose]
    public static uint64 InstantiatePrefabAt(uint64 session, StringView path,
        Vector3 position, Quaternion rotation)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        if (scene == null || path.IsEmpty || path.Length > 4096 ||
            !position.x.IsFinite || !position.y.IsFinite || !position.z.IsFinite ||
            !rotation.x.IsFinite || !rotation.y.IsFinite || !rotation.z.IsFinite ||
            !rotation.w.IsFinite ||
            rotation.x * rotation.x + rotation.y * rotation.y +
            rotation.z * rotation.z + rotation.w * rotation.w < 1.0e-12f)
            return 0;
        let created = Prefab.Instantiate(scene, path, position, rotation.Normalized);
        return (created != null && !created.IsDestroyed) ? (uint64)created.Id : 0;
    }

    /// Network session state of the scene: 0 offline, 1 server or host, 2 client.
    [CSharpExpose]
    public static int32 NetworkRole(uint64 session)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        if (scene == null || scene.Network == null)
            return 0;
        return scene.Network.IsServer ? 1 : (scene.Network.IsClient ? 2 : 0);
    }

    /// True while ticks are being run again after a correction from the server.
    [CSharpExpose]
    public static bool NetworkReplaying(uint64 session) => CSharpRuntime.PhysicsScene(session)?.Network?.Replaying ?? false;

    /// This machine's client id in the session (0 on the server or offline).
    [CSharpExpose]
    public static int32 LocalClientId(uint64 session)
    {
        let scene = CSharpRuntime.PhysicsScene(session);
        return scene != null && scene.Network != null ? scene.Network.LocalClientId : 0;
    }

    /// The client that owns a networked object: 0 = the server's (or the
    /// object has no Network Identity), -1 = stale object.
    [CSharpExpose]
    public static int32 OwnerClientId(uint64 session, uint64 entity)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        if (obj == null)
            return -1;
        let identity = obj.GetComponent<NetworkIdentity>();
        return identity ? identity.ownerId : 0;
    }

    [CSharpExpose]
    public static bool HasNetworkIdentity(uint64 session, uint64 entity)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        return obj != null && obj.HasComponent<NetworkIdentity>();
    }

    [CSharpExpose]
    public static bool GetTransient(uint64 session, uint64 entity) => CSharpRuntime.PhysicsObject(session, entity)?.Transient ?? false;

    [CSharpExpose]
    public static void SetTransient(uint64 session, uint64 entity, bool transient)
    {
        if (let obj = CSharpRuntime.PhysicsObject(session, entity))
            obj.Transient = transient;
    }

    /// Objects in the scene (as the Hierarchy counts them, transient ones included).
    [CSharpExpose]
    public static int32 ObjectCount(uint64 session) => (int32)(CSharpRuntime.PhysicsScene(session)?.Objects.Count ?? 0);

    /// Takes a C# script (by its managed instance) off its object at the end of the frame. False when it is not on it.
    [CSharpExpose]
    public static bool RemoveScript(uint64 session, uint64 entity, int32 instance)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        if (obj == null || instance <= 0)
            return false;
        for (let component in obj.Components)
        {
            if (let script = component as CSharpBehaviour)
            {
                if (script.ManagedInstance == instance)
                {
                    obj.Scene.RemoveComponentLater(script);
                    return true;
                }
            }
        }
        return false;
    }
}
