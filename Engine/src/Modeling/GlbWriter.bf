using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// Writes meshes to a binary glTF (.glb) file, for taking a model made in the editor into other tools (Blender) or
/// other engines. One primitive per mesh given, each with a plain material of the name given. Positions, normals,
/// texture coordinates and vertex colours are kept.
static class GlbWriter
{
	public static bool Write(StringView path, Span<Mesh> meshes, Span<StringView> materialNames)
	{
		let bin = scope List<uint8>();
		let json = scope String();
		let accessors = scope String();
		let views = scope String();
		let primitives = scope String();
		let materialsJson = scope String();
		int accessorCount = 0, viewCount = 0;

		// Adds a buffer view and an accessor over it; returns the accessor's number.
		int Add(Span<uint8> bytes, int count, StringView type, int componentType, bool isIndex, Vector3? min = null, Vector3? max = null)
		{
			while (bin.Count % 4 != 0)
				bin.Add(0);
			let offset = bin.Count;
			bin.AddRange(bytes);
			if (viewCount > 0)
				views.Append(',');
			views.AppendF("{{\"buffer\":0,\"byteOffset\":{},\"byteLength\":{},\"target\":{}}}", offset, bytes.Length, isIndex ? 34963 : 34962);
			if (accessorCount > 0)
				accessors.Append(',');
			accessors.AppendF("{{\"bufferView\":{},\"componentType\":{},\"count\":{},\"type\":\"{}\"", viewCount, componentType, count, type);
			if (min.HasValue)
				accessors.AppendF(",\"min\":[{},{},{}],\"max\":[{},{},{}]", min.Value.x, min.Value.y, min.Value.z, max.Value.x, max.Value.y, max.Value.z);
			accessors.Append('}');
			viewCount++;
			return accessorCount++;
		}

		for (int m < meshes.Length)
		{
			let mesh = meshes[m];
			if (mesh == null || mesh.Indices.Count == 0)
				continue;
			let n = mesh.Vertices.Count;
			let positions = scope float[n * 3];
			let normals = scope float[n * 3];
			let uvs = scope float[n * 2];
			let colors = scope float[n * 4];
			var min = Vector3(float.MaxValue);
			var max = Vector3(-float.MaxValue);
			for (int i < n)
			{
				let v = mesh.Vertices[i];
				// Tallow is left-handed; glTF is right-handed with Z the other way.
				let p = Vector3(v.position.x, v.position.y, -v.position.z);
				min = Vector3.Min(min, p);
				max = Vector3.Max(max, p);
				positions[i * 3] = p.x;
				positions[i * 3 + 1] = p.y;
				positions[i * 3 + 2] = p.z;
				normals[i * 3] = v.normal.x;
				normals[i * 3 + 1] = v.normal.y;
				normals[i * 3 + 2] = -v.normal.z;
				uvs[i * 2] = v.uv.x;
				uvs[i * 2 + 1] = v.uv.y;
				let c = EditMesh.ColorFromABGR(v.color);
				colors[i * 4] = c.r;
				colors[i * 4 + 1] = c.g;
				colors[i * 4 + 2] = c.b;
				colors[i * 4 + 3] = c.a;
			}
			// Flipping Z turns the triangles' winding round: put it back.
			let indices = scope uint32[mesh.Indices.Count];
			for (int i = 0; i + 2 < mesh.Indices.Count; i += 3)
			{
				indices[i] = mesh.Indices[i];
				indices[i + 1] = mesh.Indices[i + 2];
				indices[i + 2] = mesh.Indices[i + 1];
			}
			let position = Add(.((uint8*)positions.Ptr, positions.Count * 4), n, "VEC3", 5126, false, min, max);
			let normal = Add(.((uint8*)normals.Ptr, normals.Count * 4), n, "VEC3", 5126, false);
			let uv = Add(.((uint8*)uvs.Ptr, uvs.Count * 4), n, "VEC2", 5126, false);
			let color = Add(.((uint8*)colors.Ptr, colors.Count * 4), n, "VEC4", 5126, false);
			let index = Add(.((uint8*)indices.Ptr, indices.Count * 4), indices.Count, "SCALAR", 5125, true);
			if (!primitives.IsEmpty)
				primitives.Append(',');
			primitives.AppendF("{{\"attributes\":{{\"POSITION\":{},\"NORMAL\":{},\"TEXCOORD_0\":{},\"COLOR_0\":{}}},\"indices\":{},\"material\":{}}}", position, normal, uv, color, index, m);
		}
		for (int m < meshes.Length)
		{
			if (m > 0)
				materialsJson.Append(',');
			let name = m < materialNames.Length ? materialNames[m] : "Material";
			let escaped = scope String();
			for (let c in name.RawChars)
			{
				if (c == '"' || c == '\\')
					escaped.Append('\\');
				escaped.Append(c);
			}
			materialsJson.AppendF("{{\"name\":\"{}\",\"pbrMetallicRoughness\":{{\"baseColorFactor\":[1,1,1,1],\"metallicFactor\":0,\"roughnessFactor\":0.85}}}}", escaped);
		}
		while (bin.Count % 4 != 0)
			bin.Add(0);
		json.AppendF("{{\"asset\":{{\"version\":\"2.0\",\"generator\":\"Tallow\"}},\"scene\":0,\"scenes\":[{{\"nodes\":[0]}}],\"nodes\":[{{\"mesh\":0,\"name\":\"Model\"}}],");
		json.AppendF("\"meshes\":[{{\"primitives\":[{}]}}],\"materials\":[{}],\"buffers\":[{{\"byteLength\":{}}}],", primitives, materialsJson, bin.Count);
		json.AppendF("\"bufferViews\":[{}],\"accessors\":[{}]}}", views, accessors);
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
		return File.WriteAll(path, file) case .Ok;
	}

	/// Writes an editor model: one primitive per material slot.
	public static bool Write(StringView path, EditMesh model, Span<StringView> materialNames)
	{
		let slots = Math.Max(model.MaterialCount, 1);
		let meshes = scope List<Mesh>();
		defer
		{
			for (let mesh in meshes)
				delete mesh;
		}
		for (int32 s < (int32)slots)
		{
			let mesh = new Mesh();
			model.Build(mesh, .One, slots > 1 ? s : -1);
			meshes.Add(mesh);
		}
		return Write(path, meshes, materialNames);
	}
}
