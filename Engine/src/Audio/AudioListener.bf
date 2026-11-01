using System;

namespace Tallow;

/// The ears. Put one on the camera, or on the player's head; positioned sounds are heard from here, facing the way
/// the object faces. With none in the scene the first Camera is used, so a simple game needs nothing.
[Component]
class AudioListener : Component
{
	public override void OnFrame()
	{
		// In the editor outside play mode the Scene view's camera is the listener, so sounds can be auditioned.
		if (!Scene.IsPlaying && Audio.EditorListening)
			return;
		Audio.SetListener(Transform.Position, Transform.Forward, Transform.Rotation * Vector3.Up);
	}
}

/// A place with an echo: a hall, a cave, a tunnel. While the listener is inside, sounds gain reverb; it fades in
/// across the outer part of the sphere so walking in and out is smooth.
[Component]
class AudioReverbZone : Component
{
	/// How far the zone reaches.
	public float radius = 10;
	/// Width of the band at the edge over which the reverb fades in.
	public float fade = 3;
	/// How much reverb at full strength, 0 to 1.
	[Range(0, 1)] public float amount = 0.5f;
	/// Small room to large hall.
	[Range(0, 1)] public float roomSize = 0.6f;
	/// How quickly high frequencies die in the echo: 0 bright and ringing, 1 dull and soft.
	[Range(0, 1)] public float damping = 0.5f;

	/// 0 outside, rising to 1 once the point is inside by more than the fade band.
	public float WeightAt(Vector3 point)
	{
		let distance = (point - Transform.Position).Length;
		if (distance >= radius)
			return 0;
		return fade <= 0.001f ? 1 : Mathf.Clamp01((radius - distance) / fade);
	}

	public override void OnDrawGizmos(bool selected)
	{
		if (!selected)
			return;
		Gizmos.Lines.Sphere(Transform.Position, radius, .(0.75f, 0.55f, 0.95f, 1));
		if (fade > 0.001f && fade < radius)
			Gizmos.Lines.Sphere(Transform.Position, radius - fade, .(0.75f, 0.55f, 0.95f, 0.45f));
	}
}
