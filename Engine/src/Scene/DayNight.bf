using System;

namespace Tallow;

/// Day / Night (tallowengine.com/docs/day-night): the scene's clock (SceneEnvironment.timeOfDay) turns the sun light,
/// and the moon light if there is one, once a frame. The sums are a simple sky model: the sun's hour angle from the
/// time, its declination from the day of the year and the axis tilt, then east/up/north at the latitude. The lights'
/// colours come from the air they shine through (Atmosphere); with Auto Colours on, so do the ambient and fog colours.
static class DayNight
{
	/// Length of the moon's cycle in days.
	public const double LunarMonth = 29.53;

	/// Hours wrapped into [0, 24).
	public static float WrapHours(float hours)
	{
		var h = hours % 24.0f;
		if (h < 0)
			h += 24;
		return h >= 24 ? 0 : h;
	}

	/// The direction towards a body at hour angle `hourAngle` and declination `declination` (radians), in the
	/// scene's world (north at `northDirection` degrees from +Z, clockwise seen from above).
	static Vector3 Direction(SceneEnvironment env, double hourAngle, double declination)
	{
		let phi = env.latitude * Math.PI_d / 180.0;
		let east = -Math.Cos(declination) * Math.Sin(hourAngle);
		let up = Math.Sin(phi) * Math.Sin(declination) + Math.Cos(phi) * Math.Cos(declination) * Math.Cos(hourAngle);
		let north = Math.Cos(phi) * Math.Sin(declination) - Math.Sin(phi) * Math.Cos(declination) * Math.Cos(hourAngle);
		let yaw = env.northDirection * Math.PI_d / 180.0;
		// North is (sin yaw, 0, cos yaw) and east (cos yaw, 0, -sin yaw): at 0, north +Z and east +X.
		let x = north * Math.Sin(yaw) + east * Math.Cos(yaw);
		let z = north * Math.Cos(yaw) - east * Math.Sin(yaw);
		return Vector3((float)x, (float)up, (float)z).Normalized;
	}

	static double HourAngle(float hours) => (hours - 12.0) * 15.0 * Math.PI_d / 180.0;

	static double YearAngle(SceneEnvironment env) => 2.0 * Math.PI_d * (env.dayOfYear + 10) / 365.0;

	/// The sun's declination in radians (north of the equator positive).
	public static double SunDeclination(SceneEnvironment env) =>
		-env.axisTilt * Math.PI_d / 180.0 * Math.Cos(YearAngle(env));

	/// The moon's age in days (0 new, about 14.8 full).
	public static double MoonAge(SceneEnvironment env)
	{
		var age = (env.dayOfYear + env.timeOfDay / 24.0) % LunarMonth;
		if (age < 0)
			age += LunarMonth;
		return age;
	}

	/// How much of the moon is lit, 0 (new) to 1 (full).
	public static float MoonIllumination(SceneEnvironment env) =>
		(float)((1 - Math.Cos(2 * Math.PI_d * MoonAge(env) / LunarMonth)) * 0.5);

	/// The direction towards the sun at the environment's time of day.
	public static Vector3 SunDirection(SceneEnvironment env) =>
		Direction(env, HourAngle(env.timeOfDay), SunDeclination(env));

	/// The direction towards the moon at the environment's time of day.
	public static Vector3 MoonDirection(SceneEnvironment env)
	{
		let phase = 2 * Math.PI_d * MoonAge(env) / LunarMonth;
		let declination = -env.axisTilt * Math.PI_d / 180.0 * Math.Cos(YearAngle(env) + phase);
		return Direction(env, HourAngle(env.timeOfDay) - phase, declination);
	}

	/// The star sphere's axes in the scene's world at the environment's time: x towards the stars at right ascension 0
	/// on the celestial equator, y at 90 degrees east of it, z the celestial pole. A star fixed on that sphere turns
	/// with the sky through the night (the physical sky's stars).
	public static void CelestialBasis(SceneEnvironment env, out Vector3 x, out Vector3 y, out Vector3 z)
	{
		// Sidereal angle: the sun's hour angle plus a turn a year.
		let sidereal = HourAngle(env.timeOfDay) + 2.0 * Math.PI_d * env.dayOfYear / 365.0;
		x = Direction(env, sidereal, 0);
		y = Direction(env, sidereal - 0.5 * Math.PI_d, 0);
		z = Direction(env, 0, 0.5 * Math.PI_d);
	}

	/// The sun's height above the horizon in degrees (below it negative).
	public static float SunElevation(SceneEnvironment env) => Math.Asin(Math.Clamp(SunDirection(env).y, -1, 1)) * Mathf.Rad2Deg;

	/// Whether it is night: the sun more than 6 degrees below the horizon (the end of civil twilight).
	public static bool IsNight(SceneEnvironment env) => SunElevation(env) < -6;

	/// The Directional light the clock turns as the sun: SceneEnvironment.sunLight, else the one the renderer picks
	/// (the first that casts shadows, else the first), never the moon.
	public static Light FindSun(Scene scene)
	{
		let env = scene.Environment;
		if (env.sunLight != 0)
		{
			if (Directional(scene, env.sunLight) case .Ok(let light))
				return light;
		}
		Light sun = default;
		for (let light in scene.Lights)
		{
			if (light.type != .Directional || !light.IsActiveAndEnabled || !light.GameObject.InActiveWorld || (env.moonLight != 0 && light.GameObject.Id == env.moonLight))
				continue;
			if (!sun || (!sun.castShadows && light.castShadows))
				sun = light;
		}
		return sun;
	}

	/// The moon light, or none.
	public static Light FindMoon(Scene scene)
	{
		let env = scene.Environment;
		if (env.moonLight != 0 && env.moonLight != env.sunLight && Directional(scene, env.moonLight) case .Ok(let light))
			return light;
		return default;
	}

	static Result<Light> Directional(Scene scene, uint32 id)
	{
		let gameObject = scene.FindById(id);
		if (gameObject == null)
			return .Err;
		let light = gameObject.GetComponent<Light>();
		if (!light || light.type != .Directional)
			return .Err;
		return light;
	}

	/// Points a light so its light travels away from `toward` (the direction towards the body).
	static void Aim(Light light, Vector3 toward)
	{
		let transform = light.GameObject.Transform;
		let forward = -toward;
		if (Vector3.Dot(transform.Forward, forward) > 0.9999999f)
			return;
		let up = Math.Abs(forward.y) > 0.999f ? Vector3(0, 0, 1) : Vector3(0, 1, 0);
		transform.Rotation = Quaternion.LookRotation(forward, up);
	}

	/// Moves the clock on by `deltaTime` seconds (0 in Edit mode, or when paused) and turns the sun and moon.
	/// Does nothing while Day / Night is off.
	public static void Update(Scene scene, float deltaTime)
	{
		let env = scene.Environment;
		if (!env.dayNight)
			return;
		if (deltaTime > 0 && !env.dayNightPaused && env.dayLengthMinutes > 0)
			env.timeOfDay = WrapHours(env.timeOfDay + deltaTime * 24.0f / (env.dayLengthMinutes * 60.0f));
		Apply(scene);
	}

	/// Turns the sun and moon to the environment's time now (the editor calls it when the time is dragged).
	public static void Apply(Scene scene)
	{
		let env = scene.Environment;
		if (!env.dayNight)
			return;
		let sunDirection = SunDirection(env);
		let sunElevation = Elevation(sunDirection);
		let sun = FindSun(scene);
		if (sun)
		{
			Aim(sun, sunDirection);
			SunLight(env, sunElevation, var color, var intensity);
			SetColor(sun, color, intensity);
		}
		let moon = FindMoon(scene);
		let moonLight = MoonLight(env, var moonColor);
		if (moon)
		{
			Aim(moon, MoonDirection(env));
			SetColor(moon, moonColor, moonLight);
		}
		if (env.autoColors)
		{
			let ambient = Atmosphere.AmbientColors(sunElevation, env.sunIntensity, moonLight);
			env.ambientSky = ambient.sky.Gamma;
			env.ambientGround = ambient.ground.Gamma;
			env.fogColor = ambient.fog.Gamma;
		}
	}

	static float Elevation(Vector3 toward) => Math.Asin(Math.Clamp(toward.y, -1, 1)) * Mathf.Rad2Deg;

	/// The sun light's colour (gamma, brightest channel 1) and intensity at `elevation` degrees: Sun Intensity times
	/// what gets through the air (white at noon, orange then red near the horizon, 0 after sunset).
	public static void SunLight(SceneEnvironment env, float elevation, out Color color, out float intensity)
	{
		let t = Atmosphere.SunTransmittance(elevation);
		let peak = t.Max;
		intensity = (float)(env.sunIntensity * peak);
		color = peak > 1e-9 ? (t * (1 / peak)).Gamma : Color(1, 1, 1);
	}

	/// The moon light's intensity (Moon Intensity times the lit part of the moon and what gets through the air; 0
	/// below the horizon) and its colour (gamma), a dim cool white.
	public static float MoonLight(SceneEnvironment env, out Color color)
	{
		let t = Atmosphere.SunTransmittance(Elevation(MoonDirection(env)));
		let light = Atmosphere.MoonColor * t;
		let peak = light.Max;
		color = peak > 1e-9 ? (light * (1 / peak)).Gamma : Atmosphere.MoonColor.Gamma;
		return (float)(env.moonIntensity * MoonIllumination(env) * peak);
	}

	/// Sets a light's colour and intensity, leaving it alone when nothing visible changed (no needless network sends).
	static void SetColor(Light light, Color color, float intensity)
	{
		let old = light.color;
		if (Math.Abs(old.r - color.r) > 1e-4f || Math.Abs(old.g - color.g) > 1e-4f || Math.Abs(old.b - color.b) > 1e-4f)
			light.color = .(color.r, color.g, color.b, old.a);
		if (Math.Abs(light.intensity - intensity) > 1e-5f)
			light.intensity = intensity;
	}
}
