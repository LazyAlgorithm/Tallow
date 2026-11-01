using System;
using System.Collections;

namespace Tallow;

/// Painting a model's texture (docs/modeling.md): a picture kept in memory, painted with a round brush where it lies
/// on the model (found through each face's texture coordinates, so a stroke runs on across seams), shown at once
/// and written back to its PNG file. The faces should not share parts of the picture (unwrap first), or a stroke
/// shows up in two places.
class TexturePaint
{
	/// The texture's asset path ("Textures/crate.png").
	public String path = new .() ~ delete _;
	public uint8[] pixels ~ delete _;
	public int32 width;
	public int32 height;
	/// Changed since it was loaded or saved.
	public bool dirty;

	public bool IsLoaded => pixels != null;

	/// Reads the picture from its file. False when there is none or it cannot be read.
	public bool Load(StringView assetPath)
	{
		path.Set(assetPath);
		DeleteAndNullify!(pixels);
		let full = Assets.ResolvePath(assetPath, .. scope .());
		int32 w = 0, h = 0;
		let loaded = Native.tn_image_load(full.CStr(), &w, &h);
		if (loaded == null || w <= 0 || h <= 0)
			return false;
		width = w;
		height = h;
		pixels = new uint8[w * h * 4];
		Internal.MemCpy(pixels.Ptr, loaded, w * h * 4);
		Native.tn_image_free(loaded);
		dirty = false;
		return true;
	}

	/// Starts a new picture of one colour, to be saved under the path given.
	public void Create(StringView assetPath, int32 w, int32 h, Color color)
	{
		path.Set(assetPath);
		DeleteAndNullify!(pixels);
		width = Math.Max(w, 1);
		height = Math.Max(h, 1);
		pixels = new uint8[width * height * 4];
		for (int i < width * height)
			SetPixel(i, color);
		dirty = true;
	}

	/// Writes the picture to its file as PNG.
	public bool Save()
	{
		if (pixels == null)
			return false;
		let full = Assets.ResolvePath(path, .. scope .());
		let folder = System.IO.Path.GetDirectoryPath(full, .. scope .());
		if (!folder.IsEmpty)
			System.IO.Directory.CreateDirectory(folder).IgnoreError();
		if (!Native.tn_image_write_png(full.CStr(), pixels.Ptr, width, height))
			return false;
		dirty = false;
		return true;
	}

	/// Shows the picture as it is now on everything that uses the texture.
	public void Upload()
	{
		if (pixels != null)
			Assets.ReplaceTexture(path, pixels.Ptr, width, height);
	}

	public Color GetPixel(int32 x, int32 y)
	{
		let i = ((int)Math.Clamp(y, 0, height - 1) * width + Math.Clamp(x, 0, width - 1)) * 4;
		return .(pixels[i] / 255.0f, pixels[i + 1] / 255.0f, pixels[i + 2] / 255.0f, pixels[i + 3] / 255.0f);
	}

	/// The colour at texture coordinates (nearest pixel; V grows downwards as in pictures).
	public Color Sample(Vector2 uv)
	{
		let u = uv.x - Math.Floor(uv.x), v = uv.y - Math.Floor(uv.y);
		return GetPixel((int32)(u * width), (int32)(v * height));
	}

	void SetPixel(int index, Color color)
	{
		let i = index * 4;
		pixels[i] = ToByte(color.r);
		pixels[i + 1] = ToByte(color.g);
		pixels[i + 2] = ToByte(color.b);
		pixels[i + 3] = ToByte(color.a);
	}

	static uint8 ToByte(float v) => (uint8)Math.Clamp((int)Math.Round(v * 255), 0, 255);

	/// One dab of a round brush centred on a point of the model (in its own space), `radius` across in the same
	/// units: pixels whose place on the model is within the radius move towards the colour, by `strength` in the
	/// middle and less towards the edge (`hardness` 1 is a hard edge, 0 fades all the way). Faces of `skipHidden`
	/// are left alone when it is set. Returns how many pixels changed.
	public int Dab(EditMesh mesh, Vector3 center, float radius, Color color, float strength, float hardness = 0.5f, bool skipHidden = false)
	{
		if (pixels == null || radius <= 0)
			return 0;
		// Each pixel takes the strongest weight any triangle gives it, so pixels on shared edges are not painted twice.
		let weights = scope Dictionary<int32, float>();
		let corners = scope List<int32>();
		for (let face in mesh.faces)
		{
			if (skipHidden && face.hidden)
				continue;
			corners.Clear();
			mesh.Triangulate(face, corners);
			for (int t = 0; t + 2 < corners.Count; t += 3)
			{
				let i0 = corners[t], i1 = corners[t + 1], i2 = corners[t + 2];
				let p0 = mesh.positions[face.verts[i0]], p1 = mesh.positions[face.verts[i1]], p2 = mesh.positions[face.verts[i2]];
				let closest = MeshOps.ClosestOnTriangle(center, p0, p1, p2);
				if ((closest - center).Length > radius)
					continue;
				DabTriangle(p0, p1, p2, face.uvs[i0], face.uvs[i1], face.uvs[i2], center, radius, hardness, weights);
			}
		}
		for (let pair in weights)
		{
			let w = Math.Clamp(pair.value * strength, 0, 1);
			let i = (int)pair.key * 4;
			let old = Color(pixels[i] / 255.0f, pixels[i + 1] / 255.0f, pixels[i + 2] / 255.0f, pixels[i + 3] / 255.0f);
			SetPixel(pair.key, .(old.r + (color.r - old.r) * w, old.g + (color.g - old.g) * w, old.b + (color.b - old.b) * w, old.a + (color.a - old.a) * w));
		}
		if (!weights.IsEmpty)
			dirty = true;
		return weights.Count;
	}

	/// The pixels of one triangle's part of the picture near the brush, with their brush weights.
	void DabTriangle(Vector3 p0, Vector3 p1, Vector3 p2, Vector2 t0, Vector2 t1, Vector2 t2, Vector3 center, float radius, float hardness, Dictionary<int32, float> weights)
	{
		// The triangle in pixels.
		let a = Vector2(t0.x * width, t0.y * height), b = Vector2(t1.x * width, t1.y * height), c = Vector2(t2.x * width, t2.y * height);
		let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
		if (Math.Abs(area) < 1.0e-6f)
			return;
		// Pixels this far outside an edge still count, so seams do not show a gap.
		float Reach(Vector2 from, Vector2 to) => 1.0f / Math.Max(Math.Abs(area) / Math.Max((to - from).Length, 1.0e-6f), 1.0e-6f);
		let reach0 = Reach(b, c), reach1 = Reach(c, a), reach2 = Reach(a, b);
		// Only the part of the triangle round the brush: its pixels per metre bound how far the brush reaches.
		let edge1 = (p1 - p0).Length, edge2 = (p2 - p0).Length;
		let perMetre = Math.Max((b - a).Length / Math.Max(edge1, 1.0e-6f), (c - a).Length / Math.Max(edge2, 1.0e-6f));
		let closest = MeshOps.ClosestOnTriangle(center, p0, p1, p2);
		MeshOps.Barycentric(closest, p0, p1, p2, let cu, let cv, let cw);
		let middle = a * cu + b * cv + c * cw;
		let span = radius * perMetre * 2 + 2;
		let minX = (int32)Math.Max(Math.Floor(Math.Max(Math.Min(a.x, Math.Min(b.x, c.x)) - 1, middle.x - span)), 0);
		let maxX = (int32)Math.Min(Math.Ceiling(Math.Min(Math.Max(a.x, Math.Max(b.x, c.x)) + 1, middle.x + span)), width - 1);
		let minY = (int32)Math.Max(Math.Floor(Math.Max(Math.Min(a.y, Math.Min(b.y, c.y)) - 1, middle.y - span)), 0);
		let maxY = (int32)Math.Min(Math.Ceiling(Math.Min(Math.Max(a.y, Math.Max(b.y, c.y)) + 1, middle.y + span)), height - 1);
		let inner = Math.Clamp(hardness, 0, 1) * radius;
		for (int32 y = minY; y <= maxY; y++)
		{
			for (int32 x = minX; x <= maxX; x++)
			{
				let q = Vector2(x + 0.5f, y + 0.5f);
				// Barycentric coordinates in the picture.
				let w0 = ((b.x - q.x) * (c.y - q.y) - (b.y - q.y) * (c.x - q.x)) / area;
				let w1 = ((c.x - q.x) * (a.y - q.y) - (c.y - q.y) * (a.x - q.x)) / area;
				let w2 = 1 - w0 - w1;
				if (w0 < -reach0 || w1 < -reach1 || w2 < -reach2)
					continue;
				let place = p0 * w0 + p1 * w1 + p2 * w2;
				let distance = (place - center).Length;
				if (distance >= radius)
					continue;
				let weight = distance <= inner ? 1.0f : 1 - (distance - inner) / Math.Max(radius - inner, 1.0e-6f);
				let index = y * width + x;
				if (!weights.TryGetValue(index, let existing) || existing < weight)
					weights[index] = weight;
			}
		}
	}

	/// Fills the faces' parts of the picture with a colour (and a pixel round them, so edges do not show).
	public void Fill(EditMesh mesh, Span<int32> faces, Color color)
	{
		if (pixels == null)
			return;
		let corners = scope List<int32>();
		for (let f in faces)
		{
			let face = mesh.faces[f];
			corners.Clear();
			mesh.Triangulate(face, corners);
			for (int t = 0; t + 2 < corners.Count; t += 3)
			{
				let t0 = face.uvs[corners[t]], t1 = face.uvs[corners[t + 1]], t2 = face.uvs[corners[t + 2]];
				let a = Vector2(t0.x * width, t0.y * height), b = Vector2(t1.x * width, t1.y * height), c = Vector2(t2.x * width, t2.y * height);
				let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
				if (Math.Abs(area) < 1.0e-6f)
					continue;
				float Reach(Vector2 from, Vector2 to) => 1.0f / Math.Max(Math.Abs(area) / Math.Max((to - from).Length, 1.0e-6f), 1.0e-6f);
				let reach0 = Reach(b, c), reach1 = Reach(c, a), reach2 = Reach(a, b);
				let minX = (int32)Math.Max(Math.Floor(Math.Min(a.x, Math.Min(b.x, c.x)) - 1), 0);
				let maxX = (int32)Math.Min(Math.Ceiling(Math.Max(a.x, Math.Max(b.x, c.x)) + 1), width - 1);
				let minY = (int32)Math.Max(Math.Floor(Math.Min(a.y, Math.Min(b.y, c.y)) - 1), 0);
				let maxY = (int32)Math.Min(Math.Ceiling(Math.Max(a.y, Math.Max(b.y, c.y)) + 1), height - 1);
				for (int32 y = minY; y <= maxY; y++)
				{
					for (int32 x = minX; x <= maxX; x++)
					{
						let q = Vector2(x + 0.5f, y + 0.5f);
						let w0 = ((b.x - q.x) * (c.y - q.y) - (b.y - q.y) * (c.x - q.x)) / area;
						let w1 = ((c.x - q.x) * (a.y - q.y) - (c.y - q.y) * (a.x - q.x)) / area;
						if (w0 >= -reach0 && w1 >= -reach1 && 1 - w0 - w1 >= -reach2)
							SetPixel(y * width + x, color);
					}
				}
			}
		}
		dirty = true;
	}

	/// Writes a palette picture: cells of colour in rows of `columns`, `cell` pixels square each, for flat-coloured
	/// low-poly models (faces put in a cell with MeshUV.ToCell). Cells past the colours given are white.
	public static bool WritePalette(StringView assetPath, Span<Color> colors, int32 columns, int32 rows, int32 cell = 16)
	{
		let paint = scope TexturePaint();
		paint.Create(assetPath, columns * cell, rows * cell, .White);
		for (int32 row < rows)
		{
			for (int32 column < columns)
			{
				let k = row * columns + column;
				if (k >= colors.Length)
					continue;
				for (int32 y < cell)
				{
					for (int32 x < cell)
						paint.SetPixel((row * cell + y) * paint.width + column * cell + x, colors[k]);
				}
			}
		}
		return paint.Save();
	}
}
