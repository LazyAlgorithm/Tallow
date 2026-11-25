using System;

namespace Tallow;

/// `--daynight-test`: prints the sun and moon directions through the day, checks the sun's path (highest at noon,
/// below the horizon at midnight, rising in the east, symmetric round noon, North Direction turns it), that a scene's
/// sun light follows the clock and the time dragged in Edit mode, and that the settings save and load.
static class DayNightTest
{
	static int sFailed;

	static void Check(bool ok, StringView what)
	{
		if (!ok)
		{
			sFailed++;
			Console.WriteLine(scope $"FAIL: {what}");
		}
	}

	static float Azimuth(Vector3 d) => Math.Atan2(d.x, d.z) * Mathf.Rad2Deg;

	static bool Near(Vector3 a, Vector3 b, float tolerance = 1e-4f) => (a - b).Length < tolerance;

	public static int Run()
	{
		let env = scope SceneEnvironment();
		env.dayNight = true;
		env.latitude = 40;
		for (let day in int32[?](172, 355))
		{
			env.dayOfYear = day;
			Console.WriteLine(scope $"latitude 40, day {day}:");
			for (int hour = 0; hour < 24; hour += 3)
			{
				env.timeOfDay = hour;
				let s = DayNight.SunDirection(env);
				let m = DayNight.MoonDirection(env);
				Console.WriteLine(scope $"  {hour:00}:00 sun ({s.x:F3}, {s.y:F3}, {s.z:F3}) elev {DayNight.SunElevation(env):F1}  moon ({m.x:F3}, {m.y:F3}, {m.z:F3}) lit {DayNight.MoonIllumination(env):F2}");
			}
			env.timeOfDay = 12;
			let noon = DayNight.SunElevation(env);
			for (float h = 0; h < 24; h += 0.25f)
			{
				env.timeOfDay = h;
				if (h != 12 && DayNight.SunElevation(env) >= noon)
				{
					Check(false, scope $"day {day}: noon is the highest ({h} is not lower)");
					break;
				}
			}
			env.timeOfDay = 0;
			Check(DayNight.SunElevation(env) < 0, scope $"day {day}: midnight below the horizon");
			Check(DayNight.IsNight(env), scope $"day {day}: midnight is night");
			// Symmetric round noon: the azimuth mirrors.
			for (float x = 1; x <= 6; x++)
			{
				env.timeOfDay = 12 - x;
				let before = Azimuth(DayNight.SunDirection(env));
				let elevBefore = DayNight.SunElevation(env);
				env.timeOfDay = 12 + x;
				let after = Azimuth(DayNight.SunDirection(env));
				Check(Math.Abs(before + after) < 0.5f && Math.Abs(elevBefore - DayNight.SunElevation(env)) < 0.01f,
					scope $"day {day}: symmetric round noon at +-{x} h ({before:F2} vs {after:F2})");
			}
		}
		Check(noonHeight(40, 172) > 73 && noonHeight(40, 172) < 73.6f, "June solstice noon at 40N is about 73.4 degrees");

		// Sun rises in the east: day 80 (equinox), equator, 06:00.
		env.latitude = 0;
		env.dayOfYear = 80;
		env.timeOfDay = 6;
		Check(DayNight.SunDirection(env).x > 0.99f, "06:00 at the equinox the sun is east (+X)");
		env.timeOfDay = 18;
		Check(DayNight.SunDirection(env).x < -0.99f, "18:00 at the equinox the sun is west (-X)");

		// North Direction 90: north is +X, so everything turns by 90 degrees (+Z goes to +X).
		env.latitude = 40;
		env.dayOfYear = 172;
		for (float h = 0; h < 24; h += 2.5f)
		{
			env.timeOfDay = h;
			env.northDirection = 0;
			let a = DayNight.SunDirection(env);
			let ma = DayNight.MoonDirection(env);
			env.northDirection = 90;
			let b = DayNight.SunDirection(env);
			let mb = DayNight.MoonDirection(env);
			Check(Near(b, .(a.z, a.y, -a.x)) && Near(mb, .(ma.z, ma.y, -ma.x)), scope $"North Direction 90 turns the sky at {h}");
		}
		env.northDirection = 0;

		// The moon: full about 14.8 days in, new at 0.
		env.dayOfYear = 15;
		env.timeOfDay = 0;
		Check(DayNight.MoonIllumination(env) > 0.99f, "day 15 (age 15 days) is about full moon");
		env.dayOfYear = 30;
		env.timeOfDay = 12;
		Check(DayNight.MoonIllumination(env) < 0.15f, "day 30.5 (age ~1 day) is about new moon");

		SceneChecks();
		Console.WriteLine(sFailed == 0 ? "DAYNIGHT TEST PASS" : scope $"DAYNIGHT TEST FAIL ({sFailed})");
		return sFailed == 0 ? 0 : 1;
	}

	static float noonHeight(float latitude, int32 day)
	{
		let env = scope SceneEnvironment();
		env.latitude = latitude;
		env.dayOfYear = day;
		env.timeOfDay = 12;
		return DayNight.SunElevation(env);
	}

	static void SceneChecks()
	{
		let scene = scope Scene();
		let fill = scene.CreateGameObject("Fill");
		let fillLight = fill.AddComponent<Light>();
		fillLight.castShadows = false;
		let sunObject = scene.CreateGameObject("Sun");
		let sun = sunObject.AddComponent<Light>();
		let moonObject = scene.CreateGameObject("Moon");
		moonObject.AddComponent<Light>().castShadows = false;
		let fillRotation = fill.Transform.Rotation;

		// Off: nothing moves.
		let before = sunObject.Transform.Rotation;
		DayNight.Update(scene, 1);
		Check(sunObject.Transform.Rotation == before, "Day / Night off leaves the sun alone");

		let env = scene.Environment;
		env.dayNight = true;
		env.timeOfDay = 12;
		env.moonLight = moonObject.Id;
		Check(DayNight.FindSun(scene) == sun, "the sun is the shadow-casting directional light, never the moon");
		DayNight.Update(scene, 0);
		Check(Near(-sunObject.Transform.Forward, DayNight.SunDirection(env), 1e-3f), "the sun light points from the sun at 12:00");
		Check(Near(-moonObject.Transform.Forward, DayNight.MoonDirection(env), 1e-3f), "the moon light points from the moon");
		Check(fill.Transform.Rotation == fillRotation, "other lights are left alone");
		Check(env.timeOfDay == 12, "Edit mode (no time step) does not run the clock");

		// Edit-mode scrub: the time is dragged, the sun follows.
		env.timeOfDay = 18;
		DayNight.Apply(scene);
		let at18 = -sunObject.Transform.Forward;
		Console.WriteLine(scope $"scrub to 18:00: sun light from ({at18.x:F3}, {at18.y:F3}, {at18.z:F3})");
		Check(Near(at18, DayNight.SunDirection(env), 1e-3f), "dragging the time to 18:00 moves the sun");

		// Playing: 60 s of a 24-minute day is one hour.
		DayNight.Update(scene, 60);
		Check(Math.Abs(env.timeOfDay - 19) < 1e-3f, scope $"60 s of a 24 min day is 1 h ({env.timeOfDay})");
		env.dayNightPaused = true;
		DayNight.Update(scene, 60);
		Check(Math.Abs(env.timeOfDay - 19) < 1e-3f, "paused keeps the time");
		env.dayNightPaused = false;
		env.timeOfDay = 23.5f;
		DayNight.Update(scene, 60);
		Check(Math.Abs(env.timeOfDay - 0.5f) < 1e-3f, "the time wraps past midnight");

		// Picking a light by id.
		env.sunLight = fill.Id;
		Check(DayNight.FindSun(scene) == fillLight, "sunLight picks the named light");

		// Save and load.
		env.timeOfDay = 7.25f;
		env.dayLengthMinutes = 12;
		env.latitude = -33;
		env.axisTilt = 20;
		env.northDirection = 45;
		env.dayOfYear = 300;
		env.moonShadows = false;
		env.dayNightPaused = true;
		let text = scope String();
		SceneSerializer.Save(scene, text);
		let loaded = scope Scene();
		SceneSerializer.Load(loaded, text);
		let back = loaded.Environment;
		Check(back.dayNight && back.timeOfDay == 7.25f && back.dayLengthMinutes == 12 && back.latitude == -33 && back.axisTilt == 20 &&
			back.northDirection == 45 && back.dayOfYear == 300 && !back.moonShadows && back.dayNightPaused, "Day / Night settings save and load");
		Check(back.sunLight == fill.Id && back.moonLight == moonObject.Id && loaded.FindById(back.sunLight) != null, "sun and moon light ids save and load");

		// An old scene (no Day / Night lines) loads with it off and writes none.
		let old = scope Scene();
		SceneSerializer.Load(old, "scene \"Old\"\nenv fogDensity 0.01\n");
		Check(!old.Environment.dayNight && old.Environment.timeOfDay == 10 && old.Environment.sunLight == 0, "an old scene loads with Day / Night off");
		let oldText = scope String();
		SceneSerializer.Save(old, oldText);
		Check(!oldText.Contains("dayNight") && !oldText.Contains("timeOfDay") && !oldText.Contains("sunLight"), "a scene without Day / Night saves no Day / Night lines");
	}
}
