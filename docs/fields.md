# Component fields

A component's public fields are saved with the scene and shown in the Inspector, as are private ones marked `[ShowInInspector]`. Fields marked `[NonSerialized]` are left out, and `[HideInInspector]` saves a field without showing it.

## Single values

A field can hold any of these:

- numbers (`float`, `double`, and every integer type)
- `bool` and `char`
- enums (shown by name; engine enums need `[Reflect(.All)]` for their names)
- `Vector2`, `Vector3`, `Vector4`, `Int3`, `Quaternion`, `Matrix4` and `Color`
- `String`, declared as `public String name = new .() ~ delete _;`
- references to objects in the scene: `GameObject`, `Transform` or any component type

## Lists and arrays

A `List<T>`, an array `T[]` or a fixed-size array `T[N]` of any of the types above is saved and shown too:

```beef
public List<Vector3> waypoints = new .() ~ delete _;
public List<String> names = new .() ~ DeleteContainerAndItems!(_);
public List<Transform> targets = new .() ~ delete _;
public float[] weights = new .[3] ~ delete _;
public Color[4] palette;
```

In the Inspector a list shows its size, then a row for each element with buttons to move it up (^) and remove it (x). The size's + button adds a copy of the last element. Lists of 16 elements or fewer start open; click the arrow to open or close one. A fixed-size `T[N]` keeps its size.

Scripts use them as ordinary lists. Whatever they hold when the scene is saved is what loads next time.

Some things to know:

- **Ownership:** declare them with `new` and free them (`~ delete _`, or `DeleteContainerAndItems!` for a list of Strings). A List or `T[]` that is null gets made when the Inspector or a scene file puts something in it, and is never freed.
- **References:** a list of references is remapped when objects are copied or loaded, like a single reference. When an object is destroyed, its entries become null rather than being removed.
- **What lists can't do:**
  - nest (a `List<List<float>>` is left out)
  - hold structs or classes of your own (use several lists, or a data asset)
  - be `[Sync]`ed over the network
- **Data assets:** data assets save their lists the same way, except lists of references, since a data asset has no scene to refer to.
