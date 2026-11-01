using System;
using System.Collections;
using System.IO;
using Tallow;

namespace SavingTests;

enum Mood : int16 { Happy, Sad = 5, Angry = -3 }

struct Stats
{
	[Saved] public int32 hp;
	[Saved] public float speed;
	public int32 notSaved;
}

class Inventory
{
	[Saved] public List<String> items = new .() ~ DeleteContainerAndItems!(_);
	[Saved] public int32 gold;
}

class BigInventory : Inventory
{
	[Saved] public int32 slots;
}

[Component]
class Everything : Component
{
	[Saved] public bool b;
	[Saved] public int8 i8;
	[Saved] public int16 i16;
	[Saved] public int32 i32;
	[Saved] public int64 i64;
	[Saved] public uint8 u8;
	[Saved] public uint16 u16;
	[Saved] public uint32 u32;
	[Saved] public uint64 u64;
	[Saved] public int iSize;
	[Saved] public char8 c8;
	[Saved] public char32 c32;
	[Saved] public float f;
	[Saved] public double dbl;
	[Saved] public String text = new .() ~ delete _;
	[Saved] public String nullText;
	[Saved] public Vector2 v2;
	[Saved] public Vector3 v3;
	[Saved] public Vector4 v4;
	[Saved] public Int3 i3;
	[Saved] public Quaternion q;
	[Saved] public Color color;
	[Saved] public Matrix4 matrix;
	[Saved] public Mood mood;
	[Saved] public int32[4] sized;
	[Saved] public Vector3[2][3] sizedNested;
	[Saved] public int32[] array ~ delete _;
	[Saved] public String[] strings ~ DeleteContainerAndItems!(_);
	[Saved] public int32[,] grid ~ delete _;
	[Saved] public float[,,] cube ~ delete _;
	[Saved] public List<Vector3> path = new .() ~ delete _;
	[Saved] public List<List<int32>> nested = new .() ~ DeleteContainerAndItems!(_);
	[Saved] public Queue<int32> queue = new .() ~ delete _;
	[Saved] public HashSet<String> tags = new .() ~ DeleteContainerAndItems!(_);
	[Saved] public LinkedList<double> linked = new .() ~ delete _;
	[Saved] public Dictionary<String, Vector2> places = new .() ~ DeleteDictionaryAndKeys!(_);
	[Saved] public Dictionary<int32, List<int32>> buckets = new .() ~ DeleteDictionaryAndValues!(_);
	[Saved] public Stats stats;
	[Saved] public Inventory inventory = new .() ~ delete _;
	[Saved] public BigInventory big = new .() ~ delete _;
	[Saved] public List<Stats> team = new .() ~ delete _;
	[Saved("renamed")] public int32 oldName;
	[Saved] public GameObject other;
	[Saved] public Everything otherComponent;
	[Saved] public List<GameObject> objects = new .() ~ delete _;
	public int32 notSaved;
}

[Component]
class Progress : Component
{
	[Saved] public int32 coins;
	[Saved] public GameObject target;
	public int32 seenAtAwake = -1;
	public int32 loadedCalls;

	public override void Awake()
	{
		seenAtAwake = coins;
	}

	public override void OnLoaded()
	{
		loadedCalls++;
	}
}

[DataAsset]
class TestSettings : DataAsset
{
	public float maxSpeed = 10;
	public String title = new .("Untitled") ~ delete _;
	[Saved] public float volume = 0.8f;
	[Saved] public List<String> recent = new .() ~ DeleteContainerAndItems!(_);
	public int32 loadedCalls;
	public override void OnLoaded()
	{
		loadedCalls++;
	}
}

class Refs : ISaveReferences
{
	public Scene scene;
	public int64 KeyOf(GameObject gameObject) => gameObject.Id;
	public GameObject Find(int64 key) => scene.FindById((uint32)key);
}

class Program
{
	static int sFailed;
	static void Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		if (!pass)
			sFailed++;
	}

	static void Fill(Everything e, GameObject other)
	{
		e.b = true;
		e.i8 = -8;
		e.i16 = -1600;
		e.i32 = -320000;
		e.i64 = -6400000000;
		e.u8 = 200;
		e.u16 = 60000;
		e.u32 = 4000000000;
		e.u64 = 0xFFFFFFFFFFFFFFF0;
		e.iSize = 123456789;
		e.c8 = 'Z';
		e.c32 = (char32)0x1F600;
		e.f = 1.25f;
		e.dbl = 0.1;
		e.text.Set("hello \"world\"\n");
		e.v2 = .(1, 2);
		e.v3 = .(3, 4, 5);
		e.v4 = .(6, 7, 8, 9);
		e.i3 = .(-1, 2, -3);
		e.q = .(0.1f, 0.2f, 0.3f, 0.9f);
		e.color = .(0.5f, 0.25f, 1, 0.75f);
		for (int i < 16)
			e.matrix.m[i] = i * 0.5f;
		e.mood = .Angry;
		e.sized = .(1, 2, 3, 4);
		e.sizedNested[1][2] = .(7, 8, 9);
		e.array = new .(5, 6, 7);
		e.strings = new .(new String("a"), new String("bb"));
		e.grid = new int32[2, 3];
		e.grid[1, 2] = 42;
		e.grid[0, 1] = -1;
		e.cube = new float[2, 2, 2];
		e.cube[1, 0, 1] = 3.5f;
		e.path.Add(.(1, 1, 1));
		e.path.Add(.(2, 2, 2));
		let inner = new List<int32>();
		inner.Add(10);
		inner.Add(20);
		e.nested.Add(inner);
		e.nested.Add(new List<int32>());
		e.queue.Add(3);
		e.queue.Add(1);
		e.tags.Add(new String("red"));
		e.tags.Add(new String("fast"));
		e.linked.AddLast(1.5);
		e.linked.AddLast(2.5);
		e.places[new String("home")] = .(4, 5);
		let bucket = new List<int32>();
		bucket.Add(99);
		e.buckets[7] = bucket;
		e.stats.hp = 77;
		e.stats.speed = 3.5f;
		e.stats.notSaved = 5;
		e.inventory.items.Add(new String("sword"));
		e.inventory.gold = 12;
		e.big.slots = 30;
		e.big.gold = 9;
		e.team.Add(.() { hp = 1, speed = 2 });
		e.team.Add(.() { hp = 3, speed = 4 });
		e.oldName = 55;
		e.other = other;
		e.otherComponent = other.GetComponent<Everything>();
		e.objects.Add(other);
		e.objects.Add(null);
		e.notSaved = 1234;
	}

	static void Compare(Everything a, Everything b, StringView how)
	{
		Check(a.b == b.b && a.i8 == b.i8 && a.i16 == b.i16 && a.i32 == b.i32 && a.i64 == b.i64, scope $"{how}: signed integers and bool");
		Check(a.u8 == b.u8 && a.u16 == b.u16 && a.u32 == b.u32 && a.u64 == b.u64 && a.iSize == b.iSize, scope $"{how}: unsigned integers");
		Check(a.c8 == b.c8 && a.c32 == b.c32 && a.f == b.f && a.dbl == b.dbl, scope $"{how}: chars and floats");
		Check(a.text == b.text && b.nullText == null, scope $"{how}: strings");
		Check(a.v2 == b.v2 && a.v3 == b.v3 && a.v4 == b.v4 && a.i3 == b.i3 && a.q.x == b.q.x && a.q.w == b.q.w && a.color.g == b.color.g && a.color.a == b.color.a, scope $"{how}: vectors, quaternion, colour");
		var matrixSame = true;
		for (int i < 16)
		{
			if (a.matrix.m[i] != b.matrix.m[i])
				matrixSame = false;
		}
		Check(matrixSame, scope $"{how}: matrix");
		Check(b.mood == .Angry, scope $"{how}: enum");
		Check(b.sized[3] == 4 && b.sizedNested[1][2] == Vector3(7, 8, 9), scope $"{how}: sized arrays");
		Check(b.array != null && b.array.Count == 3 && b.array[2] == 7, scope $"{how}: T[]");
		Check(b.strings != null && b.strings.Count == 2 && b.strings[1] == "bb", scope $"{how}: String[]");
		Check(b.grid != null && b.grid.GetLength(0) == 2 && b.grid.GetLength(1) == 3 && b.grid[1, 2] == 42 && b.grid[0, 1] == -1, scope $"{how}: T[,]");
		Check(b.cube != null && b.cube[1, 0, 1] == 3.5f, scope $"{how}: T[,,]");
		Check(b.path.Count == 2 && b.path[1] == Vector3(2, 2, 2), scope $"{how}: List<Vector3>");
		Check(b.nested.Count == 2 && b.nested[0].Count == 2 && b.nested[0][1] == 20 && b.nested[1].Count == 0, scope $"{how}: List<List<int32>>");
		Check(b.queue.Count == 2 && b.queue.PopFront() == 3, scope $"{how}: Queue");
		var hasRed = false;
		for (let tag in b.tags)
		{
			if (tag == "red")
				hasRed = true;
		}
		Check(b.tags.Count == 2 && hasRed, scope $"{how}: HashSet<String>");
		Check(b.linked.Count == 2 && b.linked.Last.Value == 2.5, scope $"{how}: LinkedList");
		Vector2 home = default;
		for (let kv in b.places)
		{
			if (kv.key == "home")
				home = kv.value;
		}
		Check(b.places.Count == 1 && home == Vector2(4, 5), scope $"{how}: Dictionary<String, Vector2>");
		Check(b.buckets.Count == 1 && b.buckets[7].Count == 1 && b.buckets[7][0] == 99, scope $"{how}: Dictionary<int32, List<int32>>");
		Check(b.stats.hp == 77 && b.stats.speed == 3.5f && b.stats.notSaved == 0, scope $"{how}: struct with [Saved] fields");
		Check(b.inventory.gold == 12 && b.inventory.items.Count == 1 && b.inventory.items[0] == "sword", scope $"{how}: class with [Saved] fields");
		Check(b.big.slots == 30 && b.big.gold == 9, scope $"{how}: derived class keeps its base's fields");
		Check(b.team.Count == 2 && b.team[1].hp == 3 && b.team[1].speed == 4, scope $"{how}: List of structs");
		Check(b.oldName == 55, scope $"{how}: renamed key");
		Check(b.other == a.other && b.otherComponent == a.otherComponent && b.objects.Count == 2 && b.objects[0] == a.other && b.objects[1] == null, scope $"{how}: references to scene objects");
		Check(b.notSaved == 0, scope $"{how}: unmarked field left alone");
	}

	static Scene MakeScene()
	{
		let scene = new Scene();
		Scene.Active = scene;
		let floor = scene.CreateGameObject("Floor");
		floor.AddComponent<BoxCollider>().size = .(200, 1, 200);
		floor.Transform.Position = .(0, -0.5f, 0);
		scene.CreateGameObject("Keeper").AddComponent<Progress>();
		scene.CreateGameObject("Doomed").AddComponent<Progress>();
		return scene;
	}

	static void Step(Scene scene, int ticks)
	{
		for (int i < ticks)
		{
			scene.FixedUpdate();
			Time.DeltaTime = Time.FixedDeltaTime;
			scene.Update();
			SaveSystem.Update();
		}
	}

	static void SceneSaves()
	{
		NetworkManager.RegisterPrefab("Crate", new (scene) =>
			{
				let crate = scene.CreateGameObject("Crate");
				crate.AddComponent<BoxCollider>().size = .(1, 1, 1);
				crate.AddComponent<Rigidbody>();
				crate.AddComponent<SavedTransform>();
				crate.AddComponent<Progress>();
				return crate;
			});
		SaveSystem.Storage = new MemorySaveStorage();

		let first = MakeScene();
		first.StartPlay();
		let keeper = first.Find("Keeper").GetComponent<Progress>();
		keeper.coins = 42;
		first.Destroy(first.Find("Doomed"));
		let crate = NetworkManager.CreateRegistered(first, "Crate");
		crate.Transform.Position = .(0, 5, 0);
		crate.GetComponent<Progress>().coins = 7;
		keeper.target = crate;
		Step(first, 3);
		let body = crate.GetComponent<Rigidbody>();
		var state = body.State;
		state.position = .(0, 20, 0);
		state.linearVelocity = .(3, 0, 0);
		body.SetState(state);
		Step(first, 1);
		let savedPosition = crate.Transform.Position;
		let savedVelocity = body.Velocity;

		let task = SaveSystem.Save("test");
		Check(task.Done && task.Succeeded && SaveSystem.Exists("test"), "Save writes to the storage");

		// Change everything, then load.
		keeper.coins = 0;
		keeper.target = null;
		first.Destroy(crate);
		Step(first, 2);
		// Gone before the load: the one found afterwards is made again (it may well get the freed one's memory, so
		// comparing the two references says nothing).
		let crateGone = first.Find("Crate") == null;
		let load = SaveSystem.Load("test");
		Step(first, 2);
		Check(load.Done && load.Succeeded, "Load reads it back");
		Check(keeper.coins == 42 && keeper.loadedCalls == 1, "a [Saved] field comes back, and OnLoaded is called");
		let again = first.Find("Crate");
		Check(crateGone && again != null && again.GetComponent<Progress>().coins == 7, "an object made while playing is made again, with its fields");
		Check(keeper.target == again, "a reference to it points at the new one");
		Check(first.Find("Doomed") == null, "a scene object that was destroyed stays gone");
		if (again != null)
		{
			Check(Vector3.Distance(again.Transform.Position, savedPosition) < 0.2f, scope $"SavedTransform puts it back where it was ({again.Transform.Position} vs {savedPosition})");
			let againBody = again.GetComponent<Rigidbody>();
			Check(againBody.Velocity.x > 2.5f, scope $"and moving as it was ({againBody.Velocity} vs {savedVelocity})");
		}
		var crates = 0;
		for (let gameObject in first.Objects)
		{
			if (gameObject.Name == "Crate" && !gameObject.IsDestroyed)
				crates++;
		}
		Check(crates == 1, scope $"loading again does not make duplicates ({crates} crates)");
		first.StopPlay();
		delete first;

		// Loading at start: the save is in place before any Awake.
		let second = MakeScene();
		SaveSystem.LoadAtStart = true;
		SaveSystem.StartSlot.Set("test");
		SaveSystem.NewRun();
		second.StartPlay();
		Step(second, 2);
		let keeper2 = second.Find("Keeper").GetComponent<Progress>();
		Check(keeper2.seenAtAwake == 42, scope $"LoadAtStart: Awake already sees the saved value ({keeper2.seenAtAwake})");
		Check(second.Find("Doomed") == null && second.Find("Crate") != null && keeper2.target == second.Find("Crate"), "LoadAtStart: removed, made again and referenced");
		let crate2 = second.Find("Crate");
		if (crate2 != null)
			Check(crate2.GetComponent<Rigidbody>().Velocity.x > 2.5f, scope $"LoadAtStart: the body starts moving on its first tick ({crate2.GetComponent<Rigidbody>().Velocity})");
		second.StopPlay();
		delete second;
		SaveSystem.LoadAtStart = false;

		// Slots.
		SaveSystem.Delete("test");
		Check(!SaveSystem.Exists("test"), "Delete empties a slot");
		let third = scope Scene();
		Scene.Active = third;
		let missing = SaveSystem.Load("nothing-here");
		Check(missing.Done && missing.Succeeded && !missing.Found, "loading an empty slot finds nothing and changes nothing");

		// Files, under names a player types.
		let folder = scope $"{GamePaths.PlayerData}saving-test";
		SaveSystem.Storage = new FileSaveStorage(folder);
		let name = "My Castle: v2/3 \"final\" 100%";
		let fileTask = SaveSystem.Save(name);
		Check(fileTask.Done && fileTask.Succeeded && SaveSystem.Exists(name), scope $"a save under a typed name goes to a file ({GamePaths.PlayerData})");
		let names = scope List<String>();
		SaveSystem.ListSlots(names);
		var listed = false;
		for (let n in names)
		{
			if (n == name)
				listed = true;
		}
		Check(listed, "and is listed under the same name");
		ClearAndDeleteItems!(names);
		SaveSystem.Delete(name);
		Check(!SaveSystem.Exists(name), "and deleted");
	}

	static void DataAssets()
	{
		// An asset file as the editor writes it.
		let folder = scope $"{GamePaths.PlayerData}asset-test";
		Directory.CreateDirectory(scope $"{folder}/Data").IgnoreError();
		Assets.ProjectPath.Set(folder);
		DataAsset.Storage = new FileSaveStorage(scope $"{folder}/player");
		DataAsset.Storage.Delete("Data/Settings");
		{
			let made = DataAsset.Create(typeof(TestSettings)) as TestSettings;
			made.maxSpeed = 25;
			made.title.Set("Arena");
			made.volume = 0.5f;
			made.recent.Add(new String("Foundry"));
			let text = scope String();
			made.WriteText(text);
			delete made;
			File.WriteAllText(scope $"{folder}/Data/Settings.tdata" , text).IgnoreError();
		}
		DataAsset.ClearCache();
		let settings = DataAsset.Get<TestSettings>();
		Check(settings != null && settings.AssetPath == "Data/Settings.tdata", scope $"Get<T>() finds the project's asset of that class ({settings?.AssetPath})");
		Check(settings.maxSpeed == 25 && settings.title == "Arena" && settings.volume == 0.5f && settings.recent.Count == 1, "it has the file's values, lists included");
		Check(DataAsset.Get<TestSettings>() == settings && DataAsset.Get<TestSettings>("Data/Settings.tdata") == settings, "every script gets the same one");
		settings.volume = 0.2f;
		settings.recent.Add(new String("Sanctum"));
		settings.maxSpeed = 99;
		settings.Save();
		DataAsset.ClearCache();
		let again = DataAsset.Get<TestSettings>();
		Check(again.volume == 0.2f && again.recent.Count == 2 && again.loadedCalls == 1, "the player's [Saved] fields come back from their folder");
		Check(again.maxSpeed == 25, "fields that are not [Saved] come from the file");
		again.Revert();
		Check(again.volume == 0.5f && again.recent.Count == 1, "Revert goes back to the file's values");
		DataAsset.ClearCache();
		let fresh = DataAsset.Get<TestSettings>();
		Check(fresh.volume == 0.5f, "and forgets the player's copy");
		DataAsset.ClearCache();
	}

	public static int Main(String[] args)
	{
		let scene = scope Scene();
		let refs = scope Refs() { scene = scene };
		let source = scene.CreateGameObject("Source");
		let other = scene.CreateGameObject("Other");
		other.AddComponent<Everything>();
		let a = source.AddComponent<Everything>();
		Fill(a, other);
		Check(a.HasSavedFields, "components with [Saved] fields say so");

		let writer = scope SaveIO();
		writer.references = refs;
		a.SaveFields(writer);
		let tree = writer.TakeRoot();
		defer delete tree;

		// Straight from the tree.
		{
			let target = scene.CreateGameObject("Target").AddComponent<Everything>();
			let reader = scope SaveIO(tree);
			reader.references = refs;
			target.SaveFields(reader);
			Compare(a, target, "tree");
		}
		// Through bytes.
		let bytes = scope List<uint8>();
		tree.ToBytes(bytes);
		{
			let back = SaveNode.FromBytes(bytes);
			defer delete back;
			Check(back != null, scope $"bytes read back ({bytes.Count} bytes)");
			let target = scene.CreateGameObject("Target2").AddComponent<Everything>();
			let reader = scope SaveIO(back);
			reader.references = refs;
			target.SaveFields(reader);
			Compare(a, target, "bytes");
			// Loading twice over the same fields replaces rather than adds.
			let again = scope SaveIO(back);
			again.references = refs;
			target.SaveFields(again);
			Check(target.path.Count == 2 && target.tags.Count == 2 && target.nested.Count == 2 && target.inventory.items.Count == 1, "loading again replaces collections");
		}
		// Through text.
		let text = scope String();
		tree.ToText(text);
		{
			let back = SaveNode.FromText(text);
			defer delete back;
			Check(back != null, "text read back");
			let target = scene.CreateGameObject("Target3").AddComponent<Everything>();
			let reader = scope SaveIO(back);
			reader.references = refs;
			target.SaveFields(reader);
			Compare(a, target, "text");
		}
		// A damaged save is refused.
		bytes[bytes.Count / 2] ^= 0x40;
		let damaged = SaveNode.FromBytes(bytes);
		Check(damaged == null, "a changed byte is refused");
		delete damaged;
		// A save from an older version: missing values keep their defaults, unknown ones are skipped.
		{
			let older = tree.Clone();
			defer delete older;
			delete older.Take("i32");
			older.Set("fieldThatIsGone", SaveNode.MakeInt(5));
			let target = scene.CreateGameObject("Target4").AddComponent<Everything>();
			target.i32 = 777;
			let reader = scope SaveIO(older);
			reader.references = refs;
			target.SaveFields(reader);
			Check(target.i32 == 777 && target.i64 == a.i64, "a value missing from the save keeps its default");
		}
		// Null collections are saved as null and load as empty or null.
		{
			let target = scene.CreateGameObject("Target5").AddComponent<Everything>();
			target.array = null;
			let w = scope SaveIO();
			target.SaveFields(w);
			let t = w.TakeRoot();
			defer delete t;
			let reader = scope SaveIO(t);
			let into = scene.CreateGameObject("Target6").AddComponent<Everything>();
			into.array = new .(1, 2);
			into.SaveFields(reader);
			Check(into.array == null, "a null array loads as null");
		}
		Console.WriteLine(scope $"{bytes.Count} bytes, {text.Length} characters of text");
		SceneSaves();
		DataAssets();
		Console.WriteLine(sFailed == 0 ? "All saving checks passed." : scope $"{sFailed} saving checks FAILED.");
		return sFailed == 0 ? 0 : 1;
	}
}
