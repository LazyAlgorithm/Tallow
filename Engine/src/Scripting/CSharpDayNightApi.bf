using System;

namespace Tallow;

/// The Day / Night clock for C# (Managed/Tallow.API/DayNight.cs): the scene's clock settings, where the sun and moon
/// are, and the events the shared clock crosses (sunrise, sunset, each whole hour). It works on the scene the game is
/// playing, the one a script's Scene is. A setting is a number into the list in DayNight.cs; a direction travels as
/// three floats and a colour as four.
[CSharpExpose]
static class CSharpDayNight
{
	static Scene Active() => CSharpRuntime.PhysicsScene(CSharpRuntime.Session);

	/// Reads a setting into values (one float, or three for a direction, four for a colour). False without a scene or
	/// for an unknown one.
	[CSharpExpose]
	public static bool Get(int32 which, Span<float> values)
	{
		let scene = Active();
		if (scene == null || values.Length < 4)
			return false;
		let env = scene.Environment;
		let sunDirection = DayNight.SunDirection(env);
		let moonDirection = DayNight.MoonDirection(env);
		var sunColor = Color(1, 1, 1);
		var sunIntensity = 0.0f;
		if (env.dayNight)
		{
			DayNight.SunLight(env, DayNight.SunElevation(env), var color, var intensity);
			sunColor = color;
			sunIntensity = intensity;
		}
		else
		{
			let sun = DayNight.FindSun(scene);
			if (sun)
			{
				sunColor = .(sun.color.r, sun.color.g, sun.color.b, 1);
				sunIntensity = sun.intensity;
			}
		}
		switch (which)
		{
		case 0: values[0] = env.dayNight ? 1 : 0;
		case 1: values[0] = (float)DayNight.SimulationTime(scene);
		case 2: values[0] = env.dayLengthMinutes;
		case 3: values[0] = env.dayNight && !env.dayNightPaused && env.dayLengthMinutes > 0 ? 24.0f / (env.dayLengthMinutes * 60.0f) : 0;
		case 4: values[0] = env.dayNightPaused ? 1 : 0;
		case 5: values[0] = env.latitude;
		case 6: values[0] = env.axisTilt;
		case 7: values[0] = env.northDirection;
		case 8: values[0] = env.dayOfYear;
		case 9: values[0] = DayNight.IsNight(env) ? 1 : 0;
		case 10: values[0] = sunDirection.x; values[1] = sunDirection.y; values[2] = sunDirection.z;
		case 11: values[0] = sunColor.r; values[1] = sunColor.g; values[2] = sunColor.b; values[3] = sunColor.a;
		case 12: values[0] = sunIntensity;
		case 13: values[0] = moonDirection.x; values[1] = moonDirection.y; values[2] = moonDirection.z;
		case 14: values[0] = (float)(DayNight.MoonAge(env) / DayNight.LunarMonth);
		case 15: values[0] = DayNight.MoonIllumination(env);
		default: return false;
		}
		return true;
	}

	/// Sets a setting from one number (the clock's own: the time of day, the day's length, paused, where the scene is
	/// on the planet). False without a scene, for an unknown one or for a value that is not finite.
	[CSharpExpose]
	public static bool Set(int32 which, float value)
	{
		let scene = Active();
		if (scene == null || !value.IsFinite)
			return false;
		let env = scene.Environment;
		switch (which)
		{
		case 0: env.dayNight = value != 0;
		case 1: env.timeOfDay = DayNight.WrapHours(value);
		case 2: env.dayLengthMinutes = Math.Max(value, 0);
		case 4: env.dayNightPaused = value != 0;
		case 5: env.latitude = Math.Clamp(value, -90, 90);
		case 6: env.axisTilt = Math.Clamp(value, 0, 90);
		case 7: env.northDirection = value;
		case 8: env.dayOfYear = Math.Clamp((int32)value, 1, 365);
		default: return false;
		}
		DayNight.Apply(scene);
		return true;
	}

	/// The next Day / Night event the shared clock crossed since the last call: -1 when there is none, else the tick
	/// in the low 32 bits, the kind in bits 32-33 (0 sunrise, 1 sunset, 2 hour) and an hour event's hour in bits 34-38.
	[CSharpExpose]
	public static int64 TakeEvent()
	{
		let scene = Active();
		return scene != null ? DayNightEvents.Take(scene) : -1;
	}
}
