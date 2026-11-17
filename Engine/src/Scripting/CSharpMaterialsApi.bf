using System;

namespace Tallow;

/// Shared materials for C# (Managed/Tallow.API/Materials.cs). A material is named by its project path; changing it
/// changes every object that uses it, on this machine only. `made` is true for a material made in code
/// (Material.Create), which is made again, blank, if it was freed while nothing used it.
[CSharpExpose]
static class CSharpMaterials
{
	static Material Find(StringView path, bool made) => made ? Material.Create(path) : Material.Load(path);

	static int32 Copy(StringView text, Span<uint8> buffer)
	{
		let count = Math.Min(text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}

	/// Whether the material is there (loading it when it is a file not loaded yet). Made in code: makes it.
	[CSharpExpose]
	public static bool Exists(StringView path, bool made) => !path.IsEmpty && Find(path, made) != null;

	/// Sets a value by name (Material.SetNamedValue). False when there is no such material.
	[CSharpExpose]
	public static bool SetValue(StringView path, bool made, StringView name, Vector4 value)
	{
		let material = Find(path, made);
		if (material == null || name.IsEmpty)
			return false;
		material.SetNamedValue(name, value);
		return true;
	}

	/// A value by name into values (4 floats). False when there is no such material.
	[CSharpExpose]
	public static bool GetValue(StringView path, bool made, StringView name, Span<float> values)
	{
		let material = Find(path, made);
		if (material == null || values.Length < 4)
			return false;
		let value = material.GetNamedValue(name);
		values[0] = value.x;
		values[1] = value.y;
		values[2] = value.z;
		values[3] = value.w;
		return true;
	}

	/// Sets a text field ("shader", "texture", "normalMap"...) or, for any other name, a texture property of the
	/// custom shader. False when there is no such material.
	[CSharpExpose]
	public static bool SetText(StringView path, bool made, StringView name, StringView value)
	{
		let material = Find(path, made);
		if (material == null || name.IsEmpty)
			return false;
		let field = material.NamedText(name);
		if (field != null)
		{
			field.Set(value);
			material.Changed();
		}
		else
			material.SetTexture(name, value);
		return true;
	}

	/// A text field or texture property (see SetText); -1 when there is no such material.
	[CSharpExpose]
	public static int32 GetText(StringView path, bool made, StringView name, Span<uint8> buffer)
	{
		let material = Find(path, made);
		if (material == null)
			return -1;
		let field = material.NamedText(name);
		if (field != null)
			return Copy(field, buffer);
		let text = scope String();
		material.GetTexture(name, text);
		return Copy(text, buffer);
	}

	/// Makes a material in code under a path, copying another's settings when `from` names one ("" for a blank
	/// one). An existing material of that path is kept as it is. False when `from` is not found.
	[CSharpExpose]
	public static bool Create(StringView path, StringView from)
	{
		if (path.IsEmpty)
			return false;
		Material source = null;
		if (!from.IsEmpty)
		{
			source = Material.Load(from);
			if (source == null)
				return false;
		}
		let existed = Material.CachedCount;
		let material = Material.Create(path);
		if (source != null && Material.CachedCount != existed)
		{
			let text = scope String();
			source.Write(text);
			material.Read(text);
			material.Changed();
		}
		return true;
	}
}
