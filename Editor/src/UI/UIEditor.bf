using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// The UI tab: a visual editor for UI documents (.tui).
/// Left: the element tree. Middle: a live preview you can click to select elements.
/// Right: the selected element's tag, text, events and style properties. Save writes the markup back.
extension EditorApp
{
	UIDocumentData mUiData ~ delete _;
	String mUiPath = new .() ~ delete _;
	String mUiStatus = new .() ~ delete _;
	String mUiNewProperty = new .() ~ delete _;
	UIElement mUiSelected;
	bool mUiFocus;
	float mUiPreviewScale = 1;
	int32 mUiPreviewSize = 2;

	static readonly char8*[?] UiTags = .("panel", "text", "button", "image", "input", "bar", "slider", "toggle", "canvas");
	// Sized by UiTags so that a tag added there without a name and a hint here does not compile.
	static readonly char8*[UiTags.Count] UiTagNames = .("Panel", "Text", "Button", "Image", "Text Field", "Progress Bar", "Slider",
		"Toggle", "Canvas");
	static readonly char8*[UiTags.Count] UiTagHints = .("Groups and arranges other components", "A line of text", "Runs a method when pressed",
		"Shows a picture", "Lets the player type; bound to a field", "A bar filled by a bound number",
		"A handle dragged between two numbers; calls a method when moved", "A switch that is on or off; calls a method when changed",
		"An empty area that a method draws into every frame");

	static StringView UiTagName(StringView tag)
	{
		for (int i < UiTags.Count)
		{
			if (tag == StringView(UiTags[i]))
				return StringView(UiTagNames[i]);
		}
		return tag;
	}

	/// Called when the markup or stylesheet was saved from the code editor: refresh the preview and the scene.
	void OnUiSourceSaved(StringView path)
	{
		if (mUiData != null)
		{
			let stylePath = scope String();
			UIDocumentData.StylePathFor(mUiPath, stylePath);
			if (path == mUiPath || path == stylePath)
			{
				mUiData.Load(mUiPath);
				mUiSelected = null;
			}
		}
		for (let component in mScene.Components)
		{
			if (let document = component as UIDocument)
				document.Reload();
		}
	}

	/// Opens the document's markup or its stylesheet in the Scripts tab. The stylesheet is moved
	/// into its own .tcss file the first time, so each language gets its own highlighting.
	void OpenUiSource(bool stylesheet)
	{
		if (stylesheet)
			mUiData.separateStyleFile = true;
		SaveUI();
		if (!stylesheet)
		{
			OpenScript(mUiPath);
			return;
		}
		let stylePath = scope String();
		UIDocumentData.StylePathFor(mUiPath, stylePath);
		OpenScript(stylePath);
	}

	static readonly char8*[?] UiStyleNames = .("width", "height", "padding", "margin", "gap", "flex-direction", "flex-grow", "align-items",
		"justify-content", "background-color", "color", "font-size", "border-radius", "border-width", "border-color", "text-align",
		"position", "left", "top", "right", "bottom", "display");
	// The view the document is laid out for; the preview is then drawn smaller or bigger to fit its panel.
	static readonly (int32 w, int32 h, char8* name)[?] UiSizes = .((960, 540, "960 x 540"), (1280, 720, "1280 x 720"), (1920, 1080, "1920 x 1080"),
		(2560, 1080, "2560 x 1080 (wide)"), (1024, 768, "1024 x 768 (4:3)"), (1950, 900, "1950 x 900 (phone)"), (900, 1950, "900 x 1950 (phone upright)"));

	/// The view a document is designed for, taken from a UI Document in the open scene that shows it: its Reference
	/// Height, and Reference Width where it has one. Returns false when no component in the scene uses the document.
	bool UiDesignSize(StringView path, out float width, out float height)
	{
		width = 0;
		height = 0;
		for (let component in mScene.Components)
		{
			let document = component as UIDocument;
			if (document == null || document.document.IsEmpty || document.referenceHeight <= 0)
				continue;
			if (!path.EndsWith(document.document) && !scope String(path)..Replace('\\', '/').EndsWith(document.document))
				continue;
			height = document.referenceHeight;
			width = document.referenceWidth > 0 ? document.referenceWidth : Math.Round(height * 16 / 9);
			return true;
		}
		return false;
	}

	void OpenUI(StringView path)
	{
		mShowUI = true;
		mDockUI = true;
		delete mUiData;
		mUiData = new UIDocumentData();
		mUiPath.Set(path);
		mUiSelected = null;
		mUiStatus.Clear();
		if (!mUiData.Load(path))
			mUiStatus.Set("Could not read the file.");
		mUiFocus = true;
		// Start on the size the document is designed for, when a UI Document in the scene says what that is.
		if (UiDesignSize(path, let designWidth, let designHeight))
		{
			for (int32 i < (int32)UiSizes.Count)
			{
				if (UiSizes[i].h == (int32)designHeight && UiSizes[i].w == (int32)designWidth)
					mUiPreviewSize = i;
			}
		}
	}

	void CreateUIAsset(StringView name)
	{
		if (!ProjectGenerator.IsValidName(name))
		{
			Log.Error("UI document names use letters, digits and underscores, and start with a letter.");
			return;
		}
		let path = scope $"{mBrowsePath}/{name}.tui";
		if (File.Exists(path))
		{
			Log.Error(scope $"{path} already exists.");
			return;
		}
		File.WriteAllText(path, """
			<style>
			#screen { width: 100%; height: 100%; align-items: center; justify-content: center }
			.card { width: 320; padding: 20; gap: 10; background-color: #1b2028f2; border-radius: 8 }
			.title { font-size: 24 }
			</style>

			<panel id="screen">
				<panel class="card">
					<text class="title">New UI</text>
					<button onclick="OnPressed">Button</button>
				</panel>
			</panel>

			""").IgnoreError();
		RefreshAssetList();
		OpenUI(path);
	}

	void SaveUI()
	{
		if (mUiData == null)
			return;
		let text = scope String();
		mUiData.Save(text);
		if (mUiData.separateStyleFile)
		{
			let stylePath = scope String();
			UIDocumentData.StylePathFor(mUiPath, stylePath);
			File.WriteAllText(stylePath, scope String(mUiData.styleText)..Append('\n')).IgnoreError();
		}
		if (File.WriteAllText(mUiPath, text) case .Ok)
		{
			mUiStatus.Set("Saved.");
			// Documents already showing in the scene pick the change up straight away.
			for (let component in mScene.Components)
			{
				if (let document = component as UIDocument)
					document.Reload();
			}
		}
		else
			mUiStatus.Set("Could not save.");
	}

	void DrawUiTree(UIElement element, int depth)
	{
		// "Button  Play", "Panel  card": what the element is and how to recognise it, without markup syntax.
		let label = scope String();
		label.Append(UiTagName(element.tag));
		if (!element.text.IsEmpty)
			label.AppendF("  \"{}\"", element.text.Length > 20 ? element.text.Substring(0, 20) : (StringView)element.text);
		else if (!element.Id.IsEmpty)
			label.AppendF("  {}", element.Id);
		else if (!element.attributes.Get("class").IsEmpty)
			label.AppendF("  {}", element.attributes.Get("class"));
		var flags = ImGui.TreeFlags.OpenOnArrow | ImGui.TreeFlags.SpanAvailWidth | ImGui.TreeFlags.DefaultOpen;
		if (element.children.Count == 0)
			flags |= ImGui.TreeFlags.Leaf;
		if (element == mUiSelected)
			flags |= ImGui.TreeFlags.Selected;
		ImGui.PushID(Internal.UnsafeCastToPtr(element));
		let open = ImGui.TreeNode(label.CStr(), flags);
		if (ImGui.IsItemClicked(0) && !ImGui.IsItemToggledOpen())
			mUiSelected = element;
		if (open)
		{
			for (let child in element.children)
				DrawUiTree(child, depth + 1);
			ImGui.TreePop();
		}
		ImGui.PopID();
	}

	/// Deepest element under a point in document space.
	UIElement PickUiElement(UIElement element, float x, float y)
	{
		if (!element.visible || x < element.x || y < element.y || x >= element.x + element.width || y >= element.y + element.height)
			return null;
		for (int i = element.children.Count - 1; i >= 0; i--)
		{
			let hit = PickUiElement(element.children[i], x, y);
			if (hit != null)
				return hit;
		}
		return element;
	}

	bool UiAttribute(char8* label, UIElement element, StringView name)
	{
		let value = scope String(element.attributes.Get(name));
		BeginProperty(label);
		ImGui.PushID(label);
		let changed = ImGui.InputText("##a", value);
		ImGui.PopID();
		if (changed)
		{
			if (value.IsEmpty)
				element.attributes.Remove(name);
			else
				element.attributes.Set(name, value);
		}
		return changed;
	}

	void DrawUIEditor()
	{
		if (!mShowUI)
			return;
		if (mDockUI && mAssetCenterDock != 0)
		{
			ImGui.SetNextWindowDockID(mAssetCenterDock);
			mDockUI = false;
		}
		if (mUiFocus && Time.FrameCount > 5)
		{
			ImGui.SetWindowFocus("UI");
			mUiFocus = false;
		}
		if (ImGui.Begin("UI", &mShowUI, ImGui.WindowFlags.NoScrollbar | ImGui.WindowFlags.NoScrollWithMouse))
		{
			if (mUiData == null || mUiData.root == null)
				ImGui.TextDisabled("Create an interface with Project > + > UI Document, or double-click a .tui file.");
			else
				DrawUIEditorContents();
		}
		ImGui.End();
	}

	void DrawUIEditorContents()
	{
		DrawUiToolbar();
		let total = ImGui.GetContentRegionAvail();
		let sideWidth = 250.0f;
		ImGui.BeginChild("tree", .(sideWidth, 0), ImGui.ChildBorders);
		DrawUiElementTree();
		ImGui.EndChild();
		ImGui.SameLine();
		ImGui.BeginChild("preview", .(Math.Max(total.x - sideWidth * 2 - 16, 100), 0), 0, ImGui.WindowFlags.NoScrollbar | ImGui.WindowFlags.NoScrollWithMouse);
		DrawUiPreview();
		ImGui.EndChild();
		ImGui.SameLine();
		ImGui.BeginChild("properties", .(0, 0), ImGui.ChildBorders);
		if (mUiSelected == null)
			ImGui.TextWrapped("Click an element in the preview or the tree to edit it.");
		else
			DrawUiProperties(mUiSelected);
		ImGui.EndChild();
	}

	/// Save, the HTML and CSS sources, and the screen size the preview stands for.
	void DrawUiToolbar()
	{
		if (ImGui.SmallButton("Save"))
			SaveUI();
		ImGui.SameLine();
		if (ImGui.SmallButton("Open HTML"))
			OpenUiSource(false);
		ImGui.SameLine();
		if (ImGui.SmallButton("Open CSS"))
			OpenUiSource(true);
		ImGui.SameLine(0, 14);
		ImGui.SetNextItemWidth(190);
		if (ImGui.BeginCombo("##size", UiSizes[mUiPreviewSize].name))
		{
			for (int32 i < (int32)UiSizes.Count)
			{
				if (ImGui.Selectable(UiSizes[i].name, mUiPreviewSize == i))
					mUiPreviewSize = i;
			}
			ImGui.EndCombo();
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("The screen the preview stands for. The whole of it is always shown, drawn smaller or bigger to fit this panel.");
		ImGui.SameLine();
		ImGui.TextDisabled(scope String()..AppendF("{}%", (int)Math.Round(mUiPreviewScale * 100)).CStr());
		ImGui.SameLine();
		ImGui.TextDisabled(mUiStatus.CStr());
		ImGui.Separator();
	}

	/// The components that can be added (inside the selection when it can hold others, otherwise beside it), and the
	/// document's elements as a tree.
	void DrawUiElementTree()
	{
		ImGui.TextDisabled("Components");
		for (int32 i < (int32)UiTags.Count)
		{
			if (ImGui.Selectable(scope String()..AppendF("+  {}", StringView(UiTagNames[i])).CStr()))
			{
				// New components go inside the selection when it can hold others, otherwise beside it.
				var parent = mUiSelected ?? mUiData.root;
				if (parent.tag != "panel")
					parent = parent.parent ?? mUiData.root;
				let created = parent.AddChild(StringView(UiTags[i]));
				if (UIDocumentData.IsTextTag(created.tag))
					created.text.Set(created.tag == "button" ? "Button" : "Text");
				mUiSelected = created;
			}
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip(UiTagHints[i]);
		}
		ImGui.Spacing();
		ImGui.Separator();
		ImGui.TextDisabled("Hierarchy");
		for (let child in mUiData.root.children)
			DrawUiTree(child, 0);
	}

	/// The document laid out for the chosen screen and drawn at whatever scale shows all of it in the panel, as a UI
	/// Document's Reference Height does in the game; a click selects the element under the mouse.
	void DrawUiPreview()
	{
		let available = ImGui.GetContentRegionAvail();
		let designW = (float)UiSizes[mUiPreviewSize].w;
		let designH = (float)UiSizes[mUiPreviewSize].h;
		// The document is laid out for the chosen screen and drawn at whatever scale shows all of it in the panel,
		// as a UI Document's Reference Height does in the game: sizes in the document never outgrow the preview.
		let scale = Math.Max(Math.Min(available.x / designW, available.y / designH), 0.02f);
		mUiPreviewScale = scale;
		let viewW = designW * scale;
		let viewH = designH * scale;
		var origin = ImGui.GetCursorScreenPos();
		// In the middle of the panel.
		origin.x += Math.Floor(Math.Max(available.x - viewW, 0) * 0.5f);
		origin.y += Math.Floor(Math.Max(available.y - viewH, 0) * 0.5f);
		ImGui.SetCursorScreenPos(origin);
		ImGui.InvisibleButton("##preview", .(Math.Max(viewW, 1), Math.Max(viewH, 1)));
		let previewHovered = ImGui.IsItemHovered();
		ImGui.DrawRectFilled(origin, .(origin.x + viewW, origin.y + viewH), .(0.16f, 0.19f, 0.23f, 1));
		ImGui.DrawRect(.(origin.x - 1, origin.y - 1), .(origin.x + viewW + 1, origin.y + viewH + 1), .(0.35f, 0.4f, 0.47f, 1));
		mUiData.scale = scale;
		mUiData.Layout(designW, designH);
		ImGui.PushClipRect(origin, .(origin.x + viewW, origin.y + viewH));
		mUiData.Draw(origin, null, false);
		ImGui.PopClipRect();
		if (previewHovered && ImGui.IsMouseClicked(0))
		{
			let mouse = ImGui.GetMousePos();
			mUiSelected = PickUiElement(mUiData.root, (mouse.x - origin.x) / scale, (mouse.y - origin.y) / scale);
			if (mUiSelected == mUiData.root)
				mUiSelected = null;
		}
		if (mUiSelected != null)
		{
			let min = ImGui.Vec2(origin.x + mUiSelected.x * scale, origin.y + mUiSelected.y * scale);
			ImGui.DrawRect(min, .(min.x + mUiSelected.width * scale, min.y + mUiSelected.height * scale), .(1.0f, 0.62f, 0.15f, 1), 0, 2);
		}
	}

	void DrawUiProperties(UIElement element)
	{
		if (BeginPropertyTable("element"))
		{
			BeginProperty("Type");
			if (ImGui.BeginCombo("##tag", scope String(UiTagName(element.tag)).CStr()))
			{
				for (int32 i < (int32)UiTags.Count)
				{
					if (ImGui.Selectable(UiTagNames[i], element.tag == StringView(UiTags[i])))
						element.tag.Set(StringView(UiTags[i]));
				}
				ImGui.EndCombo();
			}
			if (UIDocumentData.IsTextTag(element.tag))
			{
				BeginProperty("Text");
				ImGui.InputText("##text", element.text);
			}
			UiAttribute("Id", element, "id");
			UiAttribute("Class", element, "class");
			UiAttribute("On Click", element, "onclick");
			UiAttribute("On Load", element, "onload");
			if (element.tag != "panel" && element.tag != "button")
				UiAttribute("Bind", element, "bind");
			if (element.tag == "image")
				UiAttribute("Source", element, "src");
			if (element.tag == "canvas")
			{
				UiAttribute("On Draw", element, "ondraw");
				UiAttribute("Preview Name", element, "preview");
				if (ImGui.IsItemHovered())
					ImGui.SetTooltip("What this panel shows here in place of the game's drawing. Not used while the game runs.");
				UiAttribute("Preview Picture", element, "preview-src");
				if (ImGui.IsItemHovered())
					ImGui.SetTooltip("A picture shown here in place of the game's drawing, such as a screenshot of it. Not used while the game runs.");
			}
			ImGui.EndTable();
		}

		ImGui.SeparatorText("Style");
		String remove = null;
		if (BeginPropertyTable("style"))
		{
			for (let item in element.style.items)
			{
				BeginProperty(item.key.CStr());
				ImGui.PushID(item.key.CStr());
				ImGui.SetNextItemWidth(-26);
				ImGui.InputText("##v", item.value);
				ImGui.SameLine();
				if (ImGui.SmallButton("x"))
					remove = item.key;
				ImGui.PopID();
			}
			ImGui.EndTable();
		}
		if (remove != null)
			element.style.Remove(scope String(remove));
		ImGui.SetNextItemWidth(-1);
		if (ImGui.BeginCombo("##addstyle", "Add style property..."))
		{
			for (let name in UiStyleNames)
			{
				if (!element.style.Has(StringView(name)) && ImGui.Selectable(name))
				{
					let current = scope String(element.computed.Get(StringView(name)));
					element.style.Set(StringView(name), current.IsEmpty ? "0" : (StringView)current);
				}
			}
			ImGui.EndCombo();
		}
		ImGui.TextDisabled("Values from the stylesheet apply unless overridden here.");

		ImGui.SeparatorText("Element");
		let parent = element.parent;
		let index = parent != null ? parent.children.IndexOf(element) : -1;
		ImGui.BeginDisabled(index <= 0);
		if (ImGui.Button("Move Up"))
			Swap!(parent.children[index], parent.children[index - 1]);
		ImGui.EndDisabled();
		ImGui.SameLine();
		ImGui.BeginDisabled(parent == null || index < 0 || index >= parent.children.Count - 1);
		if (ImGui.Button("Move Down"))
			Swap!(parent.children[index], parent.children[index + 1]);
		ImGui.EndDisabled();
		ImGui.SameLine();
		if (ImGui.Button("Delete") && parent != null)
		{
			parent.children.Remove(element);
			delete element;
			mUiSelected = null;
		}
	}
}
