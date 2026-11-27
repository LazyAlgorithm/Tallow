using System;

namespace Tallow;

/// The cloud layer's clock and weather offset (tallowengine.com/docs/clouds). The shaders only ever receive a world
/// offset, never a time, so the weather is one pure function of the scene's settings and the clock: peers with the same
/// clock and `cloudSeed` agree on the clouds with no network state. The 2D sky layer and the volumetric march (C2)
/// share it.
static class Clouds
{
	/// The weather's time in seconds: the session's simulation clock (the server's tick, eased between ticks, so every
	/// peer is on the same timeline), the local clock while playing, or the real clock in the editor. A paused day/night
	/// clock does not stop it (C3c).
	public static double Seconds(Scene scene)
	{
		let network = scene?.Network;
		if (network != null && network.Mode != .Offline)
			return (network.ServerTick - 1 + Time.InterpolationAlpha) / (double)Time.TickRate;
		if (scene != null && scene.IsPlaying)
			return (Time.Tick - 1 + Time.InterpolationAlpha) / (double)Time.TickRate;
		return Time.RealTime;
	}

	/// How far the weather has drifted in metres: towards +Z at 0 degrees, clockwise seen from above (the same
	/// convention as northDirection).
	public static Vector2 WindOffset(SceneEnvironment env, double seconds)
	{
		let radians = env.cloudWindDirection * Mathf.Deg2Rad;
		Vector2 direction = .(Math.Sin(radians), Math.Cos(radians));
		return direction * (float)(env.cloudWindSpeed * seconds);
	}

	/// The seed's move of the weather map: a whole number of metres from the same generator, so two peers with the
	/// same seed sample the same pattern without the shaders carrying a seed.
	public static Vector2 SeedOffset(SceneEnvironment env)
	{
		let seed = (uint32)env.cloudSeed;
		return .((float)(seed & 0xFFFF) * 0.061f, (float)(seed >> 16) * 0.061f);
	}

	/// The world offset both cloud paths sample the weather at: the wind's drift plus the seed's move.
	public static Vector2 Offset(SceneEnvironment env, double seconds) => WindOffset(env, seconds) + SeedOffset(env);
}
