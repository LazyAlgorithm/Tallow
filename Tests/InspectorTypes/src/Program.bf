using System;
using System.Collections;
using Tallow;
using Tallow.Editor;

namespace InspectorTypeTests;

[Reflect(.All)] enum Small : uint8 { Zero = 0, Sparse = 201 }
[Reflect(.All)] enum Wide : int64 { Negative = -7000000000, Positive = 9000000000 }
[Component] class Values : Component
{
	public int platformInt = 5000000000;
	public uint platformUInt = 6000000000;
	public int8 i8 = -120;
	public uint8 u8 = 250;
	public int16 i16 = -30000;
	public uint16 u16 = 60000;
	public int32 i32 = -2000000000;
	public uint32 u32 = 4000000000;
	public int64 i64 = int64.MinValue;
	public uint64 u64 = uint64.MaxValue;
	public float f = 1.25f;
	public double d = 0.12345678901234567;
	public bool flag = true;
	public char8 c8 = 'Q';
	public char16 c16 = 'Ω';
	public char32 c32 = '🙂';
	public Vector2 v2 = .(2, 3);
	public Vector3 v3 = .(4, 5, 6);
	public Vector4 v4 = .(7, 8, 9, 10);
	public Int3 lattice = .(11, 12, 13);
	public Quaternion rotation = .Identity;
	public Color color = .(0.1f, 0.2f, 0.3f, 0.4f);
	public Matrix4 matrix = .Identity;
	public String text = new .("text with spaces") ~ delete _;
	public Small small = .Sparse;
	public Wide wide = .Negative;
	[ShowInInspector] private int privateInt = 7000000000;
	[HideInInspector] public double hiddenDouble = 1234567890.1234567;
	public int Private => privateInt;
}
class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	public static int Main(String[] args)
	{
		bool ok = true;
		let scene = scope Scene();
		let obj = scene.CreateGameObject("Values");
		let values = obj.AddComponent<Values>();
		List<FieldRef> fields = scope .();
		ComponentRegistry.GetFields(values, fields);
		ok &= Check(fields.Count == 28, "all default numeric, character, vector, matrix and enum fields reflected");
		for (let field in fields)
		{
			let saved = scope String();
			SceneSerializer.WriteValue(field, saved);
			List<StringView> tokens = scope .();
			List<String> storage = scope .();
			defer
			{
				for (let item in storage)
					delete item;
			}
			SceneSerializer.Tokenize(saved, tokens, storage);
			var bytes = scope uint8[128];
			Internal.MemCpy(&bytes, field.ptr, field.type.Size);
			if (field.kind != .String)
				Internal.MemSet(field.ptr, 0, field.type.Size);
			SceneSerializer.ReadValue(field, .(tokens.Ptr, tokens.Count));
			if (field.kind != .String)
				ok &= Check(Internal.MemCmp(&bytes, field.ptr, field.type.Size) == 0, scope $"{field.name}: exact typed round trip");
		}
		let text = scope String();
		SceneSerializer.Save(scene, text);
		let loaded = scope Scene();
		SceneSerializer.Load(loaded, text);
		let result = loaded.Find("Values").GetComponent<Values>();
		ok &= Check(result.platformInt == 5000000000 && result.u64 == uint64.MaxValue && result.i64 == int64.MinValue && result.Private == 7000000000, "scene preserves full-width integer limits and private int");
		ok &= Check(result.d == values.d && result.hiddenDouble == values.hiddenDouble && result.v4.w == 10 && result.small == .Sparse && result.wide == .Negative, "scene preserves double precision, vector4 and non-int32 enums");
		let clipboard = scope ComponentClipboard();
		clipboard.Copy(values);
		let copy = clipboard.PasteNew(scene.CreateGameObject("Copy")) as Values;
		ok &= Check(copy != null && copy.u64 == uint64.MaxValue && copy.d == values.d && copy.Private == 7000000000, "component clipboard preserves expanded types");
		Vector2 pan = .(100, -80);
		float zoom = 1;
		let origin = ImGui.Vec2(30, 40);
		let mouse = ImGui.Vec2(350, 220);
		let before = NodeCanvas.ToGraph(mouse, origin, pan, zoom);
		NodeCanvas.ZoomAt(ref pan, ref zoom, origin, mouse, 3);
		ok &= Check((NodeCanvas.ToGraph(mouse, origin, pan, zoom) - before).Length < 0.001f, "shared canvas zoom keeps mouse anchor fixed");
		let size = ImGui.Vec2(700, 400);
		let center = NodeCanvas.CenterNode(size, pan, zoom);
		let screen = NodeCanvas.ToScreen(center + .(95, 30), .(0, 0), pan, zoom);
		ok &= Check(Math.Abs(screen.x - 350) < 0.001f && Math.Abs(screen.y - 200) < 0.001f, "Add Node placement remains visible after panning and zooming");
		return ok ? 0 : 1;
	}
}
