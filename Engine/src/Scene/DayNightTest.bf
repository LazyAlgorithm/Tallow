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

		ColorChecks();
		SceneChecks();
		Console.WriteLine(sFailed == 0 ? "DAYNIGHT TEST PASS" : scope $"DAYNIGHT TEST FAIL ({sFailed})");
		return sFailed == 0 ? 0 : 1;
	}

	/// The time after noon the sun's elevation crosses 0 (bisection).
	static float Sunset(SceneEnvironment env)
	{
		float lo = 12, hi = 24;
		for (int i = 0; i < 40; i++)
		{
			let mid = (lo + hi) * 0.5f;
			env.timeOfDay = mid;
			if (DayNight.SunElevation(env) > 0)
				lo = mid;
			else
				hi = mid;
		}
		return (lo + hi) * 0.5f;
	}

	static void SunAt(SceneEnvironment env, float hours, StringView label, out float redOverGreen, out float intensity)
	{
		env.timeOfDay = hours;
		let elevation = DayNight.SunElevation(env);
		DayNight.SunLight(env, elevation, var color, out intensity);
		let t = Atmosphere.SunTransmittance(elevation);
		redOverGreen = t.g > 1e-12 ? (float)(t.r / t.g) : float.PositiveInfinity;
		let ambient = Atmosphere.AmbientColors(elevation, env.sunIntensity, 0);
		let sky = ambient.sky.Gamma;
		let fog = ambient.fog.Gamma;
		Console.WriteLine(scope $"  {label} ({hours:F2} h, elev {elevation:F2}): sun colour ({color.r:F3}, {color.g:F3}, {color.b:F3}) intensity {intensity:F4} R/G {redOverGreen:F3}  ambient sky ({sky.r:F3}, {sky.g:F3}, {sky.b:F3}) fog ({fog.r:F3}, {fog.g:F3}, {fog.b:F3})");
	}

	/// D1c: the sun's colour and intensity through the air, the moonlight, Auto Colours.
	static void ColorChecks()
	{
		let env = scope SceneEnvironment();
		env.dayNight = true;
		env.latitude = 40;
		env.dayOfYear = 172;
		env.sunIntensity = Atmosphere.ReferenceSunIntensity;
		let sunset = Sunset(env);
		Console.WriteLine(scope $"sun colour (latitude 40, day 172, sun intensity {env.sunIntensity}; SkyScale {Atmosphere.SkyScale:E4}, FogScale {Atmosphere.FogScale:E4}):");
		SunAt(env, 12, "12:00", var rgNoon, var iNoon);
		SunAt(env, 18, "18:00", var rg18, var i18);
		SunAt(env, sunset, "sunset", var rgSunset, var iSunset);
		SunAt(env, sunset + 0.5f, "sunset + 30 min", ?, var iAfter);
		SunAt(env, 0, "00:00", ?, var iMidnight);
		env.timeOfDay = 12;
		Check(Math.Abs(iNoon - env.sunIntensity * Atmosphere.SunTransmittance(DayNight.SunElevation(env)).Max) < 1e-4f, "noon intensity is Sun Intensity times the transmittance");
		Check(iNoon > 0.9f * env.sunIntensity, "noon is about full strength");
		Check(rgNoon < 1.1f, scope $"noon is about white (R/G {rgNoon:F3})");
		Check(rg18 > rgNoon && rgSunset > rg18 && rgSunset > 2, scope $"R/G rises to sunset ({rgNoon:F3} -> {rg18:F3} -> {rgSunset:F3})");
		// Monotonic in small steps from noon to sunset.
		float last = 0;
		for (float h = 12; h <= sunset; h += 0.25f)
		{
			env.timeOfDay = h;
			let t = Atmosphere.SunTransmittance(DayNight.SunElevation(env));
			let rg = (float)(t.r / t.g);
			if (rg < last - 1e-5f)
			{
				Check(false, scope $"R/G falls at {h:F2} h ({last:F4} -> {rg:F4})");
				break;
			}
			last = rg;
		}
		Check(iSunset < iNoon && i18 < iNoon, "the sun is dimmer low down");
		Check(iAfter < 0.02f * iNoon, scope $"30 min after sunset the sun is about dark ({iAfter:F5})");
		Check(iMidnight == 0, "no sun at midnight");

		// Ambient follows: noon calibrated to the old default brightness, night dark.
		env.timeOfDay = 12;
		let noonAmbient = Atmosphere.AmbientColors(DayNight.SunElevation(env), env.sunIntensity, 0);
		let oldSky = Atmosphere.Rgb(Math.Pow(0.42, 2.2), Math.Pow(0.50, 2.2), Math.Pow(0.62, 2.2));
		Check(Math.Abs(noonAmbient.sky.Luminance / oldSky.Luminance - 1) < 0.15, scope $"noon ambient sky within 15% of the old default ({noonAmbient.sky.Luminance / oldSky.Luminance:F3})");
		Check(noonAmbient.sky.b > noonAmbient.sky.r, "noon ambient sky is blue");
		env.timeOfDay = 0;
		let nightAmbient = Atmosphere.AmbientColors(DayNight.SunElevation(env), env.sunIntensity, 0);
		Check(nightAmbient.sky.Luminance < 0.05 * noonAmbient.sky.Luminance && nightAmbient.sky.Luminance > 0, "night ambient is dark but not black");
		env.timeOfDay = sunset;
		let sunsetAmbient = Atmosphere.AmbientColors(0, env.sunIntensity, 0);
		Check(sunsetAmbient.fog.r / sunsetAmbient.fog.b > noonAmbient.fog.r / noonAmbient.fog.b, "the fog is warmer at sunset than at noon");

		// Moonlight: a full moon high at midnight (day 15, age about 15 days).
		env.dayOfYear = 15;
		env.timeOfDay = 0;
		env.latitude = 0;
		let moonLight = DayNight.MoonLight(env, var moonColor);
		Console.WriteLine(scope $"  full moon midnight: moon elev {Math.Asin(DayNight.MoonDirection(env).y) * Mathf.Rad2Deg:F1}, colour ({moonColor.r:F3}, {moonColor.g:F3}, {moonColor.b:F3}) intensity {moonLight:F4}");
		Check(moonLight > 0 && moonLight <= env.moonIntensity, "moonlight at a full-moon midnight");
		Check(moonColor.b > moonColor.r, "moonlight is cool");
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

		Check(Math.Abs(sun.intensity - env.sunIntensity * (float)Atmosphere.SunTransmittance(DayNight.SunElevation(env)).Max) < 1e-4f, "Day / Night sets the sun light's intensity");
		let ambientBefore = env.ambientSky;
		Check(env.ambientSky == ambientBefore && env.fogColor == scope SceneEnvironment().fogColor, "Auto Colours off keeps the hand-picked colours");
		env.autoColors = true;
		DayNight.Apply(scene);
		Check(env.ambientSky != ambientBefore, "Auto Colours sets the ambient sky");
		env.autoColors = false;
		env.ambientSky = ambientBefore;

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
		env.sunIntensity = 2.5f;
		env.moonIntensity = 0.1f;
		env.autoColors = true;
		let text = scope String();
		SceneSerializer.Save(scene, text);
		let loaded = scope Scene();
		SceneSerializer.Load(loaded, text);
		let back = loaded.Environment;
		Check(back.dayNight && back.timeOfDay == 7.25f && back.dayLengthMinutes == 12 && back.latitude == -33 && back.axisTilt == 20 &&
			back.northDirection == 45 && back.dayOfYear == 300 && !back.moonShadows && back.dayNightPaused &&
			back.sunIntensity == 2.5f && back.moonIntensity == 0.1f && back.autoColors, "Day / Night settings save and load");
		Check(back.sunLight == fill.Id && back.moonLight == moonObject.Id && loaded.FindById(back.sunLight) != null, "sun and moon light ids save and load");

		// An old scene (no Day / Night lines) loads with it off and writes none.
		let old = scope Scene();
		SceneSerializer.Load(old, "scene \"Old\"\nenv fogDensity 0.01\n");
		Check(!old.Environment.dayNight && old.Environment.timeOfDay == 10 && old.Environment.sunLight == 0, "an old scene loads with Day / Night off");
		let oldText = scope String();
		SceneSerializer.Save(old, oldText);
		Check(!oldText.Contains("dayNight") && !oldText.Contains("timeOfDay") && !oldText.Contains("sunLight") && !oldText.Contains("sunIntensity") &&
			!oldText.Contains("autoColors"), "a scene without Day / Night saves no Day / Night lines");
		// Every environment value of the old scene is what it was before Day / Night (the class defaults).
		let fresh = scope SceneEnvironment();
		let o = old.Environment;
		Check(o.ambientSky == fresh.ambientSky && o.ambientGround == fresh.ambientGround && o.fogColor == fresh.fogColor &&
			o.sunIntensity == fresh.sunIntensity && o.moonIntensity == fresh.moonIntensity && !o.autoColors && o.fogDensity == 0.01f,
			"an old scene's environment is unchanged");
		let oldSun = old.CreateGameObject("Sun").AddComponent<Light>();
		let oldColor = oldSun.color;
		DayNight.Update(old, 1);
		Check(oldSun.color == oldColor && oldSun.intensity == 1 && o.ambientSky == fresh.ambientSky, "an old scene's sun keeps its colour");
	}
}
