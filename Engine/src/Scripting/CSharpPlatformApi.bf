using System;
using System.Collections;

namespace Tallow;

/// Engine services C# scripts use that are not components: gamepads, touch, the window, quality presets,
/// achievements and stats, subtitles, dialogue variables, decals and wind. Each wraps the Beef static class of the
/// same purpose with the binding generator's types (Managed/Tallow.API/Platform.cs gives C# its usual shape).
[CSharpExpose]
static class CSharpPlatform
{
	static int Pad(int32 pad) => Math.Clamp(pad, 0, Gamepad.MaxPads - 1);

	/// Copies text for C# (UTF-8); the text's length, which may be more than the buffer (call again with more room).
	static int32 Copy(StringView text, Span<uint8> buffer)
	{
		let count = Math.Min(text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}

	// ---- gamepads

	[CSharpExpose]
	public static bool GamepadConnected(int32 pad) => pad >= 0 && pad < Gamepad.MaxPads && Gamepad.IsConnected(pad);

	/// 0 Generic, 1 Xbox, 2 PlayStation, 3 Nintendo.
	[CSharpExpose]
	public static int32 GamepadKindOf(int32 pad) => (int32)Gamepad.Kind(Pad(pad));

	[CSharpExpose]
	public static int32 GamepadNameOf(int32 pad, Span<uint8> buffer) => Copy(Gamepad.Name(Pad(pad)), buffer);

	/// state 0 held, 1 pressed this frame, 2 released this frame.
	[CSharpExpose]
	public static bool GamepadButtonState(int32 button, int32 pad, int32 state)
	{
		if (button < 0 || button >= (int32)GamepadButton.Count)
			return false;
		let b = (GamepadButton)button;
		switch (state)
		{
		case 1: return Gamepad.GetButtonDown(b, Pad(pad));
		case 2: return Gamepad.GetButtonUp(b, Pad(pad));
		default: return Gamepad.GetButton(b, Pad(pad));
		}
	}

	[CSharpExpose]
	public static float GamepadAxisValue(int32 axis, int32 pad) =>
		axis >= 0 && axis < (int32)GamepadAxis.Count ? Gamepad.GetAxis((GamepadAxis)axis, Pad(pad)) : 0;

	[CSharpExpose]
	public static void GamepadRumble(float low, float high, float seconds, int32 pad) => Gamepad.Rumble(low, high, seconds, Pad(pad));

	// ---- touch

	[CSharpExpose]
	public static int32 TouchCount() => (int32)Touch.Fingers.Count;

	/// Finger index: values gets id, x, y, start x, start y, delta x, delta y, start time, down (1/0). False past the end.
	[CSharpExpose]
	public static bool TouchFinger(int32 index, Span<float> values)
	{
		if (index < 0 || index >= Touch.Fingers.Count || values.Length < 9)
			return false;
		let finger = Touch.Fingers[index];
		values[0] = (float)(finger.id & 0xFFFFFF);
		values[1] = finger.position.x;
		values[2] = finger.position.y;
		values[3] = finger.start.x;
		values[4] = finger.start.y;
		values[5] = finger.delta.x;
		values[6] = finger.delta.y;
		values[7] = finger.startTime;
		values[8] = finger.down ? 1 : 0;
		return true;
	}

	// ---- the window and quality

	[CSharpExpose]
	public static bool WindowFullscreen() => GameWindow.Fullscreen;

	[CSharpExpose]
	public static void SetWindowFullscreen(bool on) => GameWindow.Fullscreen = on;

	/// 0 Low, 1 Medium, 2 High, 3 Ultra, 4 Custom.
	[CSharpExpose]
	public static int32 QualityCurrent() => (int32)Quality.Level;

	[CSharpExpose]
	public static int32 QualityRecommended() => (int32)Quality.Recommended;

	/// Applies a preset (0 Low ... 3 Ultra) at once; save: kept for the next start. False for Custom or out of range.
	[CSharpExpose]
	public static bool QualitySet(int32 level, bool save)
	{
		if (level < 0 || level > (int32)QualityLevel.Ultra)
			return false;
		Quality.Set((QualityLevel)level);
		if (save)
			Quality.Save();
		return true;
	}

	/// One quality setting's value as text (Quality.Write's names: vsync, renderScale, shadows...), its length; -1 for
	/// a name that is not one.
	[CSharpExpose]
	public static int32 QualityValueText(StringView name, Span<uint8> buffer)
	{
		let all = scope String();
		Quality.Write(Quality.Current, all);
		for (let line in all.Split('\n'))
		{
			let equals = line.IndexOf('=');
			if (equals > 0 && line.Substring(0, equals) == name)
				return Copy(line.Substring(equals + 1), buffer);
		}
		return -1;
	}

	/// Changes one quality setting and applies it (the level becomes Custom unless the values match a preset); save:
	/// kept for the next start. False for a name that is not a setting.
	[CSharpExpose]
	public static bool QualitySetValue(StringView name, StringView value, bool save)
	{
		let all = scope String();
		Quality.Write(Quality.Current, all);
		if (!all.StartsWith(scope $"{name}=") && !all.Contains(scope $"\n{name}="))
			return false;
		Quality.Current = Quality.Read(scope $"{name}={value}", Quality.Current);
		Quality.Level = Quality.LevelOf(Quality.Current);
		Quality.Apply();
		if (save)
			Quality.Save();
		return true;
	}

	/// Applies one preset's lighting settings only (0 Low ... 3 Ultra): shadows, ambient occlusion, global illumination,
	/// reflections and the volumetric fog grid. The render scale, upscaler and the other quality settings stay as they
	/// are. False for Custom or out of range.
	[CSharpExpose]
	public static bool QualitySetLighting(int32 level)
	{
		if (level < 0 || level > (int32)QualityLevel.Ultra)
			return false;
		Quality.SetLighting((QualityLevel)level);
		return true;
	}

	/// The preset whose lighting settings are in use (0 Low ... 3 Ultra), or 4 (Custom).
	[CSharpExpose]
	public static int32 QualityLightingLevel() => (int32)Quality.LightingLevel;

	/// Changes one lighting setting (Quality.Write's names: shadows, shadowMapSize, ambientOcclusion, reflectionProbes,
	/// volumetricFog, fogTileSize, fogSlices, fogTemporal or fogLocalLights) and applies only the lighting settings;
	/// save: kept for the next start. False for a name a lighting preset does not change.
	[CSharpExpose]
	public static bool QualitySetLightingValue(StringView name, StringView value, bool save)
	{
		if (!Quality.SetLightingValue(name, value))
			return false;
		if (save)
			Quality.Save();
		return true;
	}

	/// Whether an upscaler (0 Off, 1 FSR 1, 2 FSR 2, 3 DLSS) can run on this machine: -1 when it can, else the length of
	/// the reason it cannot (written to the buffer).
	[CSharpExpose]
	public static int32 UpscalerReason(int32 kind, Span<uint8> buffer)
	{
		if (kind < 0 || kind > (int32)UpscalerKind.DLSS)
			return Copy("Not an upscaler", buffer);
		let reason = scope String();
		if (Upscaling.IsSupported((UpscalerKind)kind, reason))
			return -1;
		return Copy(reason, buffer);
	}

	/// The upscaler really in use: the setting, or FSR 1 (1) when that one cannot run here.
	[CSharpExpose]
	public static int32 UpscalerEffective() => (int32)Upscaling.Effective;

	/// The graphics card's maker: 0 unknown, 1 NVIDIA, 2 AMD, 3 Intel, 4 Apple, 5 other.
	[CSharpExpose]
	public static int32 GpuVendorKind() => (int32)Upscaling.Vendor;

	/// The antialiasing really in use (an AntialiasMode number): the setting, or what the card or the engine can do instead.
	[CSharpExpose]
	public static int32 AntialiasEffective() => (int32)Antialiasing.Resolve(RenderView.AntialiasingMode);

	// ---- achievements and stats (Steam when the game runs there, else saved locally)

	[CSharpExpose]
	public static bool AchievementUnlock(StringView id) => Achievements.Unlock(id);

	[CSharpExpose]
	public static bool AchievementUnlocked(StringView id) => Achievements.IsUnlocked(id);

	[CSharpExpose]
	public static void AchievementProgress(StringView id, int32 current, int32 max) => Achievements.SetProgress(id, current, max);

	[CSharpExpose]
	public static void AchievementClear(StringView id)
	{
		if (id.IsEmpty)
			Achievements.ClearAll();
		else
			Achievements.Clear(id);
	}

	[CSharpExpose]
	public static int32 StatGet(StringView name, bool localOnly) => Achievements.GetStat(name, localOnly);

	[CSharpExpose]
	public static void StatSet(StringView name, int32 value, bool localOnly) => Achievements.SetStat(name, value, localOnly);

	[CSharpExpose]
	public static int32 StatAdd(StringView name, int32 amount, bool localOnly) => Achievements.AddStat(name, amount, localOnly);

	// ---- subtitles

	/// A subtitle line (speaker may be empty) for seconds (0: worked out from its length); colour rgba. Its id.
	[CSharpExpose]
	public static int32 SubtitleShow(StringView speaker, StringView text, float seconds, Vector4 color) =>
		Subtitles.Show(speaker, text, seconds, .(color.x, color.y, color.z, color.w));

	/// A sound caption ("[door creaks]").
	[CSharpExpose]
	public static int32 SubtitleCaption(StringView text, float seconds) => Subtitles.Caption(text, seconds);

	[CSharpExpose]
	public static void SubtitleHide(int32 id) => Subtitles.Hide(id);

	[CSharpExpose]
	public static bool SubtitleShowing(int32 id) => Subtitles.IsShowing(id);

	[CSharpExpose]
	public static void SubtitlesClear() => Subtitles.Clear();

	// ---- dialogue variables (what dialogue conditions and Set nodes read and write)

	[CSharpExpose]
	public static float DialogueVariable(StringView name) => DialogueVariables.Get(name);

	[CSharpExpose]
	public static void SetDialogueVariable(StringView name, float value) => DialogueVariables.Set(name, value);

	[CSharpExpose]
	public static bool DialogueCondition(StringView condition) => DialogueVariables.Evaluate(condition);

	[CSharpExpose]
	public static void DialogueVariablesClear() => DialogueVariables.Clear();

	// ---- decals and wind

	/// A short-lived decal pressed onto surfaces at a point (bullet holes, footprints): texture path, size in metres,
	/// lifetime in seconds (0: until there are too many), colour rgba, spin in degrees. False without the scene.
	[CSharpExpose]
	public static bool DecalSpawn(uint64 session, Vector3 position, Vector3 normal, StringView texture, float size,
		float lifetime, Vector4 color, float spin)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		if (scene == null || texture.IsEmpty)
			return false;
		Decals.Spawn(scene, position, normal, texture, size, lifetime, .(color.x, color.y, color.z, color.w), spin);
		return true;
	}

	[CSharpExpose]
	public static void DecalsClear(uint64 session)
	{
		if (let scene = CSharpRuntime.PhysicsScene(session))
			Decals.Clear(scene);
	}

	/// A decal box of any size and turn (rotation as x, y, z, w), pressed along its Z axis.
	[CSharpExpose]
	public static bool DecalSpawnBox(uint64 session, Vector3 position, Vector4 rotation, Vector3 size, StringView texture,
		float lifetime, Vector4 color, float angleLimit)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		if (scene == null || texture.IsEmpty)
			return false;
		let volume = Matrix4.TRS(position, Quaternion(rotation.x, rotation.y, rotation.z, rotation.w), size);
		Decals.Spawn(scene, volume, texture, lifetime, .(color.x, color.y, color.z, color.w), angleLimit);
		return true;
	}

	/// How many spawned decals a scene keeps (the oldest make way).
	[CSharpExpose]
	public static int32 DecalsMax() => (int32)Decals.MaxSpawned;

	[CSharpExpose]
	public static void SetDecalsMax(int32 count) => Decals.MaxSpawned = Math.Max(count, 0);

	/// The wind's velocity at a point (Wind Zones and the scene's wind), metres a second.
	[CSharpExpose]
	public static Vector3 WindAt(uint64 session, Vector3 position)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		return scene != null ? Wind.At(scene, position) : .Zero;
	}

	/// How gusty the wind is now, 0 to 1.
	[CSharpExpose]
	public static float WindGusts(uint64 session)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		return scene != null ? Wind.Gusts(scene) : 0;
	}

	// ---- save games ([Saved] fields and the objects SaveSystem keeps)

	/// Starts saving (load false) or loading a slot; the handle's id.
	[CSharpExpose]
	public static int32 SaveStart(StringView slot, bool load) =>
		(load ? SaveSystem.Load(slot.IsEmpty ? "default" : slot) : SaveSystem.Save(slot.IsEmpty ? "default" : slot)).id;

	/// How a save or load is doing: bit 1 done, 2 succeeded, 4 found (loading: the slot held a save).
	[CSharpExpose]
	public static int32 SaveProgress(int32 id)
	{
		let handle = SaveHandle(id);
		return (handle.Done ? 1 : 0) | (handle.Succeeded ? 2 : 0) | (handle.Found ? 4 : 0);
	}

	[CSharpExpose]
	public static int32 SaveError(int32 id, Span<uint8> buffer) => Copy(SaveHandle(id).Error(.. scope .()), buffer);

	[CSharpExpose]
	public static bool SaveExists(StringView slot) => SaveSystem.Exists(slot.IsEmpty ? "default" : slot);

	[CSharpExpose]
	public static void SaveDelete(StringView slot) => SaveSystem.Delete(slot.IsEmpty ? "default" : slot);

	/// The save slots, one a line.
	[CSharpExpose]
	public static int32 SaveSlots(Span<uint8> buffer)
	{
		let slots = scope List<String>();
		SaveSystem.ListSlots(slots);
		let text = scope String();
		for (let slot in slots)
			text.Append(slot, "\n");
		ClearAndDeleteItems(slots);
		return Copy(text, buffer);
	}

	// ---- voice chat

	/// 1 a microphone exists, 2 it is open, 4 this machine is sending its voice now.
	[CSharpExpose]
	public static int32 VoiceState() =>
		(VoiceChat.HasMicrophone ? 1 : 0) | (VoiceChat.MicrophoneOpen ? 2 : 0) | (VoiceChat.IsTransmitting ? 4 : 0);

	[CSharpExpose]
	public static float VoiceMicrophoneLevel() => VoiceChat.MicrophoneLevel;

	/// Talks from code (an open-mic toggle, say) as if the push-to-talk key were held.
	[CSharpExpose]
	public static void VoiceSetTalk(bool on) => VoiceChat.Talk = on;

	[CSharpExpose]
	public static bool VoiceTalk() => VoiceChat.Talk;

	[CSharpExpose]
	public static bool VoiceSpeaking(int32 clientId) => VoiceChat.IsSpeaking(clientId);

	[CSharpExpose]
	public static void VoiceMute(int32 clientId, bool muted) => VoiceChat.Mute(clientId, muted);

	[CSharpExpose]
	public static bool VoiceMuted(int32 clientId) => VoiceChat.IsMuted(clientId);

	[CSharpExpose]
	public static void VoiceSetVolume(int32 clientId, float volume) => VoiceChat.SetPlayerVolume(clientId, volume);

	[CSharpExpose]
	public static float VoiceVolume(int32 clientId) => VoiceChat.GetPlayerVolume(clientId);

	/// A voice chat setting by number (bools as 0 or 1): 0 Enabled, 1 PushToTalk, 2 PushToTalkKey, 3 Activation,
	/// 4 ReleaseTime, 5 MicrophoneVolume, 6 Volume, 7 AutoLevel, 8 Muted, 9 Deafened, 10 Proximity, 11 MinDistance,
	/// 12 MaxDistance, 13 TeamOnly, 14 Loopback, 15 Bitrate.
	[CSharpExpose]
	public static float VoiceSetting(int32 which)
	{
		switch (which)
		{
		case 0: return VoiceChat.Enabled ? 1 : 0;
		case 1: return VoiceChat.PushToTalk ? 1 : 0;
		case 2: return (float)(int32)VoiceChat.PushToTalkKey;
		case 3: return VoiceChat.Activation;
		case 4: return VoiceChat.ReleaseTime;
		case 5: return VoiceChat.MicrophoneVolume;
		case 6: return VoiceChat.Volume;
		case 7: return VoiceChat.AutoLevel ? 1 : 0;
		case 8: return VoiceChat.Muted ? 1 : 0;
		case 9: return VoiceChat.Deafened ? 1 : 0;
		case 10: return VoiceChat.Proximity ? 1 : 0;
		case 11: return VoiceChat.MinDistance;
		case 12: return VoiceChat.MaxDistance;
		case 13: return VoiceChat.TeamOnly ? 1 : 0;
		case 14: return VoiceChat.Loopback ? 1 : 0;
		case 15: return VoiceChat.Bitrate;
		default: return 0;
		}
	}

	[CSharpExpose]
	public static void SetVoiceSetting(int32 which, float value)
	{
		let on = value != 0;
		switch (which)
		{
		case 0: VoiceChat.Enabled = on;
		case 1: VoiceChat.PushToTalk = on;
		case 2: VoiceChat.PushToTalkKey = (KeyCode)(int32)value;
		case 3: VoiceChat.Activation = Math.Clamp(value, 0, 1);
		case 4: VoiceChat.ReleaseTime = Math.Max(value, 0);
		case 5: VoiceChat.MicrophoneVolume = Math.Max(value, 0);
		case 6: VoiceChat.Volume = Math.Max(value, 0);
		case 7: VoiceChat.AutoLevel = on;
		case 8: VoiceChat.Muted = on;
		case 9: VoiceChat.Deafened = on;
		case 10: VoiceChat.Proximity = on;
		case 11: VoiceChat.MinDistance = Math.Max(value, 0);
		case 12: VoiceChat.MaxDistance = Math.Max(value, 0);
		case 13: VoiceChat.TeamOnly = on;
		case 14: VoiceChat.Loopback = on;
		case 15: VoiceChat.Bitrate = (int32)Math.Clamp(value, 6000, 128000);
		default:
		}
	}

	[CSharpExpose]
	public static int32 VoicePushToTalkAction(Span<uint8> buffer) => Copy(VoiceChat.PushToTalkAction, buffer);

	[CSharpExpose]
	public static void SetVoicePushToTalkAction(StringView action) => VoiceChat.PushToTalkAction.Set(action);

	static List<int64> sSpeakingChanges = new .() ~ delete _;
	static bool sWatchingSpeaking;

	/// The next player who started or stopped being heard (client id in the low 32 bits, bit 32 set when they
	/// started), or -1 when there is none. The first call starts collecting them.
	[CSharpExpose]
	public static int64 VoiceTakeSpeakingChange()
	{
		if (!sWatchingSpeaking)
		{
			sWatchingSpeaking = true;
			VoiceChat.OnSpeakingChanged.Add(new (clientId, speaking) =>
				{
					if (sSpeakingChanges.Count < 1024)
						sSpeakingChanges.Add((int64)(uint32)clientId | (speaking ? (1L << 32) : 0));
				});
		}
		if (sSpeakingChanges.IsEmpty)
			return -1;
		return sSpeakingChanges.PopFront();
	}

	// ---- the game's asset files (in the project, or packed in a built game)

	[CSharpExpose]
	public static bool AssetExists(StringView path) => !path.IsEmpty && Assets.FileExists(path);

	/// Makes a folder's files loadable by their path inside it, ahead of the game's own (mods, Workshop items).
	[CSharpExpose]
	public static void AssetsAddSearchPath(StringView folder)
	{
		if (!folder.IsEmpty)
			Assets.AddSearchPath(folder);
	}

	/// The file's bytes into buffer; its length (more than the buffer: call again with room), or -1 when missing.
	[CSharpExpose]
	public static int32 AssetRead(StringView path, Span<uint8> buffer)
	{
		let data = scope List<uint8>();
		if (path.IsEmpty || !Assets.ReadBytes(path, data))
			return -1;
		for (int i < Math.Min(data.Count, buffer.Length))
			buffer[i] = data[i];
		return (int32)data.Count;
	}
}
