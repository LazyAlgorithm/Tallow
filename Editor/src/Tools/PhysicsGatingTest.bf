using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Headless check that a backend without soft bodies or ropes cannot be given those components, while it can still
/// be given the features it has. Run with: TallowLauncher --test-physics-gating
static class PhysicsGatingTest
{
	public static int Run()
	{
		int failures = 0;

		// The real backend advertises everything, so the components are available.
		PhysicsBackends.Override3D("Jolt");
		failures += Check("Jolt advertises soft bodies", PhysicsBackends.Selected3D.Features.Has(.SoftBodies));
		failures += Check("Jolt advertises ropes", PhysicsBackends.Selected3D.Features.Has(.Ropes));
		let joltSoft = ComponentAvailability.CanAdd(typeof(SoftBody), null, let joltSoftReason);
		let joltRope = ComponentAvailability.CanAdd(typeof(Rope), null, let joltRopeReason);
		let joltBox = ComponentAvailability.CanAdd(typeof(BoxCollider), null, let joltBoxReason);
		let joltRigid = ComponentAvailability.CanAdd(typeof(Rigidbody), null, let joltRigidReason);
		failures += Check("SoftBody can be added under Jolt", joltSoft);
		failures += Check("Rope can be added under Jolt", joltRope);
		failures += Check("BoxCollider can be added under Jolt", joltBox);
		failures += Check("Rigidbody can be added under Jolt", joltRigid);

		// The limited profile has the rigid-body features but not soft bodies or ropes.
		PhysicsBackends.Override3D("JoltLimited");
		let limited = PhysicsBackends.Selected3D;
		failures += Check("limited profile is selected", limited != null && limited.Id == "JoltLimited");
		failures += Check("limited profile has no soft bodies", !limited.Features.Has(.SoftBodies));
		failures += Check("limited profile has no ropes", !limited.Features.Has(.Ropes));
		failures += Check("limited profile offers only wheeled vehicles",
			limited.Features.Has(.WheeledVehicles) && !limited.Features.Has(.MotorcycleVehicles) && !limited.Features.Has(.TrackedVehicles));
		let limitedSoft = ComponentAvailability.CanAdd(typeof(SoftBody), null, let softReason);
		let limitedRope = ComponentAvailability.CanAdd(typeof(Rope), null, let ropeReason);
		let limitedBox = ComponentAvailability.CanAdd(typeof(BoxCollider), null, let boxReason);
		let limitedRigid = ComponentAvailability.CanAdd(typeof(Rigidbody), null, let rigidReason);
		failures += Check("SoftBody is refused under the limited profile", !limitedSoft);
		failures += Check("Rope is refused under the limited profile", !limitedRope);
		failures += Check("BoxCollider is still allowed", limitedBox);
		failures += Check("Rigidbody is still allowed", limitedRigid);
		failures += Check("the refusal names a feature", !softReason.IsEmpty);

		// Loading keeps components even when the backend cannot run them; the component stays inert.
		ComponentAvailability.Loading = true;
		let loadedSoft = ComponentAvailability.CanAdd(typeof(SoftBody), null, let loadReason);
		ComponentAvailability.Loading = false;
		failures += Check("loading keeps a SoftBody", loadedSoft);

		Console.WriteLine(failures == 0 ? "PHYSICS GATING PASS" : scope $"PHYSICS GATING FAIL ({failures})");
		PhysicsBackends.Override3D("");
		return failures == 0 ? 0 : 1;
	}

	static int Check(StringView what, bool ok)
	{
		let line = scope String();
		line.AppendF("[{}] {}", ok ? "PASS" : "FAIL", what);
		Console.WriteLine(line);
		return ok ? 0 : 1;
	}
}
