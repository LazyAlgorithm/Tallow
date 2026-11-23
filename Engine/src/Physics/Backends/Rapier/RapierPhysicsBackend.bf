using System;
using System.Collections;

namespace Tallow;

/// Rapier3D, through the C bindings pinned in third_party/rapier. Provider features list only what the integration
/// implements and has conformance for; the editor hides everything else for a Rapier project.
class RapierPhysicsBackend : PhysicsBackend
{
	/// Every feature the Rapier integration implements today. The exact/shared snapshots and cross-platform
	/// determinism are verified: identical fixed-scene state hashes on Linux x86_64 and the Windows x86_64 build,
	/// with Rapier's enhanced-determinism build.
	public static PhysicsFeatures AllFeatures
	{
		get
		{
			PhysicsFeature[?] list = .(
				.RigidBodies, .KinematicBodies, .Sensors, .ContinuousCollision, .Sleeping, .FreezeRotation, .Debris,
				.BoxShape, .SphereShape, .CapsuleShape, .CylinderShape, .ConvexHullShape, .MeshShape, .CompoundShape,
				.BallJoint, .SwingLimit, .HingeJoint, .HingeMotor, .SliderJoint, .SliderSpring,
				.CharacterController, .CharacterPush, .Raycast, .RaycastAll, .ShapeCast, .Overlap, .Check,
				.ContactEvents, .ContactStay, .TriggerEvents, .BuoyancyRigidBodies, .WorldStatesSeparated,
				.NavigationGeometry, .FixedBodyIds, .MultipleWorlds, .SaveRestoreExact, .SharedPhysicsState, .CrossPlatformDeterminism, .Ragdolls, .Vehicles, .WheeledVehicles, .SoftBodies, .SoftBodyDents, .SoftBodyPressure, .SoftBodySkin,
				.SoftBodyTearing, .BuoyancySoftBodies, .Ropes, .RopeKnots);
			PhysicsFeatures features = .(0);
			for (let feature in list)
				features.bits |= (uint64)feature;
			return features;
		}
	}

	public override StringView Id => "Rapier";
	public override StringView DisplayName => "Rapier3D";
	public override ModuleKind Kind => .Physics3D;
	public override int32 IntegrationVersion => 1;
	public override StringView LibraryVersion => "Rapier 0.36.1+c.0 (C bindings)";
	public override bool Available => Rapier.tn_rapier_available() == 1;
	public override PhysicsDimension Dimension => .Three;
	public override PhysicsFeatures Features => AllFeatures;

	public override PhysicsBackendWorld CreateWorld(PhysicsWorldSettings settings) => new RapierPhysicsBackendWorld(settings, Features);
}
