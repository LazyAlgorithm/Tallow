using System;

namespace Tallow;

/// Keeps this object's place in saves: its position (each axis can be left out), rotation and scale, relative to its
/// parent, and with a Rigidbody or Character Controller on the object, how it is moving, so that something falling
/// or rolling when the game was saved carries on when it is loaded. Leave out what never changes: each value left out
/// is a little less to store.
///
/// An object made while the game ran (from a prefab, or a registered network prefab) with this component on it is
/// made again when a save is loaded, so dropped and placed things come back where they were.
///
/// A handle (ComponentHandle): its settings are SavedTransformData's fields. It writes its own save
/// (`static SaveFields`, which SaveSystem finds as it does OnSaving); a velocity loaded before the body exists
/// waits in a SavedTransformState until the first tick.
[Component, HandleFields]
struct SavedTransform : ComponentHandle<SavedTransformData>
{
	/// SaveSystem: what the class's SaveFields did.
	static void SaveFields(GameObject gameObject, SaveIO io)
	{
		let settings = gameObject.GetComponent<SavedTransform>();
		let Transform = gameObject.Transform;
		let positionX = settings.positionX, positionY = settings.positionY, positionZ = settings.positionZ;
		let rotation = settings.rotation, scale = settings.scale, velocity = settings.velocity, angularVelocity = settings.angularVelocity;
		var position = Transform.LocalPosition;
		var turned = Transform.LocalRotation;
		var size = Transform.LocalScale;
		var moved = false;
		if (positionX && io.Key("x"))
		{
			io.Value(ref position.x);
			moved = true;
		}
		if (positionY && io.Key("y"))
		{
			io.Value(ref position.y);
			moved = true;
		}
		if (positionZ && io.Key("z"))
		{
			io.Value(ref position.z);
			moved = true;
		}
		if (rotation && io.Key("rotation"))
		{
			io.Value(ref turned);
			moved = true;
		}
		if (scale && io.Key("scale"))
		{
			io.Value(ref size);
			moved = true;
		}

		let body = gameObject.GetComponent<Rigidbody>();
		let character = gameObject.GetComponent<CharacterController>();
		var linear = Vector3.Zero;
		var spin = Vector3.Zero;
		if (io.Writing)
		{
			if (body.IsValid && body.HasBody && !body.isKinematic)
			{
				let state = body.State;
				linear = state.linearVelocity;
				spin = state.angularVelocity;
			}
			else if (character.IsValid)
				linear = character.Velocity;
		}
		var hasLinear = false, hasSpin = false;
		if (velocity && (body.IsValid || character.IsValid) && io.Key("velocity"))
		{
			io.Value(ref linear);
			hasLinear = true;
		}
		if (angularVelocity && body.IsValid && io.Key("spin"))
		{
			io.Value(ref spin);
			hasSpin = true;
		}
		if (io.Writing)
			return;

		if (moved)
		{
			Transform.LocalPosition = position;
			Transform.LocalRotation = turned;
			Transform.LocalScale = size;
		}
		if (body.IsValid && body.HasBody)
		{
			// The body already exists (loading while playing): move it and set it going at once.
			var state = body.State;
			state.position = Transform.Position;
			state.rotation = Transform.Rotation;
			if (hasLinear)
				state.linearVelocity = linear;
			if (hasSpin)
				state.angularVelocity = spin;
			body.SetState(state);
		}
		else if (character.IsValid && character.HasCharacter)
			character.Teleport(Transform.Position, hasLinear ? linear : .Zero);
		else if (hasLinear || hasSpin)
		{
			// Loaded before the body exists (loading at start): set it going on the first tick.
			let state = ComponentState<SavedTransformState>.Make(gameObject.Scene.World, gameObject.Entity);
			state.gameObject = gameObject;
			state.pending = true;
			state.pendingVelocity = linear;
			state.pendingSpin = spin;
		}
	}

	/// What FixedUpdate did, for the ones with a velocity waiting (Tick.SavedTransforms, after Tick.FixedUpdate).
	public static void TickAll(Scene scene)
	{
		for (let (entity, state) in ComponentState<SavedTransformState>.In(scene.World, .. scope .()))
		{
			if (state.pending && state.gameObject != null && state.gameObject.ActiveInHierarchy)
				Tick(state);
		}
	}

	static void Tick(SavedTransformState waiting)
	{
		let gameObject = waiting.gameObject;
		let Transform = gameObject.Transform;
		let body = gameObject.GetComponent<Rigidbody>();
		if (body.IsValid && body.HasBody)
		{
			var state = body.State;
			state.linearVelocity = waiting.pendingVelocity;
			state.angularVelocity = waiting.pendingSpin;
			body.SetState(state);
			waiting.pending = false;
			return;
		}
		let character = gameObject.GetComponent<CharacterController>();
		if (character.IsValid && character.HasCharacter)
		{
			character.Teleport(Transform.Position, waiting.pendingVelocity);
			waiting.pending = false;
			return;
		}
		if (!body.IsValid && !character.IsValid)
			waiting.pending = false;
	}

	static void OnRemove(void* world, uint64 entity) => ComponentState<SavedTransformState>.Release(world, entity);
}

/// What to keep, in the object's entity (SavedTransform is the handle).
[Component, HandleData]
struct SavedTransformData
{
	public bool positionX = true;
	public bool positionY = true;
	public bool positionZ = true;
	public bool rotation = true;
	public bool scale = false;
	/// With a Rigidbody or Character Controller: its speed and direction.
	public bool velocity = true;
	/// With a Rigidbody: how fast it spins.
	public bool angularVelocity = true;

	public this() { }
}

/// A velocity loaded before the object's body existed, given to it on the first tick that it does.
class SavedTransformState
{
	public GameObject gameObject;
	public bool pending;
	public Vector3 pendingVelocity;
	public Vector3 pendingSpin;
}
