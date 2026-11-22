using System;
using System.Collections;

namespace Tallow;

/// A reduced Jolt integration used by tests and CI to prove capability gating before a second real backend exists. It
/// runs the same Jolt world but advertises no soft bodies or ropes, so their components cannot be added and existing
/// ones stay inert. It is not listed unless a test switch enables it.
class JoltLimitedPhysicsBackend : PhysicsBackend
{
	public static bool Enabled;

	public static PhysicsFeatures LimitedFeatures => .(JoltPhysicsBackend.AllFeatures.bits &
		~((uint64)PhysicsFeature.SoftBodies | (uint64)PhysicsFeature.SoftBodyDents |
		(uint64)PhysicsFeature.SoftBodyPressure | (uint64)PhysicsFeature.SoftBodySkin |
		(uint64)PhysicsFeature.Ropes | (uint64)PhysicsFeature.RopePulleys |
		(uint64)PhysicsFeature.RopeKnots | (uint64)PhysicsFeature.BuoyancySoftBodies |
		(uint64)PhysicsFeature.MotorcycleVehicles | (uint64)PhysicsFeature.TrackedVehicles));

	public override StringView Id => "JoltLimited";
	public override StringView DisplayName => "Jolt (limited test profile)";
	public override ModuleKind Kind => .Physics3D;
	public override int32 IntegrationVersion => 1;
	public override StringView LibraryVersion => "vendored Jolt";
	public override bool Available => Enabled;
	public override PhysicsDimension Dimension => .Three;
	public override PhysicsFeatures Features => LimitedFeatures;

	public override PhysicsBackendWorld CreateWorld(PhysicsWorldSettings settings) => new JoltPhysicsBackendWorld(settings, Features);
}
