using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// The game's editor scripts (C# in any folder named Editor under src/; Tallow.Build compiles them into
/// Tallow.Game.Editor, which no game build has): custom Inspectors, editor windows and Tools menu commands, written
/// against Managed/Tallow.Editor. They are loaded after every successful compile, into a context of their own, so
/// they work in Edit mode and during Play alike. Their widgets are drawn here, with the editor's ImGui.
extension EditorApp
{
	/// The functions editor scripts call (Tallow.Editor's EditorHost.HostTable, in the same order).
	[CRepr]
	struct EditorHostTable
	{
		public int32 version;
		public int32 size;
		public function void(int32, char8*, int32) log;
		public function void(int32, char8*, int32) text;
		public function int32(char8*, int32, float, float) button;
		public function int32(char8*, int32, int32*) toggle;
		public function int32(char8*, int32, float*, float, float, float, int32) floatField;
		public function int32(char8*, int32, int32*, float, int32, int32) intField;
		public function int32(char8*, int32, float*, int32) vectorField;
		public function int32(char8*, int32, char8*, int32, int32, char8**, int32*) textField;
		public function int32(char8*, int32, char8*, int32, int32*) popup;
		public function int32(char8*, int32, int32) foldout;
		public function void(int32, int32) layout;
		public function void(float, char8*, int32) progress;
		public function void(char8*, int32) tooltip;
		public function int32(char8*, int32) targetField;
		public function int32() targetDefault;
		public function int32(char8*, int32, char8**, int32*) targetRead;
		public function int32(char8*, int32, char8*, int32) targetWrite;
		public function int32(int32, char8**, int32*) query;
		// The open scene, for editor scripts that edit in Edit mode (ids are GameObject.Id; 0 means none).
		public function uint32() selectedObject;
		public function void(uint32) selectObject;
		public function uint32(char8*, int32) findObject;
		public function uint32(uint32) objectParent;
		public function uint32(uint32) objectChildCount;
		public function uint32(uint32, int32) objectChild;
		public function int32(uint32, char8**, int32*) objectName;
		public function int32(uint32, char8*, int32) renameObject;
		public function uint32(char8*, int32, uint32) createObject;
		public function uint32(uint32) duplicateObject;
		public function void(uint32) deleteObject;
		public function int32(uint32, float*) objectPosition;
		public function int32(uint32, float, float, float) setObjectPosition;
		public function int32(uint32, float*) objectRotation;
		public function int32(uint32, float, float, float) setObjectRotation;
		public function int32(uint32, float*) objectScale;
		public function int32(uint32, float, float, float) setObjectScale;
		public function int32(uint32) componentCount;
		public function int32(uint32, int32, char8**, int32*) componentType;
		public function int32(uint32, char8*, int32) addComponent;
		public function int32(uint32, char8*, int32) removeComponent;
		public function int32(uint32, char8*, int32, char8**, int32*) fieldList;
		public function int32(uint32, char8*, int32, char8*, int32, char8**, int32*) fieldRead;
		public function int32(uint32, char8*, int32, char8*, int32, char8*, int32) fieldWrite;
		public function void() markDirty;
		public function int32(char8*, int32) componentField;
		public function int32() componentDefault;
	}

	/// What the editor calls in them (Tallow.Editor's EditorHost.ManagedTable).
	[CRepr]
	struct EditorManagedTable
	{
		public function int32(char8*) load;
		public function int32() unload;
		public function int32(int32, int32, char8*, int32) describe;
		public function int32(char8*) findInspector;
		public function int32(int32, int64) drawInspector;
		public function int32(int32, int32) window;
		public function int32(int32) runMenu;
		public function int32(int32) drawPage;
		public function int32(char8*, int32) findComponentInspector;
		public function int32(int32, uint32, char8*, int32) drawComponentInspector;
	}

	class CSharpEditorWindow
	{
		public String menuPath = new .() ~ delete _;
		public String title = new .() ~ delete _;
		public bool open;
	}

	[CLink] static extern int32 tn_csharp_editor_configure(char8* editorAssembly, void* hostTable, void* managedTable);

	static EditorApp sExtensionsApp;
	static EditorManagedTable sExtensions;
	static bool sExtensionsConfigured;
	/// The script a C# Inspector is drawing (only while it draws), and whether one of its fields was edited.
	static CSharpBehaviour sInspectorTarget;
	static bool sInspectorEdited;
	/// Text the scripts read back, valid until the next call.
	static String sHostText = new .() ~ delete _;

	bool mExtensionsLoaded;
	List<CSharpEditorWindow> mExtensionWindows = new .() ~ DeleteContainerAndItems!(_);
	List<String> mExtensionMenus = new .() ~ DeleteContainerAndItems!(_);
	/// The editor scripts' Preferences tabs (titles), after the editor's own.
	List<String> mExtensionPages = new .() ~ DeleteContainerAndItems!(_);
	/// Script class -> its Inspector's index (-1: none), asked of the scripts once per class and load.
	Dictionary<String, int32> mExtensionInspectors = new .() ~ DeleteDictionaryAndKeys!(_);
	/// Windows open when the editor last closed (from the open-windows file), opened once the scripts have loaded.
	List<String> mExtensionWindowsToOpen = new .() ~ DeleteContainerAndItems!(_);
	bool mExtensionWindowsChanged;

	/// After a successful compile: the editor scripts as just built, or none when the game has none (.NET is not
	/// started for a game without them).
	void ReloadEditorExtensions()
	{
		let project = Project.Current;
		let bin = scope $"{project.Path}/.tallow-csharp/bin";
		let built = File.Exists(scope $"{bin}/Tallow.Game.Editor/Tallow.Game.Editor.dll");
		if (!built && !mExtensionsLoaded)
			return;
		// What was open stays open across the reload.
		for (let window in mExtensionWindows)
			if (window.open)
				mExtensionWindowsToOpen.Add(new String(window.menuPath));
		UnloadEditorExtensions();
		if (!built || !ConfigureEditorExtensions())
			return;
		let count = sExtensions.load(bin.CStr());
		if (count < 0)
			return;
		mExtensionsLoaded = true;
		let buffer = scope String();
		for (int32 index = 0; ; index++)
		{
			if (!DescribeExtension(1, index, buffer))
				break;
			let tab = buffer.IndexOf('\t');
			let window = new CSharpEditorWindow();
			window.menuPath.Set(buffer.Substring(0, tab));
			window.title.Set(buffer.Substring(tab + 1));
			for (let name in mExtensionWindowsToOpen)
				window.open |= name == window.menuPath;
			mExtensionWindows.Add(window);
		}
		ClearAndDeleteItems!(mExtensionWindowsToOpen);
		for (int32 index = 0; ; index++)
		{
			if (!DescribeExtension(2, index, buffer))
				break;
			mExtensionMenus.Add(new String(buffer));
		}
		for (int32 index = 0; ; index++)
		{
			if (!DescribeExtension(3, index, buffer))
				break;
			mExtensionPages.Add(new String(buffer));
		}
	}

	static bool DescribeExtension(int32 kind, int32 index, String output)
	{
		output.Clear();
		let needed = sExtensions.describe(kind, index, null, 0);
		if (needed < 0)
			return false;
		let buffer = scope char8[needed + 1];
		sExtensions.describe(kind, index, buffer.Ptr, needed + 1);
		output.Append(buffer.Ptr, needed);
		return true;
	}

	void UnloadEditorExtensions()
	{
		if (mExtensionsLoaded)
		{
			sExtensions.unload();
			mExtensionsLoaded = false;
		}
		ClearAndDeleteItems!(mExtensionWindows);
		ClearAndDeleteItems!(mExtensionMenus);
		ClearAndDeleteItems!(mExtensionPages);
		for (let key in mExtensionInspectors.Keys)
			delete key;
		mExtensionInspectors.Clear();
	}

	/// Starts .NET when it is not running (Play starts it too, and it stays) and hands Tallow.Editor the editor's
	/// functions, once.
	bool ConfigureEditorExtensions()
	{
		if (sExtensionsConfigured)
			return true;
		let engine = Project.Current.EngineRoot;
		let runtimeFolder = scope $"{engine}/Managed/Tallow.ManagedRuntime/bin/Debug/net11.0";
		let editorApi = scope $"{engine}/Managed/Tallow.Editor/bin/Debug/net11.0/Tallow.Editor.dll";
		if (!File.Exists(editorApi))
		{
			Log.Error(scope $"The editor scripts cannot load: {editorApi} is missing. Compile the C# project again.");
			return false;
		}
		if (!CSharpRuntime.Initialize(scope $"{runtimeFolder}/Tallow.ManagedRuntime.runtimeconfig.json", scope $"{runtimeFolder}/Tallow.ManagedRuntime.dll"))
			return false;
		EditorHostTable host = .()
		{
			version = 3,
			size = sizeof(EditorHostTable),
			log = => HostLog,
			text = => HostText,
			button = => HostButton,
			toggle = => HostToggle,
			floatField = => HostFloat,
			intField = => HostInt,
			vectorField = => HostVector,
			textField = => HostTextField,
			popup = => HostPopup,
			foldout = => HostFoldout,
			layout = => HostLayout,
			progress = => HostProgress,
			tooltip = => HostTooltip,
			targetField = => HostTargetField,
			targetDefault = => HostTargetDefault,
			targetRead = => HostTargetRead,
			targetWrite = => HostTargetWrite,
			query = => HostQuery,
			selectedObject = => HostSelectedObject,
			selectObject = => HostSelectObject,
			findObject = => HostFindObject,
			objectParent = => HostObjectParent,
			objectChildCount = => HostObjectChildCount,
			objectChild = => HostObjectChild,
			objectName = => HostObjectName,
			renameObject = => HostRenameObject,
			createObject = => HostCreateObject,
			duplicateObject = => HostDuplicateObject,
			deleteObject = => HostDeleteObject,
			objectPosition = => HostObjectPosition,
			setObjectPosition = => HostSetObjectPosition,
			objectRotation = => HostObjectRotation,
			setObjectRotation = => HostSetObjectRotation,
			objectScale = => HostObjectScale,
			setObjectScale = => HostSetObjectScale,
			componentCount = => HostComponentCount,
			componentType = => HostComponentType,
			addComponent = => HostAddComponent,
			removeComponent = => HostRemoveComponent,
			fieldList = => HostFieldList,
			fieldRead = => HostFieldRead,
			fieldWrite = => HostFieldWrite,
			markDirty = => HostMarkDirty,
			componentField = => HostComponentField,
			componentDefault = => HostComponentDefault
		};
		if (tn_csharp_editor_configure(editorApi.CStr(), &host, &sExtensions) == 0)
		{
			Log.Error(scope $"The editor scripts cannot load: {StringView(CSharpRuntime.[Friend]tn_csharp_error())}");
			return false;
		}
		sExtensionsApp = this;
		sExtensionsConfigured = true;
		return true;
	}

	/// The Inspector for a script class, -1 for none.
	int32 FindExtensionInspector(StringView scriptType)
	{
		if (!mExtensionsLoaded || scriptType.IsEmpty)
			return -1;
		if (mExtensionInspectors.TryGetAlt(scriptType, ?, let found))
			return found;
		let name = new String(scriptType);
		let index = sExtensions.findInspector(name.CStr());
		mExtensionInspectors[name] = index;
		return index;
	}

	/// A C# script's fields: its custom Inspector when it has one, else the field list. True when one was edited.
	bool DrawManagedSection(CSharpBehaviour component)
	{
		let index = FindExtensionInspector(component.scriptType);
		if (index < 0)
			return DrawManagedFields(component);
		sInspectorTarget = component;
		sInspectorEdited = false;
		ImGui.PushID(scope $"csharpinspector{index}".CStr());
		let result = sExtensions.drawInspector(index, (int64)(int)Internal.UnsafeCastToPtr(component));
		ImGui.PopID();
		sInspectorTarget = null;
		var edited = sInspectorEdited;
		if (result < 0)
		{
			// Still editable: the plain fields, under what went wrong.
			ImGui.PushTextWrapPos(0);
			ImGui.TextColored(EditorTheme.Error, "This script's C# Inspector failed (see Console). Its fields:");
			ImGui.PopTextWrapPos();
			edited |= DrawManagedFields(component);
		}
		return edited;
	}

	/// The C# Inspector for a built-in component ("Tallow.Light"), -1 for none.
	int32 FindExtensionComponentInspector(StringView componentType)
	{
		if (!mExtensionsLoaded || componentType.IsEmpty)
			return -1;
		let name = scope String(componentType);
		return sExtensions.findComponentInspector(name.CStr(), (int32)name.Length);
	}

	/// The component a C# Inspector is drawing (only while it draws), and whether it edited anything.
	static uint32 sInspectorComponentObject;
	static String sInspectorComponentType = new .() ~ delete _;
	static bool sInspectorComponentDrawing;
	static bool sInspectorComponentEdited;

	/// A built-in component's section, drawn by its C# Inspector instead of the field list. True when it edited
	/// something (the caller marks the scene dirty and runs the component's OnValidate on it).
	bool DrawManagedComponentSection(GameObject gameObject, int32 inspectorIndex, StringView componentType,
		List<FieldRef> fields)
	{
		sInspectorComponentObject = gameObject.Id;
		sInspectorComponentType.Set(componentType);
		sInspectorComponentDrawing = true;
		sInspectorComponentEdited = false;
		ImGui.PushID(scope $"csharpcomponent{inspectorIndex}:{gameObject.Id}".CStr());
		let name = scope String(componentType);
		let result = sExtensions.drawComponentInspector(inspectorIndex, gameObject.Id, name.CStr(), (int32)name.Length);
		ImGui.PopID();
		sInspectorComponentDrawing = false;
		var edited = sInspectorComponentEdited;
		if (result < 0)
		{
			// Still editable: the plain fields, under what went wrong.
			ImGui.PushTextWrapPos(0);
			ImGui.TextColored(EditorTheme.Error, "This component's C# Inspector failed (see Console). Its fields:");
			ImGui.PopTextWrapPos();
			edited |= sExtensionsApp.DrawFieldList(fields, "fields");
		}
		return edited;
	}

	/// Preferences tab index of the editor scripts.
	void DrawExtensionPage(int index)
	{
		if (!mExtensionsLoaded || index < 0 || index >= mExtensionPages.Count)
			return;
		ImGui.PushID(scope $"csharppage{index}".CStr());
		let result = sExtensions.drawPage((int32)index);
		ImGui.PopID();
		if (result < 0)
		{
			ImGui.PushTextWrapPos(0);
			ImGui.TextColored(EditorTheme.Error, "This page's C# code failed. See Console.");
			ImGui.PopTextWrapPos();
		}
	}

	/// The Tools menu: the editor scripts' windows and commands, in submenus by their paths.
	void DrawExtensionsMenu()
	{
		if (mExtensionWindows.Count == 0 && mExtensionMenus.Count == 0)
			return;
		if (!ImGui.BeginMenu("Tools"))
			return;
		let paths = scope List<StringView>();
		for (let window in mExtensionWindows)
			paths.Add(window.menuPath);
		for (let menu in mExtensionMenus)
			paths.Add(menu);
		DrawExtensionsSubmenu(paths, "");
		ImGui.EndMenu();
	}

	/// The items and submenus of paths under prefix ("" or "Level/"), each submenu once, in the order they come.
	void DrawExtensionsSubmenu(List<StringView> paths, StringView prefix)
	{
		let drawn = scope List<StringView>();
		for (int i < paths.Count)
		{
			let path = paths[i];
			if (!path.StartsWith(prefix))
				continue;
			let rest = path.Substring(prefix.Length);
			let slash = rest.IndexOf('/');
			if (slash < 0)
			{
				let label = scope String(rest);
				if (i < mExtensionWindows.Count)
				{
					let window = mExtensionWindows[i];
					if (ImGui.MenuItem(label.CStr(), null, window.open))
					{
						window.open = !window.open;
						mExtensionWindowsChanged = true;
						if (window.open)
							ImGui.SetWindowFocus(scope $"{window.title}###csharp:{window.menuPath}".CStr());
						else
							sExtensions.window((int32)i, 1);
					}
				}
				else if (ImGui.MenuItem(label.CStr()))
					sExtensions.runMenu((int32)(i - mExtensionWindows.Count));
				continue;
			}
			let folder = rest.Substring(0, slash);
			bool seen = false;
			for (let other in drawn)
				seen |= other == folder;
			if (seen)
				continue;
			drawn.Add(folder);
			if (ImGui.BeginMenu(scope String(folder).CStr()))
			{
				DrawExtensionsSubmenu(paths, scope $"{prefix}{folder}/");
				ImGui.EndMenu();
			}
		}
	}

	/// The open editor-script windows, each frame.
	void DrawExtensionWindows()
	{
		for (int i < mExtensionWindows.Count)
		{
			let window = mExtensionWindows[i];
			if (!window.open)
				continue;
			ImGui.SetNextWindowSize(.(420, 320), ImGui.Cond.FirstUseEver);
			if (ImGui.Begin(scope $"{window.title}###csharp:{window.menuPath}".CStr(), &window.open))
			{
				ImGui.PushID(scope $"csharpwindow{i}".CStr());
				let result = sExtensions.window((int32)i, 0);
				ImGui.PopID();
				if (result == 0)
					window.open = false;
				else if (result < 0)
				{
					ImGui.PushTextWrapPos(0);
					ImGui.TextColored(EditorTheme.Error, "This window's C# code failed. See Console.");
					ImGui.PopTextWrapPos();
				}
			}
			ImGui.End();
			if (!window.open)
			{
				sExtensions.window((int32)i, 1);
				mExtensionWindowsChanged = true;
			}
		}
	}

	/// The open editor-script windows' lines in the open-windows file ("C#: Tools path").
	void AppendOpenExtensionWindows(String text)
	{
		for (let window in mExtensionWindows)
			if (window.open)
				text.AppendF("C#: {}\n", window.menuPath);
		// Not loaded yet: what was open stays recorded.
		if (!mExtensionsLoaded)
			for (let name in mExtensionWindowsToOpen)
				text.AppendF("C#: {}\n", name);
	}

	void ReadOpenExtensionWindows(StringView text)
	{
		for (var line in text.Split('\n'))
		{
			line.Trim();
			if (line.StartsWith("C#: "))
				mExtensionWindowsToOpen.Add(new String(line.Substring(4)));
		}
	}

	// ---- The functions editor scripts call ----

	/// A label's shown part ("Speed##front" shows "Speed").
	static StringView Shown(StringView label)
	{
		let hidden = label.IndexOf("##");
		return hidden >= 0 ? label.Substring(0, hidden) : label;
	}

	/// The label on the left as in the Inspector, then the widget's id (the whole label, hidden) for a widget filling
	/// the rest of the line.
	static char8* LabelAndId(char8* label, int32 length, String id)
	{
		let text = StringView(label, length);
		let shown = Shown(text);
		id.AppendF("##{}", text);
		if (shown.IsEmpty)
		{
			ImGui.SetNextItemWidth(-1);
			return id.CStr();
		}
		ImGui.AlignTextToFramePadding();
		ImGui.Text(shown);
		ImGui.SameLine(Math.Max(ImGui.GetWindowWidth() * 0.38f, 100));
		ImGui.SetNextItemWidth(-1);
		return id.CStr();
	}

	static void HostLog(int32 level, char8* text, int32 length)
	{
		let message = StringView(text, length);
		switch (level)
		{
		case 1: Log.Warning(message);
		case 2: Log.Error(message);
		default: Log.Info(message);
		}
	}

	static void HostText(int32 style, char8* text, int32 length)
	{
		let value = scope String(StringView(text, length));
		switch (style)
		{
		case 1: ImGui.TextDisabled(value.CStr());
		case 2: ImGui.TextWrapped(value.CStr());
		case 3: ImGui.SeparatorText(value.CStr());
		case 4, 5, 6:
			ImGui.PushTextWrapPos(0);
			ImGui.TextColored(style == 4 ? EditorTheme.Info : style == 5 ? EditorTheme.Warning : EditorTheme.Error, value.CStr());
			ImGui.PopTextWrapPos();
		default: ImGui.Text(value);
		}
	}

	static int32 HostButton(char8* label, int32 length, float width, float height)
	{
		let text = scope String(StringView(label, length));
		return ImGui.Button(text.CStr(), .(width, height)) ? 1 : 0;
	}

	static int32 HostToggle(char8* label, int32 length, int32* value)
	{
		var on = *value != 0;
		let changed = ImGui.Checkbox(LabelAndId(label, length, scope .()), ref on);
		*value = on ? 1 : 0;
		return changed ? 1 : 0;
	}

	static int32 HostFloat(char8* label, int32 length, float* value, float speed, float min, float max, int32 slider)
	{
		let id = LabelAndId(label, length, scope .());
		return (slider != 0 ? ImGui.SliderFloat(id, ref *value, min, max) : ImGui.DragFloat(id, ref *value, speed, min, max)) ? 1 : 0;
	}

	static int32 HostInt(char8* label, int32 length, int32* value, float speed, int32 min, int32 max)
	{
		let changed = ImGui.DragInt(LabelAndId(label, length, scope .()), ref *value, speed, min, max);
		if (min < max)
			*value = Math.Clamp(*value, min, max);
		return changed ? 1 : 0;
	}

	static int32 HostVector(char8* label, int32 length, float* values, int32 count)
	{
		let id = LabelAndId(label, length, scope .());
		bool changed;
		switch (count)
		{
		case 2: changed = ImGui.DragFloat2(id, values, 0.05f);
		case 3: changed = ImGui.DragFloat3(id, ref *(Vector3*)values, 0.05f);
		case 4: changed = ImGui.DragFloat4(id, values, 0.05f);
		default: changed = ImGui.ColorEdit4(id, ref *(Color*)values);
		}
		return changed ? 1 : 0;
	}

	static int32 HostTextField(char8* label, int32 length, char8* text, int32 textLength, int32 multiline, char8** result, int32* resultLength)
	{
		let id = LabelAndId(label, length, scope .());
		sHostText.Set(StringView(text, textLength));
		let changed = multiline != 0
			? ImGui.InputTextMultiline(id, sHostText, .(-1, ImGui.GetFrameHeight() * 4), 0, Math.Max(4096, sHostText.Length * 2 + 1024))
			: ImGui.InputText(id, sHostText);
		*result = sHostText.Ptr;
		*resultLength = (int32)sHostText.Length;
		return changed ? 1 : 0;
	}

	static int32 HostPopup(char8* label, int32 length, char8* options, int32 optionsLength, int32* index)
	{
		let id = LabelAndId(label, length, scope .());
		let items = scope List<StringView>();
		for (let option in StringView(options, optionsLength).Split('\n'))
			items.Add(option);
		let preview = scope String();
		if (*index >= 0 && *index < items.Count)
			preview.Set(items[*index]);
		bool changed = false;
		if (ImGui.BeginCombo(id, preview.CStr()))
		{
			for (int i < items.Count)
			{
				ImGui.PushID((int32)i);
				if (ImGui.Selectable(scope String(items[i]).CStr(), i == *index))
				{
					changed = i != *index;
					*index = (int32)i;
				}
				ImGui.PopID();
			}
			ImGui.EndCombo();
		}
		return changed ? 1 : 0;
	}

	static int32 HostFoldout(char8* label, int32 length, int32 openAtFirst)
	{
		let text = scope String(StringView(label, length));
		return ImGui.CollapsingHeader(text.CStr(), openAtFirst != 0 ? ImGui.TreeFlags.DefaultOpen : 0) ? 1 : 0;
	}

	static void HostLayout(int32 op, int32 value)
	{
		switch (op)
		{
		case 0: ImGui.SameLine();
		case 1: ImGui.Separator();
		case 2: ImGui.Spacing();
		case 3: ImGui.Indent();
		case 4: ImGui.Unindent();
		case 5: ImGui.BeginDisabled(value != 0);
		case 6: ImGui.EndDisabled();
		case 7: ImGui.PushID(value);
		case 8: ImGui.PopID();
		}
	}

	static void HostProgress(float fraction, char8* text, int32 length)
	{
		let overlay = scope String(StringView(text, length));
		ImGui.ProgressBar(Math.Clamp(fraction, 0, 1), .(-1, 0), overlay.IsEmpty ? null : overlay.CStr());
	}

	static void HostTooltip(char8* text, int32 length)
	{
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip(scope String(StringView(text, length)).CStr());
	}

	static int32 HostTargetField(char8* name, int32 length)
	{
		if (sInspectorTarget == null)
			return -1;
		let field = StringView(name, length);
		if (!sExtensionsApp.HasManagedField(sInspectorTarget, field))
			return -1;
		let edited = sExtensionsApp.DrawManagedFields(sInspectorTarget, field);
		sInspectorEdited |= edited;
		return edited ? 1 : 0;
	}

	static int32 HostTargetDefault()
	{
		if (sInspectorTarget == null)
			return -1;
		let edited = sExtensionsApp.DrawManagedFields(sInspectorTarget);
		sInspectorEdited |= edited;
		return edited ? 1 : 0;
	}

	static int32 HostTargetRead(char8* name, int32 length, char8** value, int32* valueLength)
	{
		if (sInspectorTarget == null || !sExtensionsApp.ReadManagedField(sInspectorTarget, StringView(name, length), sHostText))
			return 0;
		*value = sHostText.Ptr;
		*valueLength = (int32)sHostText.Length;
		return 1;
	}

	static int32 HostTargetWrite(char8* name, int32 length, char8* value, int32 valueLength)
	{
		let field = StringView(name, length);
		if (sInspectorTarget == null || !sExtensionsApp.HasManagedField(sInspectorTarget, field) ||
			!sInspectorTarget.WriteEditorField(field, StringView(value, valueLength)))
			return 0;
		sInspectorEdited = true;
		return 1;
	}

	static int32 HostQuery(int32 what, char8** text, int32* length)
	{
		let app = sExtensionsApp;
		sHostText.Clear();
		int32 result = 0;
		switch (what)
		{
		case 0: result = app.mPlay != .Edit ? 1 : 0;
		case 1: sHostText.Set(Project.Current.Path);
		case 2:
			if (sInspectorTarget != null)
				sHostText.Set(sInspectorTarget.scriptType);
		case 3:
			if (sInspectorTarget?.GameObject != null)
				sHostText.Set(sInspectorTarget.GameObject.Name);
		case 4:
			if (let selected = app.Selected)
				sHostText.Set(selected.Name);
		case 5: RecentProjects.GetConfigFolder(sHostText);
		}
		*text = sHostText.Ptr;
		*length = (int32)sHostText.Length;
		return result;
	}

	// ---- The open scene, for editor scripts that edit it in Edit mode ----
	// Ids are GameObject.Id. Every mutation is refused during Play (the scene is the play session's then) and marks
	// the scene dirty, so the editor's snapshot undo records a Tools command as one step.

	static bool EditingScene => sExtensionsApp.mPlay == .Edit;

	static GameObject SceneObject(uint32 id) => id != 0 ? sExtensionsApp.mScene.FindById(id) : null;

	/// "Root/Child/Grandchild" from the scene root (a leading '/' is allowed), or a name anywhere in the scene.
	static GameObject FindSceneObject(StringView path)
	{
		var target = path;
		if (target.StartsWith("/"))
			target = target.Substring(1);
		if (target.IsEmpty)
			return null;
		GameObject found = null;
		Transform parent = null;
		bool atRoot = true;
		bool matched = true;
		for (let part in target.Split('/'))
		{
			if (part.IsEmpty)
			{
				matched = false;
				break;
			}
			GameObject next = null;
			if (atRoot)
			{
				for (let root in sExtensionsApp.mScene.Roots)
					if (root.Name == part) { next = root; break; }
			}
			else
			{
				for (let child in parent.Children)
					if (child.GameObject.Name == part) { next = child.GameObject; break; }
			}
			if (next == null)
			{
				matched = false;
				break;
			}
			found = next;
			parent = next.Transform;
			atRoot = false;
		}
		if (!matched || found == null)
			return target.IndexOf('/') >= 0 ? null : sExtensionsApp.mScene.Find(target);
		return found;
	}

	static uint32 HostSelectedObject() => sExtensionsApp.mSelectedId;

	static void HostSelectObject(uint32 id)
	{
		if (id != 0 && SceneObject(id) == null)
			return;
		sExtensionsApp.mSelectedId = id;
	}

	static uint32 HostFindObject(char8* path, int32 length)
	{
		let found = FindSceneObject(StringView(path, length));
		return found != null ? found.Id : 0;
	}

	static uint32 HostObjectParent(uint32 id)
	{
		let gameObject = SceneObject(id);
		if (gameObject == null || gameObject.Transform.Parent == null)
			return 0;
		return gameObject.Transform.Parent.GameObject.Id;
	}

	static uint32 HostObjectChildCount(uint32 id)
	{
		if (id == 0)
			return (uint32)sExtensionsApp.mScene.Roots.Count;
		let gameObject = SceneObject(id);
		return gameObject != null ? (uint32)gameObject.Transform.Children.Count : 0;
	}

	static uint32 HostObjectChild(uint32 id, int32 index)
	{
		if (index < 0)
			return 0;
		if (id == 0)
		{
			let roots = sExtensionsApp.mScene.Roots;
			return index < roots.Count ? roots[index].Id : 0;
		}
		let gameObject = SceneObject(id);
		if (gameObject == null || index >= gameObject.Transform.Children.Count)
			return 0;
		return gameObject.Transform.Children[index].GameObject.Id;
	}

	static int32 HostObjectName(uint32 id, char8** text, int32* length)
	{
		*text = null;
		*length = 0;
		let gameObject = SceneObject(id);
		if (gameObject == null)
			return 0;
		sHostText.Set(gameObject.Name);
		*text = sHostText.Ptr;
		*length = (int32)sHostText.Length;
		return 1;
	}

	static int32 HostRenameObject(uint32 id, char8* name, int32 length)
	{
		if (!EditingScene)
			return 0;
		let gameObject = SceneObject(id);
		let value = StringView(name, length);
		if (gameObject == null || value.IsEmpty)
			return 0;
		gameObject.Name.Set(value);
		sExtensionsApp.MarkDirty();
		return 1;
	}

	static uint32 HostCreateObject(char8* kind, int32 length, uint32 parentId)
	{
		if (!EditingScene)
			return 0;
		// The highest id means "where the editor puts it": under the selected folder, or in front of the Scene view
		// camera. Otherwise it goes under the parent asked for, or at the root, keeping where it was made.
		let asEditor = parentId == uint32.MaxValue;
		Transform parent = null;
		if (parentId != 0 && !asEditor)
		{
			let target = SceneObject(parentId);
			if (target == null)
				return 0;
			parent = target.Transform;
		}
		let made = sExtensionsApp.CreateBuiltin(StringView(kind, length));
		if (made == null)
			return 0;
		if (!asEditor)
			made.Transform.SetParent(parent, true);
		return made.Id;
	}

	static uint32 HostDuplicateObject(uint32 id)
	{
		if (!EditingScene)
			return 0;
		let source = SceneObject(id);
		if (source == null)
			return 0;
		let copy = sExtensionsApp.Duplicate(source, source.Transform.Parent);
		if (copy == null)
			return 0;
		sExtensionsApp.MarkDirty();
		return copy.Id;
	}

	static void HostDeleteObject(uint32 id)
	{
		if (!EditingScene)
			return;
		let gameObject = SceneObject(id);
		if (gameObject == null)
			return;
		// Now, not at the end of the frame: the script goes on to work with what it deleted.
		sExtensionsApp.mScene.DestroyImmediate(gameObject);
		if (sExtensionsApp.mSelectedId == id)
			sExtensionsApp.mSelectedId = 0;
		sExtensionsApp.MarkDirty();
	}

	static int32 HostObjectPosition(uint32 id, float* values)
	{
		let gameObject = SceneObject(id);
		if (gameObject == null)
			return 0;
		let value = gameObject.Transform.Position;
		values[0] = value.x;
		values[1] = value.y;
		values[2] = value.z;
		return 1;
	}

	static int32 HostSetObjectPosition(uint32 id, float x, float y, float z)
	{
		if (!EditingScene)
			return 0;
		let gameObject = SceneObject(id);
		if (gameObject == null)
			return 0;
		gameObject.Transform.Position = .(x, y, z);
		sExtensionsApp.MarkDirty();
		return 1;
	}

	static int32 HostObjectRotation(uint32 id, float* values)
	{
		let gameObject = SceneObject(id);
		if (gameObject == null)
			return 0;
		let value = gameObject.Transform.EulerAngles;
		values[0] = value.x;
		values[1] = value.y;
		values[2] = value.z;
		return 1;
	}

	static int32 HostSetObjectRotation(uint32 id, float x, float y, float z)
	{
		if (!EditingScene)
			return 0;
		let gameObject = SceneObject(id);
		if (gameObject == null)
			return 0;
		gameObject.Transform.EulerAngles = .(x, y, z);
		sExtensionsApp.MarkDirty();
		return 1;
	}

	static int32 HostObjectScale(uint32 id, float* values)
	{
		let gameObject = SceneObject(id);
		if (gameObject == null)
			return 0;
		let value = gameObject.Transform.LocalScale;
		values[0] = value.x;
		values[1] = value.y;
		values[2] = value.z;
		return 1;
	}

	static int32 HostSetObjectScale(uint32 id, float x, float y, float z)
	{
		if (!EditingScene)
			return 0;
		let gameObject = SceneObject(id);
		if (gameObject == null)
			return 0;
		gameObject.Transform.LocalScale = .(x, y, z);
		sExtensionsApp.MarkDirty();
		return 1;
	}

	static int32 HostComponentCount(uint32 id)
	{
		let gameObject = SceneObject(id);
		if (gameObject == null)
			return -1;
		let handles = scope List<HandleComponents.Info>();
		HandleComponents.On(gameObject, handles);
		return (int32)(gameObject.Components.Count + handles.Count);
	}

	/// A component's full type name: class components (scripts too) first, then the built-in handles (Light...), as
	/// the Inspector shows them.
	static int32 HostComponentType(uint32 id, int32 index, char8** text, int32* length)
	{
		*text = null;
		*length = 0;
		let gameObject = SceneObject(id);
		if (gameObject == null || index < 0)
			return 0;
		sHostText.Clear();
		if (index < gameObject.Components.Count)
			gameObject.Components[index].GetType().GetFullName(sHostText);
		else
		{
			let handles = scope List<HandleComponents.Info>();
			HandleComponents.On(gameObject, handles);
			let at = index - gameObject.Components.Count;
			if (at >= handles.Count)
				return 0;
			sHostText.Append(handles[at].fullName);
		}
		*text = sHostText.Ptr;
		*length = (int32)sHostText.Length;
		return 1;
	}

	/// The class component of that full type name on the object, or null.
	static Component SceneClassComponent(GameObject gameObject, StringView fullName)
	{
		let buffer = scope String();
		for (let component in gameObject.Components)
		{
			buffer.Clear();
			component.GetType().GetFullName(buffer);
			if (buffer == fullName)
				return component;
		}
		return null;
	}

	/// The built-in handle component (Light...) of that full type name on the object, or null when it has none.
	static HandleComponents.Info SceneHandle(GameObject gameObject, StringView fullName)
	{
		let info = HandleComponents.Find(fullName);
		let world = gameObject.Scene?.World;
		if (info == null || world == null || !world.Has(gameObject.Entity, info.index))
			return null;
		return info;
	}

	static int32 HostAddComponent(uint32 id, char8* name, int32 length)
	{
		if (!EditingScene)
			return 0;
		let gameObject = SceneObject(id);
		if (gameObject == null)
			return 0;
		let fullName = StringView(name, length);
		if (SceneClassComponent(gameObject, fullName) != null || SceneHandle(gameObject, fullName) != null)
			return 0;
		if (let info = ComponentRegistry.Find(fullName))
		{
			if (gameObject.AddComponent(info.type) == null)
				return 0;
		}
		else if (let handle = HandleComponents.Find(fullName))
			HandleComponents.Add(gameObject, handle);
		else
			return 0;
		sExtensionsApp.MarkDirty();
		return 1;
	}

	static int32 HostRemoveComponent(uint32 id, char8* name, int32 length)
	{
		if (!EditingScene)
			return 0;
		let gameObject = SceneObject(id);
		if (gameObject == null)
			return 0;
		let fullName = StringView(name, length);
		if (let component = SceneClassComponent(gameObject, fullName))
		{
			gameObject.RemoveComponent(component);
			sExtensionsApp.MarkDirty();
			return 1;
		}
		if (let handle = SceneHandle(gameObject, fullName))
		{
			gameObject.RemoveData(handle.dataType);
			sExtensionsApp.MarkDirty();
			return 1;
		}
		return 0;
	}

	/// A component's serialized fields: a class component's or a built-in handle's, as the Inspector lists them. A C#
	/// script's own fields are managed ones, read through the Inspector's target functions.
	static bool SceneFields(GameObject gameObject, StringView fullName, List<FieldRef> fields)
	{
		fields.Clear();
		if (let component = SceneClassComponent(gameObject, fullName))
		{
			if (component is CSharpBehaviour)
				return false;
			ComponentRegistry.GetFields(component, fields);
			return true;
		}
		if (let handle = SceneHandle(gameObject, fullName))
		{
			HandleComponents.GetFields(gameObject, handle, fields);
			return true;
		}
		return false;
	}

	static StringView FieldKindName(FieldKind kind)
	{
		switch (kind)
		{
		case .Float: return "Float";
		case .Double: return "Double";
		case .Char: return "Char";
		case .Vector4: return "Vector4";
		case .Int3: return "Int3";
		case .Matrix4: return "Matrix4";
		case .Int: return "Int";
		case .Bool: return "Bool";
		case .Vector2: return "Vector2";
		case .Vector3: return "Vector3";
		case .Quaternion: return "Quaternion";
		case .Color: return "Color";
		case .String: return "String";
		case .Enum: return "Enum";
		case .ObjectReference: return "ObjectReference";
		case .List: return "List";
		case .Array: return "Array";
		}
		return "Unknown";
	}

	static int32 HostFieldList(uint32 id, char8* name, int32 nameLength, char8** text, int32* length)
	{
		*text = null;
		*length = 0;
		let gameObject = SceneObject(id);
		if (gameObject == null)
			return 0;
		let fields = scope List<FieldRef>();
		if (!SceneFields(gameObject, StringView(name, nameLength), fields))
			return 0;
		sHostText.Clear();
		for (let field in fields)
		{
			sHostText.Append(field.name);
			sHostText.Append('\t');
			sHostText.Append(FieldKindName(field.kind));
			sHostText.Append('\n');
		}
		*text = sHostText.Ptr;
		*length = (int32)sHostText.Length;
		return 1;
	}

	static int32 HostFieldRead(uint32 id, char8* name, int32 nameLength, char8* fieldName, int32 fieldLength,
		char8** text, int32* length)
	{
		*text = null;
		*length = 0;
		let gameObject = SceneObject(id);
		if (gameObject == null)
			return 0;
		let fields = scope List<FieldRef>();
		if (!SceneFields(gameObject, StringView(name, nameLength), fields))
			return 0;
		let wanted = StringView(fieldName, fieldLength);
		for (let field in fields)
		{
			if (field.name != wanted)
				continue;
			sHostText.Clear();
			if (field.kind == .String)
				sHostText.Append(StringFields.Get(field.ptr, field.type));
			else
				SceneSerializer.WriteValue(field, sHostText);
			*text = sHostText.Ptr;
			*length = (int32)sHostText.Length;
			return 1;
		}
		return 0;
	}

	static int32 HostFieldWrite(uint32 id, char8* name, int32 nameLength, char8* fieldName, int32 fieldLength,
		char8* value, int32 valueLength)
	{
		if (!EditingScene)
			return 0;
		let gameObject = SceneObject(id);
		if (gameObject == null)
			return 0;
		let fields = scope List<FieldRef>();
		if (!SceneFields(gameObject, StringView(name, nameLength), fields))
			return 0;
		let wanted = StringView(fieldName, fieldLength);
		for (let field in fields)
		{
			if (field.name != wanted)
				continue;
			let text = StringView(value, valueLength);
			if (field.kind == .String)
				StringFields.Set(field.ptr, field.type, text, field.name);
			else
			{
				let tokens = scope List<StringView>();
				let storage = scope List<String>();
				SceneSerializer.Tokenize(text, tokens, storage);
				if (tokens.Count == 0)
					return 0;
				SceneSerializer.ReadValue(field, tokens);
			}
			if (sInspectorComponentDrawing && sInspectorComponentObject == id &&
				sInspectorComponentType == StringView(name, nameLength))
				sInspectorComponentEdited = true;
			sExtensionsApp.MarkDirty();
			return 1;
		}
		return 0;
	}

	/// The fields of the component a C# Inspector is drawing.
	static bool InspectorComponentFields(List<FieldRef> fields)
	{
		let gameObject = SceneObject(sInspectorComponentObject);
		return gameObject != null && SceneFields(gameObject, sInspectorComponentType, fields);
	}

	/// One field of it, with the editor's own widget (a C# component Inspector's Field()).
	static int32 HostComponentField(char8* name, int32 length)
	{
		if (!sInspectorComponentDrawing)
			return -1;
		let fields = scope List<FieldRef>();
		if (!InspectorComponentFields(fields))
			return 0;
		let wanted = StringView(name, length);
		let only = scope List<FieldRef>();
		for (let field in fields)
			if (field.name == wanted)
				only.Add(field);
		if (only.Count == 0)
			return 0;
		let changed = sExtensionsApp.DrawFieldList(only, scope $"inspectorcomponent{wanted}");
		sInspectorComponentEdited |= changed;
		return changed ? 1 : 0;
	}

	/// All of them (DrawDefaultInspector()).
	static int32 HostComponentDefault()
	{
		if (!sInspectorComponentDrawing)
			return -1;
		let fields = scope List<FieldRef>();
		if (!InspectorComponentFields(fields))
			return 0;
		let changed = sExtensionsApp.DrawFieldList(fields, "inspectorcomponentfields");
		sInspectorComponentEdited |= changed;
		return changed ? 1 : 0;
	}

	static void HostMarkDirty() => sExtensionsApp.MarkDirty();
}
