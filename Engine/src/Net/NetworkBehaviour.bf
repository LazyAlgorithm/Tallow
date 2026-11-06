using System;

namespace Tallow;

/// Base class for networked gameplay scripts.
///
/// Put movement in Simulate: it runs on the server for every client input, and on the owning
/// client immediately (prediction) and again when the server corrects it (replay). It must
/// depend only on the input, the delta time and simulation state.
[Component]
abstract class NetworkBehaviour : Component
{
	public NetworkIdentity Identity => GetComponent<NetworkIdentity>();
	public bool IsServer => Scene.Network == null || Scene.Network.IsServer;
	public bool IsOwner
	{
		get
		{
			let identity = Identity;
			return identity.IsValid && identity.IsOwner;
		}
	}

	/// Server, inside Simulate or Update: until EndLagCompensation, every other networked object is where this
	/// object's player was seeing it when they gave the controls being run. Wrap the ray cast for a shot or a
	/// swing in the pair, so that it is judged against what the player aimed at; deal the damage after ending.
	/// Returns false and does nothing where it does not apply (no session, a client, the host's own player).
	public bool BeginLagCompensation() => Scene.Network != null && Scene.Network.BeginLagCompensation(Identity);
	public void EndLagCompensation() => Scene.Network?.EndLagCompensation();

	/// Custom transform-based motors can store rewindable simulation state in the unused velocity slots.
	/// Do not override slots owned by a Rigidbody or CharacterController on the same object.
	public virtual void CapturePredictionState(ref BodyState state) { }
	/// Extra motor metadata alongside an active body's actual velocities.
	public virtual void CaptureBodyPredictionState(ref BodyState state) { }
	/// Restore a motor/body mode before the transform and velocities are applied.
	public virtual void PreparePredictionState(BodyState state) { }
	public virtual void RestorePredictionState(BodyState state) { }

	/// Called once per tick on the owning client to sample the local controls.
	public virtual void GatherInput(ref NetInput input) { }
	/// Advance this object by one tick using the given input.
	public virtual void Simulate(NetInput input, float deltaTime) { }
}
