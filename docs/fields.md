# Component fields

A component's public fields are saved with the scene and shown in the Inspector, as are private ones marked `[ShowInInspector]`. Fields marked `[NonSerialized]` are left out, and `[HideInInspector]` saves a field without showing it.

## Single values

A field can hold any of these:

- numbers: `float`, `double`, `int`, `uint` and `long`
- `bool` and `string`
- enums (shown by name)
- `Vector2`, `Vector3`, `Vector4` and `Color`
- references to objects in the scene: `GameObject`, `Transform`, another script, or any engine component type

Fields of other types (a `Quaternion`, your own struct or class) are neither saved nor shown. (Engine Beef components also take `char`, every integer width, `Int3`, `Quaternion` and
`Matrix4`, and fixed-size arrays `T[N]`.)

## Lists and arrays

A `List<T>` or an array `T[]` of any of the types above is saved and shown too:

```csharp
public List<Vector3> Waypoints = [];
public List<string> Names = [];
public List<GameObject> Targets = [];
public float[] Weights = new float[3];
```

In the Inspector a list shows its size, then a row for each element with buttons to move it up (^) and remove it (x). The size's + button adds a copy of the last element. Lists of 16 elements or fewer start open; click the arrow to open or close one.

Scripts use them as ordinary lists. Whatever they hold when the scene is saved is what loads next time.

Some things to know:

- **Ownership:** declare them with `new` and free them (`~ delete _`, or `DeleteContainerAndItems!` for a list of Strings). A List or `T[]` that is null gets made when the Inspector or a scene file puts something in it, and is never freed.
- **References:** a list of references is remapped when objects are copied or loaded, like a single reference. When an object is destroyed, its entries become null rather than being removed.
- **What lists can't do:**
  - nest (a `List<List<float>>` is left out)
  - hold structs or classes of your own (use several lists, or a data asset)
  - be `[Sync]`ed over the network
- **Data assets:** data assets save their lists the same way, except lists of references, since a data asset has no scene to refer to.
