using System;
using System.Collections;

namespace Tallow;

/// The base class for game scripts: behaviour attached to a GameObject. It is a Component with nothing added, kept
/// as its own name because engine components (renderers, colliders, lights) move to data in the ECS while scripts
/// stay classes (docs/ecs-plan.md). Write Update for gameplay; the engine runs it per frame or, on an object with a
/// Network Identity, per network tick (Component.Update).
///
///   [Component]
///   class Spinner : Script
///   {
///       public float degreesPerSecond = 90;
///       public override void Update(TickInput input, float deltaTime)
///       {
///           Transform.Rotate(.(0, degreesPerSecond * deltaTime, 0));
///       }
///   }
[Component]
abstract class Script : Component
{
	List<Object> mOwned ~ DeleteContainerAndItems!(_);

	/// Creates text owned by this script. Keep the returned String in a field and edit it with Set or Append;
	/// the engine frees it with the script. Do not delete it or replace it with an independently owned string.
	public String CreateString(StringView value = "")
	{
		let text = new String(value);
		if (mOwned == null)
			mOwned = new .();
		mOwned.Add(text);
		return text;
	}

	/// Creates a list owned by this script. Its elements must be values or references owned elsewhere;
	/// destroying the script frees the list, not objects referred to by its elements.
	public List<T> CreateList<T>()
	{
		let list = new List<T>();
		if (mOwned == null)
			mOwned = new .();
		mOwned.Add(list);
		return list;
	}
}
