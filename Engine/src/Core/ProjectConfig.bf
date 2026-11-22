using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// Lists the whole project shares, needed while the game runs: the named physics layers and which of them collide,
/// the tags objects can carry, and the world states. Kept in ProjectConfig.tconfig at the root of the project's
/// assets (its src/ folder), which ships with the game like any other asset, and edited in the editor's Project
/// Settings. A project without the file has one layer ("Default"), no tags and one world state ("Default").
///
///   layer 0 "Default"
///   layer 3 "Echo"
///   collide 3 00000009        (hex mask of the layers layer 3 collides with)
///   tag "Enemy"
///   worldstate "Material"
///   worldstate "Echo"
///   separateworldstates 1     (each object in its own states: see SeparateWorldStates)
static class ProjectConfig
{
	public const String FileName = "ProjectConfig.tconfig";
	public const int32 MaxLayers = 32;
	public const int32 MaxWorldStates = 32;

	static String[MaxLayers] sLayerNames;
	static uint32[MaxLayers] sCollides;
	static List<String> sTags = new .() ~ DeleteContainerAndItems!(_);
	static List<String> sWorldStates = new .() ~ DeleteContainerAndItems!(_);
	static bool sReady;
	static bool sSeparateWorldStates;
	/// The project's physics choices, one per dimension. Empty means the default (Jolt for 3D, the first
	/// available provider for 2D).
	static String sPhysics3DBackend = new .("Jolt") ~ delete _;
	static String sPhysics2DBackend = new .() ~ delete _;

	/// Goes up whenever anything here changes, for code that caches what it read.
	public static int32 Version { get; private set; }

	static this()
	{
		for (int i < MaxLayers)
			sLayerNames[i] = new .();
		Reset();
	}

	static ~this()
	{
		for (int i < MaxLayers)
			delete sLayerNames[i];
	}

	/// Back to a project with nothing set up: layer 0 "Default" colliding with everything, no tags, one world state.
	public static void Reset()
	{
		for (int i < MaxLayers)
		{
			sLayerNames[i].Clear();
			sCollides[i] = uint32.MaxValue;
		}
		sLayerNames[0].Set("Default");
		ClearAndDeleteItems!(sTags);
		ClearAndDeleteItems!(sWorldStates);
		sWorldStates.Add(new .("Default"));
		sSeparateWorldStates = false;
		sPhysics3DBackend.Set("Jolt");
		sPhysics2DBackend.Clear();
		Version++;
	}

	/// Per-object world states: every object lives in its own world states, as players in different realities of
	/// one map. Objects collide, and are found by queries given PhysicsWorld.QueryWorldStates, only where their world
	/// states overlap, whatever the scene's active state is; the active state then only picks what this machine
	/// draws and hears. Off (the default), Scene.WorldState switches what collides for everything at once.
	/// Separation covers the first four world states; objects in all of them (the default) meet everything.
	public static bool SeparateWorldStates
	{
		get => sSeparateWorldStates;
		set
		{
			if (value == sSeparateWorldStates)
				return;
			sSeparateWorldStates = value;
			Version++;
		}
	}

	/// How many world states are kept apart in physics (0 when they are not).
	public static int32 SeparatedWorldStateCount => sSeparateWorldStates && sWorldStates.Count > 1 ? Math.Min((int32)sWorldStates.Count, 4) : 0;

	// ---- physics backends ----

	/// The id of the project's 3D physics provider ("Jolt", "Rapier3D"). Empty means the default. Read by
	/// PhysicsBackends; a scene does not override it.
	public static StringView Physics3DBackendId => sPhysics3DBackend;

	public static void SetPhysics3DBackend(StringView id)
	{
		let next = id.IsEmpty ? "Jolt" : id;
		if (sPhysics3DBackend == next)
			return;
		sPhysics3DBackend.Set(next);
		Version++;
	}

	/// The id of the project's 2D physics provider. Empty selects the first available 2D provider, or no 2D
	/// physics when none ships.
	public static StringView Physics2DBackendId => sPhysics2DBackend;

	public static void SetPhysics2DBackend(StringView id)
	{
		if (sPhysics2DBackend == id)
			return;
		sPhysics2DBackend.Set(id);
		Version++;
	}

	// ---- layers ----

	/// The name of a layer; empty for one the project does not use.
	public static StringView LayerName(int32 layer) => (layer >= 0 && layer < MaxLayers) ? sLayerNames[layer] : "";

	public static void SetLayerName(int32 layer, StringView name)
	{
		if (layer <= 0 || layer >= MaxLayers)
			return;
		sLayerNames[layer].Set(name);
		sLayerNames[layer].Trim();
		Version++;
	}

	/// The layer of that name, or -1.
	public static int32 LayerNamed(StringView name)
	{
		for (int32 i < MaxLayers)
		{
			if (!sLayerNames[i].IsEmpty && sLayerNames[i] == name)
				return i;
		}
		return -1;
	}

	/// A mask of the named layers, for ray and shape queries: Physics.Raycast(..., ProjectConfig.Mask("Default", "Echo")).
	public static uint32 Mask(params StringView[] names)
	{
		uint32 mask = 0;
		for (let name in names)
		{
			let layer = LayerNamed(name);
			if (layer >= 0)
				mask |= 1u << layer;
		}
		return mask;
	}

	/// True when bodies on the two layers collide.
	public static bool LayersCollide(int32 a, int32 b)
	{
		if (a < 0 || b < 0 || a >= MaxLayers || b >= MaxLayers)
			return false;
		return (sCollides[a] & (1u << b)) != 0;
	}

	/// Which layers collide with this one, as a mask.
	public static uint32 CollisionMask(int32 layer) => (layer >= 0 && layer < MaxLayers) ? sCollides[layer] : 0;

	/// Sets whether two layers collide (both ways). Takes effect for physics worlds made afterwards: the next Play.
	public static void SetLayersCollide(int32 a, int32 b, bool collide)
	{
		if (a < 0 || b < 0 || a >= MaxLayers || b >= MaxLayers)
			return;
		if (collide)
		{
			sCollides[a] |= 1u << b;
			sCollides[b] |= 1u << a;
		}
		else
		{
			sCollides[a] &= ~(1u << b);
			sCollides[b] &= ~(1u << a);
		}
		Version++;
	}

	// ---- tags ----

	public static List<String> Tags => sTags;

	public static bool HasTag(StringView tag)
	{
		for (let t in sTags)
		{
			if (t == tag)
				return true;
		}
		return false;
	}

	public static void AddTag(StringView tag)
	{
		var name = scope String(tag)..Trim();
		if (name.IsEmpty || HasTag(name))
			return;
		sTags.Add(new .(name));
		Version++;
	}

	public static void RemoveTag(StringView tag)
	{
		for (int i < sTags.Count)
		{
			if (sTags[i] == tag)
			{
				delete sTags[i];
				sTags.RemoveAt(i);
				Version++;
				return;
			}
		}
	}

	// ---- world states ----

	/// The world states, in order: a GameObject's WorldStates mask has bit i set for each one it is in.
	public static List<String> WorldStates => sWorldStates;

	/// The world state of that name, or -1.
	public static int32 WorldStateNamed(StringView name)
	{
		for (int32 i < (int32)sWorldStates.Count)
		{
			if (sWorldStates[i] == name)
				return i;
		}
		return -1;
	}

	public static void AddWorldState(StringView name)
	{
		var trimmed = scope String(name)..Trim();
		if (trimmed.IsEmpty || WorldStateNamed(trimmed) >= 0 || sWorldStates.Count >= MaxWorldStates)
			return;
		sWorldStates.Add(new .(trimmed));
		Version++;
	}

	public static void RenameWorldState(int32 index, StringView name)
	{
		if (index < 0 || index >= sWorldStates.Count)
			return;
		sWorldStates[index].Set(name);
		sWorldStates[index].Trim();
		Version++;
	}

	/// Removes the last world state (states are numbered by position, so only the last can go without moving the
	/// others' bits in every scene).
	public static void RemoveLastWorldState()
	{
		if (sWorldStates.Count <= 1)
			return;
		delete sWorldStates.PopBack();
		Version++;
	}

	// ---- reading and writing ----

	/// Reads the project's ProjectConfig.tconfig from its assets (the editor's project folder or the game's packs);
	/// the defaults when there is none.
	public static void Load()
	{
		let path = scope String();
		Assets.ResolvePath(FileName, path);
		let text = scope String();
		Reset();
		if (AssetPack.ReadAllText(path, text) case .Ok)
			Parse(text);
		sReady = true;
	}

	/// Loads once, if nothing has yet.
	public static void EnsureLoaded()
	{
		if (!sReady)
			Load();
	}

	/// Takes the settings from text in the file's format (in place of what was loaded).
	public static void Parse(StringView text)
	{
		Reset();
		sReady = true;
		List<StringView> tokens = scope .();
		List<String> storage = scope .();
		defer
		{
			for (let s in storage)
				delete s;
		}
		bool firstState = true;
		for (let line in text.Split('\n'))
		{
			tokens.Clear();
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.Count < 2)
				continue;
			switch (tokens[0])
			{
			case "layer":
				let index = SceneSerializer.ParseInt(tokens[1]);
				if (index >= 0 && index < MaxLayers && tokens.Count >= 3)
					sLayerNames[index].Set(tokens[2]);
			case "collide":
				let index = SceneSerializer.ParseInt(tokens[1]);
				if (index >= 0 && index < MaxLayers && tokens.Count >= 3)
				{
					if (uint32.Parse(tokens[2], .HexNumber) case .Ok(let mask))
						sCollides[index] = mask;
				}
			case "tag":
				if (!HasTag(tokens[1]))
					sTags.Add(new .(tokens[1]));
			case "separateworldstates":
				sSeparateWorldStates = tokens[1] != "0";
			case "physics3d":
				sPhysics3DBackend.Set(tokens[1]);
				if (sPhysics3DBackend.IsEmpty)
					sPhysics3DBackend.Set("Jolt");
			case "physics2d":
				sPhysics2DBackend.Set(tokens[1]);
			case "worldstate":
				if (firstState)
				{
					// The file names the states itself, in place of the default one.
					ClearAndDeleteItems!(sWorldStates);
					firstState = false;
				}
				if (sWorldStates.Count < MaxWorldStates)
					sWorldStates.Add(new .(tokens[1]));
			}
		}
		if (sLayerNames[0].IsEmpty)
			sLayerNames[0].Set("Default");
		// Collision is the same both ways, whatever the file says.
		for (int32 a < MaxLayers)
		{
			for (int32 b < MaxLayers)
			{
				if ((sCollides[a] & (1u << b)) == 0)
					sCollides[b] &= ~(1u << a);
			}
		}
		Version++;
	}

	public static void Write(String text)
	{
		text.Append("# Physics backends, layers, tags and world states. Edit them in the editor's Project Settings.\n");
		if (sPhysics3DBackend != "Jolt")
			text.AppendF("physics3d {}\n", SceneSerializer.Quote(sPhysics3DBackend, .. scope .()));
		if (!sPhysics2DBackend.IsEmpty)
			text.AppendF("physics2d {}\n", SceneSerializer.Quote(sPhysics2DBackend, .. scope .()));
		for (int32 i < MaxLayers)
		{
			if (!sLayerNames[i].IsEmpty)
				text.AppendF("layer {} {}\n", i, SceneSerializer.Quote(sLayerNames[i], .. scope .()));
		}
		for (int32 i < MaxLayers)
		{
			if (sCollides[i] != uint32.MaxValue)
				text.AppendF("collide {} {:X8}\n", i, sCollides[i]);
		}
		for (let tag in sTags)
			text.AppendF("tag {}\n", SceneSerializer.Quote(tag, .. scope .()));
		for (let state in sWorldStates)
			text.AppendF("worldstate {}\n", SceneSerializer.Quote(state, .. scope .()));
		if (sSeparateWorldStates)
			text.Append("separateworldstates 1\n");
	}

	/// Writes the settings to a file (the editor writes to the project's src/ folder).
	public static bool Save(StringView path)
	{
		let text = scope String();
		Write(text);
		return File.WriteAllText(path, text) case .Ok;
	}
}
