using System;
using System.Collections;
using System.Threading;

namespace Tallow;

/// Text that can live in component data (a Decal's texture, a Mesh Renderer's mesh): a pointer to one shared copy of
/// the text, which is never freed or changed, so the data can be copied byte for byte as Flecs moves it. Each
/// distinct text is kept once for the life of the program, which suits asset paths and names; do not use it for
/// text that changes every frame.
///
/// It reads and writes like a string: `decal.texture = "Textures/Crack.png";`, `if (decal.texture == "x")`,
/// `Log.Info(decal.texture)`. An empty one is `default`.
[CRepr]
struct SharedString : IHashable, IEquatable<SharedString>
{
	String mText;

	static Dictionary<StringView, String> sTable = new .() ~ DeleteDictionaryAndValues!(_);
	static Monitor sLock = new .() ~ delete _;

	public this()
	{
		mText = null;
	}

	public this(StringView text)
	{
		mText = Intern(text);
	}

	/// The one shared copy of text (null for empty text).
	static String Intern(StringView text)
	{
		if (text.IsEmpty)
			return null;
		using (sLock.Enter())
		{
			if (sTable.TryGetValue(text, let found))
				return found;
			let copy = new String(text);
			sTable[copy] = copy;
			return copy;
		}
	}

	public StringView View => mText != null ? (StringView)mText : default;
	public int Length => mText != null ? mText.Length : 0;
	public bool IsEmpty => mText == null;

	/// Changes the text (`renderer.mesh.Set("Models/Rock.glb")` writes through to the component, as for a String).
	public void Set(StringView text) mut => this = .(text);
	/// Makes it empty.
	public void Clear() mut => mText = null;

	public bool StartsWith(StringView text) => View.StartsWith(text);
	public bool EndsWith(StringView text) => View.EndsWith(text);
	public bool EndsWith(StringView text, StringComparison comparison) => View.EndsWith(text, comparison);
	public bool StartsWith(StringView text, StringComparison comparison) => View.StartsWith(text, comparison);
	public bool Contains(StringView text) => View.Contains(text);
	public bool Contains(char8 c) => View.Contains(c);

	public static implicit operator SharedString(StringView text) => .(text);
	public static implicit operator SharedString(String text) => .(text != null ? (StringView)text : default);
	public static implicit operator StringView(SharedString text) => text.View;

	/// Equal texts are the same shared copy, so comparing is comparing pointers.
	public static bool operator ==(SharedString a, SharedString b) => Internal.UnsafeCastToPtr(a.mText) == Internal.UnsafeCastToPtr(b.mText);
	public static bool operator !=(SharedString a, SharedString b) => Internal.UnsafeCastToPtr(a.mText) != Internal.UnsafeCastToPtr(b.mText);
	public static bool operator ==(SharedString a, StringView b) => a.View == b;
	public static bool operator !=(SharedString a, StringView b) => a.View != b;
	// Exact matches for a String (and a literal), which converts to both of the above.
	public static bool operator ==(SharedString a, String b) => a.View == (b != null ? (StringView)b : default);
	public static bool operator !=(SharedString a, String b) => !(a == b);

	public bool Equals(SharedString other) => this == other;
	public int GetHashCode() => (int)Internal.UnsafeCastToPtr(mText);

	public override void ToString(String output)
	{
		if (mText != null)
			output.Append(mText);
	}
}
