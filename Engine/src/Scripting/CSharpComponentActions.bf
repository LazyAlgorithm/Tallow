using System;
using System.Collections;

namespace Tallow;

/// What C# scripts can do with built-in components beyond their fields (the generated handles in
/// Managed/Tallow.API/NativeComponents.Generated.cs carry the fields; NativeComponentActions.cs adds these): play
/// particles, sequences and dialogue, set line points, ask water and cameras. Each takes the object and returns
/// false (or -1) when it has no such component.
[CSharpExpose]
static class CSharpComponentActions
{
	static GameObject Object(uint64 session, uint64 entity) => CSharpRuntime.PhysicsObject(session, entity);

	/// The object's T, not valid when it has none (or there is no object).
	static T Get<T>(GameObject obj) where T : struct, IComponentHandle => obj != null ? obj.GetComponent<T>() : default;

	/// Copies text for C# (UTF-8); the text's length, which may be more than the buffer (call again with more room).
	static int32 Copy(StringView text, Span<uint8> buffer)
	{
		let count = Math.Min(text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}

	[CSharpExpose]
	public static bool ParticlePlay(uint64 session, uint64 entity)
	{
		let obj = Object(session, entity);
		if (obj == null)
			return false;
		let particles = obj.GetComponent<ParticleSystem>();
		if (!particles)
			return false;
		particles.Play();
		return true;
	}

	/// 0 Play, 1 Pause, 2 Resume, 3 Stop, 4 Skip, 5 Seek(time). False without a Sequence Player (or when Play could
	/// not start).
	[CSharpExpose]
	public static bool SequenceControl(uint64 session, uint64 entity, int32 action, float time)
	{
		let obj = Object(session, entity);
		if (obj == null)
			return false;
		let player = obj.GetComponent<SequencePlayer>();
		if (!player)
			return false;
		switch (action)
		{
		case 0: return player.Play();
		case 1: player.Pause();
		case 2: player.Resume();
		case 3: player.Stop();
		case 4: player.Skip();
		case 5: player.Seek(time);
		default: return false;
		}
		return true;
	}

	/// The sequence's time in seconds, negative when it is not playing; NaN without a Sequence Player.
	[CSharpExpose]
	public static float SequenceTime(uint64 session, uint64 entity)
	{
		let obj = Object(session, entity);
		let player = Get<SequencePlayer>(obj);
		if (!player)
			return float.NaN;
		return player.IsPlaying ? player.Time : -1;
	}

	/// Starts the conversation, at node when it is not empty.
	[CSharpExpose]
	public static bool DialoguePlay(uint64 session, uint64 entity, StringView node)
	{
		let obj = Object(session, entity);
		let runner = Get<DialogueRunner>(obj);
		if (!runner)
			return false;
		return node.IsEmpty ? runner.Play() : runner.Play(node);
	}

	/// 0 Advance, 1 Choose(index), 2 Stop.
	[CSharpExpose]
	public static bool DialogueControl(uint64 session, uint64 entity, int32 action, int32 index)
	{
		let obj = Object(session, entity);
		let runner = Get<DialogueRunner>(obj);
		if (!runner)
			return false;
		switch (action)
		{
		case 0: runner.Advance();
		case 1: runner.Choose(index);
		case 2: runner.Stop();
		default: return false;
		}
		return true;
	}

	/// -1 without a Dialogue Runner, 0 not playing, 1 showing a line, 2 waiting for a choice (+ 16 x the number of
	/// choices).
	[CSharpExpose]
	public static int32 DialogueState(uint64 session, uint64 entity)
	{
		let obj = Object(session, entity);
		let runner = Get<DialogueRunner>(obj);
		if (!runner)
			return -1;
		if (!runner.IsPlaying)
			return 0;
		let choices = runner.Choices;
		if (choices != null && choices.Count > 0)
			return 2 + 16 * (int32)choices.Count;
		return runner.Line != null ? 1 : 0;
	}

	/// Text of the conversation now: 0 the line, 1 its speaker's name, 2 choice index's text, 3 the speaker's id.
	/// Its length (see Copy), -1 when there is none.
	[CSharpExpose]
	public static int32 DialogueText(uint64 session, uint64 entity, int32 which, int32 index, Span<uint8> buffer)
	{
		let obj = Object(session, entity);
		let runner = Get<DialogueRunner>(obj);
		if (!runner || !runner.IsPlaying)
			return -1;
		switch (which)
		{
		case 0:
			let line = runner.Line;
			return line != null ? Copy(line.text, buffer) : -1;
		case 1:
			let speaker = runner.Speaker;
			return speaker != null ? Copy(speaker.name, buffer) : (runner.Line != null ? 0 : -1);
		case 2:
			let choices = runner.Choices;
			return (choices != null && index >= 0 && index < choices.Count) ? Copy(choices[index].text, buffer) : -1;
		case 3:
			let line = runner.Line;
			return line != null ? Copy(line.speaker, buffer) : -1;
		default:
			return -1;
		}
	}

	/// Replaces a Line Renderer's points (x, y, z for each).
	[CSharpExpose]
	public static bool LineSetPositions(uint64 session, uint64 entity, Span<float> xyz)
	{
		let obj = Object(session, entity);
		let line = Get<LineRenderer>(obj);
		if (!line || xyz.Length % 3 != 0)
			return false;
		let points = scope Vector3[xyz.Length / 3];
		for (int i < points.Count)
			points[i] = .(xyz[i * 3], xyz[i * 3 + 1], xyz[i * 3 + 2]);
		line.SetPositions(points);
		return true;
	}

	/// Copies a Line Renderer's points (x, y, z each) into xyz as far as it has room; how many points it has, -1
	/// without one.
	[CSharpExpose]
	public static int32 LineGetPositions(uint64 session, uint64 entity, Span<float> xyz)
	{
		let obj = Object(session, entity);
		let line = Get<LineRenderer>(obj);
		if (!line)
			return -1;
		let count = line.PositionCount;
		for (int i < Math.Min(count, xyz.Length / 3))
		{
			let point = line.GetPosition(i);
			xyz[i * 3] = point.x;
			xyz[i * 3 + 1] = point.y;
			xyz[i * 3 + 2] = point.z;
		}
		return (int32)count;
	}

	[CSharpExpose]
	public static bool TrailClear(uint64 session, uint64 entity)
	{
		let obj = Object(session, entity);
		let trail = Get<TrailRenderer>(obj);
		if (!trail)
			return false;
		trail.Clear();
		return true;
	}

	/// A Viewmodel Pose kicks back as a shot does (amount 1 is one shot's worth).
	[CSharpExpose]
	public static bool ViewmodelKick(uint64 session, uint64 entity, float amount)
	{
		let pose = Get<ViewmodelPose>(Object(session, entity));
		if (!pose)
			return false;
		pose.Kick(amount);
		return true;
	}

	/// How far a Viewmodel Pose is into aiming, 0 at the hip to 1 down the sights (eased); -1 when there is none.
	[CSharpExpose]
	public static float ViewmodelAimBlend(uint64 session, uint64 entity)
	{
		let pose = Get<ViewmodelPose>(Object(session, entity));
		return pose ? pose.AimBlend : -1;
	}

	/// 0 Begin loading, 1 Activate (switch to the loaded scene).
	[CSharpExpose]
	public static bool SceneLoaderControl(uint64 session, uint64 entity, int32 action)
	{
		let obj = Object(session, entity);
		let loader = Get<SceneLoader>(obj);
		if (!loader)
			return false;
		switch (action)
		{
		case 0: loader.Begin();
		case 1: loader.Activate();
		default: return false;
		}
		return true;
	}

	/// Sends an event the tree's Wait For Event nodes can take; empty name: reload the tree from its file.
	[CSharpExpose]
	public static bool BehaviorTreeEvent(uint64 session, uint64 entity, StringView name)
	{
		let obj = Object(session, entity);
		let runner = Get<BehaviorTreeRunner>(obj);
		if (!runner)
			return false;
		if (name.IsEmpty)
			runner.Reload();
		else
			runner.SendEvent(name);
		return true;
	}

	/// The water's surface over point: values gets height, normal (xyz) and the water's velocity (xyz); false when
	/// the object has no Water or the point is outside it.
	[CSharpExpose]
	public static bool WaterSurface(uint64 session, uint64 entity, Vector3 point, Span<float> values)
	{
		let obj = Object(session, entity);
		let water = Get<Water>(obj);
		if (!water || values.Length < 7)
			return false;
		if (!water.SurfaceAt(point, let height, let normal, let velocity))
			return false;
		values[0] = height;
		values[1] = normal.x;
		values[2] = normal.y;
		values[3] = normal.z;
		values[4] = velocity.x;
		values[5] = velocity.y;
		values[6] = velocity.z;
		return true;
	}

	/// The object with the Water whose area holds point (0 when none).
	[CSharpExpose]
	public static uint64 WaterAt(uint64 session, Vector3 point)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		if (scene == null)
			return 0;
		let water = Water.At(scene, point);
		return water ? (uint64)water.GameObject.Id : 0;
	}

	/// Switches a Mesh Renderer's material (a .tmat path; empty for none). In a session, on the server or the owner's
	/// machine, every machine follows.
	[CSharpExpose]
	public static bool RendererSetMaterial(uint64 session, uint64 entity, StringView path)
	{
		let renderer = Get<MeshRenderer>(Object(session, entity));
		if (!renderer)
			return false;
		renderer.SetMaterial(path);
		return true;
	}

	/// Sets a property of a Mesh Renderer's own copy of its material (a custom shader property, or "color",
	/// "emissive", "metallic", "roughness", "emissiveIntensity", "cutoff", "tiling", "offset"). Networked as above.
	[CSharpExpose]
	public static bool RendererMaterialValue(uint64 session, uint64 entity, StringView name, Vector4 value)
	{
		let renderer = Get<MeshRenderer>(Object(session, entity));
		if (!renderer || name.IsEmpty)
			return false;
		renderer.SetMaterialValue(name, value);
		return true;
	}

	/// A Mesh Renderer's box in the world: values gets min (xyz) and max (xyz). False without one or with nothing
	/// to draw.
	[CSharpExpose]
	public static bool RendererBounds(uint64 session, uint64 entity, Span<float> values)
	{
		let renderer = Get<MeshRenderer>(Object(session, entity));
		if (!renderer || values.Length < 6 || renderer.ActiveMesh == null)
			return false;
		let bounds = renderer.WorldBounds;
		values[0] = bounds.min.x;
		values[1] = bounds.min.y;
		values[2] = bounds.min.z;
		values[3] = bounds.max.x;
		values[4] = bounds.max.y;
		values[5] = bounds.max.z;
		return true;
	}

	/// How many frames ago a Mesh Renderer was last drawn (in any view or shadow map): 0 this frame or the last,
	/// -1 never, -2 without a renderer.
	[CSharpExpose]
	public static int64 RendererFramesSinceDrawn(uint64 session, uint64 entity)
	{
		let renderer = Get<MeshRenderer>(Object(session, entity));
		if (!renderer)
			return -2;
		let drawn = renderer.LastDrawnFrame;
		if (drawn < 0)
			return -1;
		return Math.Max(Time.FrameCount - 1 - drawn, 0);
	}

	/// The size the game draws at (0, 0 in a headless run).
	[CSharpExpose]
	public static void ScreenSize(Span<float> size)
	{
		if (size.Length >= 2)
		{
			size[0] = Gfx.Width;
			size[1] = Gfx.Height;
		}
	}

	/// A camera's ray through a screen point (pixels from the top left of a width x height screen): values gets the
	/// origin (xyz) and direction (xyz).
	[CSharpExpose]
	public static bool CameraScreenRay(uint64 session, uint64 entity, float x, float y, float width, float height,
		Span<float> values)
	{
		let obj = Object(session, entity);
		let camera = Get<Camera>(obj);
		if (!camera || width <= 0 || height <= 0 || values.Length < 6)
			return false;
		let settings = camera.Data;
		let transform = obj.Transform;
		let aspect = width / height;
		let ndcX = 2 * x / width - 1;
		let ndcY = 1 - 2 * y / height;
		Vector3 origin = transform.Position;
		Vector3 direction = transform.Forward;
		if (settings.orthographic)
			origin = origin + transform.Right * (ndcX * settings.orthographicSize * aspect) +
				transform.Up * (ndcY * settings.orthographicSize);
		else
		{
			let tangent = Math.Tan(settings.fieldOfView * Math.PI_f / 360);
			direction = (direction + transform.Right * (ndcX * tangent * aspect) + transform.Up * (ndcY * tangent)).Normalized;
		}
		values[0] = origin.x;
		values[1] = origin.y;
		values[2] = origin.z;
		values[3] = direction.x;
		values[4] = direction.y;
		values[5] = direction.z;
		return true;
	}

	/// Where a world point shows on a width x height screen: values gets x, y (pixels from the top left) and its
	/// distance in front of the camera (negative: behind it).
	[CSharpExpose]
	public static bool CameraWorldToScreen(uint64 session, uint64 entity, Vector3 point, float width, float height,
		Span<float> values)
	{
		let obj = Object(session, entity);
		let camera = Get<Camera>(obj);
		if (!camera || width <= 0 || height <= 0 || values.Length < 3)
			return false;
		let settings = camera.Data;
		let transform = obj.Transform;
		let aspect = width / height;
		let offset = point - transform.Position;
		let depth = Vector3.Dot(offset, transform.Forward);
		var ndcX = Vector3.Dot(offset, transform.Right);
		var ndcY = Vector3.Dot(offset, transform.Up);
		if (settings.orthographic)
		{
			ndcX /= settings.orthographicSize * aspect;
			ndcY /= settings.orthographicSize;
		}
		else
		{
			let tangent = Math.Tan(settings.fieldOfView * Math.PI_f / 360);
			let scale = Math.Abs(depth) < 1e-6f ? 1e-6f : Math.Abs(depth);
			ndcX /= scale * tangent * aspect;
			ndcY /= scale * tangent;
		}
		values[0] = (ndcX + 1) * 0.5f * width;
		values[1] = (1 - ndcY) * 0.5f * height;
		values[2] = depth;
		return true;
	}

	/// The water's surface height over point (its still level where the point is not over it); NaN without Water.
	[CSharpExpose]
	public static float WaterHeight(uint64 session, uint64 entity, Vector3 point)
	{
		let water = Get<Water>(Object(session, entity));
		return water ? water.HeightAt(point) : float.NaN;
	}

	/// Whether body's Rigidbody (or soft body) was in this water at the last physics step: 1 yes, 0 no, -1 when
	/// the object has no Water or body has neither.
	[CSharpExpose]
	public static int32 WaterFloating(uint64 session, uint64 entity, uint64 body)
	{
		let water = Get<Water>(Object(session, entity));
		let other = Object(session, body);
		if (!water || other == null)
			return -1;
		let rigidbody = other.GetComponent<Rigidbody>();
		if (rigidbody.IsValid)
			return water.IsFloating(rigidbody) ? 1 : 0;
		if (let soft = other.GetComponent<SoftBody>())
			return water.IsFloating(soft) ? 1 : 0;
		return -1;
	}

	/// Plays an animation layer over some bones (empty name: stops the layer). False without a Skinned Mesh Renderer.
	[CSharpExpose]
	public static bool SkinnedLayer(uint64 session, uint64 entity, StringView name, StringView bones, float fadeSeconds)
	{
		let skinned = Get<SkinnedMeshRenderer>(Object(session, entity));
		if (!skinned)
			return false;
		if (name.IsEmpty)
			skinned.StopLayer(fadeSeconds);
		else
			skinned.PlayLayer(name, bones, fadeSeconds);
		return true;
	}

	/// Changes a model part: what 0 colour (value rgba), 1 hidden (value.x > 0.5), 2 shadow only (value.x > 0.5).
	[CSharpExpose]
	public static bool SkinnedPart(uint64 session, uint64 entity, StringView part, int32 what, Vector4 value)
	{
		let skinned = Get<SkinnedMeshRenderer>(Object(session, entity));
		if (!skinned || part.IsEmpty)
			return false;
		switch (what)
		{
		case 0: skinned.SetPartColor(part, .(value.x, value.y, value.z, value.w));
		case 1: skinned.SetPartHidden(part, value.x > 0.5f);
		case 2: skinned.SetPartShadowOnly(part, value.x > 0.5f);
		default: return false;
		}
		return true;
	}

	/// Gives model part index its own material (a .tmat path; empty: the model's own).
	[CSharpExpose]
	public static bool SkinnedPartMaterial(uint64 session, uint64 entity, int32 index, StringView path)
	{
		let skinned = Get<SkinnedMeshRenderer>(Object(session, entity));
		if (!skinned || index < 0 || index >= skinned.PartCount)
			return false;
		skinned.SetPartMaterial(index, path);
		return true;
	}

	/// How many parts the model has (-1 without a Skinned Mesh Renderer).
	[CSharpExpose]
	public static int32 SkinnedPartCount(uint64 session, uint64 entity)
	{
		let skinned = Get<SkinnedMeshRenderer>(Object(session, entity));
		return skinned ? (int32)skinned.PartCount : -1;
	}

	/// which 0: part index's name; 1: the material part (by name) uses. UTF-8 into buffer; the full length, -1 for none.
	[CSharpExpose]
	public static int32 SkinnedPartText(uint64 session, uint64 entity, int32 which, int32 index, StringView part, Span<uint8> buffer)
	{
		let skinned = Get<SkinnedMeshRenderer>(Object(session, entity));
		if (!skinned)
			return -1;
		if (which == 0)
			return index >= 0 && index < skinned.PartCount ? Copy(skinned.PartName(index), buffer) : -1;
		let path = scope String();
		skinned.GetPartMaterial(part, path);
		return Copy(path, buffer);
	}

	/// The object of bone joint (when the renderer exposes its bones as objects); 0 when none.
	[CSharpExpose]
	public static uint64 SkinnedBone(uint64 session, uint64 entity, int32 joint)
	{
		let skinned = Get<SkinnedMeshRenderer>(Object(session, entity));
		if (!skinned)
			return 0;
		let bone = skinned.BoneAt(joint);
		return bone != null && bone.GameObject != null ? (uint64)bone.GameObject.Id : 0;
	}

	/// Moves a character as a swimmer (no gravity; jumpSpeed lifts it out at the surface). False without one.
	[CSharpExpose]
	public static bool CharacterSwim(uint64 session, uint64 entity, Vector3 velocity, float deltaTime, float jumpSpeed)
	{
		let controller = Get<CharacterController>(Object(session, entity));
		if (!controller.IsValid)
			return false;
		controller.Swim(velocity, deltaTime, jumpSpeed);
		return true;
	}

	/// Sets a compute effect's vector (or colour) input by name. False without a Compute Effect.
	[CSharpExpose]
	public static bool ComputeSetVector(uint64 session, uint64 entity, StringView name, Vector4 value)
	{
		let effect = Get<ComputeEffect>(Object(session, entity));
		if (!effect || name.IsEmpty)
			return false;
		effect.SetVector(name, value);
		return true;
	}

	/// Runs a compute effect once now (for one with Every Frame off). False without one, or when it could not run.
	[CSharpExpose]
	public static bool ComputeStep(uint64 session, uint64 entity)
	{
		let effect = Get<ComputeEffect>(Object(session, entity));
		if (!effect)
			return false;
		return effect.Step();
	}

	/// Foliage brush: 0 Paint (radius, amount), 1 Erase (radius), 2 Add one plant (a = turn degrees, b = scale),
	/// 3 Clear. How many plants were added or removed; -1 without a Foliage.
	[CSharpExpose]
	public static int32 FoliageEdit(uint64 session, uint64 entity, int32 action, Vector3 point, float a, float b)
	{
		let foliage = Get<Foliage>(Object(session, entity));
		if (!foliage)
			return -1;
		switch (action)
		{
		case 0: return foliage.Paint(point, a, b);
		case 1: return foliage.Erase(point, a);
		case 2: foliage.Add(point, a, b); return 1;
		default: foliage.Clear(); return 0;
		}
	}

	/// 0 ResetShape, 1 Fill. False without a Voxel Object.
	[CSharpExpose]
	public static bool VoxelControl(uint64 session, uint64 entity, int32 action)
	{
		let voxels = Get<VoxelObject>(Object(session, entity));
		if (!voxels)
			return false;
		if (action == 0)
			voxels.ResetShape();
		else if (action == 1)
			voxels.Fill();
		else
			return false;
		return true;
	}

	/// Carves a ball out at a point in the object's own space: 1 something went, 0 nothing did, -1 no Voxel Object.
	[CSharpExpose]
	public static int32 VoxelCarveLocal(uint64 session, uint64 entity, Vector3 objectPoint, float radius)
	{
		let voxels = Get<VoxelObject>(Object(session, entity));
		if (!voxels)
			return -1;
		return voxels.CarveLocal(objectPoint, radius) ? 1 : 0;
	}
}
