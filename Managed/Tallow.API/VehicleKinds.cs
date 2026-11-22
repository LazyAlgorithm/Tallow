namespace Tallow;

/// <summary>The kinds of vehicle a physics backend can provide. A backend may offer only some of them.</summary>
public enum VehicleKind
{
    Wheeled,
    Motorcycle,
    Tracked,
}

public readonly partial record struct Vehicle
{
    /// <summary>Which kind of vehicle this is. Setting it rebuilds a running vehicle of the new kind.</summary>
    public VehicleKind Kind => (VehicleKind)VehicleApi.KindIndex(GameObject.SceneId, GameObject.Id);

    /// <summary>Switches the kind; false when the selected physics backend does not offer it.</summary>
    public bool SetKind(VehicleKind kind) => VehicleApi.SetKindIndex(GameObject.SceneId, GameObject.Id, (int)kind);
}
