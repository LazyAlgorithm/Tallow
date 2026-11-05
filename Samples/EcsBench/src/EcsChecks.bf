using System;
using System.Collections;
using System.Threading;
using Tallow;

namespace EcsBench;

[Component]
struct Marked
{
}

/// Holds a reference to another object's Light, for EcsChecks.HandleChecks.
[Component]
class LampUser : Component
{
	public Light lamp;
}

/// Counts the Update calls it gets, for EcsChecks.UpdateChecks.
[Component]
class UpdateCounter : Component
{
	public int frames;
	public int ticks;
	public bool sawControls;

	public override void Update(TickInput input, float deltaTime)
	{
		if (deltaTime == Time.FixedDeltaTime && GameObject.GetComponent<NetworkIdentity>() != null)
			ticks++;
		else
			frames++;
		if (input.raw.moveX != 0 || input.raw.moveZ != 0 || input.raw.buttons != 0)
			sawControls = true;
	}
}

/// Checks of the ECS layer (World, Query, ParallelFor, deferred changes), run with TALLOW_BENCH_MODE=check.
static class EcsChecks
{
	static int sFailures;

	static void Expect(bool condition, StringView what)
	{
		if (!condition)
		{
			sFailures++;
			Console.WriteLine($"  FAILED: {what}");
		}
	}

	public static int Run()
	{
		sFailures = 0;
		let world = scope World();
		let entities = scope List<Entity>();
		world.CreateMany<Pose>(1000, entities);
		Expect(entities.Count == 1000 && world.Count<Pose>() == 1000, "CreateMany makes 1000 entities");
		for (let entity in entities)
			world.Set<Motion>(entity, .() { velocity = .(1, 0, 0) });
		Expect(world.Get<Motion>(entities[5]).velocity.x == 1, "Set then Get");
		Expect(world.Get<RenderMatrix>(entities[5]) == null, "Get of a missing component is null");

		// Changes made while iterating wait for DeferEnd.
		let query = scope Query<Pose, Motion>(world);
		world.DeferBegin();
		int seen = 0;
		for (var chunk in query)
		{
			for (let entity in chunk.Entities)
				world.Add<Marked>(entity);
			seen += chunk.Count;
		}
		Expect(seen == 1000, "query visits every entity");
		Expect(world.Count<Marked>() == 0, "deferred adds are not applied before DeferEnd");
		world.DeferEnd();
		Expect(world.Count<Marked>() == 1000, "deferred adds are applied at DeferEnd");
		Expect(world.Get<Motion>(entities[5]).velocity.x == 1, "data survives moving to a new table");

		// Every row is visited exactly once over all threads.
		int32 total = 0;
		query.ParallelFor(scope [&] (chunk) =>
			{
				let poses = chunk.Write<Pose>();
				let motions = chunk.Read<Motion>();
				for (int i < chunk.Count)
					poses[i].position.x += motions[i].velocity.x;
				Interlocked.Add(ref total, (int32)chunk.Count);
			});
		Expect(total == 1000, "ParallelFor covers every entity once");
		Expect(world.Get<Pose>(entities[999]).position.x == 1, "ParallelFor writes land");

		// Leaving a loop early and deleting.
		for (var chunk in query)
			break;
		world.Delete(entities[0]);
		Expect(!world.IsAlive(entities[0]) && world.Count<Pose>() == 999, "Delete");
		SceneChecks();
		UpdateChecks();
		DataChecks();
		PrefabChecks();
		HandleChecks();
		WindChecks();
		DecalChecks();
		ProbeChecks();
		CameraChecks();
		AudioChecks();
		RendererChecks();
		SkinnedChecks();
		ParticleChecks();
		return sFailures;
	}

	/// GameObjects and their entities stay in step (docs/ecs-plan.md, Phase 2).
	static void SceneChecks()
	{
		let scene = scope Scene();
		let world = scene.World;
		let parent = scene.CreateGameObject("Parent");
		let child = scene.CreateGameObject("Child", parent.Transform);
		Expect(world.IsAlive(parent.Entity) && world.IsAlive(child.Entity), "each GameObject has a live entity");
		Expect(world.Get<ObjectLink>(child.Entity).gameObject == child, "ObjectLink points back at the GameObject");
		Expect(world.Parent(child.Entity) == parent.Entity, "ChildOf follows the hierarchy");
		child.Transform.SetParent(null);
		Expect(world.Parent(child.Entity).IsNull, "SetParent(null) clears ChildOf");
		child.Transform.SetParent(parent.Transform);
		child.SetActive(false);
		Expect(world.Has<InactiveSelf>(child.Entity), "SetActive(false) tags the entity");
		child.SetActive(true);
		Expect(!world.Has<InactiveSelf>(child.Entity), "SetActive(true) clears the tag");
		// Transform data lives in the entity and follows it as it moves between tables.
		parent.Transform.LocalPosition = .(1, 2, 3);
		child.Transform.LocalPosition = .(0, 1, 0);
		Expect(world.Get<TransformData>(child.Entity).localPosition.y == 1, "Transform writes land in TransformData");
		child.SetActive(false);
		child.Transform.LocalPosition = .(0, 5, 0);
		Expect(child.Transform.Position == Vector3(1, 7, 3), "world position after the entity changed tables");
		child.SetActive(true);
		world.Get<TransformData>(parent.Entity).localPosition = .(0, 0, 0);
		parent.Transform.PoseChanged();
		Expect(child.Transform.Position == Vector3(0, 5, 0), "writes through the world are seen by Transform");
		let childEntity = child.Entity;
		let parentEntity = parent.Entity;
		scene.DestroyImmediate(parent);
		Expect(!world.IsAlive(parentEntity) && !world.IsAlive(childEntity), "destroying objects deletes their entities");
		Expect(world.Count<ObjectLink>() == 0, "no entities left behind");
	}

	/// Update runs per frame on plain objects and per tick on networked ones; an object no player controls gets
	/// empty controls (Component.Update).
	static void UpdateChecks()
	{
		let previous = Scene.Active;
		let scene = scope Scene();
		let plain = scene.CreateGameObject("Plain").AddComponent<UpdateCounter>();
		let networkedObject = scene.CreateGameObject("Networked");
		let identity = networkedObject.AddComponent<NetworkIdentity>();
		identity.playerControlled = false;
		let networked = networkedObject.AddComponent<UpdateCounter>();
		// Steps added by phase run at their place in the frame: before and after the scripts' Update.
		int before = -1;
		int after = -1;
		scene.World.AddStep(scene.FramePipeline, "Check.Before", .PreUpdate, new [&] () =>
			{
				if (before < 0)
					before = plain.frames;
			}
			);
		scene.World.AddStep(scene.FramePipeline, "Check.After", .PostUpdate, new [&] () =>
			{
				if (after < 0)
					after = plain.frames;
			}
			);
		scene.StartPlay();
		for (int i < 3)
			scene.Update();
		Expect(before == 0 && after == 1, scope $"Frame pipeline runs steps in phase order around Update (before {before}, after {after})");
		for (int i < 2)
			scene.FixedUpdate();
		Expect(plain.frames == 3 && plain.ticks == 0, scope $"plain object: Update once a frame (frames {plain.frames}, ticks {plain.ticks})");
		Expect(networked.ticks == 2 && networked.frames == 0, scope $"networked object: Update once a tick (frames {networked.frames}, ticks {networked.ticks})");
		Expect(!networked.sawControls, "an object no player controls gets empty controls");

		// The per-callback lists only hold classes that override the callback.
		Expect(ScriptCallbackIndex.Of(typeof(UpdateCounter)) == .Update, "UpdateCounter overrides Update only");
		Expect(ScriptCallbackIndex.Of(typeof(Mover)) == .Update, "Mover overrides Update only");
		Expect(ScriptCallbackIndex.Of(typeof(Animator)).HasFlag(.OnLocalUpdate), "Animator overrides OnLocalUpdate");
		Expect(ScriptCallbackIndex.Of(typeof(CharacterMotor)).HasFlag(.FixedUpdate), "CharacterMotor overrides FixedUpdate");
		Expect(ScriptCallbackIndex.Of(typeof(Bench)) == .Update | .LateUpdate, "Bench overrides Update and LateUpdate");
		scene.StopPlay();
		Scene.Active = previous;
	}

	/// Data components on GameObjects: the generic API, the editor's by-type API, and scene files (Phase 3).
	static void DataChecks()
	{
		let scene = scope Scene();
		let cube = scene.CreateGameObject("Cube");
		let motion = cube.AddComponent<Motion>(.() { velocity = .(1, 2, 3), spin = .(0, 90, 0) });
		Expect(motion != null && motion.velocity.y == 2, "AddComponent<T>(value) for a data component");
		Expect(cube.HasComponent<Motion>() && cube.GetComponent<Motion>().spin.y == 90, "GetComponent<T> for a data component");
		cube.Transform.LocalPosition = .(5, 0, 0);
		cube.AddComponent<Pose>();
		Expect(cube.GetComponent<Motion>().velocity.z == 3, "data survives another data component being added");

		let listed = scope List<DataComponents.Info>();
		DataComponents.On(cube, listed);
		Expect(listed.Count == 2, scope $"DataComponents.On lists the object's two data components ({listed.Count}), not engine bookkeeping");
		Expect(DataComponents.Find("EcsBench.Motion") != null && DataComponents.Find("Tallow.TransformData") == null, "registry lists game data, hides [EngineData]");

		let text = scope String();
		SceneSerializer.Save(scene, text);
		Expect(text.Contains("data EcsBench.Motion"), "scene text has a data block");
		let loaded = scope Scene();
		SceneSerializer.Load(loaded, text);
		let copy = loaded.Find("Cube");
		Expect(copy != null && copy.HasComponent<Motion>() && copy.GetComponent<Motion>().velocity.y == 2 && copy.GetComponent<Motion>().spin.y == 90, "data component values survive save and load");
		Expect(copy != null && copy.HasComponent<Pose>() && copy.Transform.LocalPosition.x == 5, "every data component and the transform survive");

		// What script reload does: data blocks out, values changed, blocks read back by field name.
		let blocks = scope String();
		SceneSerializer.SaveData(cube, blocks);
		cube.GetComponent<Motion>().velocity = .(9, 9, 9);
		SceneSerializer.LoadData(cube, blocks);
		Expect(cube.GetComponent<Motion>().velocity.y == 2 && cube.GetComponent<Motion>().spin.y == 90, "SaveData and LoadData put data back by field name");

		cube.RemoveComponent<Motion>();
		Expect(!cube.HasComponent<Motion>() && cube.HasComponent<Pose>(), "RemoveComponent<T> for a data component");
	}

	/// Phase 3 exit, engine side: a prefab with data and a script survives instance, edit, save, load and play.
	static void PrefabChecks()
	{
		let previous = Scene.Active;
		let path = scope String();
		Environment.GetEnvironmentVariable("TMPDIR", path).IgnoreError();
		if (path.IsEmpty)
			path.Set("/tmp");
		path.AppendF("/ecs-check-{}.tprefab", (int)Internal.UnsafeCastToPtr(path) & 0xFFFF);

		let source = scope Scene();
		let root = source.CreateGameObject("Crate");
		root.AddComponent<Motion>(.() { velocity = .(1, 0, 0), spin = .(0, 10, 0) });
		root.AddComponent<UpdateCounter>();
		source.CreateGameObject("Lid", root.Transform).AddComponent<Pose>(.() { position = .(0, 2, 0), rotation = .Identity });
		Expect(Prefab.Save(root, path), "prefab with data components saves");

		let level = scope Scene();
		let instance = Prefab.Create(level, path);
		Expect(instance != null && instance.GetComponent<Motion>()?.spin.y == 10, "prefab instance has the prefab's data");
		instance?.GetComponent<Motion>().velocity = .(4, 0, 0);
		let text = scope String();
		SceneSerializer.Save(level, text);

		let played = scope Scene();
		SceneSerializer.Load(played, text);
		played.StartPlay();
		for (int i < 5)
			played.Update();
		let crate = played.Find("Crate");
		let lid = played.Find("Lid");
		Expect(crate != null && crate.GetComponent<Motion>()?.velocity.x == 4, "the instance's edit survives save, load and play");
		Expect(lid != null && lid.GetComponent<Pose>()?.position.y == 2 && lid.Transform.Parent?.GameObject == crate, "child data and hierarchy survive");
		Expect(crate?.GetComponent<UpdateCounter>()?.frames == 5, "the instance's script runs in play");
		played.StopPlay();
		Scene.Active = previous;
		System.IO.File.Delete(path).IgnoreError();
	}

	/// Phase 4: built-in components as handles over data (Light first).
	/// Wind Zone and Foliage Bender are handles: Wind reads the zones from Flecs.
	static void WindChecks()
	{
		let scene = scope Scene();
		let zone = scene.CreateGameObject("Wind").AddComponent<WindZone>();
		zone.Transform.LookAt(.(0, 0, 10));
		zone.strength = 2;
		Expect(Math.Abs(Wind.At(scene, .Zero).z - 2) < 0.001f, "a Global Wind Zone blows the way it faces");
		let gust = scene.CreateGameObject("Gust").AddComponent<WindZone>();
		gust.shape = .Sphere;
		gust.radius = 4;
		gust.Transform.LookAt(.(0, 0, 10));
		Expect(Math.Abs(Wind.At(scene, .Zero).z - 3) < 0.001f && Math.Abs(Wind.At(scene, .(0, 0, 50)).z - 2) < 0.001f, "a Sphere zone adds only inside its reach");
		gust.enabled = false;
		Expect(Math.Abs(Wind.At(scene, .Zero).z - 2) < 0.001f, "a switched-off zone does not blow");
		zone.GameObject.SetActive(false);
		Expect(Wind.At(scene, .Zero).Length < 0.001f, "a zone on an inactive object does not blow");
		let bender = scene.CreateGameObject("Bender").AddComponent<FoliageBender>();
		Expect(bender.radius == 0.9f && bender.strength == 1, "a Foliage Bender has its defaults");
		Vector4[8] places = default, push = default;
		FoliageBender.Gather(scene, .Zero, ref places, ref push);
		Expect(places[0].w == 0.9f && push[0].x == 1, "Foliage Bender gathers from Flecs");
		let text = scope String();
		SceneSerializer.Save(scene, text);
		let loaded = scope Scene();
		SceneSerializer.Load(loaded, text);
		let loadedGust = loaded.Find("Gust").GetComponent<WindZone>();
		Expect(loadedGust && loadedGust.shape == .Sphere && loadedGust.radius == 4 && !loadedGust.enabled, "a Wind Zone saves and loads");
	}

	/// SharedString in handle data (Decal's texture), saved and edited like a String.
	static void DecalChecks()
	{
		SharedString a = "Textures/ring.png";
		SharedString b = scope String("Textures/ring.png");
		Expect(a == b && a == "Textures/ring.png" && ((SharedString)default).IsEmpty, "SharedString keeps one copy of each text");
		let scene = scope Scene();
		let decal = scene.CreateGameObject("Seal").AddComponent<Decal>();
		Expect(decal.texture.IsEmpty && decal.size == Vector3(1, 1, 0.5f) && decal.roughness == 0.8f, "a Decal has its defaults");
		decal.texture = "Textures/ring.png";
		decal.order = 3;
		// Moving the entity between tables copies the data byte for byte; the text must survive it.
		scene.Find("Seal").AddComponent<WindZone>();
		Expect(decal.texture == "Textures/ring.png", "SharedString survives the entity moving tables");
		Expect(scene.Components<Decal>(.. scope .()).Count == 1, "Scene.Components<Decal> finds it");
		let fields = scope List<FieldRef>();
		HandleComponents.GetFields(decal.GameObject, HandleComponents.Find(typeof(Decal)), fields);
		Expect(fields.FindIndex(scope (field) => field.name == "texture") >= 0, "the texture field is editable");
		let text = scope String();
		SceneSerializer.Save(scene, text);
		Expect(text.Contains("component Tallow.Decal enabled 1") && text.Contains("\"Textures/ring.png\""), "a Decal saves its texture");
		let loaded = scope Scene();
		SceneSerializer.Load(loaded, text);
		let loadedDecal = loaded.Find("Seal").GetComponent<Decal>();
		Expect(loadedDecal && loadedDecal.texture == "Textures/ring.png" && loadedDecal.order == 3, "a Decal loads its texture");
	}

	/// Reflection Probe keeps its capture state outside its data (ComponentState), freed by the remove hook.
	static void ProbeChecks()
	{
		let before = ComponentState<ReflectionProbeState>.Count;
		{
			let scene = scope Scene();
			let probe = scene.CreateGameObject("Probe").AddComponent<ReflectionProbe>();
			Expect(!probe.Captured && probe.WantsCapture(0) && probe.size == Vector3(10, 10, 10), "a new probe wants capturing");
			probe.CaptureStarted(0);
			probe.CaptureFinished(5);
			Expect(probe.Captured && probe.LastLevel == 5 && ComponentState<ReflectionProbeState>.Count == before + 1, "capturing keeps state outside the data");
			// Moving tables (adding another component) must keep the same state.
			probe.GameObject.AddComponent<WindZone>();
			Expect(probe.Captured && probe.LastLevel == 5, "the state stays with the entity");
			probe.GameObject.RemoveComponent<ReflectionProbe>();
			Expect(ComponentState<ReflectionProbeState>.Count == before, "RemoveComponent frees the state");
			let second = scene.CreateGameObject("Second").AddComponent<ReflectionProbe>();
			second.CaptureStarted(0);
			scene.DestroyImmediate(second.GameObject);
			Expect(ComponentState<ReflectionProbeState>.Count == before, "destroying the object frees the state");
			scene.CreateGameObject("Third").AddComponent<ReflectionProbe>().CaptureStarted(0);
			Expect(scene.FindComponents<ReflectionProbe>(.. scope .()).Count == 1 && scene.FindComponent<ReflectionProbe>(), "FindComponents finds handles");
		}
		Expect(ComponentState<ReflectionProbeState>.Count == before, "the scene ending frees the state");

		let scene = scope Scene();
		let volume = scene.CreateGameObject("Volume").AddComponent<LightProbeVolume>();
		volume.size = .(4, 2, 4);
		volume.Counts(let x, let y, let z);
		Expect(x == 5 && y == 3 && z == 5 && volume.spacing == 1, "a Light Probe Volume counts its probes from its data");
	}

	/// Camera: the view camera is the oldest active one unless overridden; the override goes when its object does.
	static void CameraChecks()
	{
		let scene = scope Scene();
		Expect(!scene.ViewCamera, "no camera: ViewCamera is not valid");
		let main = scene.CreateGameObject("Main").AddComponent<Camera>();
		let second = scene.CreateGameObject("Second").AddComponent<Camera>();
		Expect(main.fieldOfView == 60 && main.viewmodelLayer == -1 && main.farClip == 1000, "a Camera has its defaults");
		Expect(scene.ViewCamera == main && scene.Cameras.Count == 2, "the oldest camera is the view camera");
		main.enabled = false;
		Expect(scene.ViewCamera == second && scene.Cameras.Count == 1, "a switched-off camera is passed over");
		main.enabled = true;
		second.GameObject.SetActive(false);
		scene.CameraOverride = second;
		Expect(scene.ViewCamera == main, "an inactive override is passed over");
		second.GameObject.SetActive(true);
		Expect(scene.ViewCamera == second, "an active override is the view camera");
		scene.DestroyImmediate(second.GameObject);
		Expect(!scene.CameraOverride && scene.ViewCamera == main, "the override goes with its object");
		main.fieldOfView = 75;
		Expect(Math.Abs(main.GetCameraData(1).fieldOfView - 75) < 0.001f, "GetCameraData reads the handle's data");
		let text = scope String();
		SceneSerializer.Save(scene, text);
		let loaded = scope Scene();
		SceneSerializer.Load(loaded, text);
		Expect(loaded.ViewCamera && loaded.ViewCamera.fieldOfView == 75, "a Camera saves and loads");
	}

	/// Audio Source, Listener and Reverb Zone are handles; a source's voice is AudioSourceState.
	static void AudioChecks()
	{
		let before = ComponentState<AudioSourceState>.Count;
		{
			let scene = scope Scene();
			let radio = scene.CreateGameObject("Radio");
			let source = radio.AddComponent<AudioSource>();
			Expect(source.volume == 1 && source.maxDistance == 40 && source.playOnStart && source.spatial && source.audioClip.IsEmpty, "an Audio Source has its defaults");
			Expect(!source.IsPlaying && source.Length == 0 && ComponentState<AudioSourceState>.Count == before, "a source that never played keeps no voice");
			source.Play("Sounds/missing.wav");
			Expect(source.audioClip == "Sounds/missing.wav" && !source.IsPlaying, "Play(clip) sets the clip; a missing file does not play");
			AudioSource.FrameAll(scene);
			let zone = scene.CreateGameObject("Hall").AddComponent<AudioReverbZone>();
			zone.radius = 10;
			zone.fade = 5;
			Expect(zone.WeightAt(.Zero) == 1 && Math.Abs(zone.WeightAt(.(7.5f, 0, 0)) - 0.5f) < 0.001f && zone.WeightAt(.(11, 0, 0)) == 0, "a Reverb Zone weighs points from its data");
			let ears = scene.CreateGameObject("Ears");
			ears.Transform.Position = .(3, 4, 5);
			ears.AddComponent<AudioListener>();
			AudioListener.FrameAll(scene);
			Expect(!scene.IsPlaying || Audio.ListenerPosition == Vector3(3, 4, 5), "an Audio Listener places the ears");
			let text = scope String();
			SceneSerializer.Save(scene, text);
			Expect(text.Contains("component Tallow.AudioSource enabled 1") && text.Contains("component Tallow.AudioListener enabled 1"), "audio components save under their names");
			let loaded = scope Scene();
			SceneSerializer.Load(loaded, text);
			Expect(loaded.Find("Radio").GetComponent<AudioSource>().audioClip == "Sounds/missing.wav" && loaded.Find("Ears").HasComponent<AudioListener>(), "audio components load");
		}
		Expect(ComponentState<AudioSourceState>.Count == before, "voices are freed with their scene");
	}

	/// Mesh Renderer: data in Flecs, what the renderer keeps in its RenderProxy, Scene.Renderers from the query.
	static void RendererChecks()
	{
		let before = ComponentState<RenderProxy>.Count;
		{
			let scene = scope Scene();
			let cube = scene.CreateGameObject("Cube");
			let renderer = cube.AddComponent<MeshRenderer>();
			Expect(renderer.mesh == "builtin:cube" && renderer.roughness == 0.85f && renderer.castShadows && renderer.occluder == .Auto, "a Mesh Renderer has its defaults");
			renderer.mesh.Set("builtin:sphere");
			renderer.color.g = 0.25f;
			Expect(cube.GetComponent<MeshRenderer>().mesh == "builtin:sphere" && cube.GetComponent<MeshRenderer>().color.g == 0.25f, "mesh.Set and color writes reach the data");
			let list = scene.Renderers;
			Expect(list.Count == 1 && list[0].mesh == "builtin:sphere" && list[0].GameObject == cube && list[0].Renderer == renderer, "Scene.Renderers gives the proxy with the settings copied in");
			renderer.VisualOffset = .(0, 1, 0);
			Expect(Math.Abs(renderer.RenderMatrix.Translation.y - 1) < 0.001f, "runtime-only values live in the proxy");
			renderer.enabled = false;
			Expect(scene.Renderers.Count == 0, "a switched-off renderer is not drawn");
			renderer.enabled = true;
			cube.AddComponent<WindZone>();
			Expect(renderer.VisualOffset.y == 1 && scene.Renderers.Count == 1, "the proxy stays with the entity as it moves tables");
			let text = scope String();
			SceneSerializer.Save(scene, text);
			Expect(text.Contains("component Tallow.MeshRenderer enabled 1") && text.Contains("field mesh \"builtin:sphere\""), "a Mesh Renderer saves as before");
			let loaded = scope Scene();
			SceneSerializer.Load(loaded, text);
			let loadedRenderer = loaded.Find("Cube").GetComponent<MeshRenderer>();
			Expect(loadedRenderer && loadedRenderer.mesh == "builtin:sphere" && Math.Abs(loadedRenderer.color.g - 0.25f) < 0.001f, "a Mesh Renderer loads");
			Expect(MeshRenderer.MeshOf(scene.CreateGameObject("Empty")) == null, "MeshOf an object without a renderer is null");
			cube.RemoveComponent<MeshRenderer>();
			Expect(ComponentState<RenderProxy>.Count == before, "RemoveComponent frees the proxy (reading fields makes none)");
		}
		Expect(ComponentState<RenderProxy>.Count == before, "proxies are freed with their scene");
	}

	/// Skinned Mesh Renderer: settings in Flecs, the model and clips in its SkinnedRig.
	static void SkinnedChecks()
	{
		let before = ComponentState<SkinnedRig>.Count;
		{
			let scene = scope Scene();
			let man = scene.CreateGameObject("Man");
			let skinned = man.AddComponent<SkinnedMeshRenderer>();
			Expect(skinned.model.IsEmpty && skinned.speed == 1 && skinned.loop && skinned.gpuSkinning && !skinned.exposeBones, "a Skinned Mesh Renderer has its defaults");
			Expect(ComponentState<SkinnedRig>.Count == before, "reading settings makes no rig");
			skinned.model = "Models/rigged_sample.glb";
			skinned.clip = "Wave";
			Expect(skinned.Model != null && skinned.CurrentClip == "Wave", "setting the model and clip loads them");
			Expect(ComponentState<SkinnedRig>.Count == before + 1, "the rig is made once it is needed");
			skinned.SetPartHidden("Hat", true);
			skinned.SetPartHidden("Coat", true);
			skinned.SetPartHidden("Hat", false);
			Expect(skinned.hiddenParts == "Coat", "SetPartHidden writes the setting");
			skinned.SetPartColor("Coat", .(0.5f, 0.25f, 1, 1));
			Expect(skinned.partColors == "Coat=0.5 0.25 1", "SetPartColor writes the setting");
			SkinnedMeshRenderer.FrameAll(scene);
			let renderer = man.GetComponent<MeshRenderer>();
			Expect(renderer && renderer.RuntimeMesh != null, "a frame hands the bent mesh to a Mesh Renderer it adds");
			skinned.exposeBones = true;
			SkinnedMeshRenderer.FrameAll(scene);
			Expect(skinned.BoneCount == skinned.Model.Joints.Count && skinned.BoneCount > 0, "Expose Bones makes the bone objects");
			let text = scope String();
			SceneSerializer.Save(scene, text);
			Expect(text.Contains("component Tallow.SkinnedMeshRenderer enabled 1") && text.Contains("field clip \"Wave\""), "a Skinned Mesh Renderer saves as before");
			let loaded = scope Scene();
			SceneSerializer.Load(loaded, text);
			let copy = loaded.Find("Man").GetComponent<SkinnedMeshRenderer>();
			Expect(copy && copy.model == "Models/rigged_sample.glb" && copy.hiddenParts == "Coat" && copy.exposeBones, "a Skinned Mesh Renderer loads");
			man.RemoveComponent<SkinnedMeshRenderer>();
			Expect(renderer.RuntimeMesh == null, "removing it takes its mesh off the Mesh Renderer");
			Expect(ComponentState<SkinnedRig>.Count == before, "RemoveComponent frees the rig");
		}
		Expect(ComponentState<SkinnedRig>.Count == before, "rigs are freed with their scene");
	}

	/// Particle System: settings in Flecs, particles in its ParticleState, Scene.Particles from the query.
	static void ParticleChecks()
	{
		let before = ComponentState<ParticleState>.Count;
		{
			let scene = scope Scene();
			let fire = scene.CreateGameObject("Fire");
			let system = fire.AddComponent<ParticleSystem>();
			Expect(system.mesh == "builtin:cube" && system.maxParticles == 500 && system.looping && system.AliveCount == 0, "a Particle System has its defaults");
			system.burst = 20;
			system.looping = false;
			system.lifetime = 10;
			ParticleSystem.FrameAll(scene);
			Expect(system.AliveCount == 20, "a frame emits the burst");
			Expect(scene.Particles.Count == 1 && scene.Particles[0].burst == 20 && scene.Particles[0].AliveCount == 20, "Scene.Particles gives the state with the settings copied in");
			system.Play();
			Expect(system.AliveCount == 0, "Play starts again");
			ParticleSystem.FrameAll(scene);
			Expect(system.AliveCount == 20, "and the burst comes again");
			system.enabled = false;
			Expect(scene.Particles.Count == 0, "a switched-off system is not drawn");
			ParticleSystem.FrameAll(scene);
			Expect(system.AliveCount == 20, "nor moved on");
			system.enabled = true;
			fire.SetActive(false);
			Expect(scene.Particles.Count == 1, "on an inactive object it is listed (the renderer skips it)");
			fire.SetActive(true);
			let text = scope String();
			SceneSerializer.Save(scene, text);
			Expect(text.Contains("component Tallow.ParticleSystem enabled 1") && text.Contains("field burst 20"), "a Particle System saves as before");
			let loaded = scope Scene();
			SceneSerializer.Load(loaded, text);
			let copy = loaded.Find("Fire").GetComponent<ParticleSystem>();
			Expect(copy && copy.burst == 20 && !copy.looping && copy.AliveCount == 0, "a Particle System loads, with no particles yet");
			fire.RemoveComponent<ParticleSystem>();
			Expect(ComponentState<ParticleState>.Count == before, "RemoveComponent frees the particles");
		}
		Expect(ComponentState<ParticleState>.Count == before, "particles are freed with their scene");
	}

	static void HandleChecks()
	{
		let previous = Scene.Active;
		let scene = scope Scene();
		let lamp = scene.CreateGameObject("Lamp");
		let light = lamp.AddComponent<Light>();
		Expect(light && light.IsValid, "AddComponent<Light> gives a valid handle");
		Expect(light.intensity == 1 && light.range == 10 && light.spotAngle == 45 && light.shadowMaskChannel == -1 && light.castShadows, "a new Light has its field initializers");
		light.type = .Point;
		light.intensity *= 3;
		light.color.g = 0.5f;
		Expect(lamp.GetComponent<Light>().intensity == 3 && lamp.GetComponent<Light>().color.g == 0.5f && lamp.GetComponent<Light>().type == .Point, "handle fields write through to the data");
		Expect(!scene.CreateGameObject("Empty").GetComponent<Light>(), "GetComponent on an object without one is not valid");
		Expect(scene.Lights.Count == 1, "Scene.Lights finds the light");
		light.enabled = false;
		Expect(!light.enabled && scene.Lights.Count == 0 && scene.AllLights.Count == 1, "a switched-off light is left out of Scene.Lights");
		light.enabled = true;
		Expect(scene.Lights.Count == 1, "switched back on");

		let user = scene.CreateGameObject("User").AddComponent<LampUser>();
		user.lamp = light;
		let text = scope String();
		SceneSerializer.Save(scene, text);
		Expect(text.Contains("component Tallow.Light enabled 1") && text.Contains("field intensity 3"), "a Light saves as a component line with its fields");

		let loaded = scope Scene();
		SceneSerializer.Load(loaded, text);
		let loadedLamp = loaded.Find("Lamp");
		Light loadedLight = loadedLamp != null ? loadedLamp.GetComponent<Light>() : default;
		Expect(loadedLight && loadedLight.intensity == 3 && loadedLight.type == .Point && loadedLight.color.g == 0.5f, "a Light loads with its values");
		let loadedUser = loaded.Find("User")?.GetComponent<LampUser>();
		Expect(loadedUser != null && loadedUser.lamp && loadedUser.lamp.GameObject == loadedLamp, "a script's Light field is saved as a reference and resolved");
		loadedLight.enabled = false;
		let again = scope String();
		SceneSerializer.Save(loaded, again);
		Expect(again.Contains("component Tallow.Light enabled 0"), "a switched-off light saves as such");
		loaded.DestroyImmediate(loadedLamp);
		Expect(!loadedUser.lamp, "destroying the light's object clears the reference to it");

		lamp.RemoveComponent<Light>();
		Expect(!light && !lamp.HasComponent<Light>(), "RemoveComponent<Light> leaves the handle not valid");
		Scene.Active = previous;
	}
}
