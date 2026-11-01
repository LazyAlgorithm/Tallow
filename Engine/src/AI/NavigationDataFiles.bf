using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// NavigationData's .tnav assets: the binary grid (version 2), the old text grid (version 1), or a NavMesh.
extension NavigationData
{
	static void Put(List<uint8> bytes, uint32 value)
	{
		for (int shift = 0; shift < 32; shift += 8)
			bytes.Add((uint8)(value >> shift));
	}

	static void Put(List<uint8> bytes, float value)
	{
		var copy = value;
		Put(bytes, *(uint32*)&copy);
	}

	static uint32 Get(List<uint8> bytes, ref int cursor)
	{
		let v = (uint32)bytes[cursor] | ((uint32)bytes[cursor + 1] << 8) | ((uint32)bytes[cursor + 2] << 16) | ((uint32)bytes[cursor + 3] << 24);
		cursor += 4;
		return v;
	}

	static float GetFloat(List<uint8> bytes, ref int cursor)
	{
		var bits = Get(bytes, ref cursor);
		return *(float*)&bits;
	}

	/// The most cells a grid may have, and on one side.
	const int64 MaxCells = 1000000;
	const int32 MaxSide = 4096;

	/// Whether the grid settings just read make sense, for an asset holding `count` cells.
	bool ValidGrid(int64 count)
	{
		if (width <= 0 || height <= 0 || depth <= 0 || width > MaxSide || height > MaxSide || depth > MaxSide)
			return false;
		let cellCount = (int64)width * height * depth;
		return cellCount <= MaxCells && count == cellCount && cellSize >= 0.05f && cellSize.IsFinite && chunkSize >= 1 && (flying || height == 1) &&
			origin.x.IsFinite && origin.y.IsFinite && origin.z.IsFinite;
	}

	/// Binary: "TNAV", version 2, the grid settings, then one word per cell (links, top bit = usable) plus the floor
	/// height for walking cells. Everything else about a cell follows from its index.
	public bool Save(StringView path, String error)
	{
		List<uint8> bytes = scope .();
		if (Mesh != null)
		{
			if (!Mesh.Serialize(bytes) || File.WriteAll(path, bytes) case .Err)
			{
				error.Set("Cannot write NavMesh asset.");
				return false;
			}
			return true;
		}
		bytes.Reserve(64 + cells.Count * (flying ? 4 : 8));
		bytes.Add((uint8)'T');
		bytes.Add((uint8)'N');
		bytes.Add((uint8)'A');
		bytes.Add((uint8)'V');
		Put(bytes, (uint32)2);
		Put(bytes, origin.x);
		Put(bytes, origin.y);
		Put(bytes, origin.z);
		Put(bytes, cellSize);
		Put(bytes, (uint32)width);
		Put(bytes, (uint32)height);
		Put(bytes, (uint32)depth);
		Put(bytes, (uint32)chunkSize);
		Put(bytes, flying ? 1u : 0u);
		Put(bytes, agentRadius);
		Put(bytes, agentHeight);
		Put(bytes, maxStep);
		Put(bytes, maxSlope);
		for (let c in cells)
		{
			Put(bytes, (c.links & 0x7FFFFFFF) | (c.walkable ? 0x80000000u : 0u));
			if (!flying)
				Put(bytes, c.position.y);
		}
		if (File.WriteAll(path, bytes) case .Err)
		{
			error.Set("Cannot write navigation asset.");
			return false;
		}
		return true;
	}

	public bool Load(StringView path, String error)
	{
		List<uint8> bytes = scope .();
		if (AssetPack.ReadAll(path, bytes) case .Err)
		{
			error.Set("Cannot read navigation asset.");
			return false;
		}
		if (bytes.Count >= 4 && bytes[0] == (uint8)'T' && bytes[1] == (uint8)'N' && bytes[2] == (uint8)'M' && bytes[3] == (uint8)'1')
		{
			let mesh = NavigationMesh.Deserialize(bytes);
			if (mesh == null)
			{
				error.Set("Invalid NavMesh asset.");
				return false;
			}
			SetMesh(mesh);
			return true;
		}
		delete Mesh;
		Mesh = null;
		if (bytes.Count < 4 || bytes[0] != (uint8)'T' || bytes[1] != (uint8)'N' || bytes[2] != (uint8)'A' || bytes[3] != (uint8)'V') return LoadText(StringView((char8*)bytes.Ptr, bytes.Count), error);
		const int HeaderSize = 60;
		int cursor = 4;
		cells.Clear();
		if (bytes.Count < HeaderSize || Get(bytes, ref cursor) != 2)
		{
			error.Set("Unsupported navigation asset version.");
			return false;
		}
		origin.x = GetFloat(bytes, ref cursor);
		origin.y = GetFloat(bytes, ref cursor);
		origin.z = GetFloat(bytes, ref cursor);
		cellSize = GetFloat(bytes, ref cursor);
		width = (int32)Get(bytes, ref cursor);
		height = (int32)Get(bytes, ref cursor);
		depth = (int32)Get(bytes, ref cursor);
		chunkSize = (int32)Get(bytes, ref cursor);
		flying = Get(bytes, ref cursor) == 1;
		agentRadius = GetFloat(bytes, ref cursor);
		agentHeight = GetFloat(bytes, ref cursor);
		maxStep = GetFloat(bytes, ref cursor);
		maxSlope = GetFloat(bytes, ref cursor);
		let count = (int64)(bytes.Count - HeaderSize) / (flying ? 4 : 8);
		if (!ValidGrid(count) || (int64)bytes.Count != HeaderSize + count * (flying ? 4 : 8))
		{
			width = height = depth = 0;
			error.Set("Invalid navigation dimensions.");
			return false;
		}
		cells.Resize((int)count);
		for (int32 y = 0; y < height; y++)
		{
			for (int32 z = 0; z < depth; z++)
			{
				for (int32 x = 0; x < width; x++)
				{
					let word = Get(bytes, ref cursor);
					Cell cell = default;
					cell.walkable = (word & 0x80000000) != 0;
					cell.links = word & 0x7FFFFFFF;
					cell.position = Center(x, y, z);
					if (!flying)
					{
						cell.position.y = GetFloat(bytes, ref cursor);
						if (!cell.position.y.IsFinite)
						{
							cells.Clear();
							error.Set("Navigation cell has a non-finite position.");
							return false;
						}
					}
					cells[Index(x, y, z)] = cell;
				}
			}
		}
		Touch();
		return true;
	}

	/// Reads the version 1 text format written by earlier builds. Those assets have no diagonal links; bake again to add them.
	bool LoadText(StringView text, String error)
	{
		List<StringView> tokens = scope .();
		List<String> storage = scope .();
		defer
		{
			for (let item in storage)
				delete item;
		}
		bool header = false, grid = false;
		cells.Clear();
		for (let line in text.Split('\n'))
		{
			tokens.Clear();
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.Count == 0) continue;
			if (tokens.Count == 2 && tokens[0] == "navigation" && tokens[1] == "1" && !header)
				header = true;
			else if (tokens.Count == 15 && tokens[0] == "grid" && header && !grid)
			{
				origin = .(SceneSerializer.ParseFloat(tokens[1]), SceneSerializer.ParseFloat(tokens[2]), SceneSerializer.ParseFloat(tokens[3]));
				cellSize = SceneSerializer.ParseFloat(tokens[4]);
				width = SceneSerializer.ParseInt(tokens[5]);
				height = SceneSerializer.ParseInt(tokens[6]);
				depth = SceneSerializer.ParseInt(tokens[7]);
				chunkSize = SceneSerializer.ParseInt(tokens[8]);
				flying = tokens[9] == "1";
				agentRadius = SceneSerializer.ParseFloat(tokens[10]);
				agentHeight = SceneSerializer.ParseFloat(tokens[11]);
				maxStep = SceneSerializer.ParseFloat(tokens[12]);
				maxSlope = SceneSerializer.ParseFloat(tokens[13]);
				if (!ValidGrid(SceneSerializer.ParseInt(tokens[14])))
				{
					error.Set("Invalid navigation dimensions.");
					return false;
				}
				grid = true;
			}
			else if (tokens.Count == 6 && tokens[0] == "cell" && grid && cells.Count < width * height * depth)
				cells.Add(.() { walkable = tokens[1] == "1", position = .(SceneSerializer.ParseFloat(tokens[2]), SceneSerializer.ParseFloat(tokens[3]), SceneSerializer.ParseFloat(tokens[4])), links = (uint32)SceneSerializer.ParseInt(tokens[5]) & 0x3F });
			else
			{
				error.Set("Malformed navigation asset.");
				return false;
			}
		}
		for (let cell in cells)
		{
			if (!cell.position.x.IsFinite || !cell.position.y.IsFinite || !cell.position.z.IsFinite)
			{
				error.Set("Navigation cell has a non-finite position.");
				return false;
			}
		}
		if (!grid || cells.Count != width * height * depth)
		{
			error.Set("Incomplete navigation asset.");
			return false;
		}
		Touch();
		return true;
	}
}
