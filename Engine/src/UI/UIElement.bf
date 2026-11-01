using System;
using System.Collections;
using System.IO;
using System.Reflection;

namespace Tallow;

/// Ordered name/value list used for attributes and style properties.
class UIProps
{
	/// The names and values, in the order they were set.
	public List<(String key, String value)> items = new .() ~
		{
			for (let i in _)
			{
				delete i.key;
				delete i.value;
			}
			delete _;
		};

	/// Sets a value (replacing one of the same name).
	public void Set(StringView key, StringView value)
	{
		for (let item in items)
		{
			if (item.key == key)
			{
				item.value.Set(value);
				return;
			}
		}
		items.Add((new String(key), new String(value)));
	}

	/// A value, or fallback.
	public StringView Get(StringView key, StringView fallback = default)
	{
		for (let item in items)
		{
			if (item.key == key)
				return item.value;
		}
		return fallback;
	}

	/// Whether there is a non-empty value for a name.
	public bool Has(StringView key) => !Get(key).IsEmpty;

	/// Removes a value.
	public void Remove(StringView key)
	{
		for (int i < items.Count)
		{
			if (items[i].key == key)
			{
				delete items[i].key;
				delete items[i].value;
				items.RemoveAt(i);
				return;
			}
		}
	}

	/// Removes every value.
	public void Clear()
	{
		for (let i in items)
		{
			delete i.key;
			delete i.value;
		}
		items.Clear();
	}

	/// Parses "name: value; name: value" declarations.
	public void ParseDeclarations(StringView text)
	{
		for (let part in text.Split(';'))
		{
			let colon = part.IndexOf(':');
			if (colon < 0)
				continue;
			var key = part.Substring(0, colon);
			var value = part.Substring(colon + 1);
			key.Trim();
			value.Trim();
			if (!key.IsEmpty)
				Set(key, value);
		}
	}
}

/// One element of a UI document, like an HTML tag.
/// Tags: panel, text, button, image, input, bar, slider, toggle, canvas.
class UIElement
{
	/// What the element is: panel, text, button, image, slider, toggle, bar, input or canvas.
	public String tag = new .("panel") ~ delete _;
	/// Its text.
	public String text = new .() ~ delete _;
	/// id, class, onclick, onload, src, bind ...
	public UIProps attributes = new .() ~ delete _;
	/// The element's own style="..." declarations.
	public UIProps style = new .() ~ delete _;
	/// Final style after the stylesheet and inheritance were applied.
	public UIProps computed = new .() ~ delete _;
	/// The elements inside it.
	public List<UIElement> children = new .() ~ DeleteContainerAndItems!(_);
	/// The element it is inside, or null for the document's root.
	public UIElement parent;
	/// Whether it (and everything inside it) is drawn.
	public bool visible = true;
	/// The number a slider is set to (between its min and max attributes), 1 or 0 for a toggle, and the fill
	/// of a bar that has no bind (0 to 1).
	public float value;
	/// Where the element was last drawn, in window pixels: what a canvas's ondraw handler draws into.
	public float screenX, screenY, screenWidth, screenHeight;
	/// Window pixels per document unit when it was last drawn.
	public float screenScale = 1;

	// Layout results, relative to the document's top-left corner.
	/// Where layout put it, in the document's units, relative to the document.
	public float x, y, width, height;
	/// The size it would like, worked out by layout.
	public Vector2 desired;

	/// Its id attribute (empty if it has none).
	public StringView Id => attributes.Get("id");

	/// Whether its class attribute names a class.
	public bool HasClass(StringView name)
	{
		for (let part in attributes.Get("class").Split(' ', .RemoveEmptyEntries))
		{
			if (part == name)
				return true;
		}
		return false;
	}

	/// Sets its text.
	public void SetText(StringView value) => text.Set(value);

	/// Gives the element a class it does not have yet, or takes one away: SetClass("selected", isSelected).
	public void SetClass(StringView name, bool on)
	{
		if (HasClass(name) == on)
			return;
		let classes = scope String();
		for (let part in attributes.Get("class").Split(' ', .RemoveEmptyEntries))
		{
			if (part != name)
				classes.AppendF("{}{}", classes.IsEmpty ? "" : " ", part);
		}
		if (on)
			classes.AppendF("{}{}", classes.IsEmpty ? "" : " ", name);
		attributes.Set("class", classes);
	}

	/// A copy of this element and everything under it, not yet placed anywhere.
	public UIElement Clone()
	{
		let copy = new UIElement();
		copy.tag.Set(tag);
		copy.text.Set(text);
		copy.visible = visible;
		copy.value = value;
		for (let item in attributes.items)
			copy.attributes.Set(item.key, item.value);
		for (let item in style.items)
			copy.style.Set(item.key, item.value);
		for (let child in children)
		{
			let childCopy = child.Clone();
			childCopy.parent = copy;
			copy.children.Add(childCopy);
		}
		return copy;
	}

	/// Changes one style property from code, e.g. SetStyle("background-color", "#c0392b").
	public void SetStyle(StringView name, StringView value) => style.Set(name, value);

	/// Adds a new element of a tag inside it.
	public UIElement AddChild(StringView childTag)
	{
		let child = new UIElement();
		child.tag.Set(childTag);
		child.parent = this;
		children.Add(child);
		return child;
	}

	/// The element with an id, this one or anything inside it, or null.
	public UIElement Find(StringView id)
	{
		if (Id == id)
			return this;
		for (let child in children)
		{
			let found = child.Find(id);
			if (found != null)
				return found;
		}
		return null;
	}

	// ---- style helpers ----

	/// A style value as a number (its computed style), or fallback.
	public float Number(StringView name, float fallback = 0)
	{
		var value = computed.Get(name);
		if (value.IsEmpty)
			return fallback;
		if (value.EndsWith("px"))
			value.RemoveFromEnd(2);
		if (float.Parse(value) case .Ok(let number))
			return number;
		return fallback;
	}

	/// Length that may be a percentage of a reference size. Returns false when the property is not set (auto).
	public bool Length(StringView name, float reference, out float result)
	{
		result = 0;
		var value = computed.Get(name);
		if (value.IsEmpty || value == "auto")
			return false;
		if (value.EndsWith('%'))
		{
			value.RemoveFromEnd(1);
			if (float.Parse(value) case .Ok(let percent))
			{
				result = reference * percent / 100.0f;
				return true;
			}
			return false;
		}
		if (value.EndsWith("px"))
			value.RemoveFromEnd(2);
		if (float.Parse(value) case .Ok(let number))
		{
			result = number;
			return true;
		}
		return false;
	}

	/// Reads padding / margin style shorthand: one, two or four numbers. Order: left, top, right, bottom.
	public Vector4 Edges(StringView name)
	{
		float[4] v = default;
		int count = 0;
		for (var part in computed.Get(name).Split(' ', .RemoveEmptyEntries))
		{
			if (count >= 4)
				break;
			if (part.EndsWith("px"))
				part.RemoveFromEnd(2);
			if (float.Parse(part) case .Ok(let number))
				v[count++] = number;
		}
		switch (count)
		{
		case 1: return .(v[0], v[0], v[0], v[0]);
		case 2: return .(v[1], v[0], v[1], v[0]); // vertical horizontal
		case 4: return .(v[3], v[0], v[1], v[2]); // top right bottom left
		default: return .(0, 0, 0, 0);
		}
	}

	/// A style value as a colour, or fallback.
	public Color ColorOf(StringView name, Color fallback)
	{
		Color color;
		if (ParseColor(computed.Get(name), out color))
			return color;
		return fallback;
	}

	/// Reads a CSS colour: #rgb, #rrggbb, #rrggbbaa, rgb(), rgba() or a name.
	public static bool ParseColor(StringView textIn, out Color color)
	{
		color = .(0, 0, 0, 0);
		var text = textIn;
		text.Trim();
		if (text.IsEmpty)
			return false;
		switch (text)
		{
		case "transparent": return true;
		case "white":
			color = .White;
			return true;
		case "black":
			color = .Black;
			return true;
		case "red":
			color = .(0.9f, 0.2f, 0.2f);
			return true;
		case "green":
			color = .(0.2f, 0.75f, 0.3f);
			return true;
		case "blue":
			color = .(0.2f, 0.45f, 0.9f);
			return true;
		case "yellow":
			color = .(0.95f, 0.8f, 0.2f);
			return true;
		case "gray","grey":
			color = .(0.5f, 0.5f, 0.5f);
			return true;
		}
		if (text.StartsWith('#'))
		{
			int32 Hex(char8 c) => c >= '0' && c <= '9' ? (int32)(c - '0') : (c >= 'a' && c <= 'f' ? (int32)(c - 'a') + 10 : (c >= 'A' && c <= 'F' ? (int32)(c - 'A') + 10 : 0));
			let digits = text.Substring(1);
			if (digits.Length == 3)
			{
				color = .(Hex(digits[0]) / 15.0f, Hex(digits[1]) / 15.0f, Hex(digits[2]) / 15.0f, 1);
				return true;
			}
			if (digits.Length == 6 || digits.Length == 8)
			{
				float Channel(int i) => (Hex(digits[i]) * 16 + Hex(digits[i + 1])) / 255.0f;
				color = .(Channel(0), Channel(2), Channel(4), digits.Length == 8 ? Channel(6) : 1.0f);
				return true;
			}
			return false;
		}
		if (text.StartsWith("rgb"))
		{
			let open = text.IndexOf('(');
			let close = text.IndexOf(')');
			if (open < 0 || close < open)
				return false;
			float[4] v = .(0, 0, 0, 1);
			int i = 0;
			for (var part in text.Substring(open + 1, close - open - 1).Split(','))
			{
				part.Trim();
				if (i < 4 && float.Parse(part) case .Ok(let number))
					v[i] = i < 3 ? number / 255.0f : number;
				i++;
			}
			color = .(v[0], v[1], v[2], v[3]);
			return true;
		}
		return false;
	}
}
