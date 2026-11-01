using System;
using System.Collections;
using System.IO;
using System.Reflection;

namespace Tallow;

/// A parsed UI document: the element tree plus its stylesheet, with layout and drawing.
///
///   <style>
///     .menu { width: 320; padding: 20; gap: 10; background-color: #1c2026ee; border-radius: 8 }
///     button { background-color: #2f6fb0 }
///   </style>
///   <panel class="menu" onload="OnOpen">
///     <text style="font-size: 24">My Game</text>
///     <button onclick="OnPlay">Play</button>
///   </panel>
///
/// Layout is a small flexbox: flex-direction (column | row), gap, padding, margin, width / height
/// (pixels or %), flex-grow, align-items and justify-content, plus position: absolute with left / top / right / bottom.
/// @media blocks rearrange a document for its shape (portrait or landscape, narrow or wide): see ParseStyles.
class UIDocumentData
{
	class Rule
	{
		public String selector = new .() ~ delete _;
		/// The @media condition the rule is in, or empty.
		public String media = new .() ~ delete _;
		public UIProps props = new .() ~ delete _;
		public int specificity;
		/// Place in the stylesheet: of two rules equally specific, the later one wins, as in CSS.
		public int order;
	}

	public UIElement root ~ delete _;
	public String styleText = new .() ~ delete _;
	/// True when the styles live in a .tcss file beside the document instead of a <style> block.
	public bool separateStyleFile;
	List<Rule> mRules = new .() ~ DeleteContainerAndItems!(_);

	// What the last Draw call saw; UIDocument turns these into events.
	public UIElement clicked;
	public UIElement hovered;
	/// A slider or toggle whose value the user changed during the last Draw.
	public UIElement changed;
	// The slider being dragged, so that the drag carries on when the pointer leaves it.
	UIElement mDragging;

	public static bool IsTextTag(StringView tag) => tag == "text" || tag == "button";

	// ---- parsing ----

	public bool Load(StringView path)
	{
		let text = scope String();
		if (AssetPack.ReadAllText(path, text) case .Err)
			return false;
		Parse(text);
		// menu.tui picks up menu.tcss automatically.
		let stylePath = scope String();
		StylePathFor(path, stylePath);
		let external = scope String();
		separateStyleFile = AssetPack.ReadAllText(stylePath, external) case .Ok;
		if (separateStyleFile)
		{
			external.Trim();
			if (!styleText.IsEmpty)
				external.AppendF("\n{}", styleText);
			styleText.Set(external);
			ParseStyles();
		}
		return true;
	}

	public static void StylePathFor(StringView documentPath, String stylePath)
	{
		let dot = documentPath.LastIndexOf('.');
		stylePath.Append(dot >= 0 ? documentPath.Substring(0, dot) : documentPath);
		stylePath.Append(".tcss");
	}

	/// Goes up every time the document is read again. Elements found before then are gone: code that keeps
	/// hold of elements checks this and looks them up afresh.
	public int32 version;
	static int32 sVersions;

	public void Parse(StringView source)
	{
		// Never the same number twice, even for a new document that lands where an old one was.
		version = ++sVersions;
		mDragging = null;
		clicked = null;
		hovered = null;
		changed = null;
		delete root;
		root = new UIElement();
		root.tag.Set("panel");
		root.attributes.Set("id", "root");
		styleText.Clear();
		UIElement current = root;
		int i = 0;
		let n = source.Length;
		while (i < n)
		{
			if (source[i] != '<')
			{
				// Text between tags belongs to the element it sits in.
				let start = i;
				while (i < n && source[i] != '<')
					i++;
				var piece = source.Substring(start, i - start);
				piece.Trim();
				if (!piece.IsEmpty)
				{
					if (IsTextTag(current.tag))
						current.text.Append(piece);
					else
						current.AddChild("text").text.Set(piece);
				}
				continue;
			}
			if (source.Substring(i).StartsWith("<!--"))
			{
				let end = source.IndexOf("-->", i);
				i = end < 0 ? n : end + 3;
				continue;
			}
			if (source.Substring(i).StartsWith("<style"))
			{
				let open = source.IndexOf('>', i);
				let end = source.IndexOf("</style>", i);
				if (open >= 0 && end > open)
					styleText.Append(source.Substring(open + 1, end - open - 1));
				i = end < 0 ? n : end + 8;
				continue;
			}
			let close = source.IndexOf('>', i);
			if (close < 0)
				break;
			var inner = source.Substring(i + 1, close - i - 1);
			i = close + 1;
			if (inner.StartsWith('/'))
			{
				if (current.parent != null)
					current = current.parent;
				continue;
			}
			let selfClosing = inner.EndsWith('/');
			if (selfClosing)
				inner.RemoveFromEnd(1);
			inner.Trim();
			int nameEnd = 0;
			while (nameEnd < inner.Length && !inner[nameEnd].IsWhiteSpace)
				nameEnd++;
			let element = current.AddChild(inner.Substring(0, nameEnd));
			ParseAttributes(inner.Substring(nameEnd), element);
			if (!selfClosing)
				current = element;
		}
		styleText.Trim();
		ExpandRepeats(root);
		ParseStyles();
	}

	/// An element with repeat="N" stands for N copies of itself. In each copy {i} becomes its number from 0 and
	/// {n} its number from 1, wherever they appear in its attributes, styles and text, and in its children's:
	///   <button id="slot{i}" data="{i}" onclick="OnSlot" repeat="5">Slot {n}</button>
	void ExpandRepeats(UIElement element)
	{
		for (int index = 0; index < element.children.Count; index++)
		{
			let child = element.children[index];
			let count = Math.Clamp(SceneSerializer.ParseInt(child.attributes.Get("repeat", "0")), 0, 500);
			if (!child.attributes.Has("repeat"))
			{
				ExpandRepeats(child);
				continue;
			}
			child.attributes.Remove("repeat");
			element.children.RemoveAt(index);
			for (int32 copyIndex = 0; copyIndex < count; copyIndex++)
			{
				let copy = child.Clone();
				copy.parent = element;
				Substitute(copy, copyIndex);
				element.children.Insert(index + copyIndex, copy);
				ExpandRepeats(copy);
			}
			delete child;
			index += count - 1;
		}
	}

	static void Substitute(UIElement element, int32 number)
	{
		void Fix(String text)
		{
			if (!text.Contains('{'))
				return;
			text.Replace("{i}", scope $"{number}");
			text.Replace("{n}", scope $"{number + 1}");
		}
		Fix(element.text);
		for (let item in element.attributes.items)
			Fix(item.value);
		for (let item in element.style.items)
			Fix(item.value);
		for (let child in element.children)
			Substitute(child, number);
	}

	static void ParseAttributes(StringView text, UIElement element)
	{
		int i = 0;
		let n = text.Length;
		while (i < n)
		{
			while (i < n && text[i].IsWhiteSpace)
				i++;
			let nameStart = i;
			while (i < n && text[i] != '=' && !text[i].IsWhiteSpace)
				i++;
			let name = text.Substring(nameStart, i - nameStart);
			if (name.IsEmpty)
				break;
			while (i < n && text[i].IsWhiteSpace)
				i++;
			if (i >= n || text[i] != '=')
			{
				element.attributes.Set(name, "true");
				continue;
			}
			i++;
			while (i < n && text[i].IsWhiteSpace)
				i++;
			if (i >= n)
				break;
			let quote = text[i];
			StringView value;
			if (quote == '"' || quote == '\'')
			{
				i++;
				let valueStart = i;
				while (i < n && text[i] != quote)
					i++;
				value = text.Substring(valueStart, i - valueStart);
				i++;
			}
			else
			{
				let valueStart = i;
				while (i < n && !text[i].IsWhiteSpace)
					i++;
				value = text.Substring(valueStart, i - valueStart);
			}
			if (name == "style")
				element.style.ParseDeclarations(value);
			else
				element.attributes.Set(name, value);
		}
	}

	/// Re-reads styleText into rules. Call after editing the stylesheet.
	///
	/// Rules can sit in @media blocks, which apply only while the document's layout area matches, so one document
	/// can rearrange itself for a portrait phone instead of shrinking a landscape layout until it is unreadable:
	///   @media (orientation: portrait) { #left { left: 24; right: 24; width: auto } .right { display: none } }
	///   @media (max-width: 700), (max-aspect-ratio: 4/3) { ... }
	/// Conditions: orientation (portrait | landscape), min-/max-width, min-/max-height and min-/max-aspect-ratio
	/// (width/height, such as 16/9), joined with "and"; a comma between conditions means "or". Widths and heights
	/// are in the document's own layout units (with a reference height or width, the units it is designed in), and
	/// are tested afresh on every layout, so a phone turned sideways rearranges at once. A rule in a block wins over
	/// an equally specific rule earlier in the file, as in CSS; a style="" attribute still wins over both, so give
	/// the parts that rearrange an id or class rather than inline positions.
	public void ParseStyles()
	{
		ClearAndDeleteItems!(mRules);
		// Comments (/* ... */) are left out.
		let clean = scope String(styleText);
		while (true)
		{
			let from = clean.IndexOf("/*");
			if (from < 0)
				break;
			let to = clean.IndexOf("*/", from + 2);
			clean.Remove(from, (to < 0 ? clean.Length : to + 2) - from);
		}
		ParseRules(clean, "");
		// (List.Sort is not stable, so source order is part of the key.)
		mRules.Sort(scope (a, b) => (a.specificity != b.specificity) ? (a.specificity <=> b.specificity) : (a.order <=> b.order));
	}

	void ParseRules(StringView text, StringView media)
	{
		int i = 0;
		while (i < text.Length)
		{
			let open = text.IndexOf('{', i);
			if (open < 0)
				break;
			var prelude = text.Substring(i, open - i);
			prelude.Trim();
			if (prelude.StartsWith("@media"))
			{
				// The block runs to its matching brace: it holds whole rules of its own.
				int depth = 0;
				int close = -1;
				for (int at = open; at < text.Length; at++)
				{
					if (text[at] == '{')
						depth++;
					else if (text[at] == '}' && --depth == 0)
					{
						close = at;
						break;
					}
				}
				if (close < 0)
					break;
				var condition = prelude.Substring(6);
				condition.Trim();
				ParseRules(text.Substring(open + 1, close - open - 1), condition);
				i = close + 1;
				continue;
			}
			let close = text.IndexOf('}', open);
			if (close < 0)
				break;
			for (var selector in prelude.Split(','))
			{
				selector.Trim();
				if (selector.IsEmpty)
					continue;
				let rule = new Rule();
				rule.selector.Set(selector);
				rule.media.Set(media);
				rule.specificity = selector.StartsWith('#') ? 100 : (selector.StartsWith('.') ? 10 : 1);
				rule.props.ParseDeclarations(text.Substring(open + 1, close - open - 1));
				rule.order = mRules.Count;
				mRules.Add(rule);
			}
			i = close + 1;
		}
	}

	// The layout area the @media conditions are tested against, set by Layout.
	float mViewWidth, mViewHeight;

	/// True when an @media condition holds for a layout area of this size (see ParseStyles).
	public static bool MediaMatches(StringView condition, float width, float height)
	{
		if (condition.IsEmpty)
			return true;
		// "a, b": either will do.
		for (var alternative in condition.Split(','))
		{
			bool all = true;
			// Each "(name: value)" in turn; the words around them ("screen", "and") ask nothing of a game's view.
			int at = 0;
			while (true)
			{
				let from = alternative.IndexOf('(', at);
				if (from < 0)
					break;
				let to = alternative.IndexOf(')', from);
				if (to < 0)
				{
					all = false;
					break;
				}
				at = to + 1;
				let part = alternative.Substring(from + 1, to - from - 1);
				let colon = part.IndexOf(':');
				if (colon < 0)
				{
					all = false;
					break;
				}
				var name = part.Substring(0, colon);
				name.Trim();
				var value = part.Substring(colon + 1);
				value.Trim();
				if (value.EndsWith("px"))
					value.RemoveFromEnd(2);
				float number = 0;
				let slash = value.IndexOf('/');
				if (slash >= 0)
				{
					// An aspect ratio written as a fraction: 16/9.
					var over = value.Substring(0, slash);
					var under = value.Substring(slash + 1);
					over.Trim();
					under.Trim();
					float top = 0, bottom = 1;
					if (float.Parse(over) case .Ok(let a))
						top = a;
					if (float.Parse(under) case .Ok(let b))
						bottom = b;
					number = bottom != 0 ? top / bottom : 0;
				}
				else if (float.Parse(value) case .Ok(let parsed))
					number = parsed;
				let aspect = height > 0 ? width / height : 1;
				bool holds;
				switch (name)
				{
				case "orientation": holds = value == "portrait" ? height > width : (value == "landscape" ? width >= height : false);
				case "min-width": holds = width >= number;
				case "max-width": holds = width <= number;
				case "min-height": holds = height >= number;
				case "max-height": holds = height <= number;
				case "min-aspect-ratio": holds = aspect >= number;
				case "max-aspect-ratio": holds = aspect <= number;
				default: holds = false;
				}
				if (!holds)
				{
					all = false;
					break;
				}
			}
			if (all)
				return true;
		}
		return false;
	}

	bool Matches(Rule rule, UIElement element)
	{
		if (!rule.media.IsEmpty && !MediaMatches(rule.media, mViewWidth, mViewHeight))
			return false;
		let selector = (StringView)rule.selector;
		if (selector.StartsWith('#'))
			return element.Id == selector.Substring(1);
		if (selector.StartsWith('.'))
			return element.HasClass(selector.Substring(1));
		return element.tag == selector;
	}

	void ComputeStyles(UIElement element)
	{
		element.computed.Clear();
		// Text color and size flow down from the parent, like CSS inheritance.
		if (element.parent != null)
		{
			element.computed.Set("color", element.parent.computed.Get("color", "#e6e6e6"));
			element.computed.Set("font-size", element.parent.computed.Get("font-size", "16"));
			let family = element.parent.computed.Get("font-family");
			if (!family.IsEmpty)
				element.computed.Set("font-family", family);
		}
		else
		{
			element.computed.Set("color", "#e6e6e6");
			element.computed.Set("font-size", "16");
		}
		if (element.tag == "button")
		{
			element.computed.Set("padding", "8 16");
			element.computed.Set("background-color", "#3d4654");
			element.computed.Set("border-radius", "5");
			element.computed.Set("align-items", "center");
			element.computed.Set("justify-content", "center");
		}
		else if (element.tag == "input")
		{
			element.computed.Set("width", "180");
		}
		else if (element.tag == "slider")
		{
			element.computed.Set("width", "200");
			element.computed.Set("height", "18");
			element.computed.Set("background-color", "#00000088");
			element.computed.Set("color", "#5ab0ff");
		}
		else if (element.tag == "toggle")
		{
			element.computed.Set("width", "52");
			element.computed.Set("height", "24");
			element.computed.Set("background-color", "#00000088");
			element.computed.Set("color", "#5ab0ff");
		}
		else if (element.tag == "bar")
		{
			element.computed.Set("width", "160");
			element.computed.Set("height", "14");
			element.computed.Set("background-color", "#00000088");
			element.computed.Set("color", "#4caf50");
			element.computed.Set("border-radius", "3");
		}
		for (let rule in mRules)
		{
			if (Matches(rule, element))
			{
				for (let item in rule.props.items)
					element.computed.Set(item.key, item.value);
			}
		}
		for (let item in element.style.items)
			element.computed.Set(item.key, item.value);
		for (let child in element.children)
			ComputeStyles(child);
	}

	// ---- layout ----

	static bool IsFlow(UIElement element) => element.visible && element.computed.Get("display") != "none" && element.computed.Get("position") != "absolute";

	Vector2 Measure(UIElement element, float availableWidth, float availableHeight)
	{
		// An element with a width of its own (pixels, or a percentage of the room it has) lays its contents out in
		// that, not in all the room around it, so text in it wraps where it will be drawn.
		float ownWidth;
		let contentWidth = element.Length("width", availableWidth, out ownWidth) ? ownWidth : availableWidth;
		let padding = element.Edges("padding");
		Vector2 content = .(0, 0);
		if (IsTextTag(element.tag) && !element.text.IsEmpty)
		{
			UIFonts.Push(element.computed.Get("font-family"), element.Number("font-size", 16));
			// white-space: normal breaks the text into lines to fit its width (its own, or what there is).
			let wraps = element.computed.Get("white-space") == "normal";
			let wrapWidth = contentWidth - padding.x - padding.z;
			// Measured a little narrower than it is drawn: glyphs do not grow exactly in proportion with the scale, and a
			// line that only just fit here must not break into one more line on screen than was made room for.
			let size = wraps ? ImGui.CalcTextSizeWrapped(element.text.CStr(), wrapWidth * 0.96f) : ImGui.CalcTextSize(element.text.CStr());
			ImGui.PopFont();
			content = .(size.x, size.y);
		}
		else if (element.tag == "input")
			content = .(0, element.Number("font-size", 16) + 10);
		else if (element.tag == "image")
			content = .(64, 64);

		let row = element.computed.Get("flex-direction") == "row";
		let gap = element.Number("gap");
		float main = 0;
		float cross = 0;
		int count = 0;
		for (let child in element.children)
		{
			if (child.computed.Get("display") == "none" || !child.visible)
				continue;
			var childWidth = contentWidth - padding.x - padding.z;
			if (child.computed.Get("position") == "absolute")
			{
				// Placed against this element's edges, not inside its padding (Arrange); pinned to both sides, as wide
				// as what lies between them.
				float left, right;
				if (child.Length("left", contentWidth, out left) && child.Length("right", contentWidth, out right))
					childWidth = Math.Max(contentWidth - left - right, 0);
				else
					childWidth = contentWidth;
				Measure(child, childWidth, availableHeight);
				continue;
			}
			let size = Measure(child, childWidth, availableHeight - padding.y - padding.w);
			let margin = child.Edges("margin");
			let outer = Vector2(size.x + margin.x + margin.z, size.y + margin.y + margin.w);
			main += row ? outer.x : outer.y;
			cross = Math.Max(cross, row ? outer.y : outer.x);
			count++;
		}
		if (count > 0)
		{
			main += gap * (count - 1);
			content = row ? Vector2(Math.Max(content.x, main), Math.Max(content.y, cross)) : Vector2(Math.Max(content.x, cross), Math.Max(content.y, main));
		}
		var desired = Vector2(content.x + padding.x + padding.z, content.y + padding.y + padding.w);
		float explicitSize;
		if (element.Length("width", availableWidth, out explicitSize))
			desired.x = explicitSize;
		if (element.Length("height", availableHeight, out explicitSize))
			desired.y = explicitSize;
		element.desired = desired;
		return desired;
	}

	void Arrange(UIElement element, float x, float y, float width, float height)
	{
		element.x = x;
		element.y = y;
		element.width = width;
		element.height = height;
		let padding = element.Edges("padding");
		let innerX = x + padding.x;
		let innerY = y + padding.y;
		let innerW = Math.Max(width - padding.x - padding.z, 0);
		let innerH = Math.Max(height - padding.y - padding.w, 0);
		let row = element.computed.Get("flex-direction") == "row";
		let gap = element.Number("gap");
		let align = element.computed.Get("align-items", "stretch");
		let justify = element.computed.Get("justify-content", "start");

		float used = 0;
		float grow = 0;
		int count = 0;
		for (let child in element.children)
		{
			if (!IsFlow(child))
				continue;
			let margin = child.Edges("margin");
			used += row ? child.desired.x + margin.x + margin.z : child.desired.y + margin.y + margin.w;
			grow += child.Number("flex-grow");
			count++;
		}
		if (count > 1)
			used += gap * (count - 1);
		let free = Math.Max((row ? innerW : innerH) - used, 0);
		float cursor = 0;
		float spacing = gap;
		if (grow <= 0)
		{
			if (justify == "center")
				cursor = free * 0.5f;
			else if (justify == "end")
				cursor = free;
			else if (justify == "space-between" && count > 1)
				spacing = gap + free / (count - 1);
		}

		for (let child in element.children)
		{
			if (!child.visible || child.computed.Get("display") == "none")
				continue;
			let margin = child.Edges("margin");
			if (child.computed.Get("position") == "absolute")
			{
				// Pinned to the parent's edges, outside the normal flow.
				float left, top, right, bottom;
				var cw = child.desired.x;
				var ch = child.desired.y;
				var cx = x;
				var cy = y;
				let hasLeft = child.Length("left", width, out left);
				let hasRight = child.Length("right", width, out right);
				let hasTop = child.Length("top", height, out top);
				let hasBottom = child.Length("bottom", height, out bottom);
				if (hasLeft && hasRight)
					cw = Math.Max(width - left - right, 0);
				if (hasTop && hasBottom)
					ch = Math.Max(height - top - bottom, 0);
				cx = hasLeft ? x + left : (hasRight ? x + width - right - cw : x);
				cy = hasTop ? y + top : (hasBottom ? y + height - bottom - ch : y);
				Arrange(child, cx, cy, cw, ch);
				continue;
			}
			var mainSize = row ? child.desired.x : child.desired.y;
			if (grow > 0)
				mainSize += free * child.Number("flex-grow") / grow;
			var crossSize = row ? child.desired.y : child.desired.x;
			let crossSpace = (row ? innerH : innerW) - (row ? margin.y + margin.w : margin.x + margin.z);
			float explicitCross;
			let hasExplicitCross = child.Length(row ? "height" : "width", row ? innerH : innerW, out explicitCross);
			float crossOffset = 0;
			if (align == "stretch" && !hasExplicitCross)
				crossSize = Math.Max(crossSpace, 0);
			else if (align == "center")
				crossOffset = (crossSpace - crossSize) * 0.5f;
			else if (align == "end")
				crossOffset = crossSpace - crossSize;
			if (row)
				Arrange(child, innerX + cursor + margin.x, innerY + margin.y + crossOffset, mainSize, crossSize);
			else
				Arrange(child, innerX + margin.x + crossOffset, innerY + cursor + margin.y, crossSize, mainSize);
			cursor += mainSize + (row ? margin.x + margin.z : margin.y + margin.w) + spacing;
		}
	}

	/// Resolves styles and positions every element for a view of the given size.
	public void Layout(float width, float height)
	{
		if (root == null)
			return;
		mViewWidth = width;
		mViewHeight = height;
		ComputeStyles(root);
		Measure(root, width, height);
		Arrange(root, 0, 0, width, height);
	}

	// ---- drawing ----

	/// Draws the laid-out document at a screen position. binder supplies bind="..." values; pass null for a static preview.
	/// How much bigger than laid out the document is drawn. Lay out for a view of (width / scale, height / scale)
	/// and the document fills the real one; UI Document's Reference Height does this.
	public float scale = 1;

	/// Documents can be worked with a controller: the d-pad or left stick moves a highlight from one button, toggle
	/// or slider to the next, the bottom button (A, Cross) presses it, and left and right move a slider. It takes
	/// over when the player touches the controller and hands back when they touch the mouse. Set false to do
	/// without, for a game that steers its menus itself.
	public static bool ControllerNavigation = true;

	/// The element the controller's highlight is on, or null.
	public UIElement focused;
	List<UIElement> mNavigable = new .() ~ delete _;
	bool mFocusMode;
	bool mFocusPress, mFocusDown;

	public void Draw(ImGui.Vec2 origin, UIDocument binder, bool interactive)
	{
		clicked = null;
		hovered = null;
		changed = null;
		if (!ImGui.IsMouseDown(0))
			mDragging = null;
		mNavigable.Clear();
		mFocusMode = interactive && ControllerNavigation && Input.UsingGamepad && Input.Enabled;
		mFocusPress = mFocusMode && Gamepad.GetButtonDown(.South);
		mFocusDown = mFocusMode && Gamepad.GetButton(.South);
		if (root != null)
			DrawElement(root, origin, binder, interactive);
		if (mFocusMode)
			Navigate(binder);
		else
			focused = null;
	}

	/// Moves the controller's highlight, works a slider under it, and draws it.
	void Navigate(UIDocument binder)
	{
		if (!mNavigable.Contains(focused))
			focused = null;
		if (mNavigable.IsEmpty)
			return;
		GUI.MouseOverControl = true;
		let direction = Gamepad.NavDirection;
		if (focused == null)
		{
			// Start on the element the document marks with autofocus, else at the top, leftmost of equals.
			for (let element in mNavigable)
			{
				if (element.attributes.Has("autofocus"))
				{
					focused = element;
					break;
				}
				if (focused == null || element.screenY < focused.screenY - 1 || (Math.Abs(element.screenY - focused.screenY) <= 1 && element.screenX < focused.screenX))
					focused = element;
			}
		}
		else if (direction >= 0 && focused.tag == "slider" && (direction == 1 || direction == 3))
		{
			let low = SceneSerializer.ParseFloat(focused.attributes.Get("min", "0"));
			let high = SceneSerializer.ParseFloat(focused.attributes.Get("max", "1"));
			var step = SceneSerializer.ParseFloat(focused.attributes.Get("step", "0"));
			if (step <= 0)
				step = (high - low) / 20;
			let next = Math.Clamp(focused.value + (direction == 1 ? step : -step), low, high);
			if (next != focused.value)
			{
				focused.value = next;
				changed = focused;
				let bind = focused.attributes.Get("bind");
				if (binder != null && !bind.IsEmpty)
					binder.WriteBinding(bind, scope $"{next}");
			}
		}
		else if (direction >= 0)
		{
			// The nearest element that way: distance along the direction, with drifting sideways counted double.
			let fromX = focused.screenX + focused.screenWidth * 0.5f, fromY = focused.screenY + focused.screenHeight * 0.5f;
			let dx = direction == 1 ? 1.0f : (direction == 3 ? -1.0f : 0.0f);
			let dy = direction == 2 ? 1.0f : (direction == 0 ? -1.0f : 0.0f);
			UIElement best = null;
			float bestScore = float.MaxValue;
			for (let element in mNavigable)
			{
				if (element == focused)
					continue;
				// Measured to the nearest point of the element, so that wide and narrow ones are judged alike.
				let toX = Math.Clamp(fromX, element.screenX, element.screenX + element.screenWidth) - fromX;
				let toY = Math.Clamp(fromY, element.screenY, element.screenY + element.screenHeight) - fromY;
				let along = toX * dx + toY * dy;
				if (along <= 1)
					continue;
				let across = Math.Abs(toX * dy) + Math.Abs(toY * dx);
				let score = along + across * 2;
				if (score < bestScore)
				{
					bestScore = score;
					best = element;
				}
			}
			if (best != null)
				focused = best;
		}
		if (focused != null)
		{
			hovered = focused;
			let pad = 3 * focused.screenScale;
			ImGui.DrawRect(.(focused.screenX - pad, focused.screenY - pad), .(focused.screenX + focused.screenWidth + pad, focused.screenY + focused.screenHeight + pad), .(1, 1, 1, 0.95f), focused.Number("border-radius") * focused.screenScale + pad, Math.Max(2 * focused.screenScale, 1.5f));
		}
	}

	/// Where an element is on screen this frame, and how the pointer (or the controller's highlight) is on it.
	struct ElementFrame
	{
		public ImGui.Vec2 min;
		public ImGui.Vec2 max;
		public ImGui.Vec2 mouse;
		public float radius;
		/// Under the pointer; with a controller in use, "has the highlight".
		public bool over;
		/// Clicked this frame (the controller's bottom button when it has the highlight).
		public bool pressed;
		public bool interactive;
		public Color color;
	}

	void DrawElement(UIElement element, ImGui.Vec2 origin, UIDocument binder, bool canInteract)
	{
		if (!element.visible || element.computed.Get("display") == "none")
			return;
		ElementFrame frame;
		frame.interactive = canInteract && element.attributes.Get("disabled") != "true";
		frame.min = ImGui.Vec2(origin.x + element.x * scale, origin.y + element.y * scale);
		frame.max = ImGui.Vec2(frame.min.x + element.width * scale, frame.min.y + element.height * scale);
		frame.radius = element.Number("border-radius") * scale;
		frame.mouse = ImGui.GetMousePos();
		frame.over = mFocusMode ? element == focused : (frame.mouse.x >= frame.min.x && frame.mouse.x < frame.max.x && frame.mouse.y >= frame.min.y && frame.mouse.y < frame.max.y);
		frame.pressed = mFocusMode ? mFocusPress : ImGui.IsMouseReleased(0);
		frame.color = element.ColorOf("color", .(0.9f, 0.9f, 0.9f, 1));
		element.screenX = frame.min.x;
		element.screenY = frame.min.y;
		element.screenWidth = frame.max.x - frame.min.x;
		element.screenHeight = frame.max.y - frame.min.y;
		element.screenScale = scale;

		DrawBox(element, frame);
		switch (element.tag)
		{
		case "image":
			DrawImageElement(element, frame);
		case "slider":
			DrawSlider(element, frame, binder);
		case "toggle":
			DrawToggle(element, frame, binder);
		case "bar":
			DrawBar(element, frame, binder);
		case "input":
			DrawInput(element, frame, binder);
		case "canvas":
			// A canvas is drawn by the game: its ondraw handler is called here, between what is behind it and its
			// own children.
			if (binder == null)
				DrawCanvasPlaceholder(element, frame.min, frame.max);
			else
			{
				let handler = element.attributes.Get("ondraw");
				if (!handler.IsEmpty)
					binder.Invoke(handler, element);
			}
		default:
			if (UIDocumentData.IsTextTag(element.tag))
				DrawTextElement(element, frame, binder);
		}
		for (let child in element.children)
			DrawElement(child, origin, binder, frame.interactive);
	}

	/// The element's background and border, with hover and press feedback on buttons (no style rules needed).
	void DrawBox(UIElement element, ElementFrame frame)
	{
		var background = element.ColorOf("background-color", .(0, 0, 0, 0));
		let isButton = element.tag == "button" || element.attributes.Has("onclick");
		if (frame.interactive && (isButton || element.tag == "toggle" || element.tag == "slider"))
			mNavigable.Add(element);
		if (isButton && frame.over && frame.interactive)
		{
			hovered = element;
			GUI.MouseOverControl = true;
			let shift = (mFocusMode ? mFocusDown : ImGui.IsMouseDown(0)) ? -0.06f : 0.08f;
			if (element.attributes.Get("feedback") != "none")
				background = .(Mathf.Clamp01(background.r + shift), Mathf.Clamp01(background.g + shift), Mathf.Clamp01(background.b + shift), Math.Max(background.a, 0.25f));
			if (frame.pressed)
				clicked = element;
		}
		if (background.a > 0.003f)
			ImGui.DrawRectFilled(frame.min, frame.max, background, frame.radius);
		let borderWidth = element.Number("border-width") * scale;
		if (borderWidth > 0)
			ImGui.DrawRect(frame.min, frame.max, element.ColorOf("border-color", .(1, 1, 1, 0.3f)), frame.radius, borderWidth);
	}

	void DrawImageElement(UIElement element, ElementFrame frame)
	{
		let source = element.attributes.Get("src");
		if (source.IsEmpty)
			return;
		ImGui.SetCursorScreenPos(frame.min);
		ImGui.Image(Assets.GetTexture(source).idx, .(element.width * scale, element.height * scale), .(0, 0), .(1, 1), false);
	}

	/// A track with a filled part and a knob. Drag anywhere along it.
	void DrawSlider(UIElement element, ElementFrame frame, UIDocument binder)
	{
		let low = SceneSerializer.ParseFloat(element.attributes.Get("min", "0"));
		let high = SceneSerializer.ParseFloat(element.attributes.Get("max", "1"));
		let step = SceneSerializer.ParseFloat(element.attributes.Get("step", "0"));
		let bind = element.attributes.Get("bind");
		let bound = scope String();
		if (binder != null && !bind.IsEmpty && binder.ReadBinding(bind, bound) && float.Parse(bound) case .Ok(let number))
			element.value = number;
		let min = frame.min, max = frame.max;
		let knob = element.Number("slider-thumb-size", element.height) * scale * 0.5f;
		let left = min.x + knob, right = max.x - knob;
		if (frame.interactive && !mFocusMode && ((frame.over && ImGui.IsMouseClicked(0)) || mDragging == element))
		{
			mDragging = element;
			GUI.MouseOverControl = true;
			var next = low + Mathf.Clamp01((frame.mouse.x - left) / Math.Max(right - left, 1)) * (high - low);
			if (step > 0)
				next = low + Math.Round((next - low) / step) * step;
			if (next != element.value)
			{
				element.value = next;
				changed = element;
				if (binder != null && !bind.IsEmpty)
					binder.WriteBinding(bind, scope $"{next}");
			}
		}
		if (frame.over && frame.interactive)
			GUI.MouseOverControl = true;
		let fraction = high > low ? Mathf.Clamp01((element.value - low) / (high - low)) : 0;
		let middle = (min.y + max.y) * 0.5f;
		let thickness = Math.Max(element.screenHeight * 0.16f, 2);
		let trackSource = element.attributes.Get("track-src");
		if (trackSource.IsEmpty)
		{
			ImGui.DrawRectFilled(.(left, middle - thickness), .(left + (right - left) * fraction, middle + thickness), frame.color, thickness);
			ImGui.DrawCircleFilled(.(left + (right - left) * fraction, middle), knob * (frame.over || mDragging == element ? 1.0f : 0.82f), .(1, 1, 1, 1));
			return;
		}
		// Pictures for the track, the filled part and the knob.
		let halfTrack = element.Number("slider-track-height", element.height * 0.32f) * scale * 0.5f;
		let thumbX = left + (right - left) * fraction;
		ImGui.DrawImage(Assets.GetTexture(trackSource).idx, .(min.x, middle - halfTrack), .(max.x, middle + halfTrack), false);
		let fillSource = element.attributes.Get("fill-src");
		if (!fillSource.IsEmpty && thumbX > min.x)
			ImGui.DrawImage(Assets.GetTexture(fillSource).idx, .(min.x, middle - halfTrack), .(thumbX, middle + halfTrack), false);
		let thumbSource = element.attributes.Get("thumb-src");
		if (!thumbSource.IsEmpty)
			ImGui.DrawImage(Assets.GetTexture(thumbSource).idx, .(thumbX - knob, middle - knob), .(thumbX + knob, middle + knob), false);
	}

	/// A pill with a knob at one end, off to the left and on to the right (or, toggle-style: button, a coloured button).
	void DrawToggle(UIElement element, ElementFrame frame, UIDocument binder)
	{
		let bind = element.attributes.Get("bind");
		let bound = scope String();
		if (binder != null && !bind.IsEmpty && binder.ReadBinding(bind, bound))
			element.value = (bound == "1" || bound == "true") ? 1 : 0;
		if (frame.interactive && frame.over)
		{
			GUI.MouseOverControl = true;
			hovered = element;
			if (frame.pressed)
			{
				element.value = element.value > 0.5f ? 0 : 1;
				changed = element;
				if (binder != null && !bind.IsEmpty)
					binder.WriteBinding(bind, element.value > 0.5f ? "1" : "0");
			}
		}
		let on = element.value > 0.5f;
		let half = element.screenHeight * 0.5f;
		if (element.computed.Get("toggle-style") == "button")
		{
			let fill = frame.over ? Color(0.86f, 0.84f, 0.12f, 1) : (on ? Color(0.95f, 0.59f, 0.05f, 1) : Color(0.18f, 0.35f, 0.76f, 1));
			ImGui.DrawRectFilled(frame.min, frame.max, fill, 3 * scale);
			return;
		}
		if (on)
			ImGui.DrawRectFilled(frame.min, frame.max, frame.color, half);
		ImGui.DrawCircleFilled(.(on ? frame.max.x - half : frame.min.x + half, frame.min.y + half), half * 0.78f, .(1, 1, 1, 1));
	}

	/// A bar filled to its value (0 to 1), or to the bound field's.
	void DrawBar(UIElement element, ElementFrame frame, UIDocument binder)
	{
		float fraction = Mathf.Clamp01(element.value);
		let bind = element.attributes.Get("bind");
		let value = scope String();
		if (binder != null && !bind.IsEmpty && binder.ReadBinding(bind, value) && float.Parse(value) case .Ok(let number))
			fraction = number;
		// With nothing to ask (the editor's still preview), show it half full.
		if (binder == null)
			fraction = 0.5f;
		let fill = (element.width * scale - 4) * Mathf.Clamp01(fraction);
		if (fill > 0)
			ImGui.DrawRectFilled(.(frame.min.x + 2, frame.min.y + 2), .(frame.min.x + 2 + fill, frame.max.y - 2), frame.color, Math.Max(frame.radius - 1, 0));
	}

	/// A text box editing the bound field.
	void DrawInput(UIElement element, ElementFrame frame, UIDocument binder)
	{
		let bind = element.attributes.Get("bind");
		let value = scope String();
		if (binder != null && !bind.IsEmpty)
			binder.ReadBinding(bind, value);
		ImGui.SetCursorScreenPos(frame.min);
		ImGui.SetNextItemWidth(element.width * scale);
		ImGui.PushID(Internal.UnsafeCastToPtr(element));
		ImGui.BeginDisabled(!frame.interactive);
		if (ImGui.InputText("##input", value) && binder != null && !bind.IsEmpty)
			binder.WriteBinding(bind, value);
		// A phone's keyboard does not come up for the game's canvas: in a browser on a touch screen, a tap on the
		// box asks in the browser's own box instead (prompt="..." is its question), where Paste works too.
		if (WebPlatform.IsWeb && Input.UsingTouch && frame.interactive && !mFocusMode && frame.over && ImGui.IsMouseReleased(0))
		{
			if (ImGui.IsItemActive())
				ImGui.ClearActiveID();
			let title = element.attributes.Get("prompt");
			if (WebPlatform.PromptText(title.IsEmpty ? "Type here" : title, value) && binder != null && !bind.IsEmpty)
				binder.WriteBinding(bind, value);
		}
		if (ImGui.IsItemHovered() || ImGui.IsItemActive())
			GUI.MouseOverControl = true;
		ImGui.EndDisabled();
		ImGui.PopID();
	}

	/// An element's text: its own, or with bind="field" a value from the controller, aligned as its style says.
	void DrawTextElement(UIElement element, ElementFrame frame, UIDocument binder)
	{
		let shown = scope String(element.text);
		let bind = element.attributes.Get("bind");
		if (binder != null && !bind.IsEmpty)
		{
			shown.Clear();
			binder.ReadBinding(bind, shown);
		}
		if (shown.IsEmpty)
			return;
		var padding = element.Edges("padding");
		padding = .(padding.x * scale, padding.y * scale, padding.z * scale, padding.w * scale);
		let min = frame.min, max = frame.max;
		UIFonts.Push(element.computed.Get("font-family"), element.Number("font-size", 16) * scale);
		let size = ImGui.CalcTextSize(shown.CStr());
		var tx = min.x + padding.x;
		var ty = min.y + padding.y;
		let alignText = element.computed.Get("text-align", element.tag == "button" ? "center" : "left");
		// Text in an element with a height of its own sits in the middle of it.
		if (element.tag == "text" && element.computed.Has("height"))
			ty = min.y + (element.screenHeight - size.y) * 0.5f;
		if (alignText == "center")
			tx = min.x + (element.width * scale - size.x) * 0.5f;
		else if (alignText == "right")
			tx = max.x - padding.z - size.x;
		if (element.tag == "button")
			ty = min.y + (element.height * scale - size.y) * 0.5f;
		if (element.computed.Get("white-space") == "normal")
			ImGui.DrawTextWrapped(.(min.x + padding.x, ty), frame.color, shown.CStr(), element.width * scale - padding.x - padding.z);
		else
			ImGui.DrawText(.(tx, ty), frame.color, shown.CStr());
		ImGui.PopFont();
	}

	/// What the editor's preview shows where the game will draw (there is nothing to call there): a tinted box
	/// named by the canvas's preview="..." attribute, else by its id, or the picture named by preview-src="...".
	/// Neither attribute does anything while the game runs: the ondraw handler takes the placeholder's place.
	void DrawCanvasPlaceholder(UIElement element, ImGui.Vec2 min, ImGui.Vec2 max)
	{
		let width = max.x - min.x, height = max.y - min.y;
		if (width < 2 || height < 2)
			return;
		// A tint of its own for each canvas, taken from its name, so that neighbours can be told apart.
		uint32 hash = 2166136261;
		for (let c in element.Id.RawChars)
			hash = (hash ^ (uint32)c) * 16777619;
		let hue = (float)(hash % 360) / 60.0f;
		let part = hue - Math.Floor(hue);
		float r = 0, g = 0, b = 0;
		switch ((int)hue)
		{
		case 0:
			r = 1;
			g = part;
		case 1:
			r = 1 - part;
			g = 1;
		case 2:
			g = 1;
			b = part;
		case 3:
			g = 1 - part;
			b = 1;
		case 4:
			r = part;
			b = 1;
		default:
			r = 1;
			b = 1 - part;
		}
		// Softened towards white so that the label reads on any tint.
		r = 0.45f + r * 0.55f;
		g = 0.45f + g * 0.55f;
		b = 0.45f + b * 0.55f;
		let picture = element.attributes.Get("preview-src");
		// A canvas over the whole view (cross-hairs, name tags) would tint everything under it: it gets a frame only.
		let covers = element.width >= mViewWidth * 0.9f && element.height >= mViewHeight * 0.9f;
		if (!picture.IsEmpty)
			ImGui.DrawImage(Assets.GetTexture(picture).idx, min, max, false);
		else if (!covers)
			ImGui.DrawRectFilled(min, max, .(r, g, b, 0.16f));
		ImGui.DrawRect(min, max, .(r, g, b, covers ? 0.45f : 0.9f), 0, 1);

		let title = scope String(element.attributes.Get("preview"));
		if (title.IsEmpty)
			title.Set(element.Id.IsEmpty ? "canvas" : element.Id);
		let detail = scope String();
		detail.AppendF("{} x {}", (int)Math.Round(element.width), (int)Math.Round(element.height));
		let handler = element.attributes.Get("ondraw");
		if (!handler.IsEmpty)
			detail.AppendF("  {}", handler);
		// Editor lettering, so it is sized for the screen and not with the document; smaller in a box too small for it.
		ImGui.PushClipRect(min, max);
		var size = 14.0f;
		ImGui.PushFontSize(size);
		var titleSize = ImGui.CalcTextSize(title.CStr());
		ImGui.PopFont();
		if (titleSize.x > width - 8 || titleSize.y > height - 2)
		{
			size = Math.Max(Math.Min(size * (width - 8) / Math.Max(titleSize.x, 1), height - 2), 9);
			ImGui.PushFontSize(size);
			titleSize = ImGui.CalcTextSize(title.CStr());
			ImGui.PopFont();
		}
		let detailSize = size * 0.8f;
		ImGui.PushFontSize(detailSize);
		let detailExtent = ImGui.CalcTextSize(detail.CStr());
		ImGui.PopFont();
		let twoLines = detailSize >= 9 && titleSize.y + detailExtent.y + 6 <= height && detailExtent.x <= width - 8;
		let blockHeight = titleSize.y + (twoLines ? detailExtent.y + 2 : 0);
		// In the middle of its box; a canvas over the whole view is named along its bottom edge, where the least is.
		let tx = min.x + (width - titleSize.x) * 0.5f;
		let ty = covers ? max.y - blockHeight - 6 : min.y + (height - blockHeight) * 0.5f;
		if (!picture.IsEmpty || covers)
			ImGui.DrawRectFilled(.(tx - 4, ty - 2), .(tx + titleSize.x + 4, ty + blockHeight + 2), .(0, 0, 0, 0.55f), 3);
		ImGui.PushFontSize(size);
		ImGui.DrawText(.(Math.Max(tx, min.x + 2), ty), .(r, g, b, 1), title.CStr());
		ImGui.PopFont();
		if (twoLines)
		{
			ImGui.PushFontSize(detailSize);
			ImGui.DrawText(.(min.x + (width - detailExtent.x) * 0.5f, ty + titleSize.y + 2), .(r, g, b, 0.7f), detail.CStr());
			ImGui.PopFont();
		}
		ImGui.PopClipRect();
	}

	// ---- writing back to markup ----

	public void Save(String text)
	{
		if (!styleText.IsEmpty && !separateStyleFile)
			text.AppendF("<style>\n{}\n</style>\n\n", styleText);
		if (root != null)
		{
			for (let child in root.children)
				WriteElement(child, text, 0);
		}
	}

	static void WriteElement(UIElement element, String text, int indent)
	{
		text.Append('\t', indent);
		text.AppendF("<{}", element.tag);
		for (let item in element.attributes.items)
			text.AppendF(" {}=\"{}\"", item.key, item.value);
		if (element.style.items.Count > 0)
		{
			text.Append(" style=\"");
			for (int i < element.style.items.Count)
				text.AppendF("{}{}: {}", i > 0 ? "; " : "", element.style.items[i].key, element.style.items[i].value);
			text.Append('"');
		}
		if (element.children.Count == 0 && element.text.IsEmpty)
		{
			text.Append(" />\n");
			return;
		}
		text.Append('>');
		if (element.children.Count == 0)
		{
			text.AppendF("{}</{}>\n", element.text, element.tag);
			return;
		}
		text.Append('\n');
		if (!element.text.IsEmpty)
		{
			text.Append('\t', indent + 1);
			text.AppendF("{}\n", element.text);
		}
		for (let child in element.children)
			WriteElement(child, text, indent + 1);
		text.Append('\t', indent);
		text.AppendF("</{}>\n", element.tag);
	}
}
