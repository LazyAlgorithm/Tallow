using System;
using Tallow;

namespace Sandbox;

/// Example component: makes a noise every few seconds that behaviour trees' Heard Noise nodes pick up (a ringing
/// alarm, a rattling crate).
[Component]
class NoiseMaker : Script
{
	public float interval = 6;
	/// How far away it is heard.
	public float radius = 14;

	float mNext = 2;

	public override void Update(TickInput input, float deltaTime)
	{
		mNext -= Time.DeltaTime;
		if (mNext > 0)
			return;
		mNext = interval;
		AINoise.Make(Scene, Transform.Position, radius, GameObject);
	}
}
