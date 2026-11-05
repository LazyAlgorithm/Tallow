using System;
using System.Collections;

namespace Tallow;

/// Switches, settings and effects shared without code (docs/networking.md): objects switched on and off
/// (`SetActive`), components enabled and disabled, Lights' settings changed while playing, a Particle System's
/// `Play`, `Decals.Spawn` and `Audio.PlayOneShot`. From the server for anything; from a client, only how the objects
/// it owns look and sound (their lights, and switching their lights, renderers, particles and audio sources on and
/// off), so a client cannot switch off its own collider or bring back a controller the server stopped.
/// Switches and light settings are kept (the latest of each) for players who join later; effects are of the moment.
extension NetworkSync
{
	public const uint8 MsgState = 239;
	public const uint8 MsgEffect = 238;

	enum StateKind : uint8
	{
		Active,
		Enabled,
		Light,
		/// A built-in component (handle) switched on or off: the object, then the handle's full name.
		HandleEnabled
	}

	enum EffectKind : uint8
	{
		Particles,
		Decal,
		Sound
	}

	/// How long, and how far apart, an effect played here and the same effect arriving from the server are taken to be
	/// one: a game that already shares its shots and impacts itself plays each once, not twice.
	const float SameEffectTime = 0.5f;
	const float SameSoundDistance = 2;
	const float SameDecalDistance = 0.5f;

	static void RegisterStateMessages()
	{
		NetworkManager.RegisterMessage(MsgState, new => OnState);
		NetworkManager.RegisterMessage(MsgEffect, new => OnEffect);
	}

	/// Whether every machine has an object: in the scene since the session started, or part of a networked object
	/// (its prefab) since that joined the session. Objects a machine makes for itself later (a first-person body built
	/// under the player, an effect) are its own, even under a networked object.
	static bool Everywhere(NetworkManager network, GameObject object)
	{
		for (var at = object.Transform; at != null; at = at.Parent)
		{
			if (let identity = at.GameObject.GetComponent<NetworkIdentity>())
				return object.Id < identity.[Friend]mPartsIdLimit || object.Id < network.SceneIdLimit;
		}
		return object.Id < network.SceneIdLimit;
	}

	/// Whether this machine decides about an object: the server always, a client for objects it owns.
	static bool Decides(NetworkManager network, GameObject object) => network.IsServer || Owns(network.LocalClientId, object.Transform);

	/// What a client may change on objects it owns: how they look and sound, never how they play.
	static bool Cosmetic(Component component) => component is MeshRenderer || component is SkinnedMeshRenderer || component is ParticleSystem;

	/// The built-in components that are cosmetic in the same way.
	static bool Cosmetic(HandleComponents.Info info) => info.handleType == typeof(Light) || info.handleType == typeof(AudioSource)
		|| info.handleType == typeof(Decal) || info.handleType == typeof(AudioReverbZone);

	/// Sends a state message whose first keyLength bytes name what it is about: the server passes it on and keeps
	/// the latest for players who join later; a client asks the server.
	static void SendState(NetworkManager network, NetWriter payload, int keyLength)
	{
		if (!network.IsServer)
		{
			network.SendToServer(MsgState, payload);
			return;
		}
		network.SendToAll(MsgState, payload);
		let key = scope String();
		for (int i < Math.Min(keyLength, payload.Data.Count))
			payload.Data[i].ToString(key, "X2", null);
		network.RememberState(key, MsgState, payload);
	}

	static void WriteComponentAt(NetWriter payload, Component component)
	{
		WriteTransform(payload, component.Transform);
		payload.Write<uint16>((uint16)Math.Max(component.GameObject.Components.IndexOf(component), 0));
	}

	static Component ReadComponentAt(ref NetReader reader, NetworkManager network)
	{
		if (!ReadTransform(ref reader, network, let transform))
			return null;
		let index = (int)reader.Read<uint16>();
		if (!reader.Ok || transform == null || index >= transform.GameObject.Components.Count)
			return null;
		return transform.GameObject.Components[index];
	}

	// ---- switches ----

	/// ComponentHandle.enabled: a built-in component switched on or off.
	public static void HandleEnabledChanged(GameObject object, HandleComponents.Info info, bool on)
	{
		let network = Active(object.Scene);
		if (network == null || sApplying || info == null || !Everywhere(network, object) || !Decides(network, object)
			|| (!network.IsServer && !Cosmetic(info)))
			return;
		let payload = scope NetWriter();
		payload.Write((uint8)StateKind.HandleEnabled);
		WriteTransform(payload, object.Transform);
		payload.WriteString(info.fullName);
		let keyLength = payload.Data.Count;
		payload.Write<bool>(on);
		SendState(network, payload, keyLength);
	}

	/// GameObject.SetActive: an object switched on or off.
	public static void ActiveChanged(GameObject object)
	{
		let network = Active(object.Scene);
		// Only the server switches whole objects: they may hold colliders and scripts.
		if (network == null || sApplying || !network.IsServer || !Everywhere(network, object))
			return;
		let payload = scope NetWriter();
		payload.Write((uint8)StateKind.Active);
		WriteTransform(payload, object.Transform);
		let keyLength = payload.Data.Count;
		payload.Write<bool>(object.ActiveSelf);
		SendState(network, payload, keyLength);
	}

	/// Component.Enabled: a component switched on or off.
	public static void EnabledChanged(Component component)
	{
		let network = Active(component.Scene);
		if (network == null || sApplying || component is NetworkIdentity || !Everywhere(network, component.GameObject) || !Decides(network, component.GameObject)
			|| (!network.IsServer && !Cosmetic(component)))
			return;
		let payload = scope NetWriter();
		payload.Write((uint8)StateKind.Enabled);
		WriteComponentAt(payload, component);
		let keyLength = payload.Data.Count;
		payload.Write<bool>(component.Enabled);
		SendState(network, payload, keyLength);
	}

	// ---- lights ----

	/// A Light's settings, as one value to compare and send.
	[CRepr]
	struct LightSettings
	{
		public int32 type;
		public Color color;
		public float intensity, range, innerSpotAngle, spotAngle, shadowStrength;
		public bool inverseSquare, castShadows, bakedOnly, enabled;

		public this(Light light)
		{
			this = default;
			enabled = light.enabled;
			type = (int32)light.type;
			color = light.color;
			intensity = light.intensity;
			range = light.range;
			innerSpotAngle = light.innerSpotAngle;
			spotAngle = light.spotAngle;
			shadowStrength = light.shadowStrength;
			inverseSquare = light.inverseSquare;
			castShadows = light.castShadows;
			bakedOnly = light.bakedOnly;
		}

		public bool Valid => type >= 0 && type <= 2 && color.r.IsFinite && color.g.IsFinite && color.b.IsFinite && color.a.IsFinite && intensity.IsFinite && range.IsFinite
			&& innerSpotAngle.IsFinite && spotAngle.IsFinite && shadowStrength.IsFinite;

		public void Apply(Light light)
		{
			light.type = (LightType)type;
			light.color = color;
			light.intensity = intensity;
			light.range = range;
			light.innerSpotAngle = innerSpotAngle;
			light.spotAngle = spotAngle;
			light.shadowStrength = shadowStrength;
			light.inverseSquare = inverseSquare;
			light.castShadows = castShadows;
			light.bakedOnly = bakedOnly;
			light.enabled = enabled;
		}

		public uint64 Hash
		{
			get
			{
				var copy = this;
				uint64 hash = 14695981039346656037UL;
				let bytes = (uint8*)&copy;
				for (int i < sizeof(LightSettings))
					hash = (hash ^ bytes[i]) * 1099511628211UL;
				// 0 means "not looked at yet".
				return hash == 0 ? 1 : hash;
			}
		}
	}

	/// Each tick: Lights whose settings (or on/off) changed since they were last looked at are sent (by the server,
	/// or by the client that owns them). A light seen for the first time is only noted: every machine has it as it
	/// is. A light is found by its object, which has one at most.
	public static void WatchLights(NetworkManager network)
	{
		let payload = scope NetWriter();
		for (let light in network.Scene.AllLights)
		{
			let settings = LightSettings(light);
			let hash = settings.Hash;
			let seen = light.SharedHash;
			if (seen == hash)
				continue;
			light.SharedHash = hash;
			if (seen == 0 || !Everywhere(network, light.GameObject) || !Decides(network, light.GameObject))
				continue;
			payload.Clear();
			payload.Write((uint8)StateKind.Light);
			WriteTransform(payload, light.Transform);
			let keyLength = payload.Data.Count;
			payload.Write(settings);
			SendState(network, payload, keyLength);
		}
	}

	static void OnState(int32 sender, ref NetReader reader)
	{
		let network = Active(Scene.Active);
		if (network == null)
			return;
		let start = reader.Position;
		let kind = (StateKind)reader.Read<uint8>();
		GameObject object = null;
		Component component = null;
		HandleComponents.Info handle = null;
		if (kind == .HandleEnabled)
		{
			if (!ReadTransform(ref reader, network, let transform) || transform == null)
				return;
			object = transform.GameObject;
			let name = scope String();
			reader.ReadString(name);
			handle = HandleComponents.Find(name);
			if (handle == null || !object.Scene.World.Has(object.Entity, handle.index))
				return;
		}
		else if (kind == .Active)
		{
			if (!ReadTransform(ref reader, network, let transform))
				return;
			object = transform.GameObject;
		}
		else if (kind == .Light)
		{
			if (!ReadTransform(ref reader, network, let transform))
				return;
			object = transform.GameObject;
		}
		else if (kind == .Enabled)
		{
			component = ReadComponentAt(ref reader, network);
			object = component?.GameObject;
		}
		if (object == null || !reader.Ok)
			return;
		let keyLength = reader.Position - start;
		bool on = false;
		LightSettings settings = default;
		if (kind == .Light)
		{
			settings = reader.Read<LightSettings>();
			if (!object.HasComponent<Light>() || !settings.Valid)
				return;
		}
		else
			on = reader.Read<bool>();
		if (!reader.Ok)
			return;
		// A client may change only how what it owns looks; the server passes it on to everyone else and keeps it.
		if (network.IsServer)
		{
			// A Light is cosmetic.
			let cosmetic = kind == .Light || (kind == .HandleEnabled ? Cosmetic(handle) : component != null && Cosmetic(component));
			if (!Owns(sender, object.Transform) || !cosmetic)
				return;
			let payload = scope NetWriter();
			payload.Data.AddRange(Span<uint8>(reader.Start + start, reader.Position - start));
			SendState(network, payload, keyLength);
		}
		let wasApplying = sApplying;
		sApplying = true;
		switch (kind)
		{
		case .Active: object.SetActive(on);
		case .Enabled: if (!(component is NetworkIdentity)) component.Enabled = on;
		case .HandleEnabled: object.Scene.World.Enable(object.Entity, handle.index, on);
		case .Light:
			let light = object.GetComponent<Light>();
			settings.Apply(light);
			light.SharedHash = settings.Hash;
		}
		sApplying = wasApplying;
	}

	// ---- effects ----

	/// An effect played here or arriving from the server, for telling the two apart from the same one played twice.
	public struct RecentEffect
	{
		public uint8 kind;
		public bool fromServer;
		public float time;
		public Vector3 position;
		public int hash;
	}

	/// Notes an effect this client played, or finds the same one from the other side (and uses it up). True when
	/// it was already played: the caller then does not play it again.
	static bool AlreadyPlayed(NetworkManager network, EffectKind kind, StringView name, Vector3 position, bool fromServer)
	{
		let recent = network.RecentEffects;
		let now = Time.RealTime;
		recent.RemoveAll(scope (e) => now - e.time > SameEffectTime || now < e.time);
		let hash = name.GetHashCode();
		let reach = kind == .Sound ? SameSoundDistance : SameDecalDistance;
		for (int i < recent.Count)
		{
			let e = recent[i];
			if (e.kind == (uint8)kind && e.fromServer != fromServer && e.hash == hash && (e.position - position).LengthSquared <= reach * reach)
			{
				recent.RemoveAt(i);
				return true;
			}
		}
		RecentEffect entry;
		entry.kind = (uint8)kind;
		entry.fromServer = fromServer;
		entry.time = now;
		entry.position = position;
		entry.hash = hash;
		recent.Add(entry);
		return false;
	}

	/// ParticleSystem.Play: from the server, or the client that owns the object, it plays on every machine.
	public static void ParticlesPlayed(ParticleSystem particles)
	{
		let network = Active(particles.Scene);
		if (network == null || sApplying || !Everywhere(network, particles.GameObject) || !Decides(network, particles.GameObject))
			return;
		let payload = scope NetWriter();
		payload.Write((uint8)EffectKind.Particles);
		WriteComponentAt(payload, particles);
		if (network.IsServer)
			network.SendToAll(MsgEffect, payload);
		else
			network.SendToServer(MsgEffect, payload);
	}

	/// Decals.Spawn on the server is pressed on every machine. On a client, true when the server's has just
	/// arrived (the game shares its impacts itself as well): the caller does not press it again.
	public static bool DecalSpawned(Scene scene, Matrix4 volume, StringView texture, float lifetime, Color color, float angleLimit)
	{
		let network = Active(scene);
		if (network == null || sApplying || texture.Length > 200)
			return false;
		if (!network.IsServer)
			return AlreadyPlayed(network, .Decal, texture, volume.Translation, false);
		let payload = scope NetWriter();
		payload.Write((uint8)EffectKind.Decal);
		payload.Write(volume);
		payload.WriteString(texture);
		payload.Write(lifetime);
		payload.Write(color);
		payload.Write(angleLimit);
		network.SendToAll(MsgEffect, payload);
		return false;
	}

	/// Audio.PlayOneShot on the server is heard on every machine, where each player is. On a client, true when the
	/// server's has just arrived: the caller does not play it again.
	public static bool SoundPlayed(StringView clip, Vector3 position, float volume, AudioGroup group, float minDistance, float maxDistance)
	{
		let network = Active(Scene.Active);
		if (network == null || sApplying || clip.Length > 200)
			return false;
		if (!network.IsServer)
			return AlreadyPlayed(network, .Sound, clip, position, false);
		let payload = scope NetWriter();
		payload.Write((uint8)EffectKind.Sound);
		payload.WriteString(clip);
		payload.Write(position);
		payload.Write(volume);
		payload.Write((int32)group);
		payload.Write(minDistance);
		payload.Write(maxDistance);
		network.SendToAll(MsgEffect, payload);
		return false;
	}

	static void OnEffect(int32 sender, ref NetReader reader)
	{
		let network = Active(Scene.Active);
		if (network == null)
			return;
		let kind = (EffectKind)reader.Read<uint8>();
		let wasApplying = sApplying;
		defer
		{
			sApplying = wasApplying;
		}
		switch (kind)
		{
		case .Particles:
			let start = reader.Position - 1;
			let particles = ReadComponentAt(ref reader, network) as ParticleSystem;
			if (particles == null || !reader.Ok)
				return;
			if (network.IsServer)
			{
				if (!Owns(sender, particles.Transform))
					return;
				let payload = scope NetWriter();
				payload.Data.AddRange(Span<uint8>(reader.Start + start, reader.Position - start));
				network.SendToAll(MsgEffect, payload);
			}
			sApplying = true;
			particles.Play();
		case .Decal:
			// Only the server presses decals on everyone.
			if (network.IsServer)
				return;
			let volume = reader.Read<Matrix4>();
			let texture = scope String();
			reader.ReadString(texture);
			let lifetime = reader.Read<float>();
			let color = reader.Read<Color>();
			let angleLimit = reader.Read<float>();
			if (!reader.Ok || texture.Length > 200 || !lifetime.IsFinite || !angleLimit.IsFinite)
				return;
			for (int i < 16)
			{
				if (!volume.m[i].IsFinite)
					return;
			}
			if (AlreadyPlayed(network, .Decal, texture, volume.Translation, true))
				return;
			sApplying = true;
			Decals.Spawn(network.Scene, volume, texture, lifetime, color, angleLimit);
		case .Sound:
			if (network.IsServer)
				return;
			let clip = scope String();
			reader.ReadString(clip);
			let position = reader.Read<Vector3>();
			let volume = reader.Read<float>();
			let group = reader.Read<int32>();
			let minDistance = reader.Read<float>();
			let maxDistance = reader.Read<float>();
			if (!reader.Ok || clip.Length > 200 || !Finite(position) || !volume.IsFinite || !minDistance.IsFinite || !maxDistance.IsFinite || group < 0 || group > (int32)AudioGroup.Other)
				return;
			if (AlreadyPlayed(network, .Sound, clip, position, true))
				return;
			sApplying = true;
			Audio.PlayOneShot(clip, position, volume, (AudioGroup)group, minDistance, maxDistance);
		default:
		}
	}
}
