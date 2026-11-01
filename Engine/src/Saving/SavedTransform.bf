using System;

namespace Tallow;

/// Keeps this object's place in saves: its position (each axis can be left out), rotation and scale, relative to its
/// parent, and with a Rigidbody or Character Controller on the object, how it is moving, so that something falling
/// or rolling when the game was saved carries on when it is loaded. Leave out what never changes: each value left out
/// is a little less to store.
///
/// An object made while the game ran (from a prefab, or a registered network prefab) with this component on it is
/// made again when a save is loaded, so dropped and placed things come back where they were.
[Component]
class SavedTransform : Component
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

	bool mPending;
	Vector3 mPendingVelocity;
	Vector3 mPendingSpin;

	public override bool HasSavedFields => true;

	public override void SaveFields(SaveIO io)
	{
		base.SaveFields(io);
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

		let body = GetComponent<Rigidbody>();
		let character = GetComponent<CharacterController>();
		var linear = Vector3.Zero;
		var spin = Vector3.Zero;
		if (io.Writing)
		{
			if (body != null && body.HasBody && !body.isKinematic)
			{
				let state = body.State;
				linear = state.linearVelocity;
				spin = state.angularVelocity;
			}
			else if (character != null)
				linear = character.Velocity;
		}
		var hasLinear = false, hasSpin = false;
		if (velocity && (body != null || character != null) && io.Key("velocity"))
		{
			io.Value(ref linear);
			hasLinear = true;
		}
		if (angularVelocity && body != null && io.Key("spin"))
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
		if (body != null && body.HasBody)
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
		else if (character != null && character.HasCharacter)
			character.Teleport(Transform.Position, hasLinear ? linear : .Zero);
		else if (hasLinear || hasSpin)
		{
			// Loaded before the body exists (loading at start): set it going on the first tick.
			mPending = true;
			mPendingVelocity = linear;
			mPendingSpin = spin;
		}
	}

	public override void FixedUpdate()
	{
		if (!mPending)
			return;
		let body = GetComponent<Rigidbody>();
		if (body != null && body.HasBody)
		{
			var state = body.State;
			state.linearVelocity = mPendingVelocity;
			state.angularVelocity = mPendingSpin;
			body.SetState(state);
			mPending = false;
			return;
		}
		let character = GetComponent<CharacterController>();
		if (character != null && character.HasCharacter)
		{
			character.Teleport(Transform.Position, mPendingVelocity);
			mPending = false;
			return;
		}
		if (body == null && character == null)
			mPending = false;
	}
}
