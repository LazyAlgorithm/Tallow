using System;
using System.Collections;

namespace Tallow;

/// Textures made from C# (Texture in Tallow.API): RGBA pixels put under a name that materials use as a texture path.
[CSharpExpose]
static class CSharpTextures
{
	/// The names C# made, released when the game's code goes.
	static List<String> sMade = new .() ~ DeleteContainerAndItems!(_);

	/// Puts RGBA pixels (width * height * 4 bytes) under a name (kind: TextureKind). False on a dedicated server or
	/// headless run (no graphics card), or when the pixels do not fit the size.
	[CSharpExpose]
	public static bool Upload(StringView name, int32 width, int32 height, int32 kind, Span<uint8> pixels)
	{
		if (name.IsEmpty || width <= 0 || height <= 0 || width > 8192 || height > 8192 ||
			pixels.Length != (int)width * height * 4)
			return false;
		bool known = false;
		for (let made in sMade)
			known |= made == name;
		if (!known)
			sMade.Add(new String(name));
		if (!Gfx.Initialized)
			return false;
		Assets.ReplaceTexture(name, pixels.Ptr, width, height, Kind(kind));
		return true;
	}

	/// Releases a texture made from C#. False when there was none of that name.
	[CSharpExpose]
	public static bool Remove(StringView name)
	{
		for (int i < sMade.Count)
		{
			if (sMade[i] == name)
			{
				delete sMade[i];
				sMade.RemoveAt(i);
				Assets.RemoveTexture(name);
				return true;
			}
		}
		return false;
	}

	/// Says what an image file holds before it is loaded.
	[CSharpExpose]
	public static void Hint(StringView path, int32 kind) => Textures.Hint(path, Kind(kind));

	/// What an image file holds, as worked out from its name and hints.
	[CSharpExpose]
	public static int32 KindOf(StringView path) => (int32)Textures.KindOf(path);

	/// An image file's size as width * 65536 + height; -1 when the file cannot be read.
	[CSharpExpose]
	public static int32 ImageSize(StringView path)
	{
		let full = scope String();
		Assets.ResolvePath(path, full);
		int32 width = 0, height = 0;
		let image = Native.tn_image_load(full.CStr(), &width, &height);
		if (image == null)
			return -1;
		Native.tn_image_free(image);
		return width < 32768 && height < 65536 ? width * 65536 + height : -1;
	}

	/// An image file's pixels (RGBA, 4 bytes a pixel, top row first) into pixels when it has room: the number of
	/// bytes, -1 when the file cannot be read.
	[CSharpExpose]
	public static int32 ReadImage(StringView path, Span<uint8> pixels)
	{
		let full = scope String();
		Assets.ResolvePath(path, full);
		int32 width = 0, height = 0;
		let image = Native.tn_image_load(full.CStr(), &width, &height);
		if (image == null)
			return -1;
		defer Native.tn_image_free(image);
		let count = (int)width * height * 4;
		if (pixels.Length >= count)
			Internal.MemCpy(pixels.Ptr, image, count);
		return (int32)count;
	}

	/// The game's code is going: its textures go with it.
	public static void ReleaseAll()
	{
		for (let name in sMade)
			Assets.RemoveTexture(name);
		ClearAndDeleteItems!(sMade);
	}

	static TextureKind Kind(int32 value) => value == 1 ? .Data : (value == 2 ? .Normal : .Color);
}
