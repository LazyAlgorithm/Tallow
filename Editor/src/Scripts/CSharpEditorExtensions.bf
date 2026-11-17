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
			version = 1,
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
			query = => HostQuery
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
}
