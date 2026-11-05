using System;

namespace Tallow;

/// The GameObject an entity stands for. It is a link back, not ownership: the GameObject owns its entity and deletes
/// it, so this is the one engine data component allowed a class reference (docs/ecs-plan.md, Phase 2).
[Component]
struct ObjectLink
{
	public GameObject gameObject;
}

/// On the entity of a GameObject that is switched off itself (GameObject.ActiveSelf is false). Queries leave such
/// objects out with Flecs.TermAccess.Without.
[Component]
struct InactiveSelf
{
}
