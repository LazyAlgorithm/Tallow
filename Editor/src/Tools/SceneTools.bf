using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Scene view tools: snapping, standing things on surfaces, Quick Add (Space), the project's prefabs and models listed
/// for the GameObject menu and Quick Add, and the guides drawn for them.
extension EditorApp
{
	// Snapping. The toolbar's Snap button turns it on; holding Ctrl while dragging does the opposite of the button.
	bool mSnap;
	float mSnapMove = 0.25f;
	float mSnapRotate = 15;
	float mSnapScale = 0.1f;
	float mCamSpeed = 12;
	/// A line from the selected object down to what is beneath it, with its height above it.
	bool mHeightGuide = true;

	// The project's prefabs and models (and the built-in map pieces), for the GameObject menu and Quick Add.
	List<String> mPaletteAssets = new .() ~ DeleteContainerAndItems!(_);
	List<String> mPaletteFolders = new .() ~ DeleteContainerAndItems!(_);
	bool mPaletteListed;
	// Quick Add: Space over the Scene view.
	bool mOpenQuickAdd;
	bool mFocusQuickAdd;
	String mQuickSearch = new .() ~ delete _;
	bool mQuickHit;
	Vector3 mQuickPoint;
	Vector3 mQuickNormal;

	static readonly StringView[?] BuiltinObjects = .("Create Empty", "Folder", "Cube", "Sphere", "Capsule", "Cylinder", "Cone", "Plane", "Quad",
		"Directional Light", "Point Light", "Spot Light", "Camera", "Decal", "Reflection Probe", "Light Probe Volume", "Spawn Point", "Audio Source", "Particle System", "Destructible Voxel Object",
		"Voxel Terrain", "Network Session", "Water", "Water (Low Poly)", "Ocean", "Ocean (Low Poly)");

	bool SnapActive => mSnap != ImGui.IsKeyDown(ImGui.Key.LeftCtrl);

	static float SnapValue(float value, float step) => step > 0 ? Math.Round(value / step) * step : value;

	// ------------------------------------------------------------------ settings

	/// The snapping and view settings file (named for the Map Builder window it began in, so settings carry over).
	void SceneToolSettingsPath(String path)
	{
		RecentProjects.GetConfigFolder(path);
		path.Append("map_builder.txt");
	}

	void LoadSceneToolSettings()
	{
		let path = scope String();
		SceneToolSettingsPath(path);
		let text = scope String();
		if (File.ReadAllText(path, text) case .Err)
			return;
		for (let line in text.Split('\n'))
		{
			let space = line.IndexOf(' ');
			if (space < 0)
				continue;
			let key = line.Substring(0, space);
			float number = 0;
			if (float.Parse(line.Substring(space + 1)) case .Ok(let parsed))
				number = parsed;
			switch (key)
			{
			case "snap": mSnap = number != 0;
			case "move": mSnapMove = Math.Max(number, 0.001f);
			case "rotate": mSnapRotate = Math.Max(number, 0.1f);
			case "scale": mSnapScale = Math.Max(number, 0.001f);
			case "camera": mCamSpeed = Math.Clamp(number, 0.25f, 400);
			case "height": mHeightGuide = number != 0;
			}
		}
	}

	void SaveSceneToolSettings()
	{
		let path = scope String();
		SceneToolSettingsPath(path);
		let text = scope String();
		text.AppendF("snap {}\nmove {}\nrotate {}\nscale {}\ncamera {}\nheight {}\n", mSnap ? 1 : 0, mSnapMove, mSnapRotate, mSnapScale, mCamSpeed, mHeightGuide ? 1 : 0);
		File.WriteAllText(path, text).IgnoreError();
	}

	// ------------------------------------------------------------------ surfaces

	/// Ray test against a mesh's triangles in its own space, giving the face normal too. Negative when missed.
	static float RaycastTriangles(Mesh mesh, Ray ray, out Vector3 normal)
	{
		normal = .Up;
		float best = -1.0f;
		for (int i = 0; i + 2 < mesh.Indices.Count; i += 3)
		{
			let a = mesh.Vertices[(int)mesh.Indices[i]].position;
			let b = mesh.Vertices[(int)mesh.Indices[i + 1]].position;
			let c = mesh.Vertices[(int)mesh.Indices[i + 2]].position;
			let e1 = b - a;
			let e2 = c - a;
			let p = Vector3.Cross(ray.direction, e2);
			let det = Vector3.Dot(e1, p);
			if (Math.Abs(det) < 1.0e-9f)
				continue;
			let inv = 1.0f / det;
			let s = ray.origin - a;
			let u = Vector3.Dot(s, p) * inv;
			if (u < 0 || u > 1)
				continue;
			let q = Vector3.Cross(s, e1);
			let v = Vector3.Dot(ray.direction, q) * inv;
			if (v < 0 || u + v > 1)
				continue;
			let t = Vector3.Dot(e2, q) * inv;
			if (t > 1.0e-5f && (best < 0 || t < best))
			{
				best = t;
				normal = Vector3.Cross(e1, e2);
			}
		}
		return best;
	}

	static bool IsUnder(GameObject gameObject, GameObject root)
	{
		var transform = gameObject.Transform;
		while (transform != null)
		{
			if (transform.GameObject == root)
				return true;
			transform = transform.Parent;
		}
		return false;
	}

	/// The nearest surface along a ray: drawn meshes, then terrain, then (with allowGround) the ground plane at
	/// y = 0. Objects inside ignore, and ignore itself, are passed through.
	bool RaycastScene(Ray ray, out Vector3 point, out Vector3 normal, GameObject ignore = null, bool allowGround = true, float maxDistance = 2000)
	{
		point = default;
		normal = .Up;
		float best = maxDistance;
		bool hit = false;
		for (let renderer in mScene.Renderers)
		{
			if (!renderer.IsActiveAndEnabled || !renderer.GameObject.InActiveWorld)
				continue;
			if (ignore != null && IsUnder(renderer.GameObject, ignore))
				continue;
			let mesh = renderer.ActiveMesh;
			if (mesh == null || mesh.Indices.Count == 0 || mesh.Indices.Count > 600000)
				continue;
			let boundsHit = renderer.WorldBounds.IntersectRay(ray);
			if (boundsHit < 0 || boundsHit > best)
				continue;
			let toLocal = renderer.Transform.WorldToLocal;
			let localOrigin = toLocal.TransformPoint(ray.origin);
			let localEnd = toLocal.TransformPoint(ray.origin + ray.direction);
			let localRay = Ray(localOrigin, (localEnd - localOrigin).Normalized);
			Vector3 localNormal;
			let t = RaycastTriangles(mesh, localRay, out localNormal);
			if (t < 0)
				continue;
			let worldPoint = renderer.Transform.LocalToWorld.TransformPoint(localRay.GetPoint(t));
			let distance = (worldPoint - ray.origin).Length;
			if (distance >= best)
				continue;
			best = distance;
			point = worldPoint;
			// Normals go through the inverse transpose, so that stretched objects still give the right facing.
			normal = toLocal.Transposed.TransformDirection(localNormal).Normalized;
			if (Vector3.Dot(normal, ray.direction) > 0)
				normal = -normal;
			hit = true;
		}
		let terrain = mScene.FindComponent<VoxelTerrain>();
		Vector3 ground;
		if (terrain != null && (ignore == null || !IsUnder(terrain.GameObject, ignore)) && terrain.Raycast(ray, Math.Min(best, 600), out ground))
		{
			let distance = (ground - ray.origin).Length;
			if (distance < best)
			{
				best = distance;
				point = ground;
				normal = .Up;
				hit = true;
			}
		}
		if (!hit && allowGround && ray.direction.y < -0.001f)
		{
			let distance = -ray.origin.y / ray.direction.y;
			if (distance > 0 && distance < best)
			{
				point = ray.GetPoint(distance);
				normal = .Up;
				hit = true;
			}
		}
		return hit;
	}

	void AddRendererBounds(GameObject gameObject, ref Bounds bounds)
	{
		let renderer = gameObject.GetComponent<MeshRenderer>();
		if (renderer && renderer.IsActiveAndEnabled && renderer.ActiveMesh != null)
		{
			let world = renderer.WorldBounds;
			bounds.Encapsulate(world.min);
			bounds.Encapsulate(world.max);
		}
		for (let child in gameObject.Transform.Children)
			AddRendererBounds(child.GameObject, ref bounds);
	}

	/// The world box around everything an object and its children draw.
	bool HierarchyBounds(GameObject gameObject, out Bounds bounds)
	{
		bounds = .Empty;
		AddRendererBounds(gameObject, ref bounds);
		return bounds.IsValid;
	}

	/// A turn that takes Up onto normal.
	static Quaternion UpTo(Vector3 normal)
	{
		let axis = Vector3.Cross(.Up, normal);
		let dot = Math.Clamp(Vector3.Dot(.Up, normal), -1, 1);
		if (axis.Length < 1.0e-5f)
			return dot > 0 ? .Identity : Quaternion.AngleAxis(180, .Right);
		return Quaternion.AngleAxis(Math.Acos(dot) * (180 / Math.PI_f), axis.Normalized);
	}

	/// Stands an object at a surface point: its lowest point on the surface (or its pivot, when turned to the
	/// surface), with X and Z on the snap grid while snapping.
	void PlaceOnSurface(GameObject gameObject, Vector3 point, Vector3 normal, bool alignToNormal)
	{
		var target = point;
		if (SnapActive)
		{
			target.x = SnapValue(target.x, mSnapMove);
			target.z = SnapValue(target.z, mSnapMove);
		}
		if (alignToNormal)
		{
			gameObject.Transform.Rotation = UpTo(normal) * gameObject.Transform.Rotation;
			gameObject.Transform.Position = target;
			return;
		}
		gameObject.Transform.Position = target;
		Bounds bounds;
		if (HierarchyBounds(gameObject, out bounds))
			gameObject.Transform.Position = gameObject.Transform.Position + Vector3(0, target.y - bounds.min.y, 0);
	}

	/// Moves an object down (or up) until it rests on the highest surface under its footprint. False when there
	/// is nothing under it.
	bool DropToSurface(GameObject gameObject)
	{
		Bounds bounds;
		if (!HierarchyBounds(gameObject, out bounds))
		{
			let at = gameObject.Transform.Position;
			bounds = .(at, at);
		}
		let center = bounds.Center;
		let extents = bounds.Extents * 0.8f;
		// The centre and four points inside the footprint; the highest surface is the one it rests on.
		Vector2[5] offsets = .(.(0, 0), .(-1, -1), .(1, -1), .(-1, 1), .(1, 1));
		float highest = float.MinValue;
		for (let offset in offsets)
		{
			let start = Vector3(center.x + offset.x * extents.x, bounds.min.y + 0.002f, center.z + offset.y * extents.z);
			Vector3 point, normal;
			if (RaycastScene(Ray(start, .(0, -1, 0)), out point, out normal, gameObject))
				highest = Math.Max(highest, point.y);
		}
		if (highest == float.MinValue)
			return false;
		gameObject.Transform.Position = gameObject.Transform.Position + Vector3(0, highest - bounds.min.y, 0);
		MarkDirty();
		return true;
	}

	/// What the height guide shows: the surface beneath the selection and how far it is above it.
	bool SurfaceBelow(GameObject gameObject, out Vector3 from, out Vector3 to)
	{
		Bounds bounds;
		if (!HierarchyBounds(gameObject, out bounds))
		{
			let at = gameObject.Transform.Position;
			bounds = .(at, at);
		}
		from = .(bounds.Center.x, bounds.min.y, bounds.Center.z);
		Vector3 normal;
		return RaycastScene(Ray(from + Vector3(0, 0.002f, 0), .(0, -1, 0)), out to, out normal, gameObject);
	}

	/// Where a world point is on the Scene view, false when it is behind the camera.
	bool SceneToScreen(Vector3 point, ImGui.Vec2 origin, ImGui.Vec2 size, out ImGui.Vec2 screen)
	{
		screen = default;
		let clip = (mSceneCamera.projection * mSceneCamera.view).Transform(.(point.x, point.y, point.z, 1));
		if (clip.w <= 0.0001f)
			return false;
		screen = .(origin.x + (clip.x / clip.w * 0.5f + 0.5f) * size.x, origin.y + (0.5f - clip.y / clip.w * 0.5f) * size.y);
		return true;
	}

	// ------------------------------------------------------------------ creating and placing

	/// The folder new objects go into: the selected folder, or the folder of the selected object.
	Transform PlacementParent()
	{
		var transform = Selected?.Transform;
		while (transform != null && !transform.GameObject.IsFolder)
			transform = transform.Parent;
		return transform;
	}

	/// Makes one of the GameObject menu's built-in objects (by its menu name), selected.
	GameObject CreateBuiltin(StringView kind)
	{
		GameObject made = null;
		switch (kind)
		{
		case "Create Empty": made = CreateObject("GameObject");
		case "Folder":
			// Folders sit at the origin with an identity transform so they never move their contents.
			let parent = Selected;
			made = mScene.CreateGameObject("New Folder", (parent != null && parent.IsFolder) ? parent.Transform : null);
			made.IsFolder = true;
			mSelectedId = made.Id;
		case "Spawn Point": made = CreateObject("Spawn Point");
			made.AddComponent<SpawnPoint>();
		case "Audio Source": made = CreateObject("Audio Source");
			made.AddComponent<AudioSource>();
		case "Cube": made = CreateObject("Cube", "builtin:cube");
		case "Sphere": made = CreateObject("Sphere", "builtin:sphere");
		case "Capsule": made = CreateObject("Capsule", "builtin:capsule");
		case "Cylinder": made = CreateObject("Cylinder", "builtin:cylinder");
		case "Cone": made = CreateObject("Cone", "builtin:cone");
		case "Plane": made = CreateObject("Plane", "builtin:plane");
		case "Quad": made = CreateObject("Quad", "builtin:quad");
		case "Directional Light":
			made = CreateObject("Directional Light");
			made.AddComponent<Light>();
			made.Transform.EulerAngles = .(50, -30, 0);
		case "Point Light":
			made = CreateObject("Point Light");
			let light = made.AddComponent<Light>();
			light.type = .Point;
			light.intensity = 5;
		case "Spot Light":
			made = CreateObject("Spot Light");
			let spot = made.AddComponent<Light>();
			spot.type = .Spot;
			spot.intensity = 8;
			made.Transform.EulerAngles = .(90, 0, 0);
		case "Camera": made = CreateObject("Camera");
			made.AddComponent<Camera>();
		case "Decal":
			made = CreateObject("Decal");
			made.AddComponent<Decal>();
			// Pressed down onto the ground, then onto whatever it was dropped on.
			made.Transform.EulerAngles = .(90, 0, 0);
			StickDecal(made);
		case "Reflection Probe":
			made = CreateObject("Reflection Probe");
			made.AddComponent<ReflectionProbe>();
			// At eye height: a probe sees from where it stands.
			made.Transform.Position = made.Transform.Position + .(0, 1.5f, 0);
		case "Light Probe Volume":
			made = CreateObject("Light Probe Volume");
			made.AddComponent<LightProbeVolume>();
			// Standing on the ground: its box reaches up from where it was put.
			made.Transform.Position = made.Transform.Position + .(0, 2, 0);
		case "Particle System": made = CreateObject("Particles");
			made.AddComponent<ParticleSystem>();
		case "Destructible Voxel Object":
			made = CreateObject("Voxel Object");
			made.AddComponent<VoxelObject>();
			made.AddComponent<MeshCollider>();
		case "Voxel Terrain":
			mSelectedId = 0;
			made = CreateObject("Terrain");
			// A flat area to shape, centred on the origin.
			let terrain = made.AddComponent<VoxelTerrain>();
			let area = terrain.AreaSize;
			made.Transform.Position = .(-area.x * 0.5f, 0, -area.y * 0.5f);
		case "Network Session":
			mSelectedId = 0;
			made = CreateObject("Network Session");
			made.AddComponent<NetworkSession>();
		case "Water","Water (Low Poly)","Ocean","Ocean (Low Poly)":
			let ocean = kind.StartsWith("Ocean");
			made = CreateObject(ocean ? "Ocean" : "Water");
			let water = made.AddComponent<Water>();
			water.UseLook(kind.Contains("Low Poly") ? .LowPoly : .Realistic);
			if (ocean)
			{
				// The sea: to the horizon, at the level of the ground, with a long swell.
				water.endless = true;
				water.depth = 40;
				water.waveHeight = water.look == .LowPoly ? 0.8f : 1.2f;
				water.waveLength = 30;
				made.Transform.Position = .(made.Transform.Position.x, 0, made.Transform.Position.z);
			}
			else
			{
				// A pond a little above the ground where it was put, so that it is seen at once.
				water.depth = 4;
				made.Transform.Position = made.Transform.Position + Vector3(0, 0.5f, 0);
			}
		}
		MarkDirty();
		return made;
	}

	/// An object named after a component, with that component on it.
	GameObject CreateWithComponent(ComponentRegistry.Info info)
	{
		let label = scope String();
		NiceName(info.name, label);
		let made = CreateObject(label);
		made.AddComponent(info.type);
		MarkDirty();
		return made;
	}

	/// A prefab or model from the project as a new object (not yet placed), selected.
	GameObject InstantiateAsset(StringView relative)
	{
		GameObject made = null;
		let parent = PlacementParent();
		if (MapPieces.IsPiece(relative))
			made = MapPieces.Create(mScene, relative, parent);
		else if (relative.EndsWith(".tprefab"))
		{
			Prefab.ClearCache();
			made = Prefab.Instantiate(mScene, relative);
			if (made != null && parent != null)
				made.Transform.SetParent(parent, true);
		}
		else
		{
			let name = scope String();
			Path.GetFileNameWithoutExtension(relative, name);
			mSelectedId = parent != null ? parent.GameObject.Id : 0;
			if (SkinnedModel.Load(relative) != null)
			{
				made = CreateObject(name);
				let skinned = made.AddComponent<SkinnedMeshRenderer>();
				skinned.model.Set(relative);
				skinned.Refresh();
			}
			else
				made = CreateObject(name, relative);
		}
		if (made == null)
			return null;
		mSelectedId = made.Id;
		MarkDirty();
		return made;
	}

	void TurnSelected(float degrees)
	{
		let selected = Selected;
		if (selected == null || selected.IsFolder)
			return;
		selected.Transform.Rotation = Quaternion.Euler(0, degrees, 0) * selected.Transform.Rotation;
		MarkDirty();
	}

	void SnapSelectedToGrid()
	{
		let selected = Selected;
		if (selected == null || selected.IsFolder)
			return;
		let at = selected.Transform.Position;
		selected.Transform.Position = .(SnapValue(at.x, mSnapMove), SnapValue(at.y, mSnapMove), SnapValue(at.z, mSnapMove));
		MarkDirty();
	}

	// ------------------------------------------------------------------ the palette

	void ListPalette(StringView folder, StringView relative)
	{
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (IsHidden(name))
				continue;
			ListPalette(scope $"{folder}/{name}" , relative.IsEmpty ? name : scope $"{relative}/{name}");
		}
		bool any = false;
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (IsHidden(name) || !(name.EndsWith(".tprefab") || IsModelFile(name)))
				continue;
			mPaletteAssets.Add(relative.IsEmpty ? new String(name) : new $"{relative}/{name}");
			any = true;
		}
		if (any)
			mPaletteFolders.Add(new String(relative));
	}

	void RefreshPalette()
	{
		ClearAndDeleteItems!(mPaletteAssets);
		ClearAndDeleteItems!(mPaletteFolders);
		if (Directory.Exists(Assets.ProjectPath))
			ListPalette(Assets.ProjectPath, "");
		DropWrappedModels();
		// Prefabs first (they are ready to place, with collision and materials), then plain models.
		mPaletteAssets.Sort(scope (a, b) => a.EndsWith(".tprefab") != b.EndsWith(".tprefab") ? (a.EndsWith(".tprefab") ? -1 : 1) : a.CompareTo(b, true));
		mPaletteFolders.Sort(scope (a, b) => a.CompareTo(b, true));
		// The built-in pieces come before the project's own, in their own folders.
		for (int i < MapPieces.Names.Count)
			mPaletteAssets.Insert(i, new String(MapPieces.Names[i]));
		for (int i < MapPieces.Folders.Count)
			mPaletteFolders.Insert(i, new String(MapPieces.Folders[i]));
		mPaletteListed = true;
	}

	/// Leaves out a model that a prefab already places: the prefab is the one to use, with its materials and
	/// collision (a model whose texture is given by a material looks plain white by itself). A folder left with
	/// nothing in it goes too.
	void DropWrappedModels()
	{
		let wrapped = scope HashSet<String>();
		defer
		{
			ClearAndDeleteItems!(wrapped);
		}
		for (let relative in mPaletteAssets)
		{
			if (!relative.EndsWith(".tprefab"))
				continue;
			let text = scope String();
			if (File.ReadAllText(scope $"{Assets.ProjectPath}/{relative}" , text, true) case .Err)
				continue;
			for (let line in text.Split('\n'))
			{
				if (!line.StartsWith("field mesh \"") || !line.EndsWith('"'))
					continue;
				let mesh = scope String(line.Substring(12, line.Length - 13));
				// "model.glb#2" is one part of the model: the prefab still places the model.
				let part = mesh.IndexOf('#');
				if (part >= 0)
					mesh.RemoveToEnd(part);
				if (!wrapped.ContainsAlt(mesh))
					wrapped.Add(new String(mesh));
			}
		}
		for (int i = mPaletteAssets.Count - 1; i >= 0; i--)
		{
			if (wrapped.ContainsAlt(mPaletteAssets[i]))
			{
				delete mPaletteAssets[i];
				mPaletteAssets.RemoveAt(i);
			}
		}
		for (int i = mPaletteFolders.Count - 1; i >= 0; i--)
		{
			bool used = false;
			for (let relative in mPaletteAssets)
				used |= PaletteFolderOf(relative) == mPaletteFolders[i];
			if (!used)
			{
				delete mPaletteFolders[i];
				mPaletteFolders.RemoveAt(i);
			}
		}
	}

	/// The palette folder an entry is listed under: its folder in the project, or a built-in piece's folder.
	static StringView PaletteFolderOf(StringView relative)
	{
		let slash = relative.LastIndexOf('/');
		return slash >= 0 ? relative.Substring(0, slash) : StringView();
	}

	void DrawSnapSettings()
	{
		ImGui.SeparatorText("Snapping and view");
		bool changed = ImGui.Checkbox("Snap (Ctrl does the opposite)", ref mSnap);
		ImGui.SetNextItemWidth(110);
		changed |= ImGui.DragFloat("Move step", ref mSnapMove, 0.005f, 0.001f, 100, "%.3f");
		ImGui.SetNextItemWidth(110);
		changed |= ImGui.DragFloat("Turn step", ref mSnapRotate, 0.5f, 0.1f, 180, "%.1f");
		ImGui.SetNextItemWidth(110);
		changed |= ImGui.DragFloat("Scale step", ref mSnapScale, 0.005f, 0.001f, 10, "%.3f");
		ImGui.SetNextItemWidth(110);
		changed |= ImGui.DragFloat("Camera speed", ref mCamSpeed, 0.1f, 0.25f, 400, "%.1f");
		changed |= ImGui.Checkbox("Height guide", ref mHeightGuide);
		if (changed)
			SaveSceneToolSettings();
		ImGui.TextDisabled("W/E/R/T move, turn, scale, all. End drops to the surface.\n[ and ] turn. Space in the Scene view: Quick Add.");
	}

	/// The toolbar's snapping controls: the Snap toggle and a drop-down with the steps.
	void DrawSnapToolbar()
	{
		ImGui.SameLine(0, 16);
		if (ToolButton("Snap", mSnap))
		{
			mSnap = !mSnap;
			SaveSceneToolSettings();
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip(scope $"Snap moves to {mSnapMove}, turns to {mSnapRotate} degrees and scale to {mSnapScale}. Hold Ctrl for the opposite." .CStr());
		ImGui.SameLine(0, 2);
		if (ImGui.Button("v##snapsettings"))
			ImGui.OpenPopup("SnapSettings");
		if (ImGui.BeginPopup("SnapSettings"))
		{
			DrawSnapSettings();
			ImGui.EndPopup();
		}
	}

	// ------------------------------------------------------------------ Scene view

	/// Space over the Scene view opens Quick Add: every built-in object, component, prefab and model, searchable,
	/// put where the mouse pointed.
	void UpdateQuickAdd(ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		let typing = (ImGui.tn_imgui_capture_flags() & 4) != 0;
		// In a model's edit mode, Space finds a model tool instead (ModelCommands.bf).
		if (mSceneHovered && !mFlying && !typing && mPlay == .Edit && !mModelEditing && ImGui.IsKeyPressed(ImGui.Key.Space))
		{
			let mouse = ImGui.GetMousePos();
			let ray = mSceneCamera.ViewportPointToRay((mouse.x - origin.x) / size.x, (mouse.y - origin.y) / size.y);
			mQuickHit = RaycastScene(ray, out mQuickPoint, out mQuickNormal, null, true, 300);
			mQuickSearch.Clear();
			mFocusQuickAdd = true;
			if (!mPaletteListed)
				RefreshPalette();
			mScriptCatalog.Refresh(Assets.ProjectPath, Project.Current.Name);
			ImGui.OpenPopup("QuickAdd");
		}
		if (!ImGui.BeginPopup("QuickAdd"))
			return;
		ImGui.SetNextItemWidth(320);
		if (mFocusQuickAdd)
		{
			ImGui.SetKeyboardFocusHere();
			mFocusQuickAdd = false;
		}
		ImGui.InputText("##quick", mQuickSearch, 0, "Add... (objects, components, prefabs, models)");
		let pickFirst = ImGui.IsKeyPressed(ImGui.Key.Enter);
		ImGui.BeginChild("quicklist", .(320, 340));
		int shown = 0;
		GameObject made = null;
		for (let kind in BuiltinObjects)
		{
			if (shown >= 80 || (!mQuickSearch.IsEmpty && !kind.Contains(mQuickSearch, true)))
				continue;
			if (ImGui.Selectable(scope $"{StringView(Icons.Cube)}  {kind}" .CStr()) || (pickFirst && shown == 0))
				made = CreateBuiltin(kind);
			shown++;
		}
		for (let relative in mPaletteAssets)
		{
			if (made != null || shown >= 80 || (!mQuickSearch.IsEmpty && !relative.Contains(mQuickSearch, true)))
				continue;
			if (ImGui.Selectable(scope $"{StringView(relative.EndsWith(".tprefab") ? Icons.Transform : Icons.Cube)}  {relative}" .CStr()) || (pickFirst && shown == 0))
				made = InstantiateAsset(relative);
			shown++;
		}
		for (let info in ComponentRegistry.Types)
		{
			if (made != null || shown >= 80 || !mScriptCatalog.IsVisible(info))
				continue;
			let label = scope String();
			NiceName(info.name, label);
			if (!mQuickSearch.IsEmpty && !label.Contains(mQuickSearch, true) && !info.name.Contains(mQuickSearch, true))
				continue;
			if (ImGui.Selectable(scope $"{StringView(ComponentIcon(info.name))}  Object with {label}##{info.fullName}" .CStr()) || (pickFirst && shown == 0))
				made = CreateWithComponent(info);
			shown++;
		}
		ImGui.EndChild();
		if (made != null)
		{
			if (mQuickHit && !made.IsFolder)
				PlaceOnSurface(made, mQuickPoint, mQuickNormal, false);
			mSelectedId = made.Id;
			MarkDirty();
			ImGui.CloseCurrentPopup();
		}
		if (ImGui.IsKeyPressed(ImGui.Key.Escape))
			ImGui.CloseCurrentPopup();
		ImGui.EndPopup();
	}

	/// The height guide's label, drawn over the Scene view.
	void DrawSceneOverlays(ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		let selected = Selected;
		if (!mHeightGuide || selected == null || selected.IsFolder)
			return;
		Vector3 from, to;
		if (!SurfaceBelow(selected, out from, out to))
			return;
		let height = from.y - to.y;
		ImGui.Vec2 screen;
		if (Math.Abs(height) > 0.001f && SceneToScreen((from + to) * 0.5f, origin, size, out screen))
			ImGui.DrawText(.(screen.x + 6, screen.y - 7), .(0.55f, 0.9f, 1, 0.95f), scope $"{height:0.00} m" .CStr());
	}

	/// Lines in the scene for the tools: the selection's box, the snap grid and the height guide.
	void BuildSceneToolGizmos()
	{
		let selected = Selected;
		if (selected == null || selected.IsFolder)
			return;
		Bounds bounds;
		let hasBounds = HierarchyBounds(selected, out bounds);
		// Prefab instances draw through their children: box the whole thing.
		if (hasBounds && !selected.HasComponent<MeshRenderer>())
			Gizmos.Lines.Box(bounds, .Identity, .(1.0f, 0.62f, 0.15f, 1));
		if (SnapActive && mSnapMove > 0.001f)
		{
			// The snap grid around the selection, at its foot.
			let foot = hasBounds ? Vector3(selected.Transform.Position.x, bounds.min.y, selected.Transform.Position.z) : selected.Transform.Position;
			let cells = (int)Math.Clamp(2.0f / mSnapMove, 4, 24);
			let center = Vector3(SnapValue(foot.x, mSnapMove), foot.y + 0.002f, SnapValue(foot.z, mSnapMove));
			let extent = cells * mSnapMove;
			for (int i = -cells; i <= cells; i++)
			{
				let color = i == 0 ? Color(0.4f, 0.85f, 1, 0.45f) : Color(0.4f, 0.85f, 1, 0.14f);
				let offset = i * mSnapMove;
				Gizmos.Lines.Line(center + Vector3(offset, 0, -extent), center + Vector3(offset, 0, extent), color);
				Gizmos.Lines.Line(center + Vector3(-extent, 0, offset), center + Vector3(extent, 0, offset), color);
			}
		}
		Vector3 from, to;
		if (mHeightGuide && SurfaceBelow(selected, out from, out to) && from.y - to.y > 0.001f)
		{
			let guide = Color(0.55f, 0.9f, 1, 0.9f);
			Gizmos.Lines.Line(from, to, guide);
			Gizmos.Lines.Circle(to, .Up, 0.08f, guide);
		}
	}
}
