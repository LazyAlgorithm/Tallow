using System;
using System.Collections;
using System.IO;
using Tallow;

namespace {NAMESPACE};

/// An editable exhibit root: move this object to move the entire exhibit, and edit its on-screen description here.
[Component]
class ExhibitStation : Component
{
	public int32 index;
	public String title = new .() ~ delete _, description = new .() ~ delete _, action = new .() ~ delete _;
	public Color color = .White;
}
[Component]
class ExhibitBody : Component
{
	public int32 station; }

extension Exhibition
{
	List<ExhibitStation> markers = new .() ~ delete _;
	Dictionary<GameObject, Vector3> homes = new .() ~ delete _;
	Dictionary<GameObject, Quaternion> rotations = new .() ~ delete _;
	List<(MeshRenderer renderer, float metal, float rough)> finishes = new .() ~ delete _;
	List<(SkinnedMeshRenderer skin, float speed, bool gpu)> skinSettings = new .() ~ delete _;
	[Sync] public int32 materialMode, decalMode, animationMode, shaderMode;
	[Sync] public float sharedWind = 1.1f;
	[Sync] public bool sharedIk = true;
	[Sync] public int32 sharedLod = -1;
	int appliedMaterial, appliedDecal, appliedAnimation, appliedShader, appliedLod = -1;
	bool appliedNight, appliedGate = true, appliedIk = true;
	float baseWind = 1.1f, baseSun, baseAmbient, baseIk, baseShader;
	Color baseZenith, baseHorizon, baseDecal;
	Quaternion baseDecalRotation;
	Dictionary<int32, float> nextRequest = new .() ~ delete _;
	public override void Awake()
	{
		Active = this;
		if (!authoredScene)
		{
			Log.Error("The editable Campus scene must be loaded; layout generation is an authoring command only.");
			return;
		}
		BindAuthored();
		if (GetComponent<ExhibitionHUD>() == null)
			GameObject.AddComponent<ExhibitionHUD>();
		if (NetworkSession.ModeOverride == .Offline)
			visitor = GameSetup.CreateVisitor(Scene);
		else
			Scene.CreateGameObject("Tour session").AddComponent<TourSession>();
		Log.Info(scope $"SHOWCASE_READY exhibits={exhibits.Count} objects={Scene.Objects.Count} authored=True");
	}

	void BindAuthored()
	{
		for (let c in Scene.ComponentsOfType(typeof(ExhibitStation)))
			markers.Add((ExhibitStation)c);
		markers.Sort(scope (a, b) => a.index - b.index);
		for (let m in markers)
			exhibits.Add(new Exhibit(m.index, m.title, m.description, m.action, m.Transform.Position, m.color));
		for (let o in Scene.Objects)
		{
			homes[o] = o.Transform.Position;
			rotations[o] = o.Transform.Rotation;
		}
		for (let c in Scene.ComponentsOfType(typeof(Rigidbody)))
		{
			let b = (Rigidbody)c;
			let tag = b.GetComponent<ExhibitBody>();
			if (tag != null)
				props.Add((b, b.Transform.Position, tag.station));
		}
		for (let c in Scene.ComponentsOfType(typeof(SoftBody)))
			softs.Add((SoftBody)c);
		for (let c in Scene.ComponentsOfType(typeof(Rope)))
			ropes.Add((Rope)c);
		for (let c in Scene.ComponentsOfType(typeof(VoxelObject)))
			voxels.Add((VoxelObject)c);
		for (let c in Scene.ComponentsOfType(typeof(ParticleSystem)))
			emitters.Add((ParticleSystem)c);
		for (let c in Scene.ComponentsOfType(typeof(SkinnedMeshRenderer)))
		{
			let skin = (SkinnedMeshRenderer)c;
			skins.Add(skin);
			skinSettings.Add((skin, skin.speed, skin.gpuSkinning));
		}
		for (let c in Scene.ComponentsOfType(typeof(NavigationAgent)))
		{
			let a = (NavigationAgent)c;
			if (a.surface == nav)
				walkers.Add(a);
			else if (a.surface == flight)
				drones.Add(a);
		}
		for (let c in Scene.ComponentsOfType(typeof(MeshRenderer)))
		{
			let r = (MeshRenderer)c;
			if (StationOf(r.GameObject) == 1 && r.GameObject.Name == "Material sphere")
			{
				samples.Add(r);
				finishes.Add((r, r.metallic, r.roughness));
			}
		}
		baseWind = wind.strength;
		sharedWind = baseWind;
		baseSun = sun.intensity;
		baseAmbient = Scene.Environment.ambientIntensity;
		baseZenith = Scene.Environment.skyZenith;
		baseHorizon = Scene.Environment.skyHorizon;
		baseIk = limb.weight;
		baseShader = shaderSample.Material?.GetFloat("speed") ?? 2;
		baseDecal = decal.color;
		baseDecalRotation = decal.Transform.Rotation;
		ikHome = ikTarget.Transform.Position;
		liftHome = lift.Transform.Position;
	}

	public int StationOf(GameObject o)
	{
		for (var t = o.Transform; t != null; t = t.Parent)
		{
			let station = t.GameObject.GetComponent<ExhibitStation>();
			if (station != null) return station.index;
		}
		return -1;
	}

	Vector3 HomePosition(GameObject o) => homes.TryGetValue(o, let p) ? p : o.Transform.Position;
	Quaternion HomeRotation(GameObject o) => rotations.TryGetValue(o, let p) ? p : o.Transform.Rotation;
	void RefreshAuthoredMarkers()
	{
		for (int i < markers.Count)
		{
			let m = markers[i];
			let e = exhibits[i];
			e.at = m.Transform.Position;
			e.title.Set(m.title);
			e.detail.Set(m.description);
			e.action.Set(m.action);
			e.color = m.color;
		}
	}

	void ApplySharedChanges()
	{
		if (appliedNight != Night)
		{
			appliedNight = Night;
			sun.intensity = Night ? baseSun * 0.045f : baseSun;
			Scene.Environment.ambientIntensity = Night ? baseAmbient * 0.2f : baseAmbient;
			Scene.Environment.skyZenith = Night ? .(0.015f, 0.025f, 0.07f) : baseZenith;
			Scene.Environment.skyHorizon = Night ? .(0.04f, 0.07f, 0.15f) : baseHorizon;
		}
		if (wind != null)
			wind.strength = sharedWind;
		if (appliedMaterial != materialMode)
		{
			appliedMaterial = materialMode;
			for (let f in finishes)
			{
				f.renderer.metallic = materialMode == 0 ? f.metal : 1 - f.metal;
				f.renderer.roughness = materialMode == 0 ? f.rough : f.rough < 0.4f ? 0.85f : 0.12f;
			}
		}
		if (appliedDecal != decalMode)
		{
			appliedDecal = decalMode;
			decal.color = (decalMode % 2) == 0 ? baseDecal : .(1, 0.5f, 0.2f);
			decal.Transform.Rotation = baseDecalRotation * Quaternion.Euler(0, 0, decalMode * 37 % 180);
		}
		if (appliedAnimation != animationMode)
		{
			appliedAnimation = animationMode;
			for (let s in skinSettings)
			{
				s.skin.gpuSkinning = animationMode == 0 ? s.gpu : !s.gpu;
				s.skin.speed = animationMode == 0 ? s.speed : 1.5f;
				let a = s.skin.GetComponent<Animator>();
				if (a != null)
					a.speed = s.skin.speed;
			}
		}
		if (appliedIk != sharedIk)
		{
			appliedIk = sharedIk;
			limb.weight = sharedIk ? baseIk : 0;
		}
		if (appliedShader != shaderMode)
		{
			appliedShader = shaderMode;
			shaderSample.Material?.SetFloat("speed", shaderMode == 0 ? baseShader : 6);
		}
		if (appliedLod != sharedLod)
		{
			appliedLod = sharedLod;
			LODGroup.ForceLevel = sharedLod;
			probe.Capture();
		}
		if (appliedGate != GateClosed)
		{
			appliedGate = GateClosed;
			if (!IsAuthority)
			{
				obstacle.Transform.Position = HomePosition(obstacle) + (GateClosed ? .Zero : Vector3(0, -3.8f, 0));
				obstacle.GetComponent<BoxCollider>().Refresh();
				let a = exhibits[8].at;
				nav.Rebuild(.(a + Vector3(-3, -1, -3), a + Vector3(5, 4, 3)));
			}
		}
	}

	void Request(uint8 kind, int index)
	{
		let w = scope NetWriter();
		w.Write(kind);
		w.Write((int32)index);
		Scene.Network.SendToServer(230, w);
		Notice("Exhibit request sent to the host.");
	}

	void RequestRay()
	{
		let w = scope NetWriter();
		w.Write((uint8)2);
		w.Write(camera.Transform.Position);
		w.Write(camera.Transform.Forward);
		Scene.Network.SendToServer(230, w);
	}

	public static void OnTourRequest(int32 sender, ref NetReader r)
	{
		let w = Active;
		if (w == null || !w.IsAuthority || sender <= 0) return;
		let player = w.Scene.Network.PlayerObject(sender);
		if (player == null) return;
		if (w.nextRequest.TryGetValue(sender, let after) && Time.RealTime < after) return;
		w.nextRequest[sender] = Time.RealTime + 0.08f;
		let kind = r.Read<uint8>();
		if (kind == 2)
		{
			let origin = r.Read<Vector3>();
			let dir = r.Read<Vector3>();
			if (!r.Ok || !origin.x.IsFinite || !origin.y.IsFinite || !origin.z.IsFinite || !dir.x.IsFinite || !dir.y.IsFinite || !dir.z.IsFinite || (origin - player.Transform.Position).Length > 3 || Math.Abs(dir.Length - 1) > 0.05f) return;
			w.CastInteraction(origin, dir);
			return;
		}
		let index = r.Read<int32>();
		if (!r.Ok || index < 0 || index >= w.exhibits.Count) return;
		if (kind == 3)
		{
			let p = w.exhibits[index].at + Vector3(0, 1.1f, -5.5f);
			player.GetComponent<CharacterController>()?.Teleport(p);
			return;
		}
		if ((player.Transform.Position - w.exhibits[index].at).Length > 19) return;
		if (kind == 0)
			w.Use(index);
		else if (kind == 1)
			w.Reset(index);
	}

	void CastInteraction(Vector3 at, Vector3 dir)
	{
		RaycastHit hit;
		if (!Scene.Physics.Raycast(at + dir * 0.65f, dir, 18, out hit) || hit.gameObject == null) return;
		let voxel = hit.gameObject.GetComponent<VoxelObject>();
		if (voxel != null)
		{
			voxel.Carve(hit.point, 0.55f);
			return;
		}
		let b = hit.gameObject.GetComponent<Rigidbody>();
		if (b != null && b.HasBody && !b.isKinematic)
			b.AddImpulse(dir * 22 + Vector3(0, 4, 0));
	}

	void SpawnImpactor()
	{
		let pos = exhibits[6].at + Vector3(4, 6, 0);
		let o = Scene.Network != null && Scene.Network.Mode != .Offline ? Scene.Network.Spawn("ShowcaseImpactor", pos, .Identity, 0) : GameSetup.CreateImpactor(Scene);
		if (o != null)
		{
			o.Transform.Position = pos;
			props.Add((o.GetComponent<Rigidbody>(), pos, 6));
			homes[o] = pos;
			rotations[o] = .Identity;
		}
	}

	/// Called once by the explicit authoring utility. It never runs when playing the saved scene.
	public bool SaveEditableCampus(StringView root)
	{
		StringView[3] files = .("Models/cloth16.glb", "Models/soft_box.glb", "Models/cloth8.glb");
		for (int i < 3)
		{
			if (!GlbWriter.Write(scope $"{root}/src/{files[i]}" , Mesh[1](meshes[i]), StringView[1]("Surface")))
				return false;
		}
		for (let c in Scene.ComponentsOfType(typeof(MeshRenderer)))
		{
			let r = (MeshRenderer)c;
			for (int i < 3)
			{
				if (r.RuntimeMesh == meshes[i])
				{
					r.RuntimeMesh = null;
					r.mesh.Set(files[i]);
					r.useModelMaterials = false;
				}
			}
		}
		for (let p in props)
			p.body.GameObject.AddComponent<ExhibitBody>().station = (int32)p.sector;
		for (let c in Scene.ComponentsOfType(typeof(Rope)))
		{
			let rope = (Rope)c;
			var renderer = rope.GetComponent<MeshRenderer>();
			if (renderer == null)
				renderer = rope.GameObject.AddComponent<MeshRenderer>();
			renderer.mesh.Clear();
			renderer.color = .(0.9f, 0.72f, 0.35f);
			rope.GameObject.AddComponent<RopePreview>();
		}
		let roots = scope List<GameObject>(Scene.Roots);
		let architecture = Scene.CreateGameObject("Campus architecture");
		architecture.IsFolder = true;
		let environment = Scene.CreateGameObject("Environment and cameras");
		environment.IsFolder = true;
		let groups = scope List<GameObject>();
		for (let e in exhibits)
		{
			let g = Scene.CreateGameObject(scope $"{e.index+1:00} {e.title}");
			g.Transform.Position = e.at;
			let m = g.AddComponent<ExhibitStation>();
			m.index = (int32)e.index;
			m.title.Set(e.title);
			m.description.Set(e.detail);
			m.action.Set(e.action);
			m.color = e.color;
			groups.Add(g);
		}
		for (let o in roots)
		{
			if (o == GameObject) continue;
			let name = o.Name;
			if (o == camera.GameObject || o == sun.GameObject || o == wind.GameObject || o == ocean.GameObject)
			{
				o.Transform.SetParent(environment.Transform, true);
				continue;
			}
			if (name == "Plaza tile" || name.StartsWith("Atrium") || name == "Kinetic sculpture" || name.StartsWith("Pier") || name.StartsWith("Central") || name.Contains("curb") || name == "Ocean exit step")
			{
				o.Transform.SetParent(architecture.Transform, true);
				continue;
			}
			var pos = o.Transform.Position;
			int best = 0;
			float distance = float.MaxValue;
			for (let e in exhibits)
			{
				let d = Vector2(pos.x - e.at.x, pos.z - e.at.z).Length;
				if (d < distance)
				{
					distance = d;
					best = e.index;
				}
			}
			if (name == "Pool bottom" || name == "Water bridge" || name == "Pool exit step")
				best = 11;
			o.Transform.SetParent(groups[best].Transform, true);
		}
		let spawn = Scene.CreateGameObject("Visitor spawn - move to change the entrance");
		spawn.Transform.Position = .(0, 1, -31);
		spawn.AddComponent<SpawnPoint>();
		// Put serialized soft-body and rope renderers before their simulation components.
		return SceneSerializer.SaveToFile(Scene, scope $"{root}/src/Scenes/Campus.tscene");
	}
}
