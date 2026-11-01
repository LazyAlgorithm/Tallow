using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// What kind of skeleton a rig starts from (docs/rigging.md).
enum RigTemplate
{
	/// Two legs, two arms and a head, with Mixamo's bone names, so that Mixamo's animations and the engine's humanoid
	/// clips play on it.
	Humanoid,
	/// Four legs, a tail, a neck and a head: cats, dogs, horses, lizards...
	Quadruped,
	/// Bones placed by hand, for anything else (a snake, a tentacle, a door).
	Custom
}

/// One joint of a rig and the bone that leaves it: where it starts and ends, in the model's own space. A bone's
/// end is its first child's joint; a bone without children ends at `tail`.
class RigBone
{
	public String name = new .() ~ delete _;
	public int32 parent = -1;
	public Vector3 head;
	public Vector3 tail;
	/// Bends the mesh (has weights). The end joints of chains (HeadTop_End, a tail's tip) do not.
	public bool deform = true;

	public void CopyFrom(RigBone other)
	{
		name.Set(other.name);
		parent = other.parent;
		head = other.head;
		tail = other.tail;
		deform = other.deform;
	}
}

/// A point the template's skeleton is built from (the chin, a wrist, a paw...), placed on the model.
struct RigMarker
{
	public StringView name;
	public Vector3 position;
	/// The marker on the other side (a left wrist's right wrist), moved with it while Symmetry is on; -1 for one in
	/// the middle.
	public int32 mirror;
	/// Only used when its setting is on (a quadruped's ears).
	public bool optional;
}

/// Settings for building a template's skeleton.
struct RigSettings
{
	/// Humanoid fingers: 0 none, 2 a thumb and a mitten, 5 all five.
	public int32 fingers = 5;
	/// Bones up the back between the hips and the neck.
	public int32 spine = 3;
	/// Bones in a quadruped's neck.
	public int32 neck = 2;
	/// Bones in a quadruped's tail (0 for none).
	public int32 tail = 6;
	/// A quadruped's ears and jaw.
	public bool ears = true;
	public bool jaw = true;

	public this()
	{
	}
}

/// A material of the rigged model, as its file has it, kept to write the rigged copy.
class RigMaterial
{
	public String name = new .() ~ delete _;
	public float[4] baseColor = .(1, 1, 1, 1);
	public float metallic, roughness = 1;
	public float[3] emissive;
	public int32 baseColorImage = -1, metalRoughImage = -1, normalImage = -1, occlusionImage = -1, emissiveImage = -1;
	public float normalScale = 1, occlusionStrength = 1;
	public int32 alphaMode;
	public float alphaCutoff = 0.5f;
	public bool doubleSided;
}

/// One part of the model: its triangles (into the rig's vertex lists) and which material it uses.
class RigPart
{
	public List<uint32> indices = new .() ~ delete _;
	public int32 material;
}

/// A picture the model's materials use, as RGBA pixels.
class RigImage
{
	public uint8[] pixels ~ delete _;
	public int32 width, height;
}

/// A rig in the making (docs/rigging.md): a still model (a .glb or .gltf), the skeleton put in it, and how much each
/// bone moves each vertex. Saved as a `.trig` text file beside the model, and written as a rigged `.glb` that a
/// Skinned Mesh Renderer plays animations on.
///
/// Everything is in the model's own space, as the engine draws the file (glTF's Z turned round): +X to the right of
/// a model facing -Z, which is glTF's front.
class Rig
{
	public const String Extension = ".trig";

	/// The still model rigged ("Models/dog.glb").
	public String source = new .() ~ delete _;
	public RigTemplate template = .Humanoid;
	public RigSettings settings = .();
	/// Which way the model faces (its front), across the ground.
	public Vector3 facing = .(0, 0, -1);
	public List<RigMarker> markers = new .() ~ delete _;
	public List<RigBone> bones = new .() ~ DeleteContainerAndItems!(_);

	// The model, read from the source: one list of vertices for every part.
	public List<Vector3> positions = new .() ~ delete _;
	public List<Vector3> normals = new .() ~ delete _;
	public List<Vector2> uvs = new .() ~ delete _;
	public List<Vector2> uv2s = new .() ~ delete _;
	public List<uint32> colors = new .() ~ delete _;
	public List<RigPart> parts = new .() ~ DeleteContainerAndItems!(_);
	public List<RigMaterial> materials = new .() ~ DeleteContainerAndItems!(_);
	public List<RigImage> images = new .() ~ DeleteContainerAndItems!(_);
	public bool hasUV2;
	/// The model's size: the box round its vertices.
	public Bounds bounds;

	/// How much each bone moves each vertex: vertex * bones.Count + bone. Each vertex's weights add up to 1 (or are
	/// all 0 before weights are made).
	public List<float> weights = new .() ~ delete _;

	public int VertexCount => positions.Count;
	public int BoneCount => bones.Count;

	public float Weight(int vertex, int bone) => weights[vertex * bones.Count + bone];
	public bool HasWeights => weights.Count == positions.Count * bones.Count && bones.Count > 0 && !positions.IsEmpty;

	public int FindBone(StringView name)
	{
		for (int i < bones.Count)
		{
			if (bones[i].name == name)
				return i;
		}
		return -1;
	}

	public int FindMarker(StringView name)
	{
		for (int i < markers.Count)
		{
			if (markers[i].name == name)
				return i;
		}
		return -1;
	}

	/// The right-hand side of the model (facing forward, up being +Y).
	public Vector3 Right => Vector3.Cross(.(0, 1, 0), facing).Normalized;

	// ---- reading the model ----

	/// Reads the still model a rig is for. False (with why) when it cannot be read or has nothing in it.
	public bool LoadSource(StringView path, String problem)
	{
		let full = Assets.ResolvePath(path, .. scope .());
		let scene = Native.tn_gltf_load(full.CStr());
		if (scene == null)
		{
			problem.AppendF("{} could not be read as a glTF model.", path);
			return false;
		}
		defer Native.tn_gltf_free(scene);
		source.Set(path);
		positions.Clear();
		normals.Clear();
		uvs.Clear();
		uv2s.Clear();
		colors.Clear();
		ClearAndDeleteItems!(parts);
		ClearAndDeleteItems!(materials);
		ClearAndDeleteItems!(images);
		hasUV2 = false;
		let materialIds = scope List<int32>();
		for (uint32 p < Native.tn_gltf_prim_count(scene))
		{
			let prim = Native.tn_gltf_get_prim(scene, p);
			if (prim.vertexCount == 0 || prim.indexCount < 3)
				continue;
			Matrix4 world = default;
			for (int i < 16)
				world.m[i] = prim.world[i];
			let normalMatrix = world.Inverse.Transposed;
			let mirrored = Determinant(world) < 0;
			let first = (uint32)positions.Count;
			for (uint32 v < prim.vertexCount)
			{
				let p3 = world.TransformPoint(.(prim.positions[v * 3], prim.positions[v * 3 + 1], prim.positions[v * 3 + 2]));
				positions.Add(.(p3.x, p3.y, -p3.z));
				var n = Vector3(0, 1, 0);
				if (prim.normals != null)
				{
					n = normalMatrix.TransformDirection(.(prim.normals[v * 3], prim.normals[v * 3 + 1], prim.normals[v * 3 + 2])).Normalized;
					n.z = -n.z;
				}
				normals.Add(n);
				uvs.Add(prim.uvs != null ? Vector2(prim.uvs[v * 2], prim.uvs[v * 2 + 1]) : .Zero);
				uv2s.Add(prim.uv2s != null ? Vector2(prim.uv2s[v * 2], prim.uv2s[v * 2 + 1]) : .Zero);
				if (prim.colors != null)
					colors.Add(Color(prim.colors[v * 4], prim.colors[v * 4 + 1], prim.colors[v * 4 + 2], prim.colors[v * 4 + 3]).ToABGR());
				else
					colors.Add(0xFFFFFFFF);
			}
			hasUV2 |= prim.uv2s != null;
			var material = materialIds.IndexOf(prim.material);
			if (material < 0)
			{
				material = materials.Count;
				materialIds.Add(prim.material);
				let m = new RigMaterial();
				m.name.Append(&prim.materialName);
				for (int i < 4)
					m.baseColor[i] = prim.baseColor[i];
				m.metallic = prim.metallic;
				m.roughness = prim.roughness;
				for (int i < 3)
					m.emissive[i] = prim.emissive[i];
				m.baseColorImage = prim.baseColorImage;
				m.metalRoughImage = prim.metalRoughImage;
				m.normalImage = prim.normalImage;
				m.occlusionImage = prim.occlusionImage;
				m.emissiveImage = prim.emissiveImage;
				m.normalScale = prim.normalScale;
				m.occlusionStrength = prim.occlusionStrength;
				m.alphaMode = prim.alphaMode;
				m.alphaCutoff = prim.alphaCutoff;
				m.doubleSided = prim.doubleSided != 0;
				materials.Add(m);
			}
			let part = new RigPart();
			part.material = (int32)material;
			for (uint32 i = 0; i + 2 < prim.indexCount; i += 3)
			{
				// Kept as the file winds them (a mirrored node's triangles turned back).
				part.indices.Add(first + prim.indices[i]);
				part.indices.Add(first + prim.indices[mirrored ? i + 2 : i + 1]);
				part.indices.Add(first + prim.indices[mirrored ? i + 1 : i + 2]);
			}
			parts.Add(part);
		}
		for (int32 i < Native.tn_gltf_image_count(scene))
		{
			let image = new RigImage();
			let pixels = Native.tn_gltf_get_image(scene, i, &image.width, &image.height);
			if (pixels != null)
			{
				image.pixels = new uint8[image.width * image.height * 4];
				Internal.MemCpy(image.pixels.Ptr, pixels, image.pixels.Count);
			}
			images.Add(image);
		}
		if (positions.IsEmpty)
		{
			problem.AppendF("{} has no triangles to rig.", path);
			return false;
		}
		var min = positions[0], max = positions[0];
		for (let p in positions)
		{
			min = Vector3.Min(min, p);
			max = Vector3.Max(max, p);
		}
		bounds = .(min, max);
		weights.Clear();
		return true;
	}

	static float Determinant(Matrix4 m)
	{
		// The upper 3x3 (column-major).
		let a = m.m;
		return a[0] * (a[5] * a[10] - a[9] * a[6]) - a[4] * (a[1] * a[10] - a[9] * a[2]) + a[8] * (a[1] * a[6] - a[5] * a[2]);
	}

	/// Every triangle of every part, as indices into the vertex lists.
	public void Triangles(List<uint32> output)
	{
		output.Clear();
		for (let part in parts)
			output.AddRange(part.indices);
	}

	// ---- bones ----

	/// The bone's children.
	public void Children(int bone, List<int> output)
	{
		output.Clear();
		for (int i < bones.Count)
		{
			if (bones[i].parent == bone)
				output.Add(i);
		}
	}

	/// Where a bone ends: its first child's joint, else its own tail.
	public Vector3 End(int bone)
	{
		for (int i < bones.Count)
		{
			if (bones[i].parent == bone)
				return bones[i].head;
		}
		return bones[bone].tail;
	}

	/// The bone that is this one on the other side (LeftArm and RightArm, Ear_L and Ear_R), or -1.
	public int MirrorBone(int bone)
	{
		let other = MirrorName(bones[bone].name, .. scope .());
		return other == bones[bone].name ? -1 : FindBone(other);
	}

	/// A name with its side swapped: Left/Right at the start, _L/_R, .L/.R or " L"/" R" at the end.
	public static void MirrorName(StringView name, String output)
	{
		if (name.StartsWith("Left"))
			output.AppendF("Right{}", name.Substring(4));
		else if (name.StartsWith("Right"))
			output.AppendF("Left{}", name.Substring(5));
		else
		{
			output.Append(name);
			StringView[3] lefts = .("_L", ".L", " L");
			StringView[3] rights = .("_R", ".R", " R");
			for (int k < 3)
			{
				let pair = (lefts[k], rights[k]);
				let at = name.IndexOf(pair.0);
				let atOther = name.IndexOf(pair.1);
				// A side mark ends the name, or comes before a number or another part (Ear_L1, Hand_L_End).
				if (at >= 0 && (at + 2 == name.Length || !name[at + 2].IsLetter))
				{
					output.Clear();
					output.AppendF("{}{}{}", name.Substring(0, at), pair.1, name.Substring(at + 2));
					return;
				}
				if (atOther >= 0 && (atOther + 2 == name.Length || !name[atOther + 2].IsLetter))
				{
					output.Clear();
					output.AppendF("{}{}{}", name.Substring(0, atOther), pair.0, name.Substring(atOther + 2));
					return;
				}
			}
		}
	}

	/// Adds a bone (weights for it start at nothing). Returns its index.
	public int AddBone(StringView name, int parent, Vector3 head, Vector3 tail, bool deform = true)
	{
		let bone = new RigBone();
		bone.name.Set(name);
		bone.parent = (int32)parent;
		bone.head = head;
		bone.tail = tail;
		bone.deform = deform;
		let oldCount = bones.Count;
		bones.Add(bone);
		if (weights.Count == positions.Count * oldCount && oldCount > 0)
		{
			let grown = scope List<float>(positions.Count * bones.Count);
			for (int v < positions.Count)
			{
				for (int b < oldCount)
					grown.Add(weights[v * oldCount + b]);
				grown.Add(0);
			}
			weights.Set(grown);
		}
		return bones.Count - 1;
	}

	/// Removes a bone: its children hang from its parent, and its weights go to its parent (or are spread over the
	/// others).
	public void RemoveBone(int bone)
	{
		let parent = bones[bone].parent;
		let oldCount = bones.Count;
		if (weights.Count == positions.Count * oldCount)
		{
			let shrunk = scope List<float>(positions.Count * (oldCount - 1));
			for (int v < positions.Count)
			{
				let row = weights.Ptr + v * oldCount;
				let gone = row[bone];
				if (parent >= 0)
					row[parent] += gone;
				var sum = 0.0f;
				for (int b < oldCount)
				{
					if (b != bone)
						sum += row[b];
				}
				for (int b < oldCount)
				{
					if (b != bone)
						shrunk.Add(parent < 0 && sum > 0 ? row[b] / sum : row[b]);
				}
			}
			weights.Set(shrunk);
		}
		for (let other in bones)
		{
			if (other.parent == bone)
				other.parent = parent;
			if (other.parent > bone)
				other.parent--;
		}
		delete bones[bone];
		bones.RemoveAt(bone);
	}

	/// Puts the bones in an order where every parent comes before its children (as the rigged file needs), keeping
	/// the weights with their bones.
	public void SortBones()
	{
		let order = scope List<int>();
		let placed = scope bool[bones.Count];
		void Visit(int bone)
		{
			order.Add(bone);
			placed[bone] = true;
			for (int i < bones.Count)
			{
				if (bones[i].parent == bone && !placed[i])
					Visit(i);
			}
		}
		for (int i < bones.Count)
		{
			if (!placed[i] && (bones[i].parent < 0 || bones[i].parent >= bones.Count))
			{
				bones[i].parent = -1;
				Visit(i);
			}
		}
		// A loop of parents: the rest hang from the first root.
		for (int i < bones.Count)
		{
			if (!placed[i])
			{
				bones[i].parent = (int32)order[0];
				Visit(i);
			}
		}
		var same = true;
		for (int i < order.Count)
			same &= order[i] == i;
		if (same)
			return;
		let newIndex = scope int[bones.Count];
		for (int i < order.Count)
			newIndex[order[i]] = i;
		let sorted = scope List<RigBone>();
		for (let i in order)
			sorted.Add(bones[i]);
		for (let bone in sorted)
		{
			if (bone.parent >= 0)
				bone.parent = (int32)newIndex[bone.parent];
		}
		let count = bones.Count;
		if (weights.Count == positions.Count * count)
		{
			let moved = scope List<float>(weights.Count);
			moved.Count = weights.Count;
			for (int v < positions.Count)
			{
				for (int b < count)
					moved[v * count + newIndex[b]] = weights[v * count + b];
			}
			weights.Set(moved);
		}
		bones.Clear();
		bones.AddRange(sorted);
	}

	// ---- posing (for trying the weights) ----

	/// Each bone's turn about its joint, relative to the rest pose; the identity for none.
	public List<Quaternion> pose = new .() ~ delete _;

	public void ResetPose()
	{
		pose.Clear();
		for (int i < bones.Count)
			pose.Add(.Identity);
	}

	/// Each bone's matrix taking a rest-pose point to where the pose puts it.
	public void PoseMatrices(List<Matrix4> output)
	{
		while (pose.Count < bones.Count)
			pose.Add(.Identity);
		output.Clear();
		for (int i < bones.Count)
		{
			let bone = bones[i];
			let local = Matrix4.Translate(bone.head) * Matrix4.Rotation(pose[i]) * Matrix4.Translate(-bone.head);
			// Parents come first once the bones are sorted; otherwise work up the chain.
			var matrix = local;
			if (bone.parent >= 0)
				matrix = (bone.parent < i ? output[bone.parent] : ParentMatrix(bone.parent)) * local;
			output.Add(matrix);
		}
	}

	Matrix4 ParentMatrix(int bone)
	{
		let b = bones[bone];
		let local = Matrix4.Translate(b.head) * Matrix4.Rotation(pose[bone]) * Matrix4.Translate(-b.head);
		return b.parent >= 0 ? ParentMatrix(b.parent) * local : local;
	}

	/// The vertices moved by the pose and the weights (linear blend skinning, with all of each vertex's weights).
	public void Posed(List<Vector3> outPositions, List<Vector3> outNormals)
	{
		outPositions.Clear();
		outNormals.Clear();
		if (!HasWeights)
		{
			outPositions.AddRange(positions);
			outNormals.AddRange(normals);
			return;
		}
		let matrices = scope List<Matrix4>();
		PoseMatrices(matrices);
		let count = bones.Count;
		for (int v < positions.Count)
		{
			var p = Vector3.Zero, n = Vector3.Zero;
			var total = 0.0f;
			let row = weights.Ptr + v * count;
			for (int b < count)
			{
				let w = row[b];
				if (w <= 0)
					continue;
				p = p + matrices[b].TransformPoint(positions[v]) * w;
				n = n + matrices[b].TransformDirection(normals[v]) * w;
				total += w;
			}
			outPositions.Add(total > 0 ? p / total : positions[v]);
			outNormals.Add(total > 0 ? n.Normalized : normals[v]);
		}
	}

	// ---- the .trig file ----

	/// Writes the rig as a `.trig` file's text: the model, template, settings, markers, bones and weights (each
	/// vertex's weights to four places, as bone:weight pairs).
	public void Write(String output)
	{
		output.Append("# Tallow rig (docs/rigging.md)\n");
		output.AppendF("source \"{}\"\n", source);
		output.AppendF("template {}\n", template);
		output.AppendF("facing {} {} {}\n", facing.x, facing.y, facing.z);
		output.AppendF("settings fingers {} spine {} neck {} tail {} ears {} jaw {}\n", settings.fingers, settings.spine, settings.neck, settings.tail, settings.ears ? 1 : 0, settings.jaw ? 1 : 0);
		for (let marker in markers)
			output.AppendF("marker \"{}\" {} {} {}\n", marker.name, marker.position.x, marker.position.y, marker.position.z);
		for (let bone in bones)
		{
			output.AppendF("bone \"{}\" {} {} {} {} {} {} {} {}\n", bone.name, bone.parent, bone.head.x, bone.head.y, bone.head.z, bone.tail.x, bone.tail.y, bone.tail.z,
				bone.deform ? 1 : 0);
		}
		if (!HasWeights)
			return;
		output.AppendF("vertices {}\n", positions.Count);
		let count = bones.Count;
		for (int v < positions.Count)
		{
			output.AppendF("w {}", v);
			for (int b < count)
			{
				let w = weights[v * count + b];
				if (w >= 0.00005f)
					output.AppendF(" {0}:{1:0.####}", b, w);
			}
			output.Append('\n');
		}
	}

	/// Reads a `.trig` file's text: the rig's settings, markers and bones, and its source model (read from its file).
	/// Weights are kept when the model still has as many vertices as when they were made. Problems are listed in
	/// `problems`; false when the rig cannot be used.
	public bool Parse(StringView text, String problems)
	{
		ClearAndDeleteItems!(bones);
		markers.Clear();
		let savedWeights = scope List<(int vertex, int bone, float weight)>();
		var vertexCount = -1;
		var headRead = false;
		var fingersRead = false;
		var sourceRead = false;
		int lineNumber = 0;
		for (var line in text.Split('\n'))
		{
			lineNumber++;
			line.Trim();
			if (line.IsEmpty || line.StartsWith('#'))
				continue;
			let words = scope List<StringView>();
			Words(line, words);
			if (words.IsEmpty)
				continue;
			float F(int i) => i < words.Count ? (float.Parse(words[i]) case .Ok(let value) ? value : 0) : 0;
			int I(int i) => i < words.Count ? (int.Parse(words[i]) case .Ok(let value) ? value : 0) : 0;
			switch (words[0])
			{
			case "source":
				if (words.Count < 2 || !LoadSource(words[1], problems))
					return false;
				sourceRead = true;
			case "template":
				if (words.Count > 1 && Enum.Parse<RigTemplate>(words[1]) case .Ok(let kind))
					template = kind;
				else
					problems.AppendF("line {}: no template is called '{}'\n", lineNumber, words.Count > 1 ? words[1] : "");
			case "facing":
				facing = Vector3(F(1), 0, F(3)).Normalized;
				if (facing.LengthSquared < 0.5f)
					facing = .(0, 0, -1);
			case "settings":
				for (int i = 1; i + 1 < words.Count; i += 2)
				{
					switch (words[i])
					{
					case "fingers": settings.fingers = (int32)I(i + 1);
					case "spine": settings.spine = (int32)I(i + 1);
					case "neck": settings.neck = (int32)I(i + 1);
					case "tail": settings.tail = (int32)I(i + 1);
					case "ears": settings.ears = I(i + 1) != 0;
					case "jaw": settings.jaw = I(i + 1) != 0;
					}
				}
			case "marker":
				// The template decides the markers; the file only moves them.
				if (markers.IsEmpty)
					RigTemplates.AddMarkers(this);
				let index = words.Count > 1 ? FindMarker(words[1]) : -1;
				if (index < 0)
					problems.AppendF("line {}: the {} template has no marker '{}'\n", lineNumber, template, words.Count > 1 ? words[1] : "");
				else
				{
					markers[index].position = .(F(2), F(3), F(4));
					headRead |= markers[index].name == "Head";
					fingersRead |= RigTemplates.FingerOf(markers[index].name) >= 0;
				}
			case "bone":
				if (words.Count < 10)
				{
					problems.AppendF("line {}: expected bone \"name\" parent head(x y z) tail(x y z) deform\n", lineNumber);
					continue;
				}
				let bone = new RigBone();
				bone.name.Set(words[1]);
				bone.parent = (int32)I(2);
				bone.head = .(F(3), F(4), F(5));
				bone.tail = .(F(6), F(7), F(8));
				bone.deform = I(9) != 0;
				bones.Add(bone);
			case "vertices":
				vertexCount = I(1);
			case "w":
				let vertex = I(1);
				for (int i = 2; i < words.Count; i++)
				{
					let colon = words[i].IndexOf(':');
					if (colon < 0)
						continue;
					if (int.Parse(words[i].Substring(0, colon)) case .Ok(let b) && float.Parse(words[i].Substring(colon + 1)) case .Ok(let w))
						savedWeights.Add((vertex, b, w));
				}
			default:
				problems.AppendF("line {}: '{}' is not something a rig file has\n", lineNumber, words[0]);
			}
		}
		if (!sourceRead)
		{
			problems.Append("the rig names no model (a source line)\n");
			return false;
		}
		if (markers.IsEmpty)
			RigTemplates.AddMarkers(this);
		// A rig saved before animals had a Head marker: put it where it would have been guessed.
		if (template == .Quadruped && !headRead && FindMarker("Head") >= 0)
			markers[FindMarker("Head")].position = RigTemplates.GuessHead(this);
		// And one from before people had fingertip markers: guess them from the hands.
		if (template == .Humanoid && !fingersRead && FindMarker("Left Index") >= 0)
			RigTemplates.GuessFingers(this);
		for (let bone in bones)
		{
			if (bone.parent >= bones.Count)
				bone.parent = -1;
		}
		weights.Clear();
		if (vertexCount >= 0 && vertexCount != positions.Count)
			problems.AppendF("the model has changed since the weights were made ({} vertices then, {} now): make them again\n", vertexCount, positions.Count);
		else if (vertexCount >= 0 && !bones.IsEmpty)
		{
			weights.Count = positions.Count * bones.Count;
			for (let entry in savedWeights)
			{
				if (entry.vertex >= 0 && entry.vertex < positions.Count && entry.bone >= 0 && entry.bone < bones.Count)
					weights[entry.vertex * bones.Count + entry.bone] = entry.weight;
			}
		}
		ResetPose();
		return true;
	}

	/// A line's words: spaces apart, or in quotes.
	static void Words(StringView line, List<StringView> output)
	{
		var i = 0;
		while (i < line.Length)
		{
			if (line[i] == ' ' || line[i] == '\t')
			{
				i++;
				continue;
			}
			if (line[i] == '"')
			{
				let end = line.IndexOf('"', i + 1);
				let stop = end < 0 ? line.Length : end;
				output.Add(line.Substring(i + 1, stop - i - 1));
				i = stop + 1;
				continue;
			}
			var end = i;
			while (end < line.Length && line[end] != ' ' && line[end] != '\t')
				end++;
			output.Add(line.Substring(i, end - i));
			i = end;
		}
	}

	public bool Save(StringView path)
	{
		let text = scope String();
		Write(text);
		let full = Assets.ResolvePath(path, .. scope .());
		let folder = Path.GetDirectoryPath(full, .. scope .());
		if (!folder.IsEmpty)
			Directory.CreateDirectory(folder).IgnoreError();
		return File.WriteAllText(full, text) case .Ok;
	}

	/// Reads a `.trig` file. Null (with why) when it cannot be used.
	public static Rig Load(StringView path, String problems)
	{
		let text = scope String();
		if (File.ReadAllText(Assets.ResolvePath(path, .. scope .()), text) case .Err)
		{
			problems.AppendF("{} could not be read.\n", path);
			return null;
		}
		var rig = new Rig();
		if (!rig.Parse(text, problems))
			DeleteAndNullify!(rig);
		return rig;
	}

	/// Where a model's rig and rigged copy go: Models/dog.glb gives Models/dog.trig and Models/dog_Rigged.glb.
	public static void PathsFor(StringView model, String rigPath, String riggedPath)
	{
		let dot = model.LastIndexOf('.');
		let stem = dot > model.LastIndexOf('/') ? model.Substring(0, dot) : model;
		rigPath.AppendF("{}{}", stem, Extension);
		riggedPath.AppendF("{}_Rigged.glb", stem);
	}
}
