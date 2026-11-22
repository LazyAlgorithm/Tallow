using System;
using System.Collections;

namespace Tallow;

/// C# access to a Vehicle component. The component's fields are available through the generated Vehicle handle; these
/// calls drive it and read what the backend simulates.
[CSharpExpose]
static class VehicleApi
{
    static Vehicle Live(uint64 session, uint64 entity)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        return obj != null ? obj.GetComponent<Vehicle>() : null;
    }

    [CSharpExpose]
    public static bool IsReady(uint64 session, uint64 entity)
    {
        let vehicle = Live(session, entity);
        return vehicle != null && vehicle.IsReady;
    }

    [CSharpExpose]
    public static bool SetDriverInput(uint64 session, uint64 entity, float forward, float right, float brake, float handBrake)
    {
        let vehicle = Live(session, entity);
        if (vehicle == null || !vehicle.IsReady)
            return false;
        vehicle.SetDriverInput(Mathf.Clamp(forward, -1, 1), Mathf.Clamp(right, -1, 1), Mathf.Clamp01(brake), Mathf.Clamp01(handBrake));
        return true;
    }

    [CSharpExpose]
    public static float Speed(uint64 session, uint64 entity)
    {
        let vehicle = Live(session, entity);
        return vehicle != null ? vehicle.Speed : 0;
    }

    [CSharpExpose]
    public static int32 WheelCount(uint64 session, uint64 entity)
    {
        let vehicle = Live(session, entity);
        return vehicle != null ? vehicle.WheelCount : 0;
    }

    [CSharpExpose]
    public static bool WheelOnGround(uint64 session, uint64 entity, int32 wheel)
    {
        let vehicle = Live(session, entity);
        return vehicle != null && vehicle.WheelOnGround(wheel);
    }

    [CSharpExpose]
    public static float WheelRotationAngle(uint64 session, uint64 entity, int32 wheel)
    {
        let vehicle = Live(session, entity);
        return vehicle != null ? vehicle.WheelRotationAngle(wheel) : 0;
    }

    [CSharpExpose]
    public static float WheelSteerAngle(uint64 session, uint64 entity, int32 wheel)
    {
        let vehicle = Live(session, entity);
        return vehicle != null ? vehicle.WheelSteerAngle(wheel) : 0;
    }

    [CSharpExpose]
    public static float EngineRPM(uint64 session, uint64 entity)
    {
        let vehicle = Live(session, entity);
        return vehicle != null ? vehicle.EngineRPM : 0;
    }

    /// The vehicle kind: 0 wheeled, 1 motorcycle, 2 tracked; -1 when there is no Vehicle.
    [CSharpExpose]
    public static int32 KindIndex(uint64 session, uint64 entity)
    {
        let vehicle = Live(session, entity);
        return vehicle != null ? (int32)vehicle.kind : -1;
    }

    /// Switches the vehicle kind. Rebuilds a running vehicle; false when the backend does not offer that kind.
    [CSharpExpose]
    public static bool SetKindIndex(uint64 session, uint64 entity, int32 kind)
    {
        if (kind < 0 || kind > 2)
            return false;
        let vehicle = Live(session, entity);
        if (vehicle == null)
            return false;
        let world = vehicle.Scene?.Physics;
        if (world == null || !world.SupportsVehicleKind((PhysicsVehicleKind)kind))
            return false;
        vehicle.Release();
        vehicle.kind = (PhysicsVehicleKind)kind;
        if (vehicle.Scene != null && vehicle.Scene.IsPlaying)
            return vehicle.Begin();
        return true;
    }

    [CSharpExpose]
    public static int32 Gear(uint64 session, uint64 entity)
    {
        let vehicle = Live(session, entity);
        return vehicle != null ? vehicle.Gear : 0;
    }
}
