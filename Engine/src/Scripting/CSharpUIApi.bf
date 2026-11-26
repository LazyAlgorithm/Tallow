using System;

namespace Tallow;

/// UI documents for C# scripts (Tallow.API's UIDocument and UIElement). Elements are named by their id="..."; a
/// missing object, document or element does nothing and reads as empty.
[CSharpExpose]
static class CSharpUI
{
	static UIDocument Document(uint64 session, uint64 entity)
	{
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		return obj != null ? obj.GetComponent<UIDocument>() : null;
	}

	static UIElement Element(uint64 session, uint64 entity, StringView id) => Document(session, entity)?.Find(id);

	[CSharpExpose]
	public static bool HasDocument(uint64 session, uint64 entity) => Document(session, entity) != null;

	/// Reads the document from disk again at once (after document or Variant changed), instead of at its next draw.
	[CSharpExpose]
	public static void ReloadDocument(uint64 session, uint64 entity) => Document(session, entity)?.Reload();

	[CSharpExpose]
	public static bool HasElement(uint64 session, uint64 entity, StringView id) => Element(session, entity, id) != null;

	[CSharpExpose]
	public static void SetText(uint64 session, uint64 entity, StringView id, StringView text) => Element(session, entity, id)?.SetText(text);

	/// The element's text (UTF-8 into buffer); returns its full length, -1 without the element.
	[CSharpExpose]
	public static int32 CopyText(uint64 session, uint64 entity, StringView id, Span<uint8> buffer)
	{
		let element = Element(session, entity, id);
		if (element == null)
			return -1;
		let count = Math.Min(element.text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)element.text[i];
		return (int32)element.text.Length;
	}

	[CSharpExpose]
	public static bool GetVisible(uint64 session, uint64 entity, StringView id) => Element(session, entity, id)?.visible ?? false;

	[CSharpExpose]
	public static void SetVisible(uint64 session, uint64 entity, StringView id, bool visible)
	{
		let element = Element(session, entity, id);
		if (element != null)
			element.visible = visible;
	}

	[CSharpExpose]
	public static float GetValue(uint64 session, uint64 entity, StringView id) => Element(session, entity, id)?.value ?? 0;

	[CSharpExpose]
	public static void SetValue(uint64 session, uint64 entity, StringView id, float value)
	{
		let element = Element(session, entity, id);
		if (element != null)
			element.value = value;
	}

	/// Gives the element a class (its stylesheet can style it), or takes the class away.
	[CSharpExpose]
	public static void SetClass(uint64 session, uint64 entity, StringView id, StringView name, bool on) =>
		Element(session, entity, id)?.SetClass(name, on);

	[CSharpExpose]
	public static bool HasClass(uint64 session, uint64 entity, StringView id, StringView name) =>
		Element(session, entity, id)?.HasClass(name) ?? false;
}
