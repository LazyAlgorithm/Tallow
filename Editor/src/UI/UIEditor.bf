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
	float mUiPreviewScale = 1;
	int32 mUiPreviewSize = 2;
	// The UI editor's side panels live in windows of their own, docked beside the Hierarchy and the Inspector (last
	// in each tab list, so those stay the tabs in front).
	bool mShowUITree = true;
	bool mShowUIProps = true;
	bool mDockUITree;
	bool mDockUIProps;
	// The scene behind the preview, drawn as the Game view draws it (docs: RenderView).
	RenderView mUiView ~ delete _;
	bool mUiPreviewVisible;
	ImGui.Vec2 mUiPreviewRenderSize;
	float mUiPreviewAspect = 16.0f / 9.0f;
	// Focus the UI window once when a document is opened, so a double-clicked .tui brings it to the front.
	bool mUiFocus;
	// On-screen editing of the selected element: drag it to move, drag its corner handle to resize.
	bool mUiMovingElement;
	bool mUiResizingElement;
	ImGui.Vec2 mUiEditMouse;
	float mUiEditX, mUiEditY, mUiEditW, mUiEditH;

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

	/// What an element is for, shown at the top of its properties so an empty element says what it wants.
	static StringView UiTagHint(StringView tag)
	{
		for (int i < UiTags.Count)
		{
			if (tag == StringView(UiTags[i]))
				return StringView(UiTagHints[i]);
		}
		return StringView();
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

	// The style properties the editor offers. kind is "color" (the inspector's colour picker), "choice" (a list of
	// values joined with '|', each also offering "(default)" to drop the override), "number" (drag to nudge, keeping
	// any px/% unit) or "text" (a plain box). hint is the property's tooltip; fallback is what "Add style property"
	// starts with when the element has no computed value for it.
	static readonly (char8* name, char8* hint, char8* kind, char8* options, char8* fallback)[?] UiStyles = .(
		("width", "Pixels, or a percentage of the room available", "number", "", "100"),
		("height", "Pixels, or a percentage of the room available", "number", "", "40"),
		("padding", "Space inside the edges: one number, or two / four for each side", "text", "", "10"),
		("margin", "Space outside the edges: one number, or two / four for each side", "text", "", "0"),
		("gap", "Space between the elements inside", "number", "", "10"),
		("flex-direction", "The way the elements inside flow", "choice", "column|row", "column"),
		("flex-grow", "How much of the space left over this takes", "number", "", "0"),
		("align-items", "Where the elements inside sit across the flow", "choice", "start|center|end|stretch", "stretch"),
		("justify-content", "How the elements inside spread along the flow", "choice", "start|center|end|space-between", "start"),
		("background-color", "The colour behind the element", "color", "", "#00000000"),
		("color", "The text (or control) colour", "color", "", "#e6e6e6"),
		("font-size", "How tall the text is", "number", "", "16"),
		("border-radius", "How much the corners are rounded", "number", "", "0"),
		("border-width", "How thick the outline is", "number", "", "0"),
		("border-color", "The outline's colour", "color", "", "#ffffff"),
		("text-align", "Where text sits in the element", "choice", "left|center|right", "left"),
		("position", "static lays the element out normally; absolute pins it to the parent's edges", "choice", "static|absolute", "static"),
		("left", "Distance from the parent's left edge (absolute)", "number", "", "0"),
		("top", "Distance from the parent's top edge (absolute)", "number", "", "0"),
		("right", "Distance from the parent's right edge (absolute)", "number", "", "0"),
		("bottom", "Distance from the parent's bottom edge (absolute)", "number", "", "0"),
		("display", "none hides the element and its children", "choice", "none", ""),
		("white-space", "normal wraps long text, nowrap keeps it on one line", "choice", "normal|nowrap", "nowrap"),
		("font-family", "A font file in your assets (e.g. Fonts/Title.ttf), or empty for the default", "text", "", "")
	);

	/// The index of a style property in UiStyles, or -1 when the property is not one the editor knows.
	static int32 UiStyleIndex(StringView name)
	{
		for (int i < UiStyles.Count)
			if (name == StringView(UiStyles[i].name))
				return (int32)i;
		return -1;
	}
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
		mUiFocus = true;
		// The tree and properties windows come back with the document, docked beside the Hierarchy and the Inspector.
		mShowUITree = mShowUIProps = true;
		mDockUITree = mDockUIProps = true;
		delete mUiData;
		mUiData = new UIDocumentData();
		mUiPath.Set(path);
		mUiSelected = null;
		mUiStatus.Clear();
		if (!mUiData.Load(path))
			mUiStatus.Set("Could not read the file.");
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

	bool UiAttribute(char8* label, UIElement element, StringView name, char8* hint = null)
	{
		let value = scope String(element.attributes.Get(name));
		BeginProperty(label);
		ImGui.PushID(label);
		let changed = ImGui.InputText("##a", value);
		ImGui.PopID();
		if (hint != null && ImGui.IsItemHovered())
			ImGui.SetTooltip(hint);
		if (changed)
		{
			if (value.IsEmpty)
				element.attributes.Remove(name);
			else
				element.attributes.Set(name, value);
		}
		return changed;
	}

	/// An attribute that names a picture: a text field with a "..." picker that lists the project's images.
	bool UiAssetAttribute(char8* label, UIElement element, StringView name, char8* hint = null)
	{
		BeginProperty(label);
		let path = scope String(element.attributes.Get(name));
		let changed = DrawAssetPicker(path, "texture");
		if (hint != null && ImGui.IsItemHovered())
			ImGui.SetTooltip(hint);
		if (changed)
		{
			if (path.IsEmpty)
				element.attributes.Remove(name);
			else
				element.attributes.Set(name, path);
		}
		return changed;
	}

	void DrawUIEditor()
	{
		mUiPreviewVisible = false;
		if (!mShowUI)
			return;
		if (mUiData != null && mUiView == null)
			mUiView = new RenderView((uint16)(10 + RenderView.ViewCount * 2));
		DrawUiPreviewWindow();
		if (mUiData == null || mUiData.root == null)
			return;
		DrawUiTreeWindow();
		DrawUiPropertiesWindow();
	}

	/// The editor's main window: the document over the scene, drawn as large as the tabs beside the Scene view allow.
	void DrawUiPreviewWindow()
	{
		if (mDockUI && mAssetCenterDock != 0)
		{
			ImGui.SetNextWindowDockID(mAssetCenterDock);
			mDockUI = false;
		}
		// A double-clicked .tui brings the window to the front once it is up (a few frames after it docks).
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
			{
				DrawUiToolbar();
				DrawUiPreview();
			}
		}
		ImGui.End();
	}

	/// The components that can be added and the document's elements, in a window of its own: a tab after the
	/// Hierarchy, so the Hierarchy stays in front until the tree is clicked.
	void DrawUiTreeWindow()
	{
		if (!mShowUITree)
			return;
		if (mDockUITree && mHierarchyDock != 0)
		{
			ImGui.SetNextWindowDockID(mHierarchyDock);
			mDockUITree = false;
		}
		if (ImGui.Begin("UI Elements", &mShowUITree))
			DrawUiElementTree();
		ImGui.End();
	}

	/// The selected element's tag, text, events and style, docked after the Inspector for the same reason.
	void DrawUiPropertiesWindow()
	{
		if (!mShowUIProps)
			return;
		if (mDockUIProps && mInspectorDock != 0)
		{
			ImGui.SetNextWindowDockID(mInspectorDock);
			mDockUIProps = false;
		}
		if (ImGui.Begin("UI Properties", &mShowUIProps))
		{
			if (mUiSelected == null)
			{
				ImGui.TextWrapped("Click an element in the preview or the tree to edit it.");
				ImGui.Spacing();
				DrawUiStylesheet();
			}
			else
				DrawUiProperties(mUiSelected);
		}
		ImGui.End();
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
		// The scene from the game camera behind the document, so the preview shows how the interface sits over the
		// game (the same render the Game view makes, at the aspect the document is laid out for).
		ImGui.DrawRectFilled(origin, .(origin.x + viewW, origin.y + viewH), .(0.16f, 0.19f, 0.23f, 1));
		let gameCamera = FindGameCamera();
		if (gameCamera)
		{
			mUiPreviewVisible = true;
			mUiPreviewRenderSize = .(viewW, viewH);
			mUiPreviewAspect = designW / designH;
			if (mUiView != null && mUiView.Width > 0)
				ImGui.DrawPicture(mUiView.OutputTexture, origin, .(origin.x + viewW, origin.y + viewH));
		}
		ImGui.DrawRect(.(origin.x - 1, origin.y - 1), .(origin.x + viewW + 1, origin.y + viewH + 1), .(0.35f, 0.4f, 0.47f, 1));
		mUiData.scale = scale;
		mUiData.Layout(designW, designH);
		ImGui.PushClipRect(origin, .(origin.x + viewW, origin.y + viewH));
		mUiData.Draw(origin, null, false);
		ImGui.PopClipRect();
		// On-screen editing: click selects, dragging the selection moves it, dragging its corner handle resizes it.
		let mouse = ImGui.GetMousePos();
		if (previewHovered)
		{
			// The resize handle sticks out past the element's corner, so it is tested before selecting.
			bool handleClicked = mUiSelected != null && UiHandleHovered(mUiSelected, mouse, origin, scale) && ImGui.IsMouseClicked(0);
			if (handleClicked)
			{
				mUiResizingElement = true;
				mUiMovingElement = false;
				mUiEditMouse = mouse;
				mUiEditW = mUiSelected.width;
				mUiEditH = mUiSelected.height;
			}
			else if (ImGui.IsMouseClicked(0))
			{
				var picked = PickUiElement(mUiData.root, (mouse.x - origin.x) / scale, (mouse.y - origin.y) / scale);
				if (picked == mUiData.root)
					picked = null;
				if (picked != null && picked == mUiSelected)
				{
					// Clicking the already-selected element starts moving it.
					mUiMovingElement = true;
					mUiEditMouse = mouse;
					mUiEditX = mUiSelected.x;
					mUiEditY = mUiSelected.y;
				}
				else
					mUiSelected = picked;
			}
		}
		// Apply a move or resize while its mouse button is held, and finish when it is released.
		if (mUiResizingElement || mUiMovingElement)
		{
			if (!ImGui.IsMouseDown(0))
				mUiResizingElement = mUiMovingElement = false;
			else if (mUiResizingElement)
			{
				let w = Math.Max(mUiEditW + (mouse.x - mUiEditMouse.x) / scale, 8);
				let h = Math.Max(mUiEditH + (mouse.y - mUiEditMouse.y) / scale, 8);
				UiSetStyleNumber(mUiSelected, "width", w);
				UiSetStyleNumber(mUiSelected, "height", h);
			}
			else
			{
				var x = Math.Max(mUiEditX + (mouse.x - mUiEditMouse.x) / scale, 0);
				var y = Math.Max(mUiEditY + (mouse.y - mUiEditMouse.y) / scale, 0);
				mUiSelected.style.Set("position", "absolute");
				bool snappedX = false, snappedY = false;
				float guideX = 0, guideY = 0;
				UiSnapMove(mUiSelected, mUiSelected.parent ?? mUiData.root, designW, designH, ref x, ref y, ref snappedX, ref snappedY, ref guideX, ref guideY);
				UiSetStyleNumber(mUiSelected, "left", x);
				UiSetStyleNumber(mUiSelected, "top", y);
				// Guide lines where the element snapped to a centre, an edge or another element.
				if (snappedX)
					ImGui.DrawRect(.(origin.x + guideX * scale, origin.y), .(origin.x + guideX * scale + 1, origin.y + viewH), .(1.0f, 0.4f, 0.9f, 1));
				if (snappedY)
					ImGui.DrawRect(.(origin.x, origin.y + guideY * scale), .(origin.x + viewW, origin.y + guideY * scale + 1), .(1.0f, 0.4f, 0.9f, 1));
			}
		}
		if (mUiSelected != null)
		{
			let min = ImGui.Vec2(origin.x + mUiSelected.x * scale, origin.y + mUiSelected.y * scale);
			let max = ImGui.Vec2(min.x + mUiSelected.width * scale, min.y + mUiSelected.height * scale);
			ImGui.DrawRect(min, max, .(1.0f, 0.62f, 0.15f, 1), 0, 2);
			// The corner handle for resizing.
			let hh = 6.0f;
			ImGui.DrawRectFilled(.(max.x - hh, max.y - hh), .(max.x + hh, max.y + hh), .(1.0f, 0.62f, 0.15f, 1));
		}
	}

	/// Whether the mouse is on the selected element's resize handle (its bottom-right corner, drawn a little outside).
	bool UiHandleHovered(UIElement element, ImGui.Vec2 mouse, ImGui.Vec2 origin, float scale)
	{
		let hx = origin.x + (element.x + element.width) * scale;
		let hy = origin.y + (element.y + element.height) * scale;
		let hh = 6.0f;
		return mouse.x >= hx - hh && mouse.x <= hx + hh && mouse.y >= hy - hh && mouse.y <= hy + hh;
	}

	/// Writes a style value as a whole number (or a decimal when it is not whole), for on-screen dragging.
	void UiSetStyleNumber(UIElement element, StringView name, float value)
	{
		let text = scope String();
		if (value == Math.Round(value))
			text.AppendF("{}", (int32)value);
		else
			text.AppendF("{}", value);
		element.style.Set(name, text);
	}

	/// Nudges a move so the element's edges or centre line up with the whole screen's centre, its parent's edges and
	/// centre, or a sibling's edges and centre; snapTargetX/Y come back as the line the alignment happened on, for
	/// the guide lines. screenWidth/Height are the document's size (its whole view).
	void UiSnapMove(UIElement element, UIElement parent, float screenWidth, float screenHeight,
		ref float x, ref float y, ref bool snappedX, ref bool snappedY, ref float snapTargetX, ref float snapTargetY)
	{
		let threshold = 5.0f;
		let w = element.width;
		let h = element.height;
		float bestDx = 0, bestDy = 0;
		float targetX = 0, targetY = 0;
		bool haveX = false, haveY = false;

		// The whole screen's centre: the element's own centre or edges line up with the middle of the view.
		ConsiderUiSnap(screenWidth * 0.5f, x, x + w * 0.5f, x + w, ref bestDx, ref haveX, ref targetX);
		ConsiderUiSnap(screenHeight * 0.5f, y, y + h * 0.5f, y + h, ref bestDy, ref haveY, ref targetY);

		ConsiderUiSnap(0, x, x + w * 0.5f, x + w, ref bestDx, ref haveX, ref targetX);
		ConsiderUiSnap(parent.width * 0.5f, x, x + w * 0.5f, x + w, ref bestDx, ref haveX, ref targetX);
		ConsiderUiSnap(parent.width, x, x + w * 0.5f, x + w, ref bestDx, ref haveX, ref targetX);
		ConsiderUiSnap(0, y, y + h * 0.5f, y + h, ref bestDy, ref haveY, ref targetY);
		ConsiderUiSnap(parent.height * 0.5f, y, y + h * 0.5f, y + h, ref bestDy, ref haveY, ref targetY);
		ConsiderUiSnap(parent.height, y, y + h * 0.5f, y + h, ref bestDy, ref haveY, ref targetY);

		for (let sibling in parent.children)
		{
			if (sibling == element || sibling.computed.Get("display") == "none")
				continue;
			ConsiderUiSnap(sibling.x, x, x + w * 0.5f, x + w, ref bestDx, ref haveX, ref targetX);
			ConsiderUiSnap(sibling.x + sibling.width * 0.5f, x, x + w * 0.5f, x + w, ref bestDx, ref haveX, ref targetX);
			ConsiderUiSnap(sibling.x + sibling.width, x, x + w * 0.5f, x + w, ref bestDx, ref haveX, ref targetX);
			ConsiderUiSnap(sibling.y, y, y + h * 0.5f, y + h, ref bestDy, ref haveY, ref targetY);
			ConsiderUiSnap(sibling.y + sibling.height * 0.5f, y, y + h * 0.5f, y + h, ref bestDy, ref haveY, ref targetY);
			ConsiderUiSnap(sibling.y + sibling.height, y, y + h * 0.5f, y + h, ref bestDy, ref haveY, ref targetY);
		}

		if (haveX && Math.Abs(bestDx) <= threshold)
		{
			x += bestDx;
			snappedX = true;
			snapTargetX = targetX;
		}
		if (haveY && Math.Abs(bestDy) <= threshold)
		{
			y += bestDy;
			snappedY = true;
			snapTargetY = targetY;
		}
	}

	/// Considers aligning one of three reference points (an element's edges/centre) to a target, keeping the smallest
	/// nudge so far in bestDelta/have (and the target it was for, in bestTarget).
	static void ConsiderUiSnap(float target, float ref0, float ref1, float ref2, ref float bestDelta, ref bool have, ref float bestTarget)
	{
		float best = target - ref0;
		if (Math.Abs(target - ref1) < Math.Abs(best))
			best = target - ref1;
		if (Math.Abs(target - ref2) < Math.Abs(best))
			best = target - ref2;
		if (!have || Math.Abs(best) < Math.Abs(bestDelta))
		{
			bestDelta = best;
			have = true;
			bestTarget = target;
		}
	}

	void DrawUiProperties(UIElement element)
	{
		// What the element is and what it wants, before the fields that fill that in.
		ImGui.TextDisabled(scope String(UiTagName(element.tag)).CStr());
		let hint = UiTagHint(element.tag);
		if (!hint.IsEmpty)
			ImGui.TextWrapped(scope String(hint).CStr());
		ImGui.Separator();

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
			UiAttribute("Id", element, "id", "Names this element so the stylesheet can style it (#name) and code can find it.");
			DrawUiClassField(element);
			UiAttribute("On Click", element, "onclick", "A method that runs when the element is clicked, e.g. OnPlay.");
			UiAttribute("On Load", element, "onload", "A method that runs when the document opens, e.g. OnOpen.");
			if (element.tag != "panel" && element.tag != "button")
				UiAttribute("Bind", element, "bind", "A field this element shows or edits, e.g. Health.");
			if (element.tag == "image")
				UiAssetAttribute("Source", element, "src", "A picture in your assets (e.g. icon.png). The preview shows a placeholder until one is set.");
			if (element.tag == "slider")
			{
				UiAttribute("Min", element, "min", "The value at the left of the slider.");
				UiAttribute("Max", element, "max", "The value at the right of the slider.");
				UiAttribute("Step", element, "step", "How much a drag moves the value (0 drags smoothly).");
				UiAssetAttribute("Track Picture", element, "track-src", "A picture for the track, instead of the drawn bar.");
				UiAssetAttribute("Fill Picture", element, "fill-src", "A picture for the filled part of the track.");
				UiAssetAttribute("Thumb Picture", element, "thumb-src", "A picture for the handle.");
			}
			if (element.tag == "canvas")
			{
				UiAttribute("On Draw", element, "ondraw", "A method that draws the canvas every frame, e.g. OnDrawMap.");
				UiAttribute("Preview Name", element, "preview", "What this panel shows here in place of the game's drawing. Not used while the game runs.");
				UiAssetAttribute("Preview Picture", element, "preview-src", "A picture shown here in place of the game's drawing, such as a screenshot. Not used while the game runs.");
			}
			ImGui.EndTable();
		}

		ImGui.SeparatorText("Style");
		DrawUiStyleList(element);
		DrawUiComputedStyles(element);

		ImGui.SeparatorText("Element");
		DrawUiElementButtons(element);
	}

	/// The element's own style="..." declarations, each with an editor suited to its kind, and the properties left
	/// to add.
	void DrawUiStyleList(UIElement element)
	{
		String remove = null;
		if (BeginPropertyTable("style"))
		{
			for (let item in element.style.items)
			{
				let styleIndex = UiStyleIndex(item.key);
				BeginProperty(item.key.CStr());
				if (styleIndex >= 0 && ImGui.IsItemHovered())
					ImGui.SetTooltip(UiStyles[styleIndex].hint);
				ImGui.PushID(item.key.CStr());
				ImGui.SetNextItemWidth(-26);
				UiStyleValueEdit(item.key, item.value);
				ImGui.SameLine();
				if (ImGui.SmallButton("x"))
					remove = item.key;
				ImGui.PopID();
			}
			ImGui.EndTable();
		}
		if (remove != null)
			element.style.Remove(scope String(remove));

		// Adding a property starts from what it computes to (from the stylesheet or the tag), so an override edits
		// the live value rather than a guess.
		ImGui.SetNextItemWidth(-1);
		if (ImGui.BeginCombo("##addstyle", "Add style property..."))
		{
			for (int i < UiStyles.Count)
			{
				if (element.style.Has(StringView(UiStyles[i].name)))
					continue;
				let label = scope String()..AppendF("{}  [{}]", StringView(UiStyles[i].name), StringView(UiStyles[i].kind));
				if (ImGui.Selectable(label.CStr()))
				{
					let current = scope String(element.computed.Get(StringView(UiStyles[i].name)));
					element.style.Set(StringView(UiStyles[i].name), current.IsEmpty ? StringView(UiStyles[i].fallback) : (StringView)current);
				}
				if (ImGui.IsItemHovered())
					ImGui.SetTooltip(UiStyles[i].hint);
			}
			ImGui.EndCombo();
		}
		ImGui.TextDisabled("Values from the stylesheet apply unless overridden here.");
	}

	/// The Move / Duplicate / Delete buttons and a dock-to-parent list, in the Element section.
	void DrawUiElementButtons(UIElement element)
	{
		let parent = element.parent;
		let index = parent != null ? parent.children.IndexOf(element) : -1;

		// Dock pins the element to an edge or corner of its parent, the way a game HUD anchors its pieces.
		ImGui.SetNextItemWidth(-1);
		if (ImGui.BeginCombo("##dock", "Dock to parent..."))
		{
			UiDockChoice(element, "top-left", "Top Left");
			UiDockChoice(element, "top-right", "Top Right");
			UiDockChoice(element, "bottom-left", "Bottom Left");
			UiDockChoice(element, "bottom-right", "Bottom Right");
			UiDockChoice(element, "center", "Center");
			UiDockChoice(element, "stretch-h", "Stretch Horizontally");
			UiDockChoice(element, "stretch-v", "Stretch Vertically");
			UiDockChoice(element, "fill", "Fill Parent");
			ImGui.EndCombo();
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Pin the element to an edge or corner of its parent (position: absolute with left/right/top/bottom).");

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
		ImGui.BeginDisabled(parent == null);
		if (ImGui.Button("Duplicate") && parent != null)
		{
			let copy = element.Clone();
			copy.parent = parent;
			parent.children.Insert(index + 1, copy);
			mUiSelected = copy;
		}
		ImGui.EndDisabled();
		ImGui.SameLine();
		ImGui.BeginDisabled(parent == null);
		if (ImGui.Button("Delete") && parent != null)
		{
			parent.children.Remove(element);
			delete element;
			mUiSelected = null;
		}
		ImGui.EndDisabled();
	}

	/// One entry in the dock list.
	void UiDockChoice(UIElement element, StringView edge, char8* label)
	{
		if (ImGui.Selectable(label))
			UiDockElement(element, edge);
	}

	/// Pins the element to an edge or corner of its parent by setting position: absolute and the edge pins.
	void UiDockElement(UIElement element, StringView edge)
	{
		element.style.Remove("left");
		element.style.Remove("right");
		element.style.Remove("top");
		element.style.Remove("bottom");
		element.style.Set("position", "absolute");
		if (edge == "top-left")
		{
			element.style.Set("left", "0");
			element.style.Set("top", "0");
		}
		else if (edge == "top-right")
		{
			element.style.Set("right", "0");
			element.style.Set("top", "0");
		}
		else if (edge == "bottom-left")
		{
			element.style.Set("left", "0");
			element.style.Set("bottom", "0");
		}
		else if (edge == "bottom-right")
		{
			element.style.Set("right", "0");
			element.style.Set("bottom", "0");
		}
		else if (edge == "center")
		{
			let parent = element.parent ?? mUiData.root;
			UiSetStyleNumber(element, "left", Math.Max((parent.width - element.width) * 0.5f, 0));
			UiSetStyleNumber(element, "top", Math.Max((parent.height - element.height) * 0.5f, 0));
		}
		else if (edge == "stretch-h")
		{
			element.style.Set("left", "0");
			element.style.Set("right", "0");
		}
		else if (edge == "stretch-v")
		{
			element.style.Set("top", "0");
			element.style.Set("bottom", "0");
		}
		else if (edge == "fill")
		{
			element.style.Set("left", "0");
			element.style.Set("right", "0");
			element.style.Set("top", "0");
			element.style.Set("bottom", "0");
		}
	}

	/// A read-only list of everything the element ends up with, so its styles can be read at a glance.
	void DrawUiComputedStyles(UIElement element)
	{
		if (!ImGui.TreeNode("Computed styles"))
			return;
		ImGui.TextDisabled("What the element ends up with, from the stylesheet, its tag and its inline style.");
		for (let item in element.computed.items)
			ImGui.BulletText(scope String()..AppendF("{}: {}", item.key, item.value).CStr());
		ImGui.TreePop();
	}

	/// The Class attribute, plus a list of the classes the stylesheet defines so one can be added in one click.
	void DrawUiClassField(UIElement element)
	{
		BeginProperty("Class");
		var text = scope String(element.attributes.Get("class"));
		ImGui.PushID("class");
		ImGui.SetNextItemWidth(-1);
		bool changed = ImGui.InputText("##v", text);
		ImGui.PopID();
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("One or more classes, separated by spaces, that the stylesheet styles.");
		if (changed)
		{
			if (text.IsEmpty)
				element.attributes.Remove("class");
			else
				element.attributes.Set("class", text);
		}

		BeginProperty("Add class");
		ImGui.SetNextItemWidth(-1);
		if (ImGui.BeginCombo("##addclass", "Add a class..."))
		{
			bool any = false;
			for (int i < mUiData.StyleRuleCount)
			{
				var selector = mUiData.StyleRuleSelector(i);
				if (!selector.StartsWith('.') || selector.Length <= 1 || selector.Contains(' ') || selector.Contains(','))
					continue;
				var name = selector.Substring(1);
				if (element.HasClass(name))
					continue;
				// A class styled in two rules (a @media block and the default) is offered once.
				bool offered = false;
				for (int j < i)
				{
					var earlier = mUiData.StyleRuleSelector(j);
					if (earlier.StartsWith('.') && earlier.Substring(1) == name)
						offered = true;
				}
				if (offered)
					continue;
				any = true;
				let summary = scope String();
				UiClassSummary(name, summary);
				if (ImGui.Selectable(scope String()..AppendF(".{}", name).CStr()))
					element.SetClass(name, true);
				if (!summary.IsEmpty && ImGui.IsItemHovered())
					ImGui.SetTooltip(summary.CStr());
			}
			if (!any)
				ImGui.TextDisabled("The stylesheet defines no classes yet.");
			ImGui.EndCombo();
		}
	}

	/// The stylesheet's rules, shown when nothing is selected so a document's classes and styles can be read.
	void DrawUiStylesheet()
	{
		ImGui.TextDisabled("Stylesheet");
		ImGui.Separator();
		if (mUiData.StyleRuleCount == 0)
		{
			ImGui.TextWrapped("No rules yet. Write a <style> block (or use Open CSS) to define classes like .card { background-color: #1b2028f2 }, then add them to elements with Class.");
			return;
		}
		for (int i < mUiData.StyleRuleCount)
		{
			var selector = mUiData.StyleRuleSelector(i);
			var media = mUiData.StyleRuleMedia(i);
			let props = mUiData.StyleRuleProps(i);
			let label = scope String(selector);
			if (!media.IsEmpty)
				label.AppendF("   [{}]", media);
			if (ImGui.TreeNode(label.CStr()))
			{
				if (props == null || props.items.IsEmpty)
					ImGui.TextDisabled("(no properties)");
				if (props != null)
					for (let p in props.items)
						ImGui.BulletText(scope String()..AppendF("{}: {}", p.key, p.value).CStr());
				ImGui.TreePop();
			}
		}
	}

	/// The properties one stylesheet rule for a class declares, as "name: value; ..." for a tooltip.
	void UiClassSummary(StringView className, String into)
	{
		into.Clear();
		bool any = false;
		for (int i < mUiData.StyleRuleCount)
		{
			var selector = mUiData.StyleRuleSelector(i);
			if (selector.StartsWith('.') && selector.Substring(1) == className)
			{
				let props = mUiData.StyleRuleProps(i);
				if (props != null)
					for (let p in props.items)
					{
						if (any)
							into.Append("; ");
						into.AppendF("{}: {}", p.key, p.value);
						any = true;
					}
			}
		}
	}

	/// The editor for one style value, chosen by the property's kind.
	bool UiStyleValueEdit(StringView name, String value)
	{
		let styleIndex = UiStyleIndex(name);
		if (styleIndex >= 0)
		{
			let kind = StringView(UiStyles[styleIndex].kind);
			if (kind == "color")
				return UiColorEdit(name, value);
			if (kind == "choice")
				return UiChoiceEdit(name, value, StringView(UiStyles[styleIndex].options));
			if (kind == "number")
				return UiNumberEdit(name, value);
		}
		ImGui.SetNextItemWidth(-1);
		return ImGui.InputText(scope String()..AppendF("##text{}", name).CStr(), value);
	}

	/// A colour style value: the inspector's colour picker behind a swatch, with the raw CSS value beside it for
	/// exact entry (a hex code, rgb(), or a name like "red").
	bool UiColorEdit(StringView name, String value)
	{
		bool changed = false;
		Color color;
		UIElement.ParseColor(value, out color);
		ImGui.SetNextItemWidth(22);
		if (ImGui.ColorEdit4(scope String()..AppendF("##sw{}", name).CStr(), ref color, ImGui.ColorFlags.NoInputs | ImGui.ColorFlags.NoLabel | ImGui.ColorFlags.AlphaBar | ImGui.ColorFlags.Float))
		{
			UiWriteColorText(color, value);
			changed = true;
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Choose a colour");
		ImGui.SameLine();
		ImGui.SetNextItemWidth(-24);
		if (ImGui.InputText(scope String()..AppendF("##raw{}", name).CStr(), value))
			changed = true;
		return changed;
	}

	/// A style value chosen from a list. "(default)" removes the override so the stylesheet's value shows again.
	bool UiChoiceEdit(StringView name, String value, StringView options)
	{
		bool changed = false;
		let current = scope String(value);
		ImGui.SetNextItemWidth(-1);
		if (ImGui.BeginCombo(scope String()..AppendF("##choice{}", name).CStr(), current.IsEmpty ? "(default)" : current.CStr()))
		{
			if (ImGui.Selectable("(default)", value.IsEmpty))
			{
				value.Clear();
				changed = true;
			}
			for (var option in options.Split('|', .RemoveEmptyEntries))
			{
				let opt = scope String(option);
				if (ImGui.Selectable(opt.CStr(), value == option))
				{
					value.Set(option);
					changed = true;
				}
			}
			ImGui.EndCombo();
		}
		return changed;
	}

	/// A number-like style: dragged to nudge it (click the value to type), keeping any px/% unit. Anything that is
	/// not a plain number ("auto", "8 16") falls back to a text box.
	bool UiNumberEdit(StringView name, String value)
	{
		var suffix = scope String();
		var text = scope String(value);
		if (text.EndsWith("px")) { text.RemoveFromEnd(2); suffix.Set("px"); }
		else if (text.EndsWith("%")) { text.RemoveFromEnd(1); suffix.Set("%"); }
		float number = 0;
		bool numeric = false;
		if (!text.IsEmpty && float.Parse(text) case .Ok(let parsed))
		{
			number = parsed;
			numeric = true;
		}
		if (!numeric)
		{
			ImGui.SetNextItemWidth(-1);
			return ImGui.InputText(scope String()..AppendF("##num{}", name).CStr(), value);
		}
		ImGui.SetNextItemWidth(-1);
		char8* fmt = number == Math.Round(number) ? "%.0f" : "%.2f";
		if (ImGui.DragFloat(scope String()..AppendF("##num{}", name).CStr(), ref number, 1.0f, 0, 0, fmt))
		{
			let into = scope String();
			if (number == Math.Round(number))
				into.AppendF("{}{}", (int32)number, suffix);
			else
				into.AppendF("{}{}", number, suffix);
			value.Set(into);
			return true;
		}
		return false;
	}

	static char8 UiHexDigit(int32 value) => (char8)(value < 10 ? '0' + value : 'a' + value - 10);

	static void UiAppendHex(String into, int32 value)
	{
		let v = Math.Clamp(value, 0, 255);
		into.Append(UiHexDigit(v >> 4));
		into.Append(UiHexDigit(v & 15));
	}

	/// Writes a colour as CSS: #rrggbb, with alpha added only when it is not fully opaque.
	static void UiWriteColorText(Color color, String into)
	{
		into.Clear();
		into.Append('#');
		UiAppendHex(into, (int32)Math.Round(color.r * 255));
		UiAppendHex(into, (int32)Math.Round(color.g * 255));
		UiAppendHex(into, (int32)Math.Round(color.b * 255));
		if (color.a < 0.999f)
			UiAppendHex(into, (int32)Math.Round(color.a * 255));
	}

}
