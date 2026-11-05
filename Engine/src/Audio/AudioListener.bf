using System;

namespace Tallow;

/// The ears. Put one on the camera, or on the player's head; positioned sounds are heard from here, facing the way
/// the object faces. With none in the scene the first Camera is used, so a simple game needs nothing.
///
/// A handle (ComponentHandle) with no settings of its own.
[Component]
struct AudioListener : ComponentHandle<AudioListenerData>
{
	public this() : base() { }
	public this(GameObject gameObject) : base(gameObject) { }

	/// Once a frame, before Audio.Update: the first active listener places the ears.
	public static void FrameAll(Scene scene)
	{
		// In the editor outside play mode the Scene view's camera is the listener, so sounds can be auditioned.
		if (!scene.IsPlaying && Audio.EditorListening)
			return;
		for (let listener in scene.Components<AudioListener>(.. scope .()))
		{
			if (!listener.GameObject.ActiveInHierarchy)
				continue;
			let transform = listener.Transform;
			Audio.SetListener(transform.Position, transform.Forward, transform.Rotation * Vector3.Up);
			return;
		}
	}
}

/// An Audio Listener's data: nothing but its being there (and switched on).
[Component, HandleData]
struct AudioListenerData
{
	// A component with no bytes would be a Flecs tag, which cannot be switched off or copied like the others.
	uint8 mUnused = 0;

	public this() { }
}

/// A place with an echo: a hall, a cave, a tunnel. While the listener is inside, sounds gain reverb; it fades in
/// across the outer part of the sphere so walking in and out is smooth.
///
/// A handle (ComponentHandle): its settings are AudioReverbZoneData's fields, in the object's entity.
[Component, HandleFields]
struct AudioReverbZone : ComponentHandle<AudioReverbZoneData>
{
	/// 0 outside, rising to 1 once the point is inside by more than the fade band.
	public float WeightAt(Vector3 point)
	{
		let distance = (point - Transform.Position).Length;
		if (distance >= radius)
			return 0;
		return fade <= 0.001f ? 1 : Mathf.Clamp01((radius - distance) / fade);
	}

	static void DrawGizmos(GameObject gameObject, bool selected)
	{
		if (!selected)
			return;
		let zone = gameObject.GetComponent<AudioReverbZone>();
		let position = gameObject.Transform.Position;
		Gizmos.Lines.Sphere(position, zone.radius, .(0.75f, 0.55f, 0.95f, 1));
		if (zone.fade > 0.001f && zone.fade < zone.radius)
			Gizmos.Lines.Sphere(position, zone.radius - zone.fade, .(0.75f, 0.55f, 0.95f, 0.45f));
	}
}

/// An Audio Reverb Zone's settings.
[Component, HandleData]
struct AudioReverbZoneData
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

	public this() { }
}
