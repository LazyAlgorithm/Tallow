using System;
using System.Collections;

namespace Tallow;

/// Which physics components the selected backend may provide. One table for the editor's Add Component menus, every
/// add path, scene loading and export validation.
static class PhysicsComponentRules
{
	/// Features the selected 3D world has. Before a scene makes its backend this uses the project's provider.
	public static PhysicsFeatures FeaturesFor(Scene scene)
	{
		// The project's choice is authoritative; a scene's world may still be from before the setting changed, and
		// StartPlay recreates it. A scene with an explicitly created backend (a test) falls back to that world.
		let provider = PhysicsBackends.Selected3D;
		if (provider != null)
			return provider.Features;
		if (scene != null && scene.Physics != null)
			return scene.Physics.Features;
		return .None;
	}

	/// The minimum a component needs before it may be added. False when the backend cannot provide it.
	public static bool CanAdd(Type type, Scene scene, out StringView reason)
	{
		reason = default;
		let features = FeaturesFor(scene);

		if (type == typeof(Rigidbody))
			return Need(features, .RigidBodies, "Rigid bodies", out reason);
		if (type == typeof(BoxCollider))
			return Need(features, .BoxShape, "Box shapes", out reason);
		if (type == typeof(SphereCollider))
			return Need(features, .SphereShape, "Sphere shapes", out reason);
		if (type == typeof(CapsuleCollider))
			return Need(features, .CapsuleShape, "Capsule shapes", out reason);
		if (type == typeof(MeshCollider))
			return Need(features, .MeshShape, "Mesh shapes", out reason);
		if (type == typeof(ConvexCollider))
			return Need(features, .ConvexHullShape, "Convex hull shapes", out reason);
		if (type == typeof(CompoundCollider))
			return Need(features, .CompoundShape, "Compound shapes", out reason);
		if (type == typeof(CharacterController))
			return Need(features, .CharacterController, "Character controllers", out reason);
		if (type == typeof(Joint))
			return Need(features, .BallJoint, "Ball joints", out reason);
		if (type == typeof(SoftBody))
			return Need(features, .SoftBodies, "Soft bodies", out reason);
		if (type == typeof(Rope))
			return Need(features, .Ropes, "Ropes", out reason);
		if (type == typeof(Ragdoll))
			return Need(features, .Ragdolls, "Ragdolls", out reason);
		if (type == typeof(Vehicle))
		{
			// A backend may implement any subset of the kinds; the Vehicle kind dropdown offers those it has.
			if (features.Has(.WheeledVehicles) || features.Has(.MotorcycleVehicles) || features.Has(.TrackedVehicles))
			{
				reason = default;
				return true;
			}
			reason = "Vehicles";
			return false;
		}
		if (type == typeof(Water) || type == typeof(Floater))
			return Need(features, .BuoyancyRigidBodies, "Rigid body buoyancy", out reason);
		return true;
	}

	/// The same for an existing component. Fields can require more than the type does (a jelly needs pressure, a
	/// swinging joint needs swing limits, a rope round a beam is a pulley).
	public static bool Validate(Component component, PhysicsFeatures features, out StringView reason)
	{
		reason = default;
		if (component == null)
			return true;
		if (!CanAdd(component.GetType(), component.GameObject?.Scene, out reason))
			return false;
		if (let soft = component as SoftBody)
		{
			if (soft.tearing && !features.Has(.SoftBodyTearing))
			{
				reason = "Soft body tearing is not available in the selected physics backend.";
				return false;
			}
			switch (soft.kind)
			{
			case .Jelly:
				if (!features.Has(.SoftBodyPressure))
				{
					reason = "Soft body pressure is not available in the selected physics backend.";
					return false;
				}
			case .Shell:
				if (!features.Has(.SoftBodyDents) || !features.Has(.SoftBodySkin))
				{
					reason = "Soft body dents and skinning are not available in the selected physics backend.";
					return false;
				}
			case .DrivenJelly:
				if (!features.Has(.SoftBodySkin))
				{
					reason = "Soft body skinning is not available in the selected physics backend.";
					return false;
				}
			default:
				break;
			}
		}
		if (let rope = component as Rope)
		{
			if (rope.wrapsAround && !features.Has(.RopePulleys))
			{
				reason = "Rope pulleys are not available in the selected physics backend.";
				return false;
			}
			if (rope.knotStiffness > 0 && !features.Has(.RopeKnots))
			{
				reason = "Rope knots are not available in the selected physics backend.";
				return false;
			}
		}
		if (let collider = component as Collider)
		{
			if (collider.isTrigger && !features.Has(.Sensors))
			{
				reason = "Triggers are not available in the selected physics backend.";
				return false;
			}
		}
		if (let vehicle = component as Vehicle)
		{
			if (!features.Has(PhysicsVehicleKinds.Feature(vehicle.kind)))
			{
				reason = scope $"The selected physics backend does not provide {PhysicsVehicleKinds.Name(vehicle.kind)} vehicles.";
				return false;
			}
		}
		return true;
	}

	static bool Need(PhysicsFeatures features, PhysicsFeature feature, StringView what, out StringView reason)
	{
		if (features.Has(feature))
		{
			reason = default;
			return true;
		}
		reason = what;
		return false;
	}
}
