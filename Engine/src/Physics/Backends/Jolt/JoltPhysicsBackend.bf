using System;
using System.Collections;

namespace Tallow;

/// Jolt Physics through the JoltC C API. The built-in 3D backend and the engine's default.
class JoltPhysicsBackend : PhysicsBackend
{
	/// Every feature the current Jolt integration implements. 2D features live in a separate bit space.
	public static PhysicsFeatures AllFeatures => .(((uint64)1 << 51) - 1);

	public override StringView Id => "Jolt";
	public override StringView DisplayName => "Jolt";
	public override ModuleKind Kind => .Physics3D;
	public override int32 IntegrationVersion => 1;
	public override StringView LibraryVersion => "vendored Jolt";
	public override bool Available => true;
	public override PhysicsDimension Dimension => .Three;
	public override PhysicsFeatures Features => AllFeatures;

	public override PhysicsBackendWorld CreateWorld(PhysicsWorldSettings settings) => new JoltPhysicsBackendWorld(settings, Features);
}
