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
		LineChecks();
		FoliageChecks();
		WaterChecks();
		RigidbodyChecks();
		CharacterChecks();
		AnimatorChecks();
		NavigationChecks();
		BehaviourChecks();
		DialogueChecks();
		SequenceChecks();
		SpawnChecks();
		SceneLoaderChecks();
		SavedTransformChecks();
		ViewmodelChecks();
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

	/// Rigidbody: a body made once the scene plays, following switching off, inactive objects, removal and stopping.
	static void RigidbodyChecks()
	{
		let before = ComponentState<RigidbodyState>.Count;
		let previous = Scene.Active;
		{
			let scene = scope Scene();
			Scene.Active = scene;
			let ground = scene.CreateGameObject("Ground");
			ground.Transform.Position = .(0, -0.5f, 0);
			ground.AddComponent<BoxCollider>().size = .(20, 1, 20);
			let crate = scene.CreateGameObject("Crate");
			crate.Transform.Position = .(0, 3, 0);
			crate.AddComponent<BoxCollider>();
			let body = crate.AddComponent<Rigidbody>();
			body.mass = 4;
			Expect(body.mass == 4 && body.useGravity && !body.isKinematic && body.friction == 0.5f && !body.HasBody, "a Rigidbody has its defaults and no body before play");
			Expect(body.Velocity == .Zero && !body.IsSleeping, "an absent body reads as still");
			body.AddForce(.(1, 0, 0));
			scene.StartPlay();
			scene.Update();
			Expect(body.HasBody, "playing makes the body");
			let id = body.BodyId;
			for (int i < 30)
				scene.FixedUpdate();
			Expect(crate.Transform.Position.y < 2.9f, scope $"the body falls ({crate.Transform.Position.y})");
			body.Velocity = .(0, 0, 2);
			Expect(Math.Abs(body.Velocity.z - 2) < 0.01f, "Velocity sets the body's speed");
			body.enabled = false;
			scene.FixedUpdate();
			Expect(!body.HasBody, "switching it off takes the body out");
			body.enabled = true;
			scene.Update();
			Expect(body.HasBody && body.BodyId != uint32.MaxValue, "switching it on makes a body again");
			crate.SetActive(false);
			scene.FixedUpdate();
			Expect(!body.HasBody, "an inactive object has no body");
			crate.SetActive(true);
			scene.FixedUpdate();
			Expect(body.HasBody, "and it comes back with the object");
			for (int i < 240)
				scene.FixedUpdate();
			Expect(Math.Abs(crate.Transform.Position.y - 0.5f) < 0.1f, scope $"it rests on the ground ({crate.Transform.Position.y})");
			// Built in code: the body is made at the next Starts, with every component there.
			let ball = scene.CreateGameObject("Ball");
			ball.Transform.Position = .(4, 2, 0);
			let ballBody = ball.AddComponent<Rigidbody>();
			ball.AddComponent<SphereCollider>();
			Expect(!ballBody.HasBody, "a body waits for the next Starts");
			scene.FixedUpdate();
			Expect(ballBody.HasBody, "and is made with its collider");
			ball.RemoveComponent<Rigidbody>();
			Expect(ComponentState<RigidbodyState>.Count == before + 1, "RemoveComponent takes its body out");
			let pushed = id != uint32.MaxValue;
			Expect(pushed, "the body had an id");
			scene.StopPlay();
			Expect(!body.HasBody, "stopping play takes the body out");
			let text = scope String();
			SceneSerializer.Save(scene, text);
			Expect(text.Contains("component Tallow.Rigidbody enabled 1") && text.Contains("field mass 4"), "a Rigidbody saves as before");
			let loaded = scope Scene();
			SceneSerializer.Load(loaded, text);
			Expect(loaded.Find("Crate").GetComponent<Rigidbody>().mass == 4, "and loads");
		}
		Scene.Active = previous;
		Expect(ComponentState<RigidbodyState>.Count == before, "bodies are freed with their scene");
	}

	/// Character Controller: a Jolt character made once the scene plays, walking, shape changes, switching off.
	static void CharacterChecks()
	{
		let before = ComponentState<CharacterControllerState>.Count;
		let previous = Scene.Active;
		{
			let scene = scope Scene();
			Scene.Active = scene;
			let ground = scene.CreateGameObject("Ground");
			ground.Transform.Position = .(0, -0.5f, 0);
			ground.AddComponent<BoxCollider>().size = .(40, 1, 40);
			let walker = scene.CreateGameObject("Walker");
			walker.Transform.Position = .(0, 1.5f, 0);
			let controller = walker.AddComponent<CharacterController>();
			Expect(controller.shape == .Capsule && controller.radius == 0.35f && controller.height == 1.8f && controller.canSwim && !controller.HasCharacter, "a Character Controller has its defaults and no character before play");
			controller.Move(.(1, 0, 0), 1);
			Expect(Math.Abs(walker.Transform.Position.x - 1) < 0.0001f, "with no character, Move shifts the transform");
			walker.Transform.Position = .(0, 1.5f, 0);
			scene.StartPlay();
			scene.Update();
			Expect(controller.HasCharacter, "playing makes the character");
			for (int i < 60)
			{
				controller.SimpleMove(.Zero, Time.FixedDeltaTime);
				scene.FixedUpdate();
			}
			Expect(controller.IsGrounded && Math.Abs(walker.Transform.Position.y - 0.9f) < 0.1f, scope $"it falls and stands on the ground ({walker.Transform.Position.y})");
			for (int i < 30)
			{
				controller.SimpleMove(.(2, 0, 0), Time.FixedDeltaTime);
				scene.FixedUpdate();
			}
			Expect(walker.Transform.Position.x > 0.8f, scope $"SimpleMove walks ({walker.Transform.Position.x})");
			Expect(controller.SetCapsule(0.3f, 1.2f), "SetCapsule takes a shape that fits");
			Expect(controller.radius == 0.3f && controller.height == 1.2f, "and writes the settings");
			let wall = scene.CreateGameObject("Wall");
			wall.Transform.Position = .(walker.Transform.Position.x, 0.9f, 0);
			wall.AddComponent<BoxCollider>().size = .(0.2f, 0.2f, 0.2f);
			scene.FixedUpdate();
			controller.enabled = false;
			scene.FixedUpdate();
			Expect(!controller.HasCharacter, "switching it off takes the character away");
			controller.enabled = true;
			scene.Update();
			Expect(controller.HasCharacter, "and on makes it again");
			controller.Teleport(.(5, 2, 5));
			Expect(walker.Transform.Position == .(5, 2, 5), "Teleport moves it");
			let missing = ground.GetComponent<CharacterController>();
			missing.Teleport(.(1, 1, 1));
			Expect(!missing.HasCharacter && missing.Velocity == .Zero && ground.Transform.Position == .(0, -0.5f, 0), "a missing controller reads as none, and Teleport on it does nothing");
			scene.StopPlay();
			Expect(!controller.HasCharacter && scene.Physics.Controllers.Count == 0, "stopping play takes the character away");
			let text = scope String();
			SceneSerializer.Save(scene, text);
			Expect(text.Contains("component Tallow.CharacterController enabled 1") && text.Contains("field radius 0.3"), "a Character Controller saves as before");
			walker.RemoveComponent<CharacterController>();
			Expect(ComponentState<CharacterControllerState>.Count == before, "RemoveComponent frees its state");
		}
		Scene.Active = previous;
		Expect(ComponentState<CharacterControllerState>.Count == before, "characters are freed with their scene");
	}

	/// Viewmodel Pose: the edit-mode preview through the handle's OnValidate (from the scene loader too), coming up
	/// to aim in the Frame.Viewmodels step, and Kick.
	static void ViewmodelChecks()
	{
		let previous = Scene.Active;
		{
			let scene = scope Scene();
			Scene.Active = scene;
			let camera = scene.CreateGameObject("Camera");
			let arms = scene.CreateGameObject("Arms", camera.Transform);
			let pose = arms.AddComponent<ViewmodelPose>();
			Expect(pose.aimSpeed == 8 && pose.preview == 0 && !pose.aiming, "a pose has its defaults");
			pose.preview = 1;
			HandleComponents.Find(typeof(ViewmodelPose)).onValidate(arms);
			Expect((arms.Transform.LocalPosition - pose.aimPosition).Length < 0.001f, "OnValidate shows the preview pose while editing");
			let text = scope String();
			SceneSerializer.Save(scene, text);
			let loaded = scope Scene();
			SceneSerializer.Load(loaded, text);
			let copy = loaded.Find("Arms");
			copy.Transform.LocalPosition = .Zero;
			SceneSerializer.Load(loaded, text);
			Expect((loaded.Find("Arms").Transform.LocalPosition - pose.aimPosition).Length < 0.001f, "reading a scene runs it too");
			pose.preview = 0;
			scene.StartPlay();
			pose.aiming = true;
			for (int i < 60)
			{
				Time.DeltaTime = 1 / 30.0f;
				scene.Update();
			}
			Expect((arms.Transform.LocalPosition - pose.aimPosition).Length < 0.002f && pose.AimBlend > 0.99f, scope $"aiming brings it to the aim pose ({arms.Transform.LocalPosition})");
			pose.Kick();
			scene.Update();
			Expect(arms.Transform.LocalPosition.z < pose.aimPosition.z - 0.01f, "Kick pushes it back");
			scene.StopPlay();
		}
		Scene.Active = previous;
	}

	/// Saved Transform: its own save (static SaveFields) under the old key, the place and a body's velocity coming
	/// back, and a velocity loaded before the body exists given on the first tick.
	static void SavedTransformChecks()
	{
		let previous = Scene.Active;
		{
			let scene = scope Scene();
			Scene.Active = scene;
			let crate = scene.CreateGameObject("Crate");
			crate.Transform.Position = .(1, 5, 2);
			crate.AddComponent<BoxCollider>();
			let body = crate.AddComponent<Rigidbody>();
			body.useGravity = false;
			let saved = crate.AddComponent<SavedTransform>();
			Expect(saved.positionX && saved.rotation && !saved.scale && saved.velocity, "it has its defaults");
			SaveSystem.SceneStarting(scene);
			scene.StartPlay();
			scene.FixedUpdate();
			var state = body.State;
			state.position = .(4, 5, 2);
			state.linearVelocity = .(3, 0, 0);
			body.SetState(state);
			crate.Transform.Position = .(4, 5, 2);
			let snapshot = SaveSystem.Capture(scene);
			defer delete snapshot;
			let text = scope String();
			snapshot.ToText(text);
			Expect(text.Contains("Tallow.SavedTransform") && text.Contains("velocity"), "a save keeps its place and velocity under its old key");
			state.position = .(-9, 5, 0);
			state.linearVelocity = .Zero;
			body.SetState(state);
			crate.Transform.Position = .(-9, 5, 0);
			SaveSystem.Apply(snapshot, scene);
			let at = crate.Transform.Position;
			Expect(Math.Abs(at.x - 4) < 0.01f && Math.Abs(body.Velocity.x - 3) < 0.01f, scope $"loading puts back its place and sets it moving ({at}, {body.Velocity})");
			scene.StopPlay();
			// Loaded before the body exists: the velocity waits for the first tick.
			SaveSystem.Apply(snapshot, scene);
			scene.StartPlay();
			scene.FixedUpdate();
			Expect(Math.Abs(body.Velocity.x - 3) < 0.01f, scope $"a velocity loaded before the body exists is given on the first tick ({body.Velocity})");
			scene.StopPlay();
		}
		Scene.Active = previous;
	}

	/// Scene Loader: Load On Start (Frame.SceneLoaders) adding a scene, its progress reaching 1, Finished, and a UI
	/// binding finding a handle's field.
	static void SceneLoaderChecks()
	{
		let previous = Scene.Active;
		let path = scope String()..AppendF("{}/../build/check_room.tscene", Assets.ProjectPath);
		{
			let room = scope Scene();
			room.CreateGameObject("Room Box");
			let text = scope String();
			SceneSerializer.Save(room, text);
			if (System.IO.File.WriteAllText(path, text) case .Err)
			{
				Expect(false, scope $"the check scene could not be written to {path}");
				return;
			}
		}
		{
			let scene = scope Scene();
			Scene.Active = scene;
			let o = scene.CreateGameObject("Loader");
			let loader = o.AddComponent<SceneLoader>();
			Expect(loader.loadOnStart && !loader.additive && loader.activateWhenReady, "a loader has its defaults");
			loader.scene.Set(path);
			loader.additive = true;
			scene.StartPlay();
			for (int i < 300)
			{
				Time.DeltaTime = 1 / 60.0f;
				scene.Update();
				SceneManager.Update(scene);
				if (loader.Finished && scene.Find("Room Box") != null)
					break;
			}
			// The frame after it is done, the loader lets go of it and shows 1.
			scene.Update();
			Expect(loader.Finished && loader.progress == 1 && scene.Find("Room Box") != null, "Load On Start adds the scene");
			let document = o.AddComponent<UIDocument>();
			let shown = scope String();
			Expect(document.ReadBinding("progress", shown) || document.ReadBinding("additive", shown), "a UI binding finds a built-in component's field");
			scene.StopPlay();
		}
		Scene.Active = previous;
		System.IO.File.Delete(path).IgnoreError();
	}

	/// Spawn Point: all data, no state; the chooser's order, teams and start-only points; Place; save and load.
	static void SpawnChecks()
	{
		let previous = Scene.Active;
		{
			let scene = scope Scene();
			Scene.Active = scene;
			SpawnPoint Point(StringView name, Vector3 at, int32 team, bool startOnly = false)
			{
				let o = scene.CreateGameObject(name);
				o.Transform.Position = at;
				let point = o.AddComponent<SpawnPoint>();
				point.team = team;
				point.startOnly = startOnly;
				return point;
			}
			let any = Point("Any", .(0, 0, 0), 0);
			Expect(any.clearRadius == 1 && any.UseCount == 0, "a point has its defaults");
			let red = Point("Red", .(10, 0, 0), 1);
			let line = Point("Red line-up", .(20, 0, 0), 1, true);
			Expect(SpawnPoints.Count(scene) == 2 && SpawnPoints.Count(scene, 1) == 2 && SpawnPoints.Count(scene, 2) == 1, "Count leaves out start-only points and other teams'");
			scene.StartPlay();
			Expect(SpawnPoints.Next(scene, 1) == line && line.UsedThisStart, "the start phase gives a team its line-up first");
			let second = SpawnPoints.Next(scene, 1);
			Expect(second == red, "then its own ordinary point");
			Expect(SpawnPoints.Next(scene, 2) == any, "another team gets the shared one");
			let player = scene.CreateGameObject("Player");
			let placed = SpawnPoints.Place(player, 1);
			Expect(placed && player.Transform.Position == placed.Position && placed.UseCount == 2, "Place moves an object to a point and counts the use");
			scene.StopPlay();
			red.enabled = false;
			Expect(SpawnPoints.Count(scene, 1) == 1, "a switched-off point is not given out");
			let text = scope String();
			SceneSerializer.Save(scene, text);
			Expect(!text.Contains("UseCount") && text.Contains("field startOnly 1"), "it saves its settings, not its use");
			let loaded = scope Scene();
			SceneSerializer.Load(loaded, text);
			let copy = loaded.Find("Red line-up").GetComponent<SpawnPoint>();
			Expect(copy && copy.team == 1 && copy.startOnly && copy.UseCount == 0, "and loads");
		}
		Scene.Active = previous;
	}

	/// Sequence Player: Play On Start (Frame.Sequences), moving a track's object, finishing, the playing count,
	/// Restore When Done putting the object back when it is removed, saving, freeing.
	static void SequenceChecks()
	{
		let before = ComponentState<SequencePlayerState>.Count;
		let previous = Scene.Active;
		let path = scope String()..AppendF("{}/../build/check_slide.tsequence", Assets.ProjectPath);
		if (System.IO.File.WriteAllText(path, "sequence length 1 framerate 30\ntrack transform \"Box\"\n\tkey 0 position 0 0 0 rotation 0 0 0\n\tkey 1 position 10 0 0 rotation 0 0 0\n") case .Err)
		{
			Expect(false, scope $"the check sequence could not be written to {path}");
			return;
		}
		let playing = SequencePlayer.PlayingCount;
		{
			let scene = scope Scene();
			Scene.Active = scene;
			let crate = scene.CreateGameObject("Box");
			let director = scene.CreateGameObject("Director");
			let player = director.AddComponent<SequencePlayer>();
			Expect(!player.playOnStart && player.speed == 1 && player.skippable && player.useCameraShots, "a player has its defaults");
			player.sequence.Set(path);
			player.playOnStart = true;
			bool finished = false;
			player.OnFinished.Add(new [&] () => { finished = true; });
			SaveSystem.SceneStarting(scene);
			scene.StartPlay();
			Time.DeltaTime = 0.5f;
			scene.Update();
			Expect(player.IsPlaying && SequencePlayer.PlayingCount == playing + 1, "Play On Start plays it (Frame.Sequences)");
			scene.Update();
			let x = crate.Transform.Position.x;
			Expect(x > 4 && x < 11, scope $"it moves its track's object (x {x})");
			let saved = SaveSystem.Capture(scene);
			defer delete saved;
			let text = scope String();
			saved.ToText(text);
			Expect(text.Contains("Tallow.SequencePlayer"), "a save keeps where it was");
			scene.Update();
			scene.Update();
			Expect(finished && player.State == .Finished && SequencePlayer.PlayingCount == playing, "it finishes");
			player.restoreWhenDone = true;
			player.Play();
			scene.Update();
			Expect(player.IsPlaying && crate.Transform.Position.x > 0, "it plays again");
			director.RemoveComponent<SequencePlayer>();
			Expect(SequencePlayer.PlayingCount == playing && crate.Transform.Position.x == 0, "removing it stops it and puts the object back");
			Expect(ComponentState<SequencePlayerState>.Count == before, "RemoveComponent frees its state");
			scene.StopPlay();
		}
		Scene.Active = previous;
		Expect(ComponentState<SequencePlayerState>.Count == before && SequencePlayer.PlayingCount == playing, "players are freed with their scene");
		System.IO.File.Delete(path).IgnoreError();
	}

	/// Dialogue Runner: started by Frame.Dialogue (Play On Start), lines, choices, events, and its [Saved] fields
	/// through SaveSystem (the first handle with any: SaveData, OnSaving and OnLoaded).
	static void DialogueChecks()
	{
		let before = ComponentState<DialogueRunnerState>.Count;
		let previous = Scene.Active;
		let path = scope String()..AppendF("{}/../build/check_talk.tdialogue", Assets.ProjectPath);
		if (System.IO.File.WriteAllText(path, "speaker a \"A\"\n\nnode start\n\tsay a \"Hello\"\n\tchoice \"Yes\" yes\n\tchoice \"No\" no\nnode yes\n\tadd agreed 1\n\tsay a \"Good\"\n\tevent Agreed 2\nnode no\n\tsay a \"Bye\"\n") case .Err)
		{
			Expect(false, scope $"the check dialogue could not be written to {path}");
			return;
		}
		DialogueVariables.Clear();
		{
			let scene = scope Scene();
			Scene.Active = scene;
			let guide = scene.CreateGameObject("Guide");
			let talk = guide.AddComponent<DialogueRunner>();
			Expect(talk.startNode == "start" && !talk.playOnStart && talk.readingSpeed == 15 && talk.savedNode == -1 && talk.syncNode == -1, "a runner has its defaults");
			talk.dialogue.Set(path);
			talk.playOnStart = true;
			talk.showLines = false;
			talk.acceptInput = false;
			float agreed = 0;
			talk.OnEvent.Add(new [&] (name, value) => { if (name == "Agreed") agreed = value; });
			SaveSystem.SceneStarting(scene);
			scene.StartPlay();
			Time.DeltaTime = 0.1f;
			scene.Update();
			Expect(talk.IsPlaying && talk.View == .Line && talk.Line != null && talk.Line.text == "Hello", "Play On Start plays it (Frame.Dialogue)");
			talk.Advance();
			Expect(talk.View == .Choices && talk.Choices.Count == 2, "then offers its answers");
			talk.Choose(0);
			Expect(talk.Line != null && talk.Line.text == "Good" && DialogueVariables.Get("agreed") == 1, "an answer goes to its node");
			talk.Advance();
			scene.Update();
			Expect(agreed == 2 && !talk.IsPlaying, scope $"its event reaches the game ({agreed})");
			let saved = SaveSystem.Capture(scene);
			defer delete saved;
			let text = scope String();
			saved.ToText(text);
			Expect(text.Contains("Tallow.DialogueRunner") && text.Contains("agreed"), "a save keeps its [Saved] fields (OnSaving ran)");
			DialogueVariables.Clear();
			talk.savedVariables.Clear();
			SaveSystem.Apply(saved, scene);
			Expect(talk.savedVariables.Contains("agreed") && DialogueVariables.Get("agreed") == 1, "and loading puts them back (OnLoaded ran)");
			scene.StopPlay();
			guide.RemoveComponent<DialogueRunner>();
			Expect(ComponentState<DialogueRunnerState>.Count == before, "RemoveComponent frees its state");
		}
		Scene.Active = previous;
		DialogueVariables.Clear();
		Expect(ComponentState<DialogueRunnerState>.Count == before, "runners are freed with their scene");
		System.IO.File.Delete(path).IgnoreError();
	}

	/// Behavior Tree Runner: owned text settings, started and ticked by the Frame.Behaviour step (Home, events in and
	/// out), not ticked while switched off, save and load, freeing.
	static void BehaviourChecks()
	{
		let before = ComponentState<BehaviorTreeRunnerState>.Count;
		let previous = Scene.Active;
		// A tree in the build folder (not the project's assets): an Alarm for each Hit.
		let path = scope String()..AppendF("{}/../build/check_alarm.tbt", Assets.ProjectPath);
		if (System.IO.File.WriteAllText(path, "tree \"Alarm\"\nnode 1 root 0 0\nnode 2 sequence 0 110\nnode 3 event.received -130 240 \"Hit\" \"1\" \"true\"\nnode 4 event.send 130 240 \"Alarm\"\nlink 1 2\nlink 2 3\nlink 2 4\n") case .Err)
		{
			Expect(false, scope $"the check tree could not be written to {path}");
			return;
		}
		{
			let scene = scope Scene();
			Scene.Active = scene;
			let guard = scene.CreateGameObject("Guard");
			guard.Transform.Position = .(3, 0, 4);
			let runner = guard.AddComponent<BehaviorTreeRunner>();
			Expect(runner.tree.IsEmpty && runner.tickInterval == 0 && runner.restartWhenDone && runner.startValues.IsEmpty, "a runner has its defaults");
			runner.tree.Set(path);
			runner.startValues.Set("ammo 3");
			int alarms = 0;
			runner.OnTreeEvent.Add(new [&] (name) => { if (name == "Alarm") alarms++; });
			scene.StartPlay();
			Time.DeltaTime = 0.1f;
			scene.Update();
			Expect(runner.TreeData != null && runner.Home == Vector3(3, 0, 4) && runner.TickCount == 1, "playing starts it (Home, its tree) and ticks it");
			Expect(runner.Blackboard.GetNumber("ammo") == 3, "Start Values go on its blackboard");
			scene.Update();
			Expect(alarms == 0, "no Hit, no Alarm");
			runner.SendEvent("Hit");
			scene.Update();
			scene.Update();
			Expect(alarms == 1, scope $"a Hit gives one Alarm ({alarms})");
			runner.enabled = false;
			let ticks = runner.TickCount;
			scene.Update();
			Expect(runner.TickCount == ticks, "switched off, it does not tick");
			runner.enabled = true;
			scene.StopPlay();
			let text = scope String();
			SceneSerializer.Save(scene, text);
			let loaded = scope Scene();
			SceneSerializer.Load(loaded, text);
			let copy = loaded.Find("Guard").GetComponent<BehaviorTreeRunner>();
			Expect(copy && copy.tree == path && copy.startValues == "ammo 3", "it saves and loads");
			guard.RemoveComponent<BehaviorTreeRunner>();
			Expect(ComponentState<BehaviorTreeRunnerState>.Count == before, "RemoveComponent frees its state");
		}
		Scene.Active = previous;
		Expect(ComponentState<BehaviorTreeRunnerState>.Count == before, "runners are freed with their scene");
		System.IO.File.Delete(path).IgnoreError();
	}

	/// Navigation Agent: an ObjectRef to its surface (saved as the object, none once the object goes), walking a baked
	/// path in the Frame.Navigation step, the crowd, switching off, and freeing.
	static void NavigationChecks()
	{
		let before = ComponentState<NavigationAgentState>.Count;
		let previous = Scene.Active;
		{
			let scene = scope Scene();
			Scene.Active = scene;
			let floor = scene.CreateGameObject("Floor");
			floor.Transform.Position = .(0, -0.1f, 0);
			floor.AddComponent<BoxCollider>().size = .(24, 0.2f, 24);
			let area = scene.CreateGameObject("Area");
			// A surface's box runs from its position by its size.
			area.Transform.Position = .(-10, -0.5f, -10);
			let surface = area.AddComponent<NavigationSurface>();
			surface.size = .(20, 4, 20);
			surface.cellSize = 0.4f;
			surface.includeRenderMeshes = false;
			Expect(surface.Bake() && surface.Data != null, "a surface bakes over a box floor");
			let walker = scene.CreateGameObject("Walker");
			walker.Transform.Position = .(-5, 0, -5);
			let agent = walker.AddComponent<NavigationAgent>();
			Expect(!agent.surface.IsSet && agent.radius == 0.4f && agent.useLinks, "an agent has its defaults");
			agent.surface = surface;
			Expect(agent.surface.id == area.Id && agent.Surface == surface, "its surface is an ObjectRef to the surface's object");
			Expect(scene.NavigationCrowd.Query(walker.Transform.Position, 1).Contains(agent.Runtime), "it is in the scene's crowd");
			scene.StartPlay();
			agent.SetDestination(.(5, 0, 5), 4, 0.3f);
			for (int i < 60)
			{
				Time.DeltaTime = 0.1f;
				scene.Update();
				if (agent.HasArrived)
					break;
			}
			let at = walker.Transform.Position;
			Expect(agent.HasArrived && Math.Abs(at.x - 5) < 0.5f && Math.Abs(at.z - 5) < 0.5f, scope $"Frame.Navigation walks it to its destination (at {at})");
			agent.SetDestination(.(-5, 0, 5), 4, 0.3f);
			Time.DeltaTime = 0.1f;
			scene.Update();
			agent.enabled = false;
			scene.Update();
			Expect(agent.Path.IsEmpty && !agent.HasArrived, "switching it off stops it, as OnDisable did");
			agent.enabled = true;
			scene.StopPlay();
			let text = scope String();
			SceneSerializer.Save(scene, text);
			Expect(text.Contains(scope $"field surface {area.Id} 0"), "the reference saves as the object and component");
			let loaded = scope Scene();
			SceneSerializer.Load(loaded, text);
			let copy = loaded.Find("Walker").GetComponent<NavigationAgent>();
			Expect(copy && copy.Surface != null && copy.Surface == loaded.Find("Area").GetComponent<NavigationSurface>(), "and loads, pointing at the loaded surface");
			scene.Destroy(area);
			scene.Update();
			Expect(agent.Surface == null, "a destroyed surface reads as none");
			walker.RemoveComponent<NavigationAgent>();
			Expect(scene.NavigationCrowd.Query(.(-5, 0, 5), 50).IsEmpty, "removing it takes it out of the crowd");
		}
		Scene.Active = previous;
		Expect(ComponentState<NavigationAgentState>.Count == before, "agents are freed with their scene");
	}

	/// Animator: owned text settings, started and moved on by the Frame.Animators step, a clip posing child bones.
	static void AnimatorChecks()
	{
		let before = ComponentState<AnimatorState>.Count;
		let previous = Scene.Active;
		{
			let scene = scope Scene();
			Scene.Active = scene;
			let rig = scene.CreateGameObject("Rig");
			let arm = scene.CreateGameObject("Arm", rig.Transform);
			let animator = rig.AddComponent<Animator>();
			Expect(animator.defaultClip == "Idle" && animator.clips.IsEmpty && animator.speed == 1 && animator.controller.IsEmpty, "an Animator has its defaults");
			animator.clips.Append("Animations/none.tanim");
			Expect(animator.clips == "Animations/none.tanim", "its clip list is text it owns");
			Expect(rig.GetComponentInChildren<Animator>() == animator && !arm.GetComponentInChildren<Animator>(), "GetComponentInChildren finds a built-in component");
			// A clip made in code: the arm turns 90 degrees about Y over a second.
			let clip = scope AnimationClip();
			clip.name.Set("Turn");
			clip.duration = 1;
			clip.loop = true;
			let track = clip.AddTrack("Arm");
			track.keys.Add(.() { time = 0, rotation = .Identity, scale = .(1, 1, 1) });
			track.keys.Add(.() { time = 1, rotation = Quaternion.AngleAxis(90, .Up), scale = .(1, 1, 1) });
			scene.StartPlay();
			Time.DeltaTime = 0.5f;
			scene.Update();
			Expect(animator.Runtime.[Friend]mStarted, "playing starts the Animator (Bind)");
			animator.SampleClip(clip, 0.5f);
			let turned = arm.Transform.LocalRotation;
			Expect(Math.Abs(Quaternion.Dot(turned, Quaternion.AngleAxis(45, .Up))) > 0.999f, "SampleClip poses the child bone");
			animator.SetFloat("Speed", 2);
			Expect(animator.GetFloat("Speed") == 0, "without a controller, parameters are not kept");
			scene.StopPlay();
			Expect(!animator.Runtime.[Friend]mStarted, "stopping play lets it start again next time");
			let text = scope String();
			SceneSerializer.Save(scene, text);
			Expect(text.Contains("component Tallow.Animator enabled 1") && text.Contains("field clips \"Animations/none.tanim\""), "an Animator saves as before");
			let loaded = scope Scene();
			SceneSerializer.Load(loaded, text);
			let copy = loaded.Find("Rig").GetComponent<Animator>();
			Expect(copy && copy.clips == "Animations/none.tanim" && copy.defaultClip == "Idle", "and loads");
			rig.RemoveComponent<Animator>();
			Expect(ComponentState<AnimatorState>.Count == before, "RemoveComponent frees its state");
		}
		Scene.Active = previous;
		Expect(ComponentState<AnimatorState>.Count == before, "animators are freed with their scene");
	}

	/// Water and Floater: the surface from the data, Water.At, [Sync] fields of handle data, save and load.
	static void WaterChecks()
	{
		let before = ComponentState<WaterState>.Count;
		{
			let scene = scope Scene();
			let pond = scene.CreateGameObject("Pond");
			pond.Transform.Position = .(0, 2, 0);
			let water = pond.AddComponent<Water>();
			Expect(water.look == .Realistic && water.size == .(40, 40) && water.depth == 10 && water.waveHeight == 0.4f, "a Water has its defaults");
			water.waveHeight = 0;
			Expect(water.SurfaceAt(.(3, 0, 3), 0.0, let still, let up, ?) && Math.Abs(still - 2) < 0.0001f && (up - Vector3.Up).Length < 0.0001f, "still water is flat at the object's height");
			water.waveHeight = 1;
			float lowest = float.MaxValue, highest = float.MinValue;
			for (int i < 40)
			{
				water.SurfaceAt(.(i * 0.7f, 0, 1), 0.0, let height, ?, ?);
				lowest = Math.Min(lowest, height);
				highest = Math.Max(highest, height);
			}
			Expect(highest - lowest > 0.3f && highest < 3.01f && lowest > 0.99f, scope $"waves follow a changed setting ({lowest} to {highest})");
			Expect(water.Contains(.(0, 0, 0)) && !water.Contains(.(0, -9, 0)) && !water.Contains(.(30, 0, 0)), "Contains: below the surface, above the bottom, over the water");
			Expect(Water.At(scene, .(1, 1, 1)) == water && !Water.At(scene, .(100, 1, 1)), "Water.At finds it, and not where there is none");
			let deeper = scene.CreateGameObject("Higher pond");
			deeper.Transform.Position = .(0, 3, 0);
			let higher = deeper.AddComponent<Water>();
			higher.size = .(4, 4);
			Expect(Water.At(scene, .(0, 1, 0)) == higher, "Water.At picks the highest level");
			higher.enabled = false;
			Expect(Water.At(scene, .(0, 1, 0)) == water, "a switched-off Water is not found");
			deeper.SetActive(false);
			higher.enabled = true;
			Expect(Water.At(scene, .(0, 1, 0)) == water, "nor one on an inactive object");
			// [Sync] fields of a built-in component are found by offset, so they follow the data when it moves.
			let identity = pond.AddComponent<NetworkIdentity>();
			let slots = NetworkSync.[Friend]Slots(identity);
			int found = 0;
			for (let slot in slots.slots)
			{
				if (slot.dataIndex == ComponentId<WaterData>.Index)
					found++;
			}
			Expect(found >= 25, scope $"Water's [Sync] fields are network slots ({found})");
			int heightSlot = -1;
			for (int i < slots.slots.Count)
			{
				if (slots.slots[i].dataIndex >= 0 && slots.slots[i].Ptr == &water.waveHeight)
					heightSlot = i;
			}
			Expect(heightSlot >= 0, "the wave height has a slot");
			let floater = pond.AddComponent<Floater>();
			Expect(floater.buoyancy == 1.6f && floater.drag == 1, "a Floater has its defaults");
			Expect(heightSlot >= 0 && slots.slots[heightSlot].Ptr == &water.waveHeight && *(float*)slots.slots[heightSlot].Ptr == 1, "the slot follows the data to its new table");
			NetworkSync.Forget(identity);
			let text = scope String();
			SceneSerializer.Save(scene, text);
			Expect(text.Contains("component Tallow.Water enabled 1") && text.Contains("field waveHeight 1") && text.Contains("component Tallow.Floater"), "Water and Floater save as before");
			let loaded = scope Scene();
			SceneSerializer.Load(loaded, text);
			let copy = loaded.Find("Pond").GetComponent<Water>();
			Expect(copy && copy.waveHeight == 1 && loaded.Find("Pond").GetComponent<Floater>(), "Water and Floater load");
			pond.RemoveComponent<Water>();
			Expect(ComponentState<WaterState>.Count == before, "RemoveComponent frees the waves (the only Water whose surface was asked for)");
		}
		Expect(ComponentState<WaterState>.Count == before, "waves are freed with their scene");
	}

	/// Foliage: owned text in component data (the packed plants), plants kept in FoliageState, Sync and Read.
	static void FoliageChecks()
	{
		let before = ComponentState<FoliageState>.Count;
		{
			let scene = scope Scene();
			let field = scene.CreateGameObject("Field");
			field.Transform.Position = .(10, 0, 0);
			let grass = field.AddComponent<Foliage>();
			Expect(grass.mesh == "builtin:grass" && grass.density == 6 && grass.plants != null && grass.plants.IsEmpty && grass.Count == 0, "a Foliage has its defaults");
			let other = scene.CreateGameObject("Bushes").AddComponent<Foliage>();
			Expect(Internal.UnsafeCastToPtr(grass.plants) != Internal.UnsafeCastToPtr(other.plants), "each Foliage owns its own plants text");
			let added = grass.Paint(.(10, 0, 0), 3);
			Expect(added > 10 && grass.Count == added, scope $"Paint scatters plants ({added})");
			Expect(grass.plants.IsEmpty, "the packed text is written only by Sync");
			let world = grass.PositionOf(0);
			Expect(Math.Abs(world.x - 10) <= 3.01f && Math.Abs(world.y) < 0.001f, "plants are placed in the world round the brush");
			grass.Add(.(11, 0, 1), 90, 2);
			Expect(grass.Count == added + 1, "Add places one plant");
			let erased = grass.Erase(.(11, 0, 1), 0.01f);
			Expect(erased >= 1 && grass.Count == added + 1 - erased, "Erase removes the plants inside its circle");
			let count = grass.Count;
			let visible = scope List<int32>();
			let frustum = Frustum(Matrix4.Perspective(70, 1, 0.1f, 200, false) * Matrix4.LookAt(.(10, 2, -10), .(10, 0, 0), .Up), false);
			grass.State.Visible(.(10, 2, -10), frustum, visible);
			Expect(visible.Count == count, scope $"every plant near the camera is visible ({visible.Count} of {count})");
			Expect(scene.Components<Foliage>(.. scope .()).Count == 2, "Components<Foliage> lists both");
			let text = scope String();
			Foliage.SyncAll(scene);
			Expect(!grass.plants.IsEmpty && grass.plants.Length >= count * 21, "Sync packs the plants (16 bytes each, as base 64)");
			SceneSerializer.Save(scene, text);
			Expect(text.Contains("component Tallow.Foliage enabled 1") && text.Contains("field plants "), "a Foliage saves as before, with its plants");
			let loaded = scope Scene();
			SceneSerializer.Load(loaded, text);
			let copy = loaded.Find("Field").GetComponent<Foliage>();
			Expect(copy && copy.Count == count && copy.plants == grass.plants, "a Foliage loads with its plants");
			Expect((copy.PositionOf(0) - grass.PositionOf(0)).Length < 0.001f, "a loaded plant stands where it stood");
			// Undo writes the text in place; the plants follow it the next time they are used.
			copy.plants.Clear();
			Expect(copy.Count == 0, "plants are read again when the text changes");
			copy.plants.Set(grass.plants);
			Expect(copy.Count == count, "and back");
			let info = HandleComponents.Find(typeof(Foliage));
			HandleComponents.Reset(field, info);
			Expect(grass.plants != null && grass.plants.IsEmpty && grass.Count == 0, "Reset gives the Foliage empty text of its own");
			field.RemoveComponent<Foliage>();
			Expect(ComponentState<FoliageState>.Count == before + 2, "RemoveComponent frees the plants");
		}
		Expect(ComponentState<FoliageState>.Count == before, "plants are freed with their scene");
	}

	/// Line and Trail Renderer: a list owned by component data, and the hidden child that draws them.
	static void LineChecks()
	{
		let lines = ComponentState<LineState>.Count;
		let trails = ComponentState<TrailState>.Count;
		{
			let scene = scope Scene();
			let a = scene.CreateGameObject("A");
			let b = scene.CreateGameObject("B");
			let first = a.AddComponent<LineRenderer>();
			let second = b.AddComponent<LineRenderer>();
			Expect(first.PositionCount == 2 && first.GetPosition(1) == .(0, 0, 1) && first.material.IsEmpty, "a Line Renderer starts with its two default points");
			Expect(Internal.UnsafeCastToPtr(first.positions) != Internal.UnsafeCastToPtr(second.positions), "each line owns its own point list");
			first.SetPositions(scope Vector3[](.(0, 0, 0), .(3, 0, 0), .(3, 4, 0)));
			Expect(first.PositionCount == 3 && Math.Abs(first.Length - 7) < 0.001f && second.PositionCount == 2, "SetPositions changes that line only");
			second.AddPosition(.(0, 0, 3));
			Expect(second.PositionCount == 3 && second.GetPosition(2) == .(0, 0, 3), "AddPosition adds a point at the end");
			second.ClearPositions();
			second.AddPosition(.Zero);
			second.AddPosition(.(0, 0, 1));
			Expect(second.PositionCount == 2, "ClearPositions empties the line");
			let info = HandleComponents.Find(typeof(LineRenderer));
			HandleComponents.Assign(b.GetData(info.dataType), a.GetData(info.dataType), info);
			Expect(second.PositionCount == 3 && Internal.UnsafeCastToPtr(first.positions) != Internal.UnsafeCastToPtr(second.positions), "pasting values copies the points, not the list");
			first.SetPosition(0, .(1, 1, 1));
			Expect(second.GetPosition(0) == .Zero, "and the copy stays as it was");
			HandleComponents.Reset(b, info);
			Expect(second.PositionCount == 2, "Reset brings back the default points");
			LineRenderer.FrameAll(scene);
			Expect(a.Transform.Children.Count == 1 && first.DrawnBy && first.DrawnBy.RuntimeMesh != null, "a frame makes the hidden child that draws it");
			let text = scope String();
			SceneSerializer.Save(scene, text);
			Expect(text.Contains("component Tallow.LineRenderer enabled 1") && !text.Contains("(drawn)"), "a line saves, without its hidden child");
			let loaded = scope Scene();
			SceneSerializer.Load(loaded, text);
			let copy = loaded.Find("A").GetComponent<LineRenderer>();
			Expect(copy && copy.PositionCount == 3 && copy.GetPosition(0) == .(1, 1, 1), "a line loads with its points");
			first.enabled = false;
			LineRenderer.FrameAll(scene);
			Expect(!first.DrawnBy.enabled, "a switched-off line stops drawing");
			a.RemoveComponent<LineRenderer>();
			scene.[Friend]RunDestroyQueue();
			Expect(a.Transform.Children.Count == 0, "removing it removes its hidden child");

			let ball = scene.CreateGameObject("Ball");
			let trail = ball.AddComponent<TrailRenderer>();
			Expect(trail.time == 0.5f && trail.emitting && !trail.showInEditor, "a Trail Renderer has its defaults");
			TrailRenderer.FrameAll(scene);
			Expect(trail.PositionCount == 0, "in the editor it draws nothing unless Show In Editor");
			for (int i < 5)
			{
				ball.Transform.Position = .(i, 0, 0);
				TrailRenderer.LateAll(scene);
			}
			Expect(trail.PositionCount == 5 && trail.GetPosition(4) == .(4, 0, 0), "while playing it leaves points behind");
			trail.enabled = false;
			TrailRenderer.FrameAll(scene);
			Expect(trail.PositionCount == 0, "switched off, it starts afresh");
		}
		Expect(ComponentState<LineState>.Count == lines && ComponentState<TrailState>.Count == trails, "lines and trails are freed with their scene");
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
