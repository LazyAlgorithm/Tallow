using System;
using System.Collections;
using Tallow;

namespace ProbePlacementTests;

/// Automatic light and reflection probe placement (docs/probe-placement.md), without a graphics card, on a small
/// yard: a house of two rooms joined by a doorway, with a door to the yard and a shiny floor in one room only; a
/// porch roof on posts; a shiny car and a puddle out in the open; a lamp by the house. Checks what is placed where,
/// what is left out, that placing again replaces only placed probes, and that the baker bakes the placed volumes.
class Program
{
	static int sFailures;
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		if (!pass)
			sFailures++;
		return pass;
	}

	static MeshRenderer Box(Scene scene, StringView name, Vector3 min, Vector3 max, float roughness = 0.85f, float metallic = 0)
	{
		let go = scene.CreateGameObject(name);
		go.Transform.Position = (min + max) * 0.5f;
		go.Transform.LocalScale = max - min;
		let renderer = go.AddComponent<MeshRenderer>();
		renderer.mesh.Set("builtin:cube");
		renderer.roughness = roughness;
		renderer.metallic = metallic;
		renderer.bakedLighting = true;
		return renderer;
	}

	// Room A: x 0 to 8, z 0 to 6; room B: x 8.2 to 14.2; both 3 m high under one roof.
	static void BuildYard(Scene scene)
	{
		Box(scene, "Ground", .(-23, -0.2f, -27), .(37, 0, 33));
		Box(scene, "Roof", .(-0.2f, 3, -0.2f), .(14.4f, 3.2f, 6.2f));
		// Outer walls; room A's front wall has a door to the yard (x 3.4 to 4.6).
		Box(scene, "Front A Left", .(-0.2f, 0, -0.2f), .(3.4f, 3, 0));
		Box(scene, "Front A Right", .(4.6f, 0, -0.2f), .(8.2f, 3, 0));
		Box(scene, "Front A Over Door", .(3.4f, 2.2f, -0.2f), .(4.6f, 3, 0));
		Box(scene, "Front B", .(8.2f, 0, -0.2f), .(14.4f, 3, 0));
		Box(scene, "Back", .(-0.2f, 0, 6), .(14.4f, 3, 6.2f));
		Box(scene, "West", .(-0.2f, 0, 0), .(0, 3, 6));
		Box(scene, "East", .(14.2f, 0, 0), .(14.4f, 3, 6));
		// The wall between the rooms, with a doorway (z 2.4 to 3.6).
		Box(scene, "Middle Left", .(8, 0, 0), .(8.2f, 3, 2.4f));
		Box(scene, "Middle Right", .(8, 0, 3.6f), .(8.2f, 3, 6));
		Box(scene, "Middle Over Door", .(8, 2.2f, 2.4f), .(8.2f, 3, 3.6f));
		// Room A's polished floor.
		Box(scene, "Polished Floor", .(1, 0, 1), .(7, 0.02f, 5), 0.1f);
		// A porch roof on four posts.
		Box(scene, "Porch Roof", .(20, 2.8f, 0), .(26, 3, 6));
		for (let corner in Vector2[?](.(20, 0), .(25.8f, 0), .(20, 5.8f), .(25.8f, 5.8f)))
			Box(scene, "Post", .(corner.x, 0, corner.y), .(corner.x + 0.2f, 2.8f, corner.y + 0.2f));
		// Out in the open: a shiny car and a puddle.
		Box(scene, "Car", .(-12, 0, 13), .(-8, 1.5f, 15), 0.3f, 1);
		Box(scene, "Puddle", .(-11.5f, 0, -11.5f), .(-8.5f, 0.02f, -8.5f), 0.05f);
		// A lamp by the house's west wall.
		let lamp = scene.CreateGameObject("Lamp");
		lamp.Transform.Position = .(-3, 2, 3);
		let light = lamp.AddComponent<Light>();
		light.type = .Point;
		light.range = 6;
		light.intensity = 3;
	}

	static bool Within(Bounds outer, Bounds inner, float slack) =>
		inner.min.x >= outer.min.x - slack && inner.min.y >= outer.min.y - slack && inner.min.z >= outer.min.z - slack &&
		inner.max.x <= outer.max.x + slack && inner.max.y <= outer.max.y + slack && inner.max.z <= outer.max.z + slack;

	static bool Contains(Bounds area, Vector3 p) => p.x >= area.min.x && p.y >= area.min.y && p.z >= area.min.z && p.x <= area.max.x && p.y <= area.max.y && p.z <= area.max.z;

	static int Count(ProbePlan plan, ProbePlan.Kind kind)
	{
		int count = 0;
		for (let probe in plan.reflections)
		{
			if (probe.kind == kind)
				count++;
		}
		return count;
	}

	static ProbePlan Place(Scene scene, ProbePlacementSettings settings)
	{
		let placer = new ProbePlacer(scene, settings);
		placer.Run();
		let plan = placer.Plan;
		placer.Plan = null;
		delete placer;
		return plan;
	}

	static void Placing()
	{
		let scene = scope Scene();
		BuildYard(scene);
		let settings = scope ProbePlacementSettings();
		let plan = Place(scene, settings);
		defer delete plan;
		let report = plan.Describe(.. scope .());
		Console.WriteLine(scope $"  {report}");

		let roomA = Bounds(.(0, 0, 0), .(8, 3, 6));
		let roomB = Bounds(.(8.2f, 0, 0), .(14.2f, 3, 6));
		int inA = 0, inB = 0;
		for (let probe in plan.reflections)
		{
			if (probe.kind != .Room)
				continue;
			if (Contains(roomA, probe.area.Center))
			{
				inA++;
				Check(Within(probe.area, roomA, 0.6f) && Within(roomA, probe.area, 0.6f), scope $"room A's probe is boxed to its walls ({probe.area.min} to {probe.area.max})");
				Check(probe.boxProjection && probe.importance > 0, "with box projection, over the open ground's probes");
				Check(Contains(roomA, probe.eye) && probe.eye.y > 0.9f && probe.eye.y < 2.2f, scope $"and sees from inside the room, about eye height ({probe.eye})");
			}
			if (Contains(roomB, probe.area.Center))
				inB++;
		}
		Check(inA == 1, scope $"room A, with a shiny floor, gets one reflection probe ({inA})");
		Check(inB == 0, "room B, with nothing shiny, gets none");
		int doorBetween = 0, doorOut = 0;
		for (let probe in plan.reflections)
		{
			if (probe.kind != .Doorway)
				continue;
			if (Contains(probe.area, .(8.1f, 1, 3)))
				doorBetween++;
			if (Contains(probe.area, .(4, 1, -0.1f)))
				doorOut++;
			Check(!probe.boxProjection && probe.importance == 2 && probe.area.Size.x < 5 && probe.area.Size.z < 5, scope $"a doorway probe is small and wins over the rooms' ({probe.area.Size})");
		}
		Check(doorBetween == 1, scope $"the doorway between the rooms gets a probe ({doorBetween})");
		Check(doorOut == 1, scope $"and the door to the yard ({doorOut})");
		var car = false, puddle = false;
		for (let probe in plan.reflections)
		{
			if (probe.kind == .Open && Contains(probe.area, .(-10, 0.75f, 14)))
				car = true;
			if (probe.kind == .ShinyFloor && Contains(probe.area, .(-10, 0.5f, -10)))
			{
				puddle = true;
				Check(probe.eye.y > 0.5f && probe.eye.y < 2 && probe.area.Size.x < 6, scope $"the puddle's probe is over it, seeing from just above ({probe.eye})");
			}
		}
		Check(car, "open ground round the shiny car gets a probe");
		Check(puddle, "the shiny puddle gets a probe of its own");
		Check(plan.skippedPlain > 0, scope $"places with nothing shiny are counted as left out ({plan.skippedPlain})");

		// Light probe volumes: one for each room and the porch, more where light changes.
		int roomVolumes = 0, shelterVolumes = 0, detail = 0, nearLamp = 0;
		for (let volume in plan.volumes)
		{
			if (volume.kind == .Room)
				roomVolumes++;
			if (volume.kind == .Shelter)
				shelterVolumes++;
			if (volume.kind == .Detail)
			{
				detail++;
				if (Contains(volume.area, .(-3, 1, 3)))
					nearLamp++;
			}
		}
		Check(roomVolumes == 2, scope $"each room gets a light probe volume ({roomVolumes})");
		Check(shelterVolumes == 1, scope $"the porch roof gets one ({shelterVolumes})");
		Check(detail > 0 && nearLamp > 0, scope $"closer probes where light changes, by the lamp among them ({detail}, {nearLamp} by the lamp)");
		var biggest = 0.0f;
		for (let volume in plan.volumes)
			biggest = Math.Max(biggest, volume.area.Size.x * volume.area.Size.z);
		Check(biggest < 60 * 60 * 0.5f, scope $"no volume covers the whole yard ({biggest:0} m²)");
		Check(plan.VolumeProbes <= settings.maxVolumeProbes && plan.openSpacing == settings.openSpacing, scope $"within the probe budget ({plan.VolumeProbes}), the open space left to the scene's grid");

		// The same scene places the same probes.
		let again = Place(scene, settings);
		defer delete again;
		var same = again.reflections.Count == plan.reflections.Count && again.volumes.Count == plan.volumes.Count;
		for (int i = 0; same && i < plan.reflections.Count; i++)
			same &= again.reflections[i].area.min == plan.reflections[i].area.min && again.reflections[i].eye == plan.reflections[i].eye;
		Check(same, "placing is the same every time");

		// Everywhere, shiny or not.
		let everywhere = scope ProbePlacementSettings();
		everywhere.onlyWhereShiny = false;
		let all = Place(scene, everywhere);
		defer delete all;
		Check(Count(all, .Room) == 2 && Count(all, .Shelter) == 1 && all.skippedPlain == 0, scope $"with Only Where Shiny off, both rooms and the porch get one ({Count(all, .Room)}, {Count(all, .Shelter)})");
		for (let probe in all.reflections)
		{
			if (probe.kind == .Shelter)
				Check(!probe.boxProjection && Contains(probe.area, .(23, 1.5f, 3)), "the porch's probe has no box projection (its sides are open)");
		}
		let none = scope ProbePlacementSettings();
		none.reflectionProbes = false;
		none.lightProbes = false;
		let nothing = Place(scene, none);
		defer delete nothing;
		Check(nothing.reflections.Count == 0 && nothing.volumes.Count == 0, "with both kinds off, nothing");

		// A probe of the user's own over room A: placing leaves the room to it.
		let own = scene.CreateGameObject("Room A Probe");
		own.Transform.Position = .(4, 1.5f, 3);
		own.AddComponent<ReflectionProbe>().size = .(8, 3, 6);
		let ownVolume = scene.CreateGameObject("Room A Volume");
		ownVolume.Transform.Position = .(4, 1.5f, 3);
		ownVolume.AddComponent<LightProbeVolume>().size = .(8, 3, 6);
		let beside = Place(scene, settings);
		defer delete beside;
		int roomsLeft = 0, volumesLeft = 0;
		for (let probe in beside.reflections)
		{
			if (probe.kind == .Room)
				roomsLeft++;
		}
		for (let volume in beside.volumes)
		{
			if (volume.kind == .Room && Contains(volume.area, .(4, 1.5f, 3)))
				volumesLeft++;
		}
		Check(roomsLeft == 0 && volumesLeft == 0 && beside.skippedOwn >= 2, scope $"a room with a probe and a volume of the user's own gets none placed ({beside.skippedOwn} left to theirs)");
		scene.DestroyImmediate(own);
		scene.DestroyImmediate(ownVolume);

		let empty = scope Scene();
		let emptyPlan = Place(empty, settings);
		defer delete emptyPlan;
		Check(emptyPlan.reflections.Count == 0 && emptyPlan.volumes.Count == 0, "an empty scene places nothing");
	}

	static void Applying()
	{
		let scene = scope Scene();
		BuildYard(scene);
		// The user's own probe, which placing must leave alone.
		let mine = scene.CreateGameObject("My Probe");
		mine.Transform.Position = .(30, 1.5f, 30);
		mine.AddComponent<ReflectionProbe>();
		let settings = scope ProbePlacementSettings();
		let plan = Place(scene, settings);
		defer delete plan;
		Check(ProbePlacer.Apply(scene, plan) == 0, "nothing to take away the first time");
		let probes = scene.FindComponents<ReflectionProbe>(.. scope .());
		let volumes = scene.FindComponents<LightProbeVolume>(.. scope .());
		Check(probes.Count == plan.reflections.Count + 1 && volumes.Count == plan.volumes.Count, scope $"the plan's probes are made ({probes.Count - 1} reflection probes, {volumes.Count} volumes)");
		var tagged = true;
		for (let probe in probes)
		{
			if (probe.GameObject != mine)
				tagged &= probe.GameObject.HasTag(ProbePlacer.Tag) && probe.GameObject.Transform.Parent?.GameObject.Name == "Placed Probes";
		}
		Check(tagged, "each tagged as placed, under Placed Probes");
		Check(scene.Environment.bakeProbeSpacing == settings.openSpacing, "the scene's Probe Spacing is set for open space");
		ReflectionProbe room = null;
		for (let probe in probes)
		{
			if (probe.GameObject.Name.StartsWith("Reflection Probe (Room"))
				room = probe;
		}
		Check(room != null && Math.Abs(room.CapturePoint.y - 1.6f) < 0.8f && room.boxProjection, "a room's probe sees from inside it");

		// Keeping one: the user takes its tag off.
		let kept = volumes[0].GameObject;
		kept.RemoveTag(ProbePlacer.Tag);
		let second = Place(scene, settings);
		defer delete second;
		let removed = ProbePlacer.Apply(scene, second);
		let after = scene.FindComponents<ReflectionProbe>(.. scope .());
		let afterVolumes = scene.FindComponents<LightProbeVolume>(.. scope .());
		Check(removed == plan.reflections.Count + plan.volumes.Count - 1, scope $"placing again takes away only the placed ones ({removed})");
		Check(after.Count == second.reflections.Count + 1 && afterVolumes.Count == second.volumes.Count + 1 && !mine.IsDestroyed && !kept.IsDestroyed, "the user's probe and the one they kept stay");
		let roots = scene.FindAllWithTag(ProbePlacer.Tag, .. scope .());
		int holders = 0;
		for (let root in roots)
		{
			if (root.Name == "Placed Probes")
				holders++;
		}
		Check(holders == 1, scope $"one Placed Probes object ({holders})");
		Check(ProbePlacer.Remove(scene) == second.reflections.Count + second.volumes.Count && scene.FindAllWithTag(ProbePlacer.Tag, .. scope .()).Count == 1 && !kept.IsDestroyed, "Remove takes the placed ones away, leaving the object holding the kept one");

		// The baker bakes a grid for each volume.
		ProbePlacer.Apply(scene, second);
		let bake = scope BakeSettings();
		bake.texelsPerMetre = 1;
		bake.samples = 16;
		bake.bounces = 1;
		bake.probeSpacing = 4;
		bake.probeSamples = 64;
		let baker = scope LightBaker(scene, bake);
		baker.Run();
		let total = scene.FindComponents<LightProbeVolume>(.. scope .()).Count;
		Check(baker.Probes != null && baker.Probes.grids.Count == total + 1, scope $"the baker makes the scene's grid and one for each volume ({baker.Probes?.grids.Count})");
		let inRoom = baker.Probes.Pick(.(2, 1.2f, 4));
		Check(inRoom > 0 && baker.Probes.grids[inRoom].Volume < 8.5f * 3.5f * 6.5f * 1.2f, scope $"a thing in room A is lit by the room's volume ({inRoom})");
		let indoors = baker.Probes.Sample(.(2, 1.2f, 4), .(0, 1, 0));
		let outdoors = baker.Probes.Sample(.(-10, 1.2f, 0), .(0, 1, 0));
		let coarse = baker.Probes.Sample(.(2, 1.2f, 4), .(0, 1, 0), 0);
		Check(indoors.x < outdoors.x * 0.7f, scope $"the room under its roof is darker than the open yard ({indoors.x:0.000} against {outdoors.x:0.000}; the scene's grid alone says {coarse.x:0.000})");
	}

	public static int Main(String[] args)
	{
		Placing();
		Applying();
		Console.WriteLine(sFailures == 0 ? "All probe placement checks passed." : scope $"{sFailures} probe placement check(s) failed.");
		return sFailures == 0 ? 0 : 1;
	}
}
