using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// Writes a rig as a rigged binary glTF (.glb), the model as its file had it (parts, materials, pictures, texture
/// coordinates and vertex colours) with a skeleton and each vertex's four strongest bones. Skinned Mesh Renderers
/// play animations on it, and other tools (Blender, Mixamo) read it.
///
/// The joints have no turn of their own in the rest pose, only where they are (the top bones turn the skeleton to face
/// the way the model does): a joint's rest is its place relative to its parent, and its inverse bind matrix takes the
/// model back to that joint.
static class RigExport
{
	[CLink] static extern uint8* tn_image_encode_png(uint8* pixels, int32 width, int32 height, int32* size);
	[CLink] static extern void tn_image_free_png(uint8* bytes);

	static void Escape(StringView text, String output)
	{
		for (let c in text.RawChars)
		{
			if (c == '"' || c == '\\')
				output.Append('\\');
			if (c >= ' ')
				output.Append(c);
		}
	}

	/// Writes the rigged file. False (with why) when there is nothing to write or it could not be written.
	public static bool Write(Rig rig, StringView path, String problem)
	{
		if (!rig.HasWeights)
		{
			problem.Append("The rig has no weights yet: make them first.");
			return false;
		}
		rig.SortBones();
		let boneCount = rig.bones.Count;
		let bin = scope List<uint8>();
		let accessors = scope String();
		let views = scope String();
		int accessorCount = 0, viewCount = 0;

		int View(Span<uint8> bytes, int target)
		{
			while (bin.Count % 4 != 0)
				bin.Add(0);
			let offset = bin.Count;
			bin.AddRange(bytes);
			if (viewCount > 0)
				views.Append(',');
			views.AppendF("{{\"buffer\":0,\"byteOffset\":{},\"byteLength\":{}", offset, bytes.Length);
			if (target != 0)
				views.AppendF(",\"target\":{}", target);
			views.Append('}');
			return viewCount++;
		}
		int Accessor(Span<uint8> bytes, int count, StringView type, int componentType, int target, Vector3? min = null, Vector3? max = null)
		{
			let view = View(bytes, target);
			if (accessorCount > 0)
				accessors.Append(',');
			accessors.AppendF("{{\"bufferView\":{},\"componentType\":{},\"count\":{},\"type\":\"{}\"", view, componentType, count, type);
			if (min.HasValue)
				accessors.AppendF(",\"min\":[{},{},{}],\"max\":[{},{},{}]", min.Value.x, min.Value.y, min.Value.z, max.Value.x, max.Value.y, max.Value.z);
			accessors.Append('}');
			return accessorCount++;
		}

		// Each vertex's four strongest bones, adding up to 1.
		let joints = scope uint16[rig.positions.Count * 4];
		let jointWeights = scope float[rig.positions.Count * 4];
		for (int v < rig.positions.Count)
		{
			let row = rig.weights.Ptr + v * boneCount;
			var sum = 0.0f;
			for (int slot < 4)
			{
				var best = -1;
				for (int b < boneCount)
				{
					if (row[b] <= 0)
						continue;
					var taken = false;
					for (int s < slot)
						taken |= joints[v * 4 + s] == b && jointWeights[v * 4 + s] > 0;
					if (!taken && (best < 0 || row[b] > row[best]))
						best = b;
				}
				if (best >= 0)
				{
					joints[v * 4 + slot] = (uint16)best;
					jointWeights[v * 4 + slot] = row[best];
					sum += row[best];
				}
			}
			if (sum <= 0)
			{
				jointWeights[v * 4] = 1;
				sum = 1;
			}
			for (int slot < 4)
				jointWeights[v * 4 + slot] /= sum;
		}

		// One primitive a part, with the vertices it uses.
		let primitives = scope String();
		for (let part in rig.parts)
		{
			let remap = scope Dictionary<uint32, uint32>();
			let used = scope List<uint32>();
			let indices = scope uint32[part.indices.Count];
			for (int i < part.indices.Count)
			{
				let v = part.indices[i];
				if (!remap.TryGetValue(v, var local))
				{
					local = (uint32)used.Count;
					remap[v] = local;
					used.Add(v);
				}
				indices[i] = local;
			}
			let n = used.Count;
			if (n == 0)
				continue;
			let positions = scope float[n * 3];
			let normals = scope float[n * 3];
			let uvs = scope float[n * 2];
			let uv2s = scope float[n * 2];
			let colors = scope float[n * 4];
			let partJoints = scope uint16[n * 4];
			let partWeights = scope float[n * 4];
			var min = Vector3(float.MaxValue), max = Vector3(-float.MaxValue);
			for (int i < n)
			{
				let v = used[i];
				// The engine's space has glTF's Z turned round.
				let p = Vector3(rig.positions[(int)v].x, rig.positions[(int)v].y, -rig.positions[(int)v].z);
				min = Vector3.Min(min, p);
				max = Vector3.Max(max, p);
				positions[i * 3] = p.x;
				positions[i * 3 + 1] = p.y;
				positions[i * 3 + 2] = p.z;
				normals[i * 3] = rig.normals[(int)v].x;
				normals[i * 3 + 1] = rig.normals[(int)v].y;
				normals[i * 3 + 2] = -rig.normals[(int)v].z;
				uvs[i * 2] = rig.uvs[(int)v].x;
				uvs[i * 2 + 1] = rig.uvs[(int)v].y;
				uv2s[i * 2] = rig.uv2s[(int)v].x;
				uv2s[i * 2 + 1] = rig.uv2s[(int)v].y;
				let c = EditMesh.ColorFromABGR(rig.colors[(int)v]);
				colors[i * 4] = c.r;
				colors[i * 4 + 1] = c.g;
				colors[i * 4 + 2] = c.b;
				colors[i * 4 + 3] = c.a;
				for (int s < 4)
				{
					partJoints[i * 4 + s] = joints[(int)v * 4 + s];
					partWeights[i * 4 + s] = jointWeights[(int)v * 4 + s];
				}
			}
			let position = Accessor(.((uint8*)positions.Ptr, positions.Count * 4), n, "VEC3", 5126, 34962, min, max);
			let normal = Accessor(.((uint8*)normals.Ptr, normals.Count * 4), n, "VEC3", 5126, 34962);
			let uv = Accessor(.((uint8*)uvs.Ptr, uvs.Count * 4), n, "VEC2", 5126, 34962);
			let color = Accessor(.((uint8*)colors.Ptr, colors.Count * 4), n, "VEC4", 5126, 34962);
			let joint = Accessor(.((uint8*)partJoints.Ptr, partJoints.Count * 2), n, "VEC4", 5123, 34962);
			let weight = Accessor(.((uint8*)partWeights.Ptr, partWeights.Count * 4), n, "VEC4", 5126, 34962);
			let index = Accessor(.((uint8*)indices.Ptr, indices.Count * 4), indices.Count, "SCALAR", 5125, 34963);
			if (!primitives.IsEmpty)
				primitives.Append(',');
			primitives.AppendF("{{\"attributes\":{{\"POSITION\":{},\"NORMAL\":{},\"TEXCOORD_0\":{},\"COLOR_0\":{},\"JOINTS_0\":{},\"WEIGHTS_0\":{}", position, normal, uv, color, joint, weight);
			if (rig.hasUV2)
				primitives.AppendF(",\"TEXCOORD_1\":{}", Accessor(.((uint8*)uv2s.Ptr, uv2s.Count * 4), n, "VEC2", 5126, 34962));
			primitives.AppendF("}},\"indices\":{},\"material\":{}}}", index, part.material);
		}

		// The pictures, as PNGs inside the file.
		let imagesJson = scope String();
		let texturesJson = scope String();
		for (int i < rig.images.Count)
		{
			let image = rig.images[i];
			int32 size = 0;
			uint8* png = null;
			if (image.pixels != null)
				png = tn_image_encode_png(image.pixels.Ptr, image.width, image.height, &size);
			if (i > 0)
			{
				imagesJson.Append(',');
				texturesJson.Append(',');
			}
			if (png != null)
			{
				let view = View(.(png, size), 0);
				tn_image_free_png(png);
				imagesJson.AppendF("{{\"bufferView\":{},\"mimeType\":\"image/png\"}}", view);
			}
			else
			{
				// A picture that could not be read stays a 1x1 white one, so the materials' numbering holds.
				uint8[4] white = .(255, 255, 255, 255);
				let one = tn_image_encode_png(&white, 1, 1, &size);
				let view = View(.(one, size), 0);
				tn_image_free_png(one);
				imagesJson.AppendF("{{\"bufferView\":{},\"mimeType\":\"image/png\"}}", view);
			}
			texturesJson.AppendF("{{\"source\":{}}}", i);
		}
		let materialsJson = scope String();
		for (int m < rig.materials.Count)
		{
			let material = rig.materials[m];
			if (m > 0)
				materialsJson.Append(',');
			let name = Escape(material.name, .. scope .());
			materialsJson.AppendF("{{\"name\":\"{}\",\"pbrMetallicRoughness\":{{\"baseColorFactor\":[{},{},{},{}],\"metallicFactor\":{},\"roughnessFactor\":{}", name,
				material.baseColor[0], material.baseColor[1], material.baseColor[2], material.baseColor[3], material.metallic, material.roughness);
			bool Valid(int32 image) => image >= 0 && image < rig.images.Count;
			if (Valid(material.baseColorImage))
				materialsJson.AppendF(",\"baseColorTexture\":{{\"index\":{}}}", material.baseColorImage);
			if (Valid(material.metalRoughImage))
				materialsJson.AppendF(",\"metallicRoughnessTexture\":{{\"index\":{}}}", material.metalRoughImage);
			materialsJson.Append('}');
			if (Valid(material.normalImage))
				materialsJson.AppendF(",\"normalTexture\":{{\"index\":{},\"scale\":{}}}", material.normalImage, material.normalScale);
			if (Valid(material.occlusionImage))
				materialsJson.AppendF(",\"occlusionTexture\":{{\"index\":{},\"strength\":{}}}", material.occlusionImage, material.occlusionStrength);
			if (Valid(material.emissiveImage))
				materialsJson.AppendF(",\"emissiveTexture\":{{\"index\":{}}}", material.emissiveImage);
			materialsJson.AppendF(",\"emissiveFactor\":[{},{},{}]", material.emissive[0], material.emissive[1], material.emissive[2]);
			if (material.alphaMode == 1)
				materialsJson.AppendF(",\"alphaMode\":\"MASK\",\"alphaCutoff\":{}", material.alphaCutoff);
			else if (material.alphaMode == 2)
				materialsJson.Append(",\"alphaMode\":\"BLEND\"");
			if (material.doubleSided)
				materialsJson.Append(",\"doubleSided\":true");
			materialsJson.Append('}');
		}
		if (rig.materials.IsEmpty)
			materialsJson.Append("{\"name\":\"Material\"}");

		// The skeleton: node 0 is the model, then one node a bone.
		let inverseBind = scope float[boneCount * 16];
		let nodes = scope String();
		let modelName = Path.GetFileNameWithoutExtension(rig.source, .. scope .());
		nodes.AppendF("{{\"name\":\"{}\",\"mesh\":0,\"skin\":0}}", Escape(modelName, .. scope .()));
		let roots = scope String("0");
		let jointList = scope String();
		// Every rigged model's skeleton faces the same way, so that a clip made on one means the same on another (clips
		// turn bones from their rest, and a library on the same skeleton is matched by name, not turned to face): the
		// top bones turn glTF's front (+Z) to the way the model faces, and every bone below is placed in that frame.
		let f = Vector3(rig.facing.x, 0, -rig.facing.z);
		let yaw = f.LengthSquared > 1e-8f ? Math.Atan2(f.x, f.z) : 0;
		let cosYaw = Math.Cos(yaw), sinYaw = Math.Sin(yaw);
		// Into the skeleton's frame (turned back by the yaw).
		Vector3 Unturn(Vector3 v) => .(v.x * cosYaw - v.z * sinYaw, v.y, v.x * sinYaw + v.z * cosYaw);
		for (int b < boneCount)
		{
			let bone = rig.bones[b];
			let head = Vector3(bone.head.x, bone.head.y, -bone.head.z);
			var local = head;
			if (bone.parent >= 0)
			{
				let parent = rig.bones[bone.parent].head;
				local = Unturn(head - Vector3(parent.x, parent.y, -parent.z));
			}
			nodes.AppendF(",{{\"name\":\"{}\",\"translation\":[{},{},{}]", Escape(bone.name, .. scope .()), local.x, local.y, local.z);
			if (bone.parent < 0 && Math.Abs(yaw) > 1e-6f)
				nodes.AppendF(",\"rotation\":[0,{},0,{}]", Math.Sin(yaw * 0.5f), Math.Cos(yaw * 0.5f));
			let children = scope String();
			for (int c < boneCount)
			{
				if (rig.bones[c].parent == b)
					children.AppendF("{}{}", children.IsEmpty ? "" : ",", c + 1);
			}
			if (!children.IsEmpty)
				nodes.AppendF(",\"children\":[{}]", children);
			nodes.Append('}');
			if (bone.parent < 0)
				roots.AppendF(",{}", b + 1);
			jointList.AppendF("{}{}", b == 0 ? "" : ",", b + 1);
			// Column-major: the inverse of the joint's place and turn (turned back, then moved back).
			let back = Unturn(-head);
			float[16] m = .(cosYaw, 0, sinYaw, 0, 0, 1, 0, 0, -sinYaw, 0, cosYaw, 0, back.x, back.y, back.z, 1);
			for (int i < 16)
				inverseBind[b * 16 + i] = m[i];
		}
		let bind = Accessor(.((uint8*)inverseBind.Ptr, inverseBind.Count * 4), boneCount, "MAT4", 5126, 0);
		var skeletonRoot = 1;
		for (int b < boneCount)
		{
			if (rig.bones[b].parent < 0)
			{
				skeletonRoot = b + 1;
				break;
			}
		}

		while (bin.Count % 4 != 0)
			bin.Add(0);
		let json = scope String();
		json.AppendF("{{\"asset\":{{\"version\":\"2.0\",\"generator\":\"Tallow rigger\"}},\"scene\":0,\"scenes\":[{{\"nodes\":[{}]}}],\"nodes\":[{}],", roots, nodes);
		json.AppendF("\"skins\":[{{\"inverseBindMatrices\":{},\"skeleton\":{},\"joints\":[{}]}}],", bind, skeletonRoot, jointList);
		json.AppendF("\"meshes\":[{{\"name\":\"{}\",\"primitives\":[{}]}}],\"materials\":[{}],", Escape(modelName, .. scope .()), primitives, materialsJson);
		if (!imagesJson.IsEmpty)
			json.AppendF("\"images\":[{}],\"textures\":[{}],", imagesJson, texturesJson);
		json.AppendF("\"buffers\":[{{\"byteLength\":{}}}],\"bufferViews\":[{}],\"accessors\":[{}]}}", bin.Count, views, accessors);
		while (json.Length % 4 != 0)
			json.Append(' ');

		let file = scope List<uint8>();
		void U32(uint32 value)
		{
			file.Add((uint8)value);
			file.Add((uint8)(value >> 8));
			file.Add((uint8)(value >> 16));
			file.Add((uint8)(value >> 24));
		}
		U32(0x46546C67); // "glTF"
		U32(2);
		U32((uint32)(12UL + 8 + (uint64)json.Length + 8 + (uint64)bin.Count));
		U32((uint32)json.Length);
		U32(0x4E4F534A); // "JSON"
		file.AddRange(.((uint8*)json.Ptr, json.Length));
		U32((uint32)bin.Count);
		U32(0x004E4942); // "BIN"
		file.AddRange(bin);
		let full = Assets.ResolvePath(path, .. scope .());
		let folder = Path.GetDirectoryPath(full, .. scope .());
		if (!folder.IsEmpty)
			Directory.CreateDirectory(folder).IgnoreError();
		if (File.WriteAll(full, file) case .Err)
		{
			problem.AppendF("{} could not be written.", path);
			return false;
		}
		return true;
	}
}
