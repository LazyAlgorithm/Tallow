using System;

namespace Tallow;

/// The scene's environment (sky, ambient light, fog, screen effects, colour grading) and the player's screen effect
/// choices, for C# (Managed/Tallow.API/Environment.cs). A setting is a number into the list there; colours travel as
/// four floats.
[CSharpExpose]
static class CSharpEnvironment
{
	/// Reads a setting into values (one float, or four for a colour). False without a scene or for an unknown one.
	[CSharpExpose]
	public static bool Get(uint64 session, int32 which, Span<float> values)
	{
		let env = CSharpRuntime.PhysicsScene(session)?.Environment;
		if (env == null || values.Length < 4)
			return false;
		switch (which)
		{
		case 0: values[0] = env.skyZenith.r; values[1] = env.skyZenith.g; values[2] = env.skyZenith.b; values[3] = env.skyZenith.a;
		case 1: values[0] = env.skyHorizon.r; values[1] = env.skyHorizon.g; values[2] = env.skyHorizon.b; values[3] = env.skyHorizon.a;
		case 2: values[0] = env.skyGround.r; values[1] = env.skyGround.g; values[2] = env.skyGround.b; values[3] = env.skyGround.a;
		case 3: values[0] = env.ambientSky.r; values[1] = env.ambientSky.g; values[2] = env.ambientSky.b; values[3] = env.ambientSky.a;
		case 4: values[0] = env.ambientGround.r; values[1] = env.ambientGround.g; values[2] = env.ambientGround.b; values[3] = env.ambientGround.a;
		case 5: values[0] = env.ambientIntensity;
		case 6: values[0] = env.fogColor.r; values[1] = env.fogColor.g; values[2] = env.fogColor.b; values[3] = env.fogColor.a;
		case 7: values[0] = env.fogDensity;
		case 8: values[0] = env.exposure;
		case 9: values[0] = env.bloom;
		case 10: values[0] = env.bloomThreshold;
		case 11: values[0] = env.shadowDistance;
		case 12: values[0] = env.reflectionIntensity;
		case 13: values[0] = env.ambientOcclusion;
		case 14: values[0] = env.occlusionRadius;
		case 15: values[0] = env.depthOfField;
		case 16: values[0] = env.focusDistance;
		case 17: values[0] = env.focusRange;
		case 18: values[0] = env.autoFocus ? 1 : 0;
		case 19: values[0] = env.motionBlur;
		case 20: values[0] = env.contrast;
		case 21: values[0] = env.saturation;
		case 22: values[0] = env.temperature;
		case 23: values[0] = env.tint;
		case 24: values[0] = env.colorFilter.r; values[1] = env.colorFilter.g; values[2] = env.colorFilter.b; values[3] = env.colorFilter.a;
		case 25: values[0] = env.vignette;
		case 26: values[0] = env.colorLookupStrength;
		case 27: values[0] = env.globalIllumination;
		case 28: values[0] = (int32)env.skyMode;
		case 29: values[0] = env.skyboxRotation;
		case 30: values[0] = env.skyboxExposure;
		case 31: values[0] = env.skyboxTint.r; values[1] = env.skyboxTint.g; values[2] = env.skyboxTint.b; values[3] = env.skyboxTint.a;
		case 32: values[0] = env.skyboxBlend;
		default: return false;
		}
		return true;
	}

	[CSharpExpose]
	public static bool Set(uint64 session, int32 which, float x, float y, float z, float w)
	{
		let env = CSharpRuntime.PhysicsScene(session)?.Environment;
		if (env == null || !x.IsFinite || !y.IsFinite || !z.IsFinite || !w.IsFinite)
			return false;
		switch (which)
		{
		case 0: env.skyZenith = .(x, y, z, w);
		case 1: env.skyHorizon = .(x, y, z, w);
		case 2: env.skyGround = .(x, y, z, w);
		case 3: env.ambientSky = .(x, y, z, w);
		case 4: env.ambientGround = .(x, y, z, w);
		case 5: env.ambientIntensity = x;
		case 6: env.fogColor = .(x, y, z, w);
		case 7: env.fogDensity = x;
		case 8: env.exposure = x;
		case 9: env.bloom = x;
		case 10: env.bloomThreshold = x;
		case 11: env.shadowDistance = x;
		case 12: env.reflectionIntensity = x;
		case 13: env.ambientOcclusion = x;
		case 14: env.occlusionRadius = x;
		case 15: env.depthOfField = x;
		case 16: env.focusDistance = x;
		case 17: env.focusRange = x;
		case 18: env.autoFocus = x != 0;
		case 19: env.motionBlur = x;
		case 20: env.contrast = x;
		case 21: env.saturation = x;
		case 22: env.temperature = x;
		case 23: env.tint = x;
		case 24: env.colorFilter = .(x, y, z, w);
		case 25: env.vignette = x;
		case 26: env.colorLookupStrength = x;
		case 27: env.globalIllumination = Math.Clamp(x, 0, 4);
		case 28: env.skyMode = (SkyMode)(int32)Math.Clamp(x, 0, 2);
		case 29: env.skyboxRotation = x;
		case 30: env.skyboxExposure = Math.Clamp(x, -16, 16);
		case 31: env.skyboxTint = .(x, y, z, w);
		case 32: env.skyboxBlend = Math.Clamp(x, 0, 1);
		default: return false;
		}
		return true;
	}

	/// The skybox (SkyMode.Custom): its project path, copied into buffer; the full length is returned (-1 without a
	/// scene).
	[CSharpExpose]
	public static int32 GetSkybox(uint64 session, Span<uint8> buffer)
	{
		let env = CSharpRuntime.PhysicsScene(session)?.Environment;
		if (env == null)
			return -1;
		let count = Math.Min(env.skybox.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)env.skybox[i];
		return (int32)env.skybox.Length;
	}

	/// Sets the skybox's project path (empty: none). Loaded on its first draw.
	[CSharpExpose]
	public static bool SetSkybox(uint64 session, StringView path)
	{
		let env = CSharpRuntime.PhysicsScene(session)?.Environment;
		if (env == null)
			return false;
		env.skybox.Set(path);
		return true;
	}

	/// ScreenEffects by number: 0 AmbientOcclusion, 1 DepthOfField, 2 MotionBlur, 3 WaterReflections,
	/// 4 SurfaceReflections (bools as 0 or 1), 5 MotionBlurAmount, 6 Brightness, 7 GlobalIllumination (0 ambient,
	/// 1 baked, 2 half-resolution SSGI, 3 dynamic GI, 4 dynamic GI + SSGI).
	[CSharpExpose]
	public static float GetScreenEffect(int32 which)
	{
		switch (which)
		{
		case 0: return ScreenEffects.AmbientOcclusion ? 1 : 0;
		case 1: return ScreenEffects.DepthOfField ? 1 : 0;
		case 2: return ScreenEffects.MotionBlur ? 1 : 0;
		case 3: return ScreenEffects.WaterReflections ? 1 : 0;
		case 4: return ScreenEffects.SurfaceReflections ? 1 : 0;
		case 5: return ScreenEffects.MotionBlurAmount;
		case 6: return ScreenEffects.Brightness;
		case 7: return (int32)ScreenEffects.GlobalIllumination;
		default: return 0;
		}
	}

	[CSharpExpose]
	public static void SetScreenEffect(int32 which, float value)
	{
		switch (which)
		{
		case 0: ScreenEffects.AmbientOcclusion = value != 0;
		case 1: ScreenEffects.DepthOfField = value != 0;
		case 2: ScreenEffects.MotionBlur = value != 0;
		case 3: ScreenEffects.WaterReflections = value != 0;
		case 4: ScreenEffects.SurfaceReflections = value != 0;
		case 5: ScreenEffects.MotionBlurAmount = Math.Clamp(value, 0, 2);
		case 6: ScreenEffects.Brightness = Math.Clamp(value, 0.25f, 4);
		case 7: ScreenEffects.GlobalIllumination = (GlobalIlluminationMode)(int32)Math.Clamp(value, 0, 4);
		case 100: ScreenEffects.Reset();
		default:
		}
	}
}
