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

	/// Where the element was last drawn: screenX, screenY, width, height and the screen scale. False without it.
	[CSharpExpose]
	public static bool ElementRect(uint64 session, uint64 entity, StringView id, Span<float> values)
	{
		let element = Element(session, entity, id);
		if (element == null || values.Length < 5)
			return false;
		values[0] = element.screenX;
		values[1] = element.screenY;
		values[2] = element.screenWidth;
		values[3] = element.screenHeight;
		values[4] = element.screenScale;
		return true;
	}

	/// An attribute of the element ("value", "caption", "action", "font-size"...), UTF-8 into buffer; its full
	/// length, -1 without the element.
	[CSharpExpose]
	public static int32 CopyAttribute(uint64 session, uint64 entity, StringView id, StringView name, Span<uint8> buffer)
	{
		let element = Element(session, entity, id);
		if (element == null)
			return -1;
		let value = element.attributes.Get(name);
		let count = Math.Min(value.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)value[i];
		return (int32)value.Length;
	}

	/// Sets an attribute of the element (a picture's "src", a control's "disabled", "index" or "data").
	[CSharpExpose]
	public static void SetAttribute(uint64 session, uint64 entity, StringView id, StringView name, StringView value) =>
		Element(session, entity, id)?.attributes.Set(name, value);

	/// Where the element is laid out this frame (a scrolling list's rows), in document units relative to the
	/// document. Layout runs again next frame; call it each draw.
	[CSharpExpose]
	public static void SetLayoutRect(uint64 session, uint64 entity, StringView id, float x, float y, float width, float height)
	{
		let element = Element(session, entity, id);
		if (element == null)
			return;
		element.x = x;
		element.y = y;
		element.width = width;
		element.height = height;
	}
}
