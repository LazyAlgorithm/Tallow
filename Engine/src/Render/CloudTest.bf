using System;

namespace Tallow;

/// `--cloud-test settings`: prints the cloud settings with no window, checks that a scene saves and reloads every
/// one of them, that a scene without them loads with clouds off (the class defaults), and that Environment.Reset
/// puts them back to off.
static class CloudTest
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

	static void Print(StringView label, SceneEnvironment env)
	{
		Console.WriteLine(scope $"{label}: clouds={env.clouds} mode={(int32)env.cloudMode} coverage={env.cloudCoverage} density={env.cloudDensity} altitude={env.cloudHeight} thickness={env.cloudThickness} wind={env.cloudWindSpeed} m/s at {env.cloudWindDirection} deg seed={env.cloudSeed} anisotropy={env.cloudAnisotropy} ambient={env.cloudAmbient} tint=({env.cloudTint.r}, {env.cloudTint.g}, {env.cloudTint.b}, {env.cloudTint.a}) distance={env.cloudDistance} resolution={env.cloudResolution}");
	}

	public static int RunSettings()
	{
		// A distinct value in every field, so a line that is lost or swapped shows up in the comparison.
		let scene = scope Scene();
		let env = scene.Environment;
		env.clouds = true;
		env.cloudMode = .TwoD;
		env.cloudCoverage = 0.73f;
		env.cloudDensity = 0.031f;
		env.cloudHeight = 2345;
		env.cloudThickness = 1234;
		env.cloudWindSpeed = 17.5f;
		env.cloudWindDirection = 218;
		env.cloudSeed = 987654;
		env.cloudAnisotropy = -0.35f;
		env.cloudAmbient = 0.42f;
		env.cloudTint = .(0.9f, 0.93f, 1.0f);
		env.cloudDistance = 15500;
		env.cloudResolution = 0.75f;
		Print("set", env);

		// Save and reload.
		let text = scope String();
		SceneSerializer.Save(scene, text);
		Console.WriteLine("saved scene:");
		Console.Write(text);
		let loaded = scope Scene();
		SceneSerializer.Load(loaded, text);
		let back = loaded.Environment;
		Print("reloaded", back);
		Check(back.clouds, "clouds on");
		Check(back.cloudMode == .TwoD, "cloud mode");
		Check(back.cloudCoverage == 0.73f, "cloud coverage");
		Check(back.cloudDensity == 0.031f, "cloud density");
		Check(back.cloudHeight == 2345, "cloud altitude");
		Check(back.cloudThickness == 1234, "cloud thickness");
		Check(back.cloudWindSpeed == 17.5f, "cloud wind speed");
		Check(back.cloudWindDirection == 218, "cloud wind direction");
		Check(back.cloudSeed == 987654, "cloud seed");
		Check(back.cloudAnisotropy == -0.35f, "cloud anisotropy");
		Check(back.cloudAmbient == 0.42f, "cloud ambient");
		Check(back.cloudTint.r == 0.9f && back.cloudTint.g == 0.93f && back.cloudTint.b == 1.0f && back.cloudTint.a == 1.0f, "cloud tint");
		Check(back.cloudDistance == 15500, "cloud distance");
		Check(back.cloudResolution == 0.75f, "cloud resolution");
		Check(text.Contains("env cloudSeed 987654\n"), "the seed is written as a whole number");

		// An old scene (no cloud lines) loads with clouds off and every field at the class default, and saves none.
		let old = scope Scene();
		SceneSerializer.Load(old, "scene \"Old\"\nenv fogDensity 0.01\n");
		let fresh = scope SceneEnvironment();
		let o = old.Environment;
		Print("old scene", o);
		Check(!o.clouds && o.cloudMode == fresh.cloudMode && o.cloudCoverage == fresh.cloudCoverage &&
			o.cloudDensity == fresh.cloudDensity && o.cloudHeight == fresh.cloudHeight &&
			o.cloudThickness == fresh.cloudThickness && o.cloudWindSpeed == fresh.cloudWindSpeed &&
			o.cloudWindDirection == fresh.cloudWindDirection && o.cloudSeed == fresh.cloudSeed &&
			o.cloudAnisotropy == fresh.cloudAnisotropy && o.cloudAmbient == fresh.cloudAmbient &&
			o.cloudTint == fresh.cloudTint && o.cloudDistance == fresh.cloudDistance &&
			o.cloudResolution == fresh.cloudResolution, "an old scene loads with clouds off and the class defaults");
		let oldText = scope String();
		SceneSerializer.Save(old, oldText);
		Check(!oldText.Contains("env clouds") && !oldText.Contains("env cloudMode") && !oldText.Contains("env cloudCoverage") &&
			!oldText.Contains("env cloudDensity") && !oldText.Contains("env cloudHeight") && !oldText.Contains("env cloudThickness") &&
			!oldText.Contains("env cloudWindSpeed") && !oldText.Contains("env cloudWindDirection") && !oldText.Contains("env cloudSeed") &&
			!oldText.Contains("env cloudAnisotropy") && !oldText.Contains("env cloudAmbient") && !oldText.Contains("env cloudTint") &&
			!oldText.Contains("env cloudDistance") && !oldText.Contains("env cloudResolution"),
			"a scene with clouds off saves no cloud lines");

		// Reset puts clouds back to off with the default values.
		let reset = scope SceneEnvironment();
		reset.clouds = true;
		reset.cloudCoverage = 0.9f;
		reset.cloudSeed = 42;
		reset.Reset();
		let defaults = scope SceneEnvironment();
		Check(!reset.clouds && reset.cloudCoverage == defaults.cloudCoverage && reset.cloudSeed == defaults.cloudSeed,
			"Environment.Reset puts clouds back to off and the defaults");

		// Out-of-range values are clamped on load.
		let clamped = scope Scene();
		SceneSerializer.Load(clamped, "scene \"Clamped\"\nenv cloudMode 9\nenv cloudCoverage 2\nenv cloudAnisotropy -4\nenv cloudDistance 1\nenv cloudResolution 5\nenv cloudThickness 0\n");
		let c = clamped.Environment;
		Check(c.cloudMode == .TwoD && c.cloudCoverage == 1 && c.cloudAnisotropy == -0.9f && c.cloudDistance == 500 &&
			c.cloudResolution == 1 && c.cloudThickness == 1, "cloud values are clamped on load");

		Console.WriteLine(sFailed == 0 ? "CLOUD TEST PASS" : scope $"CLOUD TEST FAIL ({sFailed})");
		return sFailed == 0 ? 0 : 1;
	}
}
