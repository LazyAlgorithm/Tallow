using System;
using System.Collections;

namespace Tallow;

/// Marks a field of a component as shared: on an object with a Network Identity, the value the server has is
/// copied to every client whenever it changes. Change it on the server; a client's own changes are overwritten.
/// Works for numbers, bool, enums, vectors, colours and String.
[AttributeUsage(.Field, .ReflectAttribute)]
struct SyncAttribute : Attribute
{
}

/// Marks the Vector3 field of a [Component] struct that is where a bare ECS entity is (it is shared like [Sync]).
/// Native ECS replication then sends the entity only to clients whose player is within the session's
/// SnapshotRelevanceRadius, as Nearby objects are (docs/unified-ecs-networking.md).
[AttributeUsage(.Field, .ReflectAttribute)]
struct SyncPositionAttribute : Attribute
{
}

/// Makes engine features work in multiplayer without game code: when a network session is running, the calls
/// below route themselves through the server and reach every machine. With no session they do nothing.
///
///   VoxelTerrain.Brush / ModifySphere, VoxelObject.Carve    applied on every machine in the server's order
///   CharacterController.SetBox / SetCapsule / ApplyShape     decided by the server, shown everywhere
///   SkinnedMeshRenderer.Play, Animator.Play                  a clip started on the server or by an object's owner plays everywhere
///   Prefab.Instantiate, Scene.Destroy                        for objects with a Network Identity, on the server
///   NavigationAgent, BehaviorTreeRunner                      think on the server only; clients see the movement
///   Soft bodies                                              a free one's object is shared; a shell's dents are the server's
///   Water                                                    waves by the session's clock; its settings and level are the server's
///   Rope.Attach, AttachStart / AttachEnd, LayAlong, Snap     tied, changed and snapped on every machine by the server
///   [Sync] fields                                            copied from the server when they change
///
/// Players that join later are brought up to date with all of it.
static class NetworkSync
{
	// Message ids the engine keeps for itself; games should use ids below 236.
	public const uint8 MsgTerrainBrush = 250;
	public const uint8 MsgVoxelCarve = 251;
	public const uint8 MsgCharacterShape = 252;
	public const uint8 MsgAnimation = 253;
	public const uint8 MsgField = 254;
	/// Reliable inventory of synchronized custom ECS data components on one networked object.
	public const uint8 MsgEcsComponents = 236;
	/// Reliable batches for GameObject-free entities with [Sync] ECS data.
	public const uint8 MsgNativeEcs = 237;
	public const uint8 MsgAudio = 249;
	public const uint8 MsgEvent = 247;
	public const uint8 MsgAnimator = 246;
	public const uint8 MsgMaterial = 245;
	public const uint8 MsgDialogue = 244;
	public const uint8 MsgSequence = 241;
	public const uint8 MsgRope = 240;
	public const uint8 MsgSoftBody = 255;

	static bool sRegistered;
	/// True while a change that arrived from the network is being applied, so it is not sent out again.
	static bool sApplying;
	public static bool IsApplying => sApplying;
	/// While on, changes made on this machine are not sent to the others: for what every machine does by itself
	/// (a sequence each one plays). Put it back as it was afterwards.
	public static bool Quiet
	{
		get => sApplying;
		set => sApplying = value;
	}

	static NetworkManager Active(Scene scene)
	{
		let network = scene?.Network;
		return network != null && network.Mode != .Offline ? network : null;
	}

	/// True while a network session is running on this scene, on the server or a client.
	public static bool InSession(Scene scene) => Active(scene) != null;

	/// True on a client of a running session: the server does the thinking for AI there.
	public static bool IsClientOf(Scene scene)
	{
		let network = Active(scene);
		return network != null && !network.IsServer;
	}

	public static void EnsureRegistered()
	{
		if (sRegistered)
			return;
		sRegistered = true;
		NetworkManager.RegisterMessage(MsgTerrainBrush, new => OnTerrainBrush);
		NetworkManager.RegisterMessage(MsgVoxelCarve, new => OnVoxelCarve);
		NetworkManager.RegisterMessage(MsgCharacterShape, new => OnCharacterShape);
		NetworkManager.RegisterMessage(MsgAnimation, new => OnAnimation);
		NetworkManager.RegisterMessage(MsgField, new => OnField);
		NetworkManager.RegisterMessage(MsgEcsComponents, new => OnEcsComponents);
		NetworkManager.RegisterMessage(MsgNativeEcs, new => NetworkManager.OnNativeMessage);
		NetworkManager.RegisterMessage(MsgAudio, new => OnAudio);
		VoiceChat.EnsureRegistered();
		NetworkManager.RegisterMessage(MsgEvent, new => OnEvent);
		NetworkManager.RegisterMessage(MsgAnimator, new => OnAnimator);
		NetworkManager.RegisterMessage(MsgMaterial, new => OnMaterial);
		NetworkManager.RegisterMessage(MsgDialogue, new => OnDialogue);
		NetworkManager.RegisterMessage(MsgSequence, new => OnSequence);
		NetworkManager.RegisterMessage(MsgRope, new => OnRope);
		NetworkManager.RegisterMessage(MsgSoftBody, new => OnSoftBody);
		RegisterStateMessages();
	}

	/// Called when a session starts. Scene objects that move by themselves get a Network Identity if they lack one,
	/// so physics props, AI characters and controllers are shared without being set up by hand. Every machine loads
	/// the same scene, so they all pick the same objects and the same ids.
	public static void Prepare(NetworkManager network)
	{
		EnsureRegistered();
		// Objects in the scene now are on every machine; ones a machine makes for itself later are its own.
		network.SceneIdLimit = network.Scene.NextId;
		network.ForgetStates();
		if (!network.AutoReplicate)
			return;
		List<GameObject> wanted = scope .();
		for (let object in network.Scene.Objects)
		{
			if (!object.ActiveInHierarchy) continue;
			if (object.GetComponent<NetworkIdentity>().IsValid)
				continue;
			let body = object.GetComponent<Rigidbody>();
			if ((body.IsValid && !body.isKinematic) || object.HasComponent<CharacterController>()
				|| object.HasComponent<NavigationAgent>() || object.GetComponent<AIMovementDriver>() != null || object.HasComponent<BehaviorTreeRunner>()
				|| object.GetComponent<NetworkBehaviour>() != null || (object.HasComponent<DialogueRunner>() && object.GetComponent<DialogueRunner>().shared) || (object.HasComponent<SequencePlayer>() && object.GetComponent<SequencePlayer>().shared)
				|| (object.GetComponent<SoftBody>()?.MovesByItself ?? false) || object.HasComponent<Water>())
				wanted.Add(object);
		}
		for (let object in wanted)
			object.AddComponent<NetworkIdentity>();
	}

	/// Gives an object that has started moving on its own during a session a Network Identity, so its motion is
	/// shared. Call it on every machine at the same moment (for example from something that is itself synced).
	public static void EnsureShared(GameObject object)
	{
		if (Active(object.Scene) != null && !object.GetComponent<NetworkIdentity>().IsValid)
			object.AddComponent<NetworkIdentity>();
	}

	/// For an object every machine creates itself while applying a shared event, such as a piece carved off a voxel
	/// object: gives it an identity whose id all machines arrive at by counting the same events.
	public static void ShareFragment(GameObject object)
	{
		let network = Active(object.Scene);
		if (network == null)
			return;
		var identity = object.GetComponent<NetworkIdentity>();
		if (!identity.IsValid)
			identity = object.AddComponent<NetworkIdentity>();
		network.AdoptFragment(identity);
	}

	// ---- naming things across machines ----

	/// An object every machine can find: by its Network Identity when it has one (spawned objects get different
	/// object ids on each machine), otherwise by the id it was given in the scene file.
	static void WriteObject(NetWriter writer, GameObject object)
	{
		let identity = object.GetComponent<NetworkIdentity>();
		writer.Write<bool>(identity.IsValid);
		writer.Write<uint32>(identity.IsValid ? identity.NetId : object.Id);
	}

	static GameObject ReadObject(ref NetReader reader, NetworkManager network)
	{
		let viaIdentity = reader.Read<bool>();
		let id = reader.Read<uint32>();
		if (!reader.Ok)
			return null;
		if (!viaIdentity)
			return network.Scene.FindById(id);
		return network.FindIdentity(id).GameObject;
	}

	/// The object that names a component across machines: the nearest ancestor with a Network Identity, or the
	/// component's own object when there is none.
	static GameObject Anchor(Component component) => Anchor(component.GameObject);

	/// The nearest object at or above this one with a Network Identity (the object itself when there is none).
	static GameObject Anchor(GameObject gameObject)
	{
		var transform = gameObject.Transform;
		while (transform != null)
		{
			if (transform.GameObject.GetComponent<NetworkIdentity>().IsValid)
				return transform.GameObject;
			transform = transform.Parent;
		}
		return gameObject;
	}

	static void Collect<T>(GameObject root, List<T> found) where T : Component
	{
		for (let component in root.Components)
		{
			if (let typed = component as T)
				found.Add(typed);
		}
		for (let child in root.Transform.Children)
			Collect<T>(child.GameObject, found);
	}

	/// Writes where a component is: its anchor object and its position among components of that type below the anchor.
	static void WriteComponent<T>(NetWriter writer, T component) where T : Component
	{
		let anchor = Anchor(component);
		List<T> all = scope .();
		Collect<T>(anchor, all);
		WriteObject(writer, anchor);
		writer.Write<uint16>((uint16)Math.Max(all.IndexOf(component), 0));
	}

	/// Writes an object every machine can find, a child of a spawned one too: its nearest ancestor with a Network
	/// Identity (itself when there is none) and the way down from there, child by child. Null is written as such.
	static void WriteTransform(NetWriter writer, Transform transform)
	{
		writer.Write<bool>(transform != null);
		if (transform == null)
			return;
		var anchor = transform;
		while (anchor != null && !anchor.GameObject.GetComponent<NetworkIdentity>().IsValid)
			anchor = anchor.Parent;
		if (anchor == null)
			anchor = transform;
		WriteObject(writer, anchor.GameObject);
		List<uint16> path = scope .();
		for (var at = transform; at != anchor; at = at.Parent)
			path.Add((uint16)at.Parent.Children.IndexOf(at));
		writer.Write<uint8>((uint8)Math.Min(path.Count, 255));
		for (int i = Math.Min(path.Count, 255) - 1; i >= 0; i--)
			writer.Write<uint16>(path[i]);
	}

	/// Reads what WriteTransform wrote. False when it named an object this machine does not have.
	static bool ReadTransform(ref NetReader reader, NetworkManager network, out Transform transform)
	{
		transform = null;
		if (!reader.Read<bool>())
			return reader.Ok;
		var at = ReadObject(ref reader, network)?.Transform;
		let depth = reader.Read<uint8>();
		for (int i < depth)
		{
			let index = (int)reader.Read<uint16>();
			at = (at != null && index < at.Children.Count) ? at.Children[index] : null;
		}
		transform = at;
		return reader.Ok && at != null;
	}

	/// Whether a client controls an object: it owns the object, or the nearest one above it with a Network Identity.
	static bool Owns(int32 sender, Transform transform)
	{
		for (var at = transform; at != null; at = at.Parent)
		{
			let identity = at.GameObject.GetComponent<NetworkIdentity>();
			if (identity.IsValid)
				return sender != 0 && identity.ownerId == sender;
		}
		return false;
	}

	static T ReadComponent<T>(ref NetReader reader, NetworkManager network) where T : Component
	{
		let anchor = ReadObject(ref reader, network);
		let index = (int)reader.Read<uint16>();
		if (anchor == null || !reader.Ok)
			return null;
		List<T> all = scope .();
		Collect<T>(anchor, all);
		return index < all.Count ? all[index] : null;
	}

	/// Server: sends to every client, and optionally keeps the message for players who join later.
	static void Broadcast(NetworkManager network, uint8 id, NetWriter payload, bool remember)
	{
		network.SendToAll(id, payload);
		if (remember)
			network.Remember(id, payload);
	}

	static bool Finite(Vector3 v) => v.x.IsFinite && v.y.IsFinite && v.z.IsFinite;

	// ---- voxels ----

	/// Returns true if the caller must not apply the brush now: on a client it has been sent to the server and
	/// will be applied when the server passes it back, so every machine edits in the same order.
	public static bool RouteBrush(VoxelTerrain terrain, Vector3 center, float radius, float strength, VoxelBrush mode, int32 paintLayer, float flattenHeight)
	{
		let network = Active(terrain.Scene);
		if (network == null || sApplying)
			return false;
		let payload = scope NetWriter();
		WriteObject(payload, terrain.GameObject);
		payload.Write(center);
		payload.Write(radius);
		payload.Write(strength);
		payload.Write<int32>((int32)mode);
		payload.Write(paintLayer);
		payload.Write(flattenHeight);
		if (network.IsServer)
		{
			Broadcast(network, MsgTerrainBrush, payload, true);
			return false;
		}
		network.SendToServer(MsgTerrainBrush, payload);
		return true;
	}

	static void OnTerrainBrush(int32 sender, ref NetReader reader)
	{
		let network = Active(Scene.Active);
		if (network == null)
			return;
		let target = ReadObject(ref reader, network);
		let center = reader.Read<Vector3>();
		let radius = reader.Read<float>();
		let strength = reader.Read<float>();
		let mode = reader.Read<int32>();
		let paintLayer = reader.Read<int32>();
		let flattenHeight = reader.Read<float>();
		let terrain = target?.GetComponent<VoxelTerrain>();
		if (!reader.Ok || terrain == null || !Finite(center) || !radius.IsFinite || !strength.IsFinite || !flattenHeight.IsFinite || mode < 0 || mode > (int32)VoxelBrush.Paint)
			return;
		// On the server this is a client's request: applying it here sends it on to everyone.
		let wasApplying = sApplying;
		sApplying = !network.IsServer;
		terrain.Brush(center, Mathf.Clamp(radius, 0, 64), strength, (VoxelBrush)mode, paintLayer, flattenHeight);
		sApplying = wasApplying;
	}

	/// Server: whether a carve asked for by a client is made. Off, only carves the server makes itself count: for a
	/// game that carves from hits it has checked, so a changed client cannot cut walls away by sending requests.
	public static bool ClientCarves = true;

	/// As RouteBrush, for VoxelObject.Carve.
	public static bool RouteCarve(VoxelObject voxels, Vector3 point, float radius)
	{
		let network = Active(voxels.Scene);
		if (network == null || sApplying)
			return false;
		let payload = scope NetWriter();
		WriteObject(payload, voxels.GameObject);
		// In the object's own space: a boulder that has rolled is not in exactly the same place on every machine.
		payload.Write(voxels.Transform.InverseTransformPoint(point));
		payload.Write(radius);
		if (network.IsServer)
		{
			Broadcast(network, MsgVoxelCarve, payload, true);
			return false;
		}
		network.SendToServer(MsgVoxelCarve, payload);
		return true;
	}

	static void OnVoxelCarve(int32 sender, ref NetReader reader)
	{
		let network = Active(Scene.Active);
		if (network == null)
			return;
		let target = ReadObject(ref reader, network);
		let point = reader.Read<Vector3>();
		let radius = reader.Read<float>();
		let voxels = GameObject.ComponentOn<VoxelObject>(target);
		if (!reader.Ok || !voxels.IsValid || !Finite(point) || !radius.IsFinite)
			return;
		if (network.IsServer && !ClientCarves)
			return;
		// On the server this is a client's request: carving here sends it on to everyone. A client applies the
		// point exactly as it came, in the object's own space, so that it does not depend on where the object is.
		let wasApplying = sApplying;
		sApplying = !network.IsServer;
		if (network.IsServer)
			voxels.Carve(voxels.Transform.TransformPoint(point), Mathf.Clamp(radius, 0, 64));
		else
			voxels.CarveLocal(point, Mathf.Clamp(radius, 0, 64));
		sApplying = wasApplying;
	}

	// ---- character controller shape ----

	static void WriteShape(NetWriter payload, CharacterController controller)
	{
		payload.Write<uint32>(controller.GameObject.GetComponent<NetworkIdentity>().NetId);
		payload.Write<int32>((int32)controller.shape);
		payload.Write(controller.radius);
		payload.Write(controller.height);
		payload.Write(controller.boxSize);
		payload.Write(controller.edgeRadius);
		payload.Write(controller.center);
	}

	/// Called after a controller's shape changed locally. The server tells everyone; a client asks the server,
	/// having already changed its own copy so the player sees it at once.
	public static void ShapeChanged(CharacterController controller)
	{
		let network = Active(controller.Scene);
		if (network == null || sApplying || !controller.GameObject.GetComponent<NetworkIdentity>().IsValid)
			return;
		let payload = scope NetWriter();
		WriteShape(payload, controller);
		if (network.IsServer)
			network.SendToAll(MsgCharacterShape, payload);
		else
			network.SendToServer(MsgCharacterShape, payload);
	}

	static void OnCharacterShape(int32 sender, ref NetReader reader)
	{
		let network = Active(Scene.Active);
		if (network == null)
			return;
		let netId = reader.Read<uint32>();
		let shape = reader.Read<int32>();
		let radius = reader.Read<float>();
		let height = reader.Read<float>();
		let boxSize = reader.Read<Vector3>();
		let edgeRadius = reader.Read<float>();
		let center = reader.Read<Vector3>();
		if (!reader.Ok || shape < 0 || shape > (int32)CharacterShape.Box || !radius.IsFinite || !height.IsFinite || !Finite(boxSize) || !edgeRadius.IsFinite || !Finite(center))
			return;
		let identity = network.FindIdentity(netId);
		if (!identity.IsValid)
			return;
		let controller = identity.GetComponent<CharacterController>();
		if (!controller)
			return;
		if (!network.IsServer)
		{
			sApplying = true;
			controller.ApplyRemoteShape((CharacterShape)shape, radius, height, boxSize, edgeRadius, center);
			sApplying = false;
			return;
		}
		// Only the player who controls a character may ask to change it, and only into something that fits.
		if (identity.ownerId == sender)
		{
			let old = controller.Data;
			controller.shape = (CharacterShape)shape;
			controller.radius = radius;
			controller.height = height;
			controller.boxSize = boxSize;
			controller.edgeRadius = edgeRadius;
			controller.center = center;
			if (controller.ApplyShape())
				return; // which told everyone
			controller.Data = old;
		}
		// Refused: put the asker back to what the server has.
		let payload = scope NetWriter();
		WriteShape(payload, controller);
		network.SendToClient(sender, MsgCharacterShape, payload);
	}

	// ---- animation ----

	static void WriteAnimation(NetWriter payload, Animator animator, SkinnedMeshRenderer skinned, StringView clip, float fade)
	{
		payload.Write<bool>(!animator);
		// An object has one Skinned Mesh Renderer and one Animator: the object says which.
		WriteTransform(payload, animator ? animator.Transform : skinned.Transform);
		payload.WriteString(clip);
		payload.Write(fade);
	}

	/// Called when an Animator or Skinned Mesh Renderer starts a different clip. The server tells everyone. A
	/// client tells the server only about objects it controls, such as its own player.
	public static void AnimationPlayed(Animator player, StringView clip, float fade) => AnimationPlayed(player, default, player.GameObject, clip, fade);
	public static void AnimationPlayed(SkinnedMeshRenderer player, StringView clip, float fade) => AnimationPlayed(default, player, player.GameObject, clip, fade);

	static void AnimationPlayed(Animator animator, SkinnedMeshRenderer skinned, GameObject object, StringView clip, float fade)
	{
		let network = Active(object.Scene);
		if (network == null || sApplying)
			return;
		if (!network.IsServer)
		{
			let owner = Anchor(object).GetComponent<NetworkIdentity>();
			if (!owner.IsValid || !owner.IsOwner)
				return;
		}
		let payload = scope NetWriter();
		WriteAnimation(payload, animator, skinned, clip, fade);
		if (network.IsServer)
			network.SendToAll(MsgAnimation, payload);
		else
			network.SendToServer(MsgAnimation, payload);
	}

	/// Called when an Animator with a controller has a parameter set (kind 0) or enters a state (kind 1). The same
	/// rule as clips: from the server, or from the player who owns the object, everyone follows.
	public static void AnimatorChanged(Animator animator, int32 kind, int32 index, float value)
	{
		let network = Active(animator.Scene);
		if (network == null || sApplying || !IsMine(animator.GameObject))
			return;
		let payload = scope NetWriter();
		WriteTransform(payload, animator.Transform);
		payload.Write((uint8)kind);
		payload.Write((int16)index);
		payload.Write(value);
		if (network.IsServer)
			network.SendToAll(MsgAnimator, payload);
		else
			network.SendToServer(MsgAnimator, payload);
	}

	/// Called when a Mesh Renderer is given another material (kind 0, name is its path) or has a value of its own
	/// material set (kind 1). The same rule as animation: from the server, or from the player who owns the
	/// object, everyone follows; the server remembers it for players who join later.
	public static void MaterialChanged(MeshRenderer renderer, int32 kind, StringView name, Vector4 value)
	{
		let network = Active(renderer.Scene);
		if (network == null || sApplying || !IsMine(renderer.GameObject) || name.Length > 200)
			return;
		let payload = scope NetWriter();
		// An object has one Mesh Renderer: the object says which.
		WriteTransform(payload, renderer.Transform);
		payload.Write((uint8)kind);
		payload.WriteString(name);
		payload.Write(value);
		if (network.IsServer)
			Broadcast(network, MsgMaterial, payload, true);
		else
			network.SendToServer(MsgMaterial, payload);
	}

	static void OnMaterial(int32 sender, ref NetReader reader)
	{
		let network = Active(Scene.Active);
		if (network == null)
			return;
		MeshRenderer renderer = default;
		if (ReadTransform(ref reader, network, let transform) && transform != null)
			renderer = transform.GameObject.GetComponent<MeshRenderer>();
		let kind = (int32)reader.Read<uint8>();
		let name = scope String();
		reader.ReadString(name);
		let value = reader.Read<Vector4>();
		// kind 0: the renderer's material; 1: one of its material's values; 2: a skinned model's part's material
		// (value.x is the part).
		if (!reader.Ok || !renderer || kind > 2 || name.Length > 200 || !value.x.IsFinite || !value.y.IsFinite || !value.z.IsFinite || !value.w.IsFinite)
			return;
		if (network.IsServer)
		{
			let owner = Anchor(renderer.GameObject).GetComponent<NetworkIdentity>();
			if (!owner.IsValid || owner.ownerId != sender || owner.ownerId == 0)
				return;
			let payload = scope NetWriter();
			WriteTransform(payload, renderer.Transform);
			payload.Write((uint8)kind);
			payload.WriteString(name);
			payload.Write(value);
			Broadcast(network, MsgMaterial, payload, true);
		}
		let wasApplying = sApplying;
		sApplying = true;
		if (kind == 0)
			renderer.SetMaterial(name);
		else if (kind == 1)
			renderer.SetMaterialValue(name, value);
		else
		{
			if (renderer.GameObject.HasComponent<SkinnedMeshRenderer>())
				renderer.GameObject.GetComponent<SkinnedMeshRenderer>().SetPartMaterial((int)value.x, name);
		}
		sApplying = wasApplying;
	}

	static void OnAnimator(int32 sender, ref NetReader reader)
	{
		let network = Active(Scene.Active);
		if (network == null)
			return;
		Animator animator = default;
		if (ReadTransform(ref reader, network, let transform) && transform != null)
			animator = transform.GameObject.GetComponent<Animator>();
		let kind = (int32)reader.Read<uint8>();
		let index = (int32)reader.Read<int16>();
		let value = reader.Read<float>();
		if (!reader.Ok || !animator || !value.IsFinite || kind > 1)
			return;
		if (network.IsServer)
		{
			let owner = Anchor(animator.GameObject).GetComponent<NetworkIdentity>();
			if (!owner.IsValid || owner.ownerId != sender || owner.ownerId == 0)
				return;
			// Passed on to the other players as it is applied here.
			let payload = scope NetWriter();
			WriteTransform(payload, animator.Transform);
			payload.Write((uint8)kind);
			payload.Write((int16)index);
			payload.Write(value);
			network.SendToAll(MsgAnimator, payload);
		}
		let wasApplying = sApplying;
		sApplying = true;
		animator.ApplyRemote(kind, index, value);
		sApplying = wasApplying;
	}

	static void OnAnimation(int32 sender, ref NetReader reader)
	{
		let network = Active(Scene.Active);
		if (network == null)
			return;
		let isSkinned = reader.Read<bool>();
		SkinnedMeshRenderer skinned = default;
		Animator animator = default;
		if (ReadTransform(ref reader, network, let transform) && transform != null)
		{
			if (isSkinned)
				skinned = transform.GameObject.GetComponent<SkinnedMeshRenderer>();
			else
				animator = transform.GameObject.GetComponent<Animator>();
		}
		let clip = scope String();
		reader.ReadString(clip);
		let fade = reader.Read<float>();
		if (!reader.Ok || (!skinned && !animator) || !fade.IsFinite)
			return;
		if (network.IsServer)
		{
			// From the client that controls the object: play it here, which passes it on to the others.
			let owner = Anchor(skinned ? skinned.GameObject : animator.GameObject).GetComponent<NetworkIdentity>();
			if (!owner.IsValid || owner.ownerId != sender)
				return;
		}
		let wasApplying = sApplying;
		sApplying = !network.IsServer;
		if (skinned)
			skinned.Play(clip, fade);
		else
			animator.Play(clip, fade);
		sApplying = wasApplying;
	}

	// ---- audio ----

	/// Called when an Audio Source plays (0), stops (1) or plays a one-off sound (2). As with animation: from the
	/// server it reaches everyone, from the player who controls the object it goes via the server.
	public static void AudioPlayed(AudioSource source, int32 action, StringView clip, float volume)
	{
		let network = Active(source.Scene);
		if (network == null || sApplying)
			return;
		if (!network.IsServer)
		{
			let owner = Anchor(source.GameObject).GetComponent<NetworkIdentity>();
			if (!owner.IsValid || !owner.IsOwner)
				return;
		}
		let payload = scope NetWriter();
		// An object has one Audio Source: the object says which.
		WriteTransform(payload, source.Transform);
		payload.Write(action);
		payload.WriteString(action == 0 ? (StringView)source.audioClip : clip);
		payload.Write(volume);
		if (network.IsServer)
			network.SendNear(source.Transform.Position, MsgAudio, payload, source.maxDistance);
		else
			network.SendToServer(MsgAudio, payload);
	}

	/// True when this machine is the one in charge of a component's object: always with no session, the server
	/// for objects nobody owns, and the owning client otherwise.
	public static bool IsMine(Component component) => IsMine(component.GameObject);

	/// The same for an object (a built-in component's).
	public static bool IsMine(GameObject gameObject)
	{
		let network = Active(gameObject.Scene);
		if (network == null)
			return true;
		let identity = Anchor(gameObject).GetComponent<NetworkIdentity>();
		if (!identity.IsValid)
			return network.IsServer;
		return identity.ownerId == network.LocalClientId || (network.IsServer && identity.ownerId == 0);
	}

	/// A client asks the server to move a shared conversation on: 0 advance, 1 choose index, 2 start at node,
	/// 3 stop. serial is the conversation step it saw, so a request about a line already gone is dropped.
	public static void DialogueRequest(DialogueRunnerState runner, int32 action, int32 serial, StringView node, int32 index = 0)
	{
		let network = Active(runner.Scene);
		if (network == null || network.IsServer || node.Length > 64)
			return;
		let payload = scope NetWriter();
		// One Dialogue Runner per object: the object says which.
		WriteTransform(payload, runner.Transform);
		payload.Write(action);
		payload.Write(serial);
		payload.Write(index);
		payload.WriteString(node);
		network.SendToServer(MsgDialogue, payload);
	}

	static void OnDialogue(int32 sender, ref NetReader reader)
	{
		let network = Active(Scene.Active);
		if (network == null || !network.IsServer)
			return;
		DialogueRunner runner = default;
		if (ReadTransform(ref reader, network, let transform) && transform != null)
			runner = transform.GameObject.GetComponent<DialogueRunner>();
		let action = reader.Read<int32>();
		let serial = reader.Read<int32>();
		let index = reader.Read<int32>();
		let node = scope String();
		reader.ReadString(node);
		if (!reader.Ok || !runner || !runner.shared || action < 0 || action > 3 || node.Length > 64)
			return;
		if (runner.onlyOwnerChooses)
		{
			let owner = Anchor(runner.GameObject).GetComponent<NetworkIdentity>();
			if (!owner.IsValid || owner.ownerId != sender)
				return;
		}
		runner.ApplyRequest(action, serial, node, index);
	}

	/// A client asks the server to control a shared sequence: 0 play, 1 pause, 2 resume, 3 stop, 4 skip, 5 seek to time.
	public static void SequenceRequest(SequencePlayerState player, int32 action, float time)
	{
		let network = Active(player.Scene);
		if (network == null || network.IsServer)
			return;
		let payload = scope NetWriter();
		// One Sequence Player per object: the object says which.
		WriteTransform(payload, player.Transform);
		payload.Write(action);
		payload.Write(time);
		network.SendToServer(MsgSequence, payload);
	}

	static void OnSequence(int32 sender, ref NetReader reader)
	{
		let network = Active(Scene.Active);
		if (network == null || !network.IsServer)
			return;
		SequencePlayer player = default;
		if (ReadTransform(ref reader, network, let transform) && transform != null)
			player = transform.GameObject.GetComponent<SequencePlayer>();
		let action = reader.Read<int32>();
		let time = reader.Read<float>();
		if (!reader.Ok || !player || !player.shared || action < 0 || action > 5 || !time.IsFinite)
			return;
		if (player.onlyOwnerControls)
		{
			let owner = Anchor(player.GameObject).GetComponent<NetworkIdentity>();
			if (!owner.IsValid || owner.ownerId != sender)
				return;
		}
		player.ApplyRequest(action, time);
	}

	/// Runs OnNetworkEvent(name, value) on a component on every machine. From the server it goes to everyone; from
	/// a client it goes through the server, which accepts it only for an object that client owns.
	public static void SendEvent(Component component, StringView name, float value = 0)
	{
		let network = Active(component.Scene);
		if (network == null)
		{
			component.OnNetworkEvent(name, value);
			return;
		}
		if (name.Length > 64 || !value.IsFinite)
			return;
		let payload = scope NetWriter();
		WriteComponent<Component>(payload, component);
		payload.WriteString(name);
		payload.Write(value);
		if (network.IsServer)
		{
			component.OnNetworkEvent(name, value);
			Broadcast(network, MsgEvent, payload, false);
		}
		else
			network.SendToServer(MsgEvent, payload);
	}

	static void OnEvent(int32 sender, ref NetReader reader)
	{
		let network = Active(Scene.Active);
		if (network == null)
			return;
		let component = ReadComponent<Component>(ref reader, network);
		let name = scope String();
		reader.ReadString(name);
		let value = reader.Read<float>();
		if (!reader.Ok || component == null || name.Length > 64 || !value.IsFinite)
			return;
		if (network.IsServer)
		{
			let owner = Anchor(component).GetComponent<NetworkIdentity>();
			if (!owner.IsValid || owner.ownerId != sender)
				return;
			component.OnNetworkEvent(name, value);
			let payload = scope NetWriter();
			WriteComponent<Component>(payload, component);
			payload.WriteString(name);
			payload.Write(value);
			Broadcast(network, MsgEvent, payload, false);
		}
		else
			component.OnNetworkEvent(name, value);
	}

	static void OnAudio(int32 sender, ref NetReader reader)
	{
		let network = Active(Scene.Active);
		if (network == null)
			return;
		AudioSource source = default;
		if (ReadTransform(ref reader, network, let transform) && transform != null)
			source = transform.GameObject.GetComponent<AudioSource>();
		let action = reader.Read<int32>();
		let clip = scope String();
		reader.ReadString(clip);
		let volume = reader.Read<float>();
		if (!reader.Ok || !source || !volume.IsFinite || action < 0 || action > 2)
			return;
		if (network.IsServer)
		{
			let owner = Anchor(source.GameObject).GetComponent<NetworkIdentity>();
			if (!owner.IsValid || owner.ownerId != sender)
				return;
		}
		// On the server, doing it here passes it on to the other players.
		let wasApplying = sApplying;
		sApplying = !network.IsServer;
		switch (action)
		{
		case 0:
			if (!clip.IsEmpty)
				source.audioClip = clip;
			source.Play();
		case 1: source.Stop();
		default: source.PlayOneShot(clip, volume);
		}
		sApplying = wasApplying;
	}

	// ---- [Sync] fields ----

	class Slot
	{
		/// Where the field is for a class component. ECS data (both built-in and game-defined)
		/// moves between Flecs tables, so Ptr resolves its current location every time.
		public void* ptr;
		public GameObject owner;
		public int32 dataIndex = -1;
		public int offset;
		public int32 size;
		public bool isString;
		/// A String field's type: String or SharedString.
		public Type type;
		public List<uint8> last = new .() ~ delete _;

		/// The field now, or null if its component has gone.
		public void* Ptr
		{
			get
			{
				if (dataIndex < 0)
					return ptr;
				let data = owner.Scene?.World?.Get(owner.Entity, dataIndex);
				return data != null ? (uint8*)data + offset : null;
			}
		}
	}

	/// The [Sync] fields of an identity's object, in a fixed order that is the same on every machine (by component,
	/// then by field name).
	class SlotList
	{
		public List<Slot> slots = new .() ~ DeleteContainerAndItems!(_);
		/// Changes when components are added, removed or replaced by a script reload.
		public int signature;
		/// Stable type names of custom data components containing supported [Sync] fields.
		public List<String> syncedDataTypes = new .() ~ DeleteContainerAndItems!(_);
		/// Reset when the component layout changes; the server must announce that layout before field indices.
		public bool structureSent;
		/// Remembers removals so a client returning to relevance can be told to clear the data.
		public bool everHadSyncedData;
	}

	static Dictionary<NetworkIdentity, SlotList> sSlots = new .() ~ DeleteDictionaryAndValues!(_);

	public static int32 SizeOf(FieldRef field)
	{
		switch (field.kind)
		{
		case .Float: return 4;
		case .Double: return 8;
		case .Bool: return 1;
		case .Vector2: return 8;
		case .Vector3,.Int3: return 12;
		case .Vector4,.Quaternion,.Color: return 16;
		case .Matrix4: return 64;
		case .Int,.Enum,.Char: return (int32)field.type.Size;
		default: return 0;
		}
	}

	static SlotList Slots(NetworkIdentity identity)
	{
		int signature = identity.GameObject.Components.Count;
		for (let component in identity.GameObject.Components)
			signature = signature * 31 + (int)(void*)Internal.UnsafeCastToPtr(component);
		let handles = scope List<HandleComponents.Info>();
		HandleComponents.On(identity.GameObject, handles);
		// By name, so that every machine lists them in the same order.
		handles.Sort(scope (a, b) => a.fullName.CompareTo(b.fullName));
		for (let info in handles)
			signature = signature * 31 + info.index + 1;
		// Custom [Component] structs can live beside class scripts and built-in handles on
		// the same GameObject entity. Include their layout in the cache key and sort their
		// names, not Flecs table order, so server and client agree on field indices.
		let dataComponents = scope List<DataComponents.Info>();
		DataComponents.On(identity.GameObject, dataComponents);
		dataComponents.Sort(scope (a, b) => a.fullName.CompareTo(b.fullName));
		for (let info in dataComponents)
			signature = signature * 31 + info.index + 1;
		bool everHadSyncedData = false;
		if (sSlots.TryGetValue(identity, let existing))
		{
			if (existing.signature == signature)
				return existing;
			everHadSyncedData = existing.everHadSyncedData || !existing.syncedDataTypes.IsEmpty;
			sSlots.Remove(identity);
			delete existing;
		}
		let list = new SlotList();
		list.signature = signature;
		list.everHadSyncedData = everHadSyncedData;
		List<FieldRef> fields = scope .();
		for (let component in identity.GameObject.Components)
		{
			fields.Clear();
			ComponentRegistry.GetFields(component, fields);
			// By name, not declaration: a class split over several files (extensions) lists its fields in the order
			// the compiler met the files, which differs between Windows and Linux builds of the same game.
			fields.Sort(scope (a, b) => a.name.CompareTo(b.name));
			for (let field in fields)
			{
				if (!field.sync)
					continue;
				let size = SizeOf(field);
				if (size == 0 && field.kind != .String)
					continue;
				let slot = new Slot();
				slot.ptr = field.ptr;
				slot.size = size;
				slot.isString = field.kind == .String;
				slot.type = field.type;
				list.slots.Add(slot);
			}
		}
		// Then the built-in components' [Sync] fields (Water's settings), found by offset in their data.
		for (let info in handles)
		{
			let data = identity.GameObject.GetData(info.dataType);
			if (data == null)
				continue;
			fields.Clear();
			HandleComponents.GetFields(identity.GameObject, info, fields);
			fields.Sort(scope (a, b) => a.name.CompareTo(b.name));
			for (let field in fields)
			{
				if (!field.sync)
					continue;
				let size = SizeOf(field);
				if (size == 0 && field.kind != .String)
					continue;
				let slot = new Slot();
				slot.owner = identity.GameObject;
				slot.dataIndex = info.index;
				slot.offset = (uint8*)field.ptr - (uint8*)data;
				slot.size = size;
				slot.isString = field.kind == .String;
				slot.type = field.type;
				list.slots.Add(slot);
			}
		}
		// Game-defined ECS structs use the same [Sync] wire format as ordinary scripts.
		// Resolve fields by offset every time: adding another component may move this
		// struct to another Flecs table without invalidating the network field slot.
		for (let info in dataComponents)
		{
			let data = identity.GameObject.GetData(info.type);
			if (data == null)
				continue;
			fields.Clear();
			DataComponents.GetFields(info.type, data, fields, identity.GameObject);
			fields.Sort(scope (a, b) => a.name.CompareTo(b.name));
			bool hasSyncedFields = false;
			for (let field in fields)
			{
				if (!field.sync)
					continue;
				let size = SizeOf(field);
				if (size == 0 && field.kind != .String)
					continue;
				hasSyncedFields = true;
				let slot = new Slot();
				slot.owner = identity.GameObject;
				slot.dataIndex = info.index;
				slot.offset = (uint8*)field.ptr - (uint8*)data;
				slot.size = size;
				slot.isString = field.kind == .String;
				slot.type = field.type;
				list.slots.Add(slot);
			}
			if (hasSyncedFields)
				list.syncedDataTypes.Add(new String(info.fullName));
		}
		if (!list.syncedDataTypes.IsEmpty)
			list.everHadSyncedData = true;
		// Ordinary network objects with no synchronized ECS data must not each
		// generate an extra reliable empty-layout message on their first tick.
		if (!list.everHadSyncedData)
			list.structureSent = true;
		sSlots[identity] = list;
		return list;
	}

	public static void Forget(NetworkIdentity identity)
	{
		if (sSlots.GetAndRemove(identity) case .Ok(let pair))
			delete pair.value;
	}

	static Span<uint8> Bytes(Slot slot)
	{
		let ptr = slot.Ptr;
		if (ptr == null)
			return default;
		if (!slot.isString)
			return .((uint8*)ptr, slot.size);
		let text = StringFields.Get(ptr, slot.type);
		return Span<uint8>((uint8*)text.Ptr, text.Length);
	}

	static void WriteField(NetWriter payload, NetworkIdentity identity, int index, Slot slot)
	{
		let bytes = Bytes(slot);
		NetworkManager.WriteNetId(payload, identity.NetId);
		payload.WriteVarUInt((uint32)index);
		payload.WriteVarUInt((uint32)Math.Min(bytes.Length, 60000));
		payload.Data.AddRange(Span<uint8>(bytes.Ptr, Math.Min(bytes.Length, 60000)));
	}

	/// The synchronized ECS type layout precedes field messages, which use compact numeric indices.
	/// Only game-defined structs containing supported [Sync] fields are mirrored. Other ECS
	/// components may stay local; built-in handles already have their own lifecycle protocol.
	static void WriteEcsComponents(NetWriter writer, NetworkIdentity identity, SlotList list)
	{
		NetworkManager.WriteNetId(writer, identity.NetId);
		writer.Write((uint8)Math.Min(list.syncedDataTypes.Count, 64));
		for (int i = 0; i < list.syncedDataTypes.Count && i < 64; i++)
			writer.WriteString(list.syncedDataTypes[i]);
	}

	static void OnEcsComponents(int32 sender, ref NetReader reader)
	{
		let network = Active(Scene.Active);
		if (network == null)
			return;
		let netId = NetworkManager.ReadNetId(ref reader);
		if (netId == SchemaNetId)
		{
			OnSchema(network, sender, ref reader);
			return;
		}
		if (network.IsServer)
			return;
		let count = (int)reader.Read<uint8>();
		if (!reader.Ok || count > 64)
			return;
		let names = scope List<String>();
		defer
		{
			for (let name in names)
				delete name;
		}
		for (int i < count)
		{
			let name = new String();
			reader.ReadString(name);
			names.Add(name);
		}
		if (!reader.Ok)
			return;
		let identity = network.FindIdentity(netId);
		if (!identity.IsValid)
			return;
		let gameObject = identity.GameObject;
		let existing = scope List<DataComponents.Info>();
		DataComponents.On(gameObject, existing);
		// Only remove server-replicated types; never remove purely local data.
		for (let info in existing)
		{
			let fields = scope List<FieldRef>();
			DataComponents.GetFields(info.type, gameObject.GetData(info.type), fields, gameObject);
			bool synced = false;
			for (let field in fields)
			{
				if (field.sync && (SizeOf(field) > 0 || field.kind == .String))
					synced = true;
			}
			if (!synced)
				continue;
			bool keep = false;
			for (let name in names)
			{
				if (name == info.fullName)
					keep = true;
			}
			if (!keep)
				gameObject.RemoveData(info.type);
		}
		for (let name in names)
		{
			let info = DataComponents.Find(name);
			if (info == null)
			{
				Log.Warning(scope $"Unknown networked ECS component '{name}'; client and server may have different game builds.");
				continue;
			}
			if (gameObject.GetData(info.type) == null)
				gameObject.AddData(info.type);
		}
		// Changes of archetype invalidate cached field indices and addresses.
		Forget(identity);
	}

	/// Server, once per snapshot: sends every [Sync] field whose value changed since it was last sent.
	public static void ServerTick(NetworkManager network)
	{
		let payload = scope NetWriter();
		for (let identity in network.Identities)
		{
			let list = Slots(identity);
			if (!list.structureSent)
			{
				payload.Clear();
				WriteEcsComponents(payload, identity, list);
				network.SendAbout(identity.NetId, MsgEcsComponents, payload);
				list.structureSent = true;
			}
			for (int i < list.slots.Count)
			{
				let slot = list.slots[i];
				let bytes = Bytes(slot);
				if (slot.last.Count == bytes.Length && (bytes.Length == 0 || Internal.MemCmp(slot.last.Ptr, bytes.Ptr, bytes.Length) == 0))
					continue;
				slot.last.Clear();
				slot.last.AddRange(bytes);
				payload.Clear();
				WriteField(payload, identity, i, slot);
				// Only to clients whose area it is in; the rest get all its fields when it comes back.
				network.SendAbout(identity.NetId, MsgField, payload);
			}
		}
	}

	/// Server: every [Sync] field of an object, to one client (it has just come into that client's area).
	public static void SendFieldsTo(NetworkManager network, NetworkIdentity identity, int32 clientId)
	{
		let list = Slots(identity);
		let payload = scope NetWriter();
		if (list.everHadSyncedData)
		{
			WriteEcsComponents(payload, identity, list);
			network.SendToClient(clientId, MsgEcsComponents, payload);
		}
		if (list.slots.Count == 0)
			return;
		for (int i < list.slots.Count)
		{
			payload.Clear();
			WriteField(payload, identity, i, list.slots[i]);
			network.SendToClient(clientId, MsgField, payload);
		}
	}

	static void OnField(int32 sender, ref NetReader reader)
	{
		let network = Active(Scene.Active);
		if (network == null || network.IsServer)
			return; // only the server's values are shared
		// Indices into a list of [Sync] fields the server does not have (see SyncSchema).
		if (network.[Friend]mServerSchema != 0 && network.[Friend]mServerSchema != SyncSchema)
			return;
		let netId = NetworkManager.ReadNetId(ref reader);
		let index = (int)reader.ReadVarUInt();
		let length = (int)reader.ReadVarUInt();
		if (!reader.Ok || length > 60000)
			return;
		uint8[] data = scope .[Math.Max(length, 1)];
		for (int i < length)
			data[i] = reader.Read<uint8>();
		if (!reader.Ok)
			return;
		let identity = network.FindIdentity(netId);
		if (!identity.IsValid)
			return;
		let list = Slots(identity);
		if (index >= list.slots.Count)
			return;
		let slot = list.slots[index];
		let ptr = slot.Ptr;
		if (ptr == null)
			return;
		if (slot.isString)
		{
			if (slot.type == typeof(SharedString))
				*(SharedString*)ptr = StringView((char8*)&data[0], length);
			else if (let text = StringFields.Writable(ptr))
				text..Clear().Append(StringView((char8*)&data[0], length));
		}
		else if (length == slot.size)
			Internal.MemCpy(ptr, &data[0], length);
	}

	// ---- soft bodies ----

	/// Dents are sent in steps of a quarter of a millimetre (up to 8 m).
	const float DentStep = 1 / 4000.0f;

	/// Writes a shell's dents: the ones deeper than half a millimetre, by vertex.
	static void WriteDents(NetWriter payload, SoftBody shell, Span<Vector3> dents)
	{
		WriteComponent<SoftBody>(payload, shell);
		payload.Write<uint32>((uint32)shell.SimulatedVertexCount);
		List<int> kept = scope .();
		for (int i < Math.Min(dents.Length, shell.SimulatedVertexCount))
		{
			if (dents[i].LengthSquared > 0.0005f * 0.0005f && Finite(dents[i]))
				kept.Add(i);
		}
		payload.Write<uint32>((uint32)kept.Count);
		for (let i in kept)
		{
			payload.Write<uint32>((uint32)i);
			for (int axis < 3)
				payload.Write<int16>((int16)Math.Clamp(Math.Round(dents[i][axis] / DentStep), -32767, 32767));
		}
	}

	/// A client's SetDents or Repair on a shell in a session: sent to the server when the client controls the object
	/// (the server dents it on every machine), dropped otherwise. Returns true when the caller must not dent it here.
	public static bool DentsRequest(SoftBody shell, Span<Vector3> dents)
	{
		let network = Active(shell.Scene);
		if (network == null || sApplying || network.IsServer)
			return false;
		if (IsMine(shell))
		{
			let payload = scope NetWriter();
			WriteDents(payload, shell, dents);
			network.SendToServer(MsgSoftBody, payload);
		}
		return true;
	}

	/// Server: a shell's dents have settled (after a crash, SetDents or Repair): every client gets them.
	public static void DentsSettled(SoftBody shell)
	{
		let network = Active(shell.Scene);
		if (network == null || sApplying || !network.IsServer)
			return;
		let dents = scope List<Vector3>();
		shell.GetDents(dents);
		let payload = scope NetWriter();
		WriteDents(payload, shell, dents);
		network.SendToAll(MsgSoftBody, payload);
	}

	static void OnSoftBody(int32 sender, ref NetReader reader)
	{
		let network = Active(Scene.Active);
		if (network == null)
			return;
		let shell = ReadComponent<SoftBody>(ref reader, network);
		let total = (int)reader.Read<uint32>();
		let count = (int)reader.Read<uint32>();
		if (!reader.Ok || shell == null || shell.kind != .Shell || total != shell.SimulatedVertexCount || count > total)
			return;
		let dents = scope List<Vector3>();
		dents.Resize(total);
		for (int i < count)
		{
			let index = (int)reader.Read<uint32>();
			Vector3 dent = default;
			for (int axis < 3)
				dent[axis] = reader.Read<int16>() * DentStep;
			if (!reader.Ok || index >= total)
				return;
			dents[index] = dent;
		}
		if (network.IsServer)
		{
			// Only the player who controls it may dent or repair it.
			if (Owns(sender, shell.Transform))
				shell.SetDents(dents);
			return;
		}
		sApplying = true;
		shell.SetDents(dents);
		sApplying = false;
	}

	// ---- ropes ----

	/// What a rope message does.
	public enum RopeChange : uint8
	{
		Tie,
		TieStart,
		TieEnd,
		LayAlong,
		Snap
	}

	/// The most points a LayAlong path sends.
	const int MaxRopePath = 512;

	static void WriteTie(NetWriter payload, Transform from, Transform to, Vector3 fromOffset, Vector3 toOffset, float length, float thickness)
	{
		payload.Write<uint8>((uint8)RopeChange.Tie);
		WriteTransform(payload, from);
		WriteTransform(payload, to);
		payload.Write(fromOffset);
		payload.Write(toOffset);
		payload.Write(length);
		payload.Write(thickness);
	}

	static void WriteRopeChange(NetWriter payload, Rope rope, RopeChange change, Transform target, Vector3 offset, Span<Vector3> path)
	{
		payload.Write<uint8>((uint8)change);
		WriteComponent<Rope>(payload, rope);
		if (change == .TieStart || change == .TieEnd)
		{
			WriteTransform(payload, target);
			payload.Write(offset);
		}
		else if (change == .LayAlong)
		{
			let count = Math.Min(path.Length, MaxRopePath);
			payload.Write<uint16>((uint16)count);
			for (int i < count)
				payload.Write(path[i]);
		}
	}

	/// A client's Rope.Attach in a session: asked of the server, which ties the rope on every machine when the client
	/// controls one of the two objects. Returns true when the caller must not tie it here.
	public static bool RopeTieRequest(GameObject from, GameObject to, Vector3 fromOffset, Vector3 toOffset, float length, float thickness)
	{
		let network = Active(from.Scene);
		if (network == null || sApplying || network.IsServer)
			return false;
		let payload = scope NetWriter();
		WriteTie(payload, from.Transform, to.Transform, fromOffset, toOffset, length, thickness);
		network.SendToServer(MsgRope, payload);
		return true;
	}

	/// A client's change to a rope in a session: sent to the server, which makes it on every machine when the client
	/// controls the rope or what it is tied to. Returns true when the caller must not change it here.
	public static bool RopeRequest(Rope rope, RopeChange change, Transform target = null, Vector3 offset = .Zero, Span<Vector3> path = default)
	{
		let network = Active(rope.Scene);
		if (network == null || sApplying || network.IsServer)
			return false;
		let payload = scope NetWriter();
		WriteRopeChange(payload, rope, change, target, offset, path);
		network.SendToServer(MsgRope, payload);
		return true;
	}

	/// Server: a rope was tied or changed here, so every machine does the same, players who join later too. A tied
	/// rope, and the half a snap leaves, become objects every machine names alike.
	public static void RopeChanged(Rope rope, RopeChange change, Transform target = null, Vector3 offset = .Zero, Span<Vector3> path = default)
	{
		let network = Active(rope.Scene);
		if (network == null || sApplying || !network.IsServer)
			return;
		let payload = scope NetWriter();
		if (change == .Tie)
		{
			ShareFragment(rope.GameObject);
			WriteTie(payload, rope.startAttachedTo, rope.endAttachedTo, rope.startOffset, rope.endOffset, rope.length, rope.thickness);
		}
		else
		{
			WriteRopeChange(payload, rope, change, target, offset, path);
			if (change == .Snap && rope.SnappedOff != null)
				ShareFragment(rope.SnappedOff.GameObject);
		}
		Broadcast(network, MsgRope, payload, true);
	}

	static void OnRope(int32 sender, ref NetReader reader)
	{
		let network = Active(Scene.Active);
		if (network == null)
			return;
		let change = (RopeChange)reader.Read<uint8>();
		if (change == .Tie)
		{
			Transform from, to;
			let found = ReadTransform(ref reader, network, out from) & ReadTransform(ref reader, network, out to);
			let fromOffset = reader.Read<Vector3>();
			let toOffset = reader.Read<Vector3>();
			let length = reader.Read<float>();
			let thickness = reader.Read<float>();
			if (!reader.Ok || !found || from == null || to == null || !Finite(fromOffset) || !Finite(toOffset) || !(length > 0 && length < 10000) || !(thickness > 0 && thickness < 100))
				return;
			if (network.IsServer)
			{
				if (Owns(sender, from) || Owns(sender, to))
					Rope.Attach(from.GameObject, to.GameObject, fromOffset, toOffset, length, thickness);
				return;
			}
			sApplying = true;
			let rope = Rope.[Friend]Tie(from.GameObject, to.GameObject, fromOffset, toOffset, length, thickness);
			ShareFragment(rope.GameObject);
			sApplying = false;
			return;
		}
		let rope = ReadComponent<Rope>(ref reader, network);
		Transform target = null;
		var offset = Vector3.Zero;
		var found = true;
		List<Vector3> path = scope .();
		if (change == .TieStart || change == .TieEnd)
		{
			found = ReadTransform(ref reader, network, out target);
			offset = reader.Read<Vector3>();
		}
		else if (change == .LayAlong)
		{
			let count = (int)reader.Read<uint16>();
			if (count > MaxRopePath)
				return;
			for (int i < count)
			{
				let point = reader.Read<Vector3>();
				if (!Finite(point))
					return;
				path.Add(point);
			}
		}
		else if (change != .Snap)
			return;
		if (!reader.Ok || rope == null || !found || !Finite(offset))
			return;
		// Only a player who controls the rope, or something it is tied to, may change it.
		if (network.IsServer && !Owns(sender, rope.Transform) && !Owns(sender, rope.startAttachedTo) && !Owns(sender, rope.endAttachedTo))
			return;
		let wasApplying = sApplying;
		sApplying = !network.IsServer;
		switch (change)
		{
		case .TieStart: rope.AttachStart(target, offset);
		case .TieEnd: rope.AttachEnd(target, offset);
		case .LayAlong: rope.LayAlong(path);
		case .Snap:
			let other = rope.Snap();
			if (!network.IsServer && other != null)
				ShareFragment(other.GameObject);
		default:
		}
		sApplying = wasApplying;
	}

	// ---- late joiners ----

	/// Server: brings a player who has just connected up to date with everything above.
	public static void ClientJoined(NetworkManager network, int32 clientId)
	{
		SendSchemaTo(network, clientId);
		network.Replay(clientId);
		let payload = scope NetWriter();
		for (let identity in network.Identities)
		{
			let controller = identity.GetComponent<CharacterController>();
			if (controller.IsValid)
			{
				payload.Clear();
				WriteShape(payload, controller);
				network.SendToClient(clientId, MsgCharacterShape, payload);
			}
			let list = Slots(identity);
			payload.Clear();
			if (list.everHadSyncedData)
			{
				WriteEcsComponents(payload, identity, list);
				network.SendToClient(clientId, MsgEcsComponents, payload);
			}
			for (int i < list.slots.Count)
			{
				payload.Clear();
				WriteField(payload, identity, i, list.slots[i]);
				network.SendToClient(clientId, MsgField, payload);
			}
		}
		network.ReplayStates(clientId);
		for (let component in network.Scene.Components)
		{
			// A shell's dents as they are now.
			if (let shell = component as SoftBody)
			{
				if (shell.kind == .Shell && shell.DeepestDent() > 0)
				{
					let dents = scope List<Vector3>();
					shell.GetDents(dents);
					payload.Clear();
					WriteDents(payload, shell, dents);
					network.SendToClient(clientId, MsgSoftBody, payload);
				}
				continue;
			}
		}
		for (let animator in network.Scene.Components<Animator>(.. scope .()))
		{
			if (animator.CurrentClip.IsEmpty)
				continue;
			payload.Clear();
			WriteAnimation(payload, animator, default, animator.CurrentClip, 0);
			network.SendToClient(clientId, MsgAnimation, payload);
		}
		for (let skinned in network.Scene.Components<SkinnedMeshRenderer>(.. scope .()))
		{
			if (skinned.CurrentClip.IsEmpty)
				continue;
			payload.Clear();
			WriteAnimation(payload, default, skinned, skinned.CurrentClip, 0);
			network.SendToClient(clientId, MsgAnimation, payload);
		}
	}

	// ---- [Sync] declarations across a script reload ----
	//
	// Fields go by their index in each object's list of [Sync] fields, so every machine must declare the same ones. A
	// session starts with one build; a script reload during it (in the editor) can change them on one machine. Then
	// that machine sends a hash of its declarations (the server to every client, a client to the server), with net id
	// 0 in an ECS layout message, and a client applies fields only while its hash is the server's. When they are
	// the same again (the other editor has reloaded too) the server sends that client every field afresh. Nothing is
	// sent in a session where no machine reloads. Bare entities do not need this: they are matched by name.

	const uint32 SchemaNetId = 0;
	static uint64 sSchema;
	static int sSchemaGeneration = -1;

	/// A hash of every [Sync] declaration in the program (script classes and data components: type, field name and
	/// size). Machines with different ones cannot use each other's field indices.
	public static uint64 SyncSchema
	{
		get
		{
			let generation = DataComponents.Generation;
			if (generation == sSchemaGeneration)
				return sSchema;
			sSchemaGeneration = generation;
			uint64 hash = 14695981039346656037UL;
			let names = scope List<StringView>();
			let sizes = scope Dictionary<StringView, int>();
			for (let info in ComponentRegistry.Types)
			{
				names.Clear();
				sizes.Clear();
				for (let field in info.type.GetFields(.Instance | .Public | .NonPublic))
				{
					if ((field.GetCustomAttribute<SyncAttribute>() case .Ok) || (field.GetCustomAttribute<SyncPositionAttribute>() case .Ok))
					{
						names.Add(field.Name);
						sizes[field.Name] = field.FieldType.Size;
					}
				}
				if (names.IsEmpty)
					continue;
				names.Sort(scope (a, b) => a.CompareTo(b));
				MixSchema(ref hash, info.fullName, 0);
				for (let name in names)
					MixSchema(ref hash, name, sizes[name]);
			}
			for (let info in DataComponents.SyncedTypes)
			{
				MixSchema(ref hash, info.fullName, 0);
				for (let field in info.syncedFields)
					MixSchema(ref hash, field.name, field.size);
			}
			sSchema = hash == 0 ? 1 : hash;
			return sSchema;
		}
	}

	static void MixSchema(ref uint64 hash, StringView name, int size)
	{
		for (let c in name.RawChars)
			hash = (hash ^ (uint8)c) * 1099511628211UL;
		hash = (hash ^ (uint64)(size + 0x100)) * 1099511628211UL;
	}

	static void WriteSchema(NetWriter payload, uint64 schema)
	{
		NetworkManager.WriteNetId(payload, SchemaNetId);
		payload.Write(schema);
	}

	/// Each tick, server and client: tells the other side when a script reload has changed this machine's [Sync]
	/// declarations.
	public static void WatchSchema(NetworkManager network)
	{
		let schema = SyncSchema;
		if (network.[Friend]mSchemaAtStart == 0)
		{
			network.[Friend]mSchemaAtStart = schema;
			network.[Friend]mSchemaSent = schema;
			return;
		}
		if (schema == network.[Friend]mSchemaSent)
			return;
		network.[Friend]mSchemaSent = schema;
		let payload = scope NetWriter();
		WriteSchema(payload, schema);
		if (network.IsServer)
		{
			network.SendToAll(MsgEcsComponents, payload);
			for (let client in network.[Friend]mClients)
			{
				if ((client.syncSchema != 0 ? client.syncSchema : network.[Friend]mSchemaAtStart) == schema)
					SendEveryField(network, client.id);
			}
		}
		else
			network.SendToServer(MsgEcsComponents, payload);
	}

	/// Server: a client that joins after a reload changed the server's declarations is told them.
	static void SendSchemaTo(NetworkManager network, int32 clientId)
	{
		if (network.[Friend]mSchemaAtStart == 0 || network.[Friend]mSchemaSent == network.[Friend]mSchemaAtStart)
			return;
		let payload = scope NetWriter();
		WriteSchema(payload, network.[Friend]mSchemaSent);
		network.SendToClient(clientId, MsgEcsComponents, payload);
	}

	static void OnSchema(NetworkManager network, int32 sender, ref NetReader reader)
	{
		let schema = reader.Read<uint64>();
		if (!reader.Ok || schema == 0)
			return;
		let own = SyncSchema;
		if (network.IsServer)
		{
			for (let client in network.[Friend]mClients)
			{
				if (client.id != sender)
					continue;
				client.syncSchema = schema;
				if (schema == own)
					SendEveryField(network, sender);
			}
			return;
		}
		network.[Friend]mServerSchema = schema;
		if (schema == own)
			return;
		// So that the server knows, and sends everything again once the two agree.
		let payload = scope NetWriter();
		WriteSchema(payload, own);
		network.SendToServer(MsgEcsComponents, payload);
		if (network.[Friend]mSchemaWarned != schema)
		{
			network.[Friend]mSchemaWarned = schema;
			Log.Warning("The server's [Sync] fields are not the same as this machine's (a script was reloaded on one of them, or they run different builds): [Sync] fields of objects are not applied until they match again.");
		}
	}

	/// Server: every [Sync] field of every object a client has in its area, after their declarations agree again.
	static void SendEveryField(NetworkManager network, int32 clientId)
	{
		HashSet<uint32> outside = null;
		for (let client in network.[Friend]mClients)
		{
			if (client.id == clientId)
				outside = client.outside;
		}
		for (let identity in network.Identities)
		{
			if (outside == null || !outside.Contains(identity.NetId))
				SendFieldsTo(network, identity, clientId);
		}
	}
}

extension NetworkManager
{
	/// [Sync] declarations (NetworkSync.SyncSchema): this machine's when the session started and as last sent; on a
	/// client, the server's once it has said (0: assumed the same); the one last warned about.
	uint64 mSchemaAtStart, mSchemaSent, mServerSchema, mSchemaWarned;
}
