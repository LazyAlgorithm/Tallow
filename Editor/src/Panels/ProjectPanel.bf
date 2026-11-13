using System;
using System.Collections;
using System.IO;
using System.Diagnostics;
using Tallow;

namespace Tallow.Editor;

/// The Project window: a folder tree on the left and an icon grid on the right.
/// Assets can be dragged onto the Scene, Hierarchy and Inspector, moved between folders by
/// dragging, and imported by dropping files from the desktop onto the editor.
extension EditorApp
{
	class AssetEntry
	{
		public String name = new .() ~ delete _;
		public String path = new .() ~ delete _;
		public bool isFolder;
	}

	List<AssetEntry> mAssetEntries = new .() ~ DeleteContainerAndItems!(_);
	String mListedPath = new .() ~ delete _;
	String mListedSearch = new .() ~ delete _;
	String mProjectSearch = new .() ~ delete _;
	String mSelectedAsset = new .() ~ delete _;
	String mRenamePath = new .() ~ delete _;
	String mRenameText = new .() ~ delete _;
	String mDeletePath = new .() ~ delete _;
	/// The files that name what is about to be deleted (relative paths).
	List<String> mDeleteUsers = new .() ~ DeleteContainerAndItems!(_);
	String mNewItemName = new .() ~ delete _;
	/// The class of the data asset being made (+ > Data Asset).
	String mNewDataType = new .() ~ delete _;
	String mPendingMoveFrom = new .() ~ delete _;
	String mPendingMoveTo = new .() ~ delete _;
	uint32 mPendingPrefabId;
	String mPendingPrefabFolder = new .() ~ delete _;
	int32 mNewItemKind = -1; // 0 folder, 1 script, 2 scene
	ScriptTemplateKind mNewScriptTemplate = .Basic;
	ProjectFolderMonitor mFolderMonitor = new .() ~ delete _;
	ScriptComponentCatalog mScriptCatalog = new .() ~ delete _;
	Stopwatch mFolderScanClock = new .(true) ~ delete _;
	bool mModelsScanned;

	void PollProjectFolders()
	{
		ModelImport.Update();
		if (mFolderScanClock.ElapsedMilliseconds < 1000) return;
		mFolderScanClock.Restart();
		// FBX, OBJ, ... converted to glTF when first seen and whenever they change (docs/model-import.md).
		if (!mModelsScanned)
		{
			mModelsScanned = true;
			RefreshAssetIds();
			ModelImport.Scan();
		}
		if (!mFolderMonitor.Poll(Assets.ProjectPath)) return;
		// New files get IDs, and assets moved outside the editor have their references brought up to date.
		RefreshAssetIds();
		ModelImport.Scan();
		mScriptCatalog.Refresh(Assets.ProjectPath, Project.Current.Name);
		if (!Directory.Exists(mBrowsePath))
			mBrowsePath.Set(Assets.ProjectPath);
		if (!File.Exists(mSelectedAsset) && !Directory.Exists(mSelectedAsset))
			mSelectedAsset.Clear();
		RefreshAssetList();
		NodeLibrary.RefreshSubgraphs(Assets.ProjectPath);
	}

	float mTileSize = 76;
	bool mOpenRename;
	bool mOpenDelete;
	bool mOpenNewItem;

	static bool HasExtension(StringView path, params StringView[] extensions)
	{
		for (let ext in extensions)
		{
			if (path.EndsWith(ext, .OrdinalIgnoreCase))
				return true;
		}
		return false;
	}

	static bool IsModelFile(StringView path) => Assets.IsModelPath(path);
	static bool IsImageFile(StringView path) => HasExtension(path, ".png", ".jpg", ".jpeg", ".tga", ".bmp");
	static bool IsAudioFile(StringView path) => HasExtension(path, ".wav", ".ogg", ".mp3", ".flac");

	/// Program.bf is generated start-up plumbing, not something to edit from the editor.
	/// Not shown: dot files, the project's plumbing, and "Compiled" folders, which hold built shaders.
	// An asset's ID file (.tmeta, docs/asset-ids.md) travels with it and is never shown.
	// A converted model's import settings (docs/model-import.md) are shown in its Inspector, not as a file of their own.
	static bool IsHidden(StringView name) => name.StartsWith('.') || name == "Program.bf" || name == "Compiled" || name.EndsWith(AssetDatabase.MetaSuffix) || (name.EndsWith(".import") && Assets.IsConvertedModel(name.Substring(0, name.Length - 7)));

	void ToRelative(StringView full, String outRelative)
	{
		let root = Assets.ProjectPath;
		if (full.Length > root.Length && full.StartsWith(root))
			outRelative.Append(full.Substring(root.Length + 1));
	}

	void RefreshAssetList()
	{
		ClearAndDeleteItems!(mAssetEntries);
		mListedPath.Set(mBrowsePath);
		mListedSearch.Set(mProjectSearch);
		if (mProjectSearch.IsEmpty)
			ListFolder(mBrowsePath, false);
		else
			ListFolder(Assets.ProjectPath, true);
		mAssetEntries.Sort(scope (a, b) =>
			{
				if (a.isFolder != b.isFolder)
					return a.isFolder ? -1 : 1;
				return String.Compare(a.name, b.name, true);
			});
	}

	void ListFolder(StringView folder, bool recursive)
	{
		if (mAssetEntries.Count > 800)
			return;
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (IsHidden(name))
				continue;
			let full = scope $"{folder}/{name}";
			if (!recursive || name.Contains(mProjectSearch, true))
				AddEntry(name, full, true);
			if (recursive)
				ListFolder(full, true);
		}
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (IsHidden(name))
				continue;
			// A graph's generated script is an implementation detail; the graph stands for it.
			if (name.EndsWith(".bf") && File.Exists(scope $"{folder}/{name.Substring(0, name.Length - 3)}.tgraph"))
				continue;
			// The same for the shader a shader graph generates.
			if (name.EndsWith(".tshader") && File.Exists(scope $"{folder}/{name.Substring(0, name.Length - 8)}.tsgraph"))
				continue;
			if (name.EndsWith(".tcompute") && File.Exists(scope $"{folder}/{name.Substring(0, name.Length - 9)}.tsgraph"))
				continue;
			if (!recursive || name.Contains(mProjectSearch, true))
				AddEntry(name, scope $"{folder}/{name}" , false);
		}
	}

	void AddEntry(StringView name, StringView path, bool isFolder)
	{
		let entry = new AssetEntry();
		entry.name.Set(name);
		entry.path.Set(path);
		entry.isFolder = isFolder;
		mAssetEntries.Add(entry);
	}

	void DrawProject()
	{
		if (ImGui.Begin("Project"))
		{
			// Where this panel is docked is where timeline-like windows open.
			let projectDock = ImGui.GetWindowDockID();
			if (projectDock != 0)
				mBottomDock = projectDock;
			if (mListedPath != mBrowsePath || mListedSearch != mProjectSearch)
				RefreshAssetList();
			DrawProjectHeader();
			ImGui.BeginChild("folders", .(210, 0), ImGui.ChildBorders);
			DrawProjectFolders(Assets.ProjectPath);
			ImGui.EndChild();
			ImGui.SameLine();
			ImGui.BeginChild("grid");
			let activate = DrawAssetGrid();
			ImGui.EndChild();
			if (activate != null)
				ActivateAsset(activate);
		}
		ImGui.End();

		// Moves are applied after the panel is drawn so the listing is not changed mid-iteration.
		if (!mPendingMoveFrom.IsEmpty)
		{
			MoveAsset(mPendingMoveFrom, mPendingMoveTo);
			mPendingMoveFrom.Clear();
		}
		// Defer new asset creation until the grid is finished: saving a
		// prefab refreshes the list and must not invalidate its iteration.
		if (mPendingPrefabId != 0)
		{
			let dropped = mScene.FindById(mPendingPrefabId);
			if (dropped != null)
				SaveSceneObjectAsPrefab(dropped, mPendingPrefabFolder);
			mPendingPrefabId = 0;
			mPendingPrefabFolder.Clear();
		}
		DrawProjectPopups();
	}

	/// The create menu, the breadcrumb of the folder shown, the search box and the icon size.
	void DrawProjectHeader()
	{
		if (ImGui.Button("+"))
			ImGui.OpenPopup("ProjectCreate");
		if (ImGui.BeginPopup("ProjectCreate"))
		{
			DrawProjectCreateMenu();
			ImGui.EndPopup();
		}
		ImGui.SameLine();
		DrawBreadcrumb();
		let right = ImGui.GetWindowWidth();
		ImGui.SameLine(Math.Max(right - 330, 260));
		ImGui.SetNextItemWidth(200);
		ImGui.InputText("##projectsearch", mProjectSearch, 0, "Search");
		ImGui.SameLine();
		ImGui.SetNextItemWidth(100);
		ImGui.SliderFloat("##tilesize", ref mTileSize, 48, 128, "");
		ImGui.Separator();
	}

	/// The folder tree on the left, from the asset folder down.
	void DrawProjectFolders(StringView assetRoot)
	{
		var rootFlags = ImGui.TreeFlags.DefaultOpen | ImGui.TreeFlags.OpenOnArrow | ImGui.TreeFlags.SpanAvailWidth;
		if (mBrowsePath == assetRoot)
			rootFlags |= ImGui.TreeFlags.Selected;
		let rootOpen = ImGui.TreeNode(scope String()..AppendF("{}  Assets###root", StringView(Icons.Folder)).CStr(), rootFlags);
		if (ImGui.IsItemClicked(0) && !ImGui.IsItemToggledOpen())
			mBrowsePath.Set(assetRoot);
		AcceptMoveInto(assetRoot);
		if (rootOpen)
		{
			DrawFolderTree(assetRoot);
			ImGui.TreePop();
		}
	}

	/// The icons of what is in the folder shown (or matches the search), and the menu on the empty space. Returns the
	/// asset double-clicked or opened from its menu, or null.
	AssetEntry DrawAssetGrid()
	{
		AssetEntry activate = null;
		let avail = ImGui.GetContentRegionAvail();
		let cell = mTileSize + 14;
		let columns = Math.Max(1, (int)(avail.x / cell));
		let labelHeight = ImGui.GetTextLineHeight() * 2 + 4;
		for (int i < mAssetEntries.Count)
		{
			if (i % columns != 0)
				ImGui.SameLine(0, 6);
			ImGui.PushID((int32)i);
			if (DrawAssetTile(mAssetEntries[i], labelHeight))
				activate = mAssetEntries[i];
			ImGui.PopID();
		}
		if (mAssetEntries.Count == 0)
			ImGui.TextDisabled(mProjectSearch.IsEmpty ? "This folder is empty. Right-click to create, or drop files here." : "Nothing matches the search.");

		// Empty space: deselect, context menu.
		let rest = ImGui.GetContentRegionAvail();
		ImGui.InvisibleButton("##gridspace", .(Math.Max(rest.x, 1), Math.Max(rest.y, 24)));
		if (ImGui.IsItemClicked(0))
			mSelectedAsset.Clear();
		AcceptMoveInto(mBrowsePath);
		if (ImGui.BeginPopupContextItem("gridmenu"))
		{
			DrawProjectCreateMenu();
			ImGui.Separator();
			if (ImGui.MenuItem("Show in File Manager"))
				ShowInFileManager(mBrowsePath);
			if (ImGui.MenuItem("Refresh"))
				RefreshAssetList();
			ImGui.EndPopup();
		}
		if (ImGui.IsWindowFocused() && !mSelectedAsset.IsEmpty && (ImGui.tn_imgui_capture_flags() & 4) == 0)
		{
			if (ImGui.IsKeyPressed(ImGui.Key.F2))
				BeginRename(mSelectedAsset);
			// The same question as Delete in the asset's menu.
			if (ImGui.IsKeyPressed(ImGui.Key.Delete))
			{
				mDeletePath.Set(mSelectedAsset);
				mOpenDelete = true;
			}
		}
		return activate;
	}

	/// One asset's tile: its icon and name, selected by a click, dragged to move it or drop it on an object. True
	/// when it is to be opened (double-clicked, or Open from its menu).
	bool DrawAssetTile(AssetEntry entry, float labelHeight)
	{
		bool activate = false;
		let tileMin = ImGui.GetCursorScreenPos();
		ImGui.InvisibleButton("tile", .(mTileSize + 8, mTileSize + labelHeight));
		NoteTestRect(scope $"asset:{entry.path}");
		let hovered = ImGui.IsItemHovered();
		let selected = mSelectedAsset == entry.path;
		// Selected when the click is let go over it, so dragging a material into an object's field leaves the
		// Inspector on the object.
		if (ImGui.IsItemClicked(0))
			mProjectPressed.Set(entry.path);
		if (mProjectPressed == entry.path && ImGui.IsMouseReleased(0))
		{
			if (hovered)
			{
				mSelectedAsset.Set(entry.path);
				// A material clicked here is what the Inspector shows, until an object is selected again.
				mInspectAsset = entry.name.EndsWith(".tmat") || entry.name.EndsWith(".tdata");
			}
			mProjectPressed.Clear();
		}
		if (hovered && ImGui.IsMouseDoubleClicked(0))
			activate = true;
		if (selected || hovered)
			ImGui.DrawRectFilled(tileMin, .(tileMin.x + mTileSize + 8, tileMin.y + mTileSize + labelHeight), selected ? Color(0.17f, 0.36f, 0.53f, 0.9f) : Color(1, 1, 1, 0.06f), 4);
		DrawAssetIcon(entry, .(tileMin.x + 4, tileMin.y + 4), mTileSize);
		DrawTileLabel(entry.name, .(tileMin.x + 2, tileMin.y + mTileSize + 6), mTileSize + 4);

		if (ImGui.BeginDragDropSource())
		{
			mProjectPressed.Clear();
			let relative = scope String();
			ToRelative(entry.path, relative);
			ImGui.SetDragDropPayload("ASSET", relative.Ptr, relative.Length);
			ImGui.Text(entry.name);
			ImGui.EndDragDropSource();
		}
		if (entry.isFolder)
			AcceptMoveInto(entry.path);
		if (DrawAssetMenu(entry))
			activate = true;
		return activate;
	}

	/// The menu on an asset's tile. True when Open was chosen.
	bool DrawAssetMenu(AssetEntry entry)
	{
		if (!ImGui.BeginPopupContextItem("tilemenu"))
			return false;
		bool open = false;
		mSelectedAsset.Set(entry.path);
		if (ImGui.MenuItem("Open"))
			open = true;
		if (entry.name.EndsWith(".tgraph"))
		{
			if (ImGui.MenuItem("View Generated Code"))
				ViewGraphCode(entry.path);
			if (ImGui.MenuItem("Convert to Script"))
				ConvertGraphToScript(entry.path);
		}
		else if (entry.name.EndsWith(".cs") || entry.name.EndsWith(".bf") || entry.name.EndsWith(".tasmdef") || entry.name.EndsWith(".tui") || entry.name.EndsWith(".tcss") || entry.name.EndsWith(".tshader") || entry.name.EndsWith(".tcompute"))
		{
			if (ImGui.MenuItem("Open in Code Editor"))
				OpenScript(entry.path);
		}
		if (ImGui.MenuItem("Rename", "F2"))
			BeginRename(entry.path);
		if (ImGui.MenuItem("Find References"))
			LogAssetReferences(entry.path);
		if (ImGui.MenuItem("Export Package..."))
		{
			let picked = scope List<StringView>();
			picked.Add(entry.path);
			OpenExportPackage(picked);
		}
		if (ImGui.MenuItem("Delete"))
		{
			mDeletePath.Set(entry.path);
			mOpenDelete = true;
		}
		ImGui.Separator();
		if (ImGui.MenuItem("Show in File Manager"))
			ShowInFileManager(entry.isFolder ? (StringView)entry.path : mBrowsePath);
		ImGui.EndPopup();
		return open;
	}

	void DrawBreadcrumb()
	{
		let assetRoot = Assets.ProjectPath;
		if (ImGui.SmallButton("Assets"))
			mBrowsePath.Set(assetRoot);
		if (mBrowsePath.Length <= assetRoot.Length)
			return;
		let relative = scope String(mBrowsePath.Substring(assetRoot.Length + 1));
		let built = scope String(assetRoot);
		int32 id = 0;
		for (let part in relative.Split('/'))
		{
			built.AppendF("/{}", part);
			ImGui.SameLine(0, 2);
			ImGui.TextDisabled(">");
			ImGui.SameLine(0, 2);
			ImGui.PushID(id++);
			if (ImGui.SmallButton(scope String(part).CStr()))
			{
				mBrowsePath.Set(built);
				ImGui.PopID();
				break;
			}
			ImGui.PopID();
		}
	}

	void DrawFolderTree(StringView folder)
	{
		List<String> names = scope .();
		defer
		{
			for (let n in names)
				delete n;
		}
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = new String();
			entry.GetFileName(name);
			if (IsHidden(name))
				delete name;
			else
				names.Add(name);
		}
		names.Sort(scope (a, b) => String.Compare(a, b, true));
		for (let name in names)
		{
			let full = scope $"{folder}/{name}";
			bool hasChildren = false;
			for (let child in Directory.EnumerateDirectories(full))
			{
				let childName = scope String();
				child.GetFileName(childName);
				if (!IsHidden(childName))
				{
					hasChildren = true;
					break;
				}
			}
			var flags = ImGui.TreeFlags.OpenOnArrow | ImGui.TreeFlags.SpanAvailWidth;
			if (!hasChildren)
				flags |= ImGui.TreeFlags.Leaf;
			if (mBrowsePath == full)
				flags |= ImGui.TreeFlags.Selected;
			// Keep the branch leading to the current folder open.
			if (mBrowsePath.StartsWith(scope $"{full}/"))
				ImGui.SetNextItemOpen(true, ImGui.Cond.Once);
			let open = ImGui.TreeNode(name.CStr(), flags);
			if (ImGui.IsItemClicked(0) && !ImGui.IsItemToggledOpen())
				mBrowsePath.Set(full);
			AcceptMoveInto(full);
			if (open)
			{
				if (hasChildren)
					DrawFolderTree(full);
				ImGui.TreePop();
			}
		}
	}

	/// Accept asset moves and Hierarchy object drops onto folder rows,
	/// folder tiles, and the currently browsed folder's empty grid area.
	void AcceptMoveInto(StringView folder)
	{
		if (!ImGui.BeginDragDropTarget())
			return;
		let payload = ImGui.AcceptDragDropPayload("ASSET");
		if (payload != null)
		{
			mPendingMoveFrom.Clear();
			mPendingMoveFrom.AppendF("{}/{}", Assets.ProjectPath, StringView((char8*)payload.data, payload.dataSize));
			mPendingMoveTo.Set(folder);
		}
		let objectPayload = ImGui.AcceptDragDropPayload("GAMEOBJECT");
		if (objectPayload != null && objectPayload.dataSize == sizeof(uint32))
		{
			mPendingPrefabId = *(uint32*)objectPayload.data;
			mPendingPrefabFolder.Set(folder);
		}
		ImGui.EndDragDropTarget();
	}

	void MoveAsset(StringView from, StringView toFolder)
	{
		let name = scope String();
		Path.GetFileName(from, name);
		let target = scope $"{toFolder}/{name}";
		if (target == from || toFolder.StartsWith(scope $"{from}/") || toFolder == from)
			return;
		if (File.Exists(target) || Directory.Exists(target))
		{
			Log.Warning(scope $"{name} already exists in that folder.");
			return;
		}
		// Its .tmeta and side files go with it, and every file that names it is changed to the new path.
		if (MoveAssetTracked(from, target))
			Log.Info(scope $"Moved {name}.");
		else
			Log.Error(scope $"Could not move {name}.");
		RefreshAssetList();
	}

	/// The coloured band and label a file of some kind shows when it has no picture of its own.
	struct FileBadge
	{
		public StringView suffix;
		public Color color;
		public char8* tag;

		public this(StringView suffix, Color color, char8* tag)
		{
			this.suffix = suffix;
			this.color = color;
			this.tag = tag;
		}
	}

	static FileBadge[?] sFileBadges = .(
		.(".cs", .(0.30f, 0.62f, 0.84f, 1), "C#"),
		.(".tasmdef", .(0.43f, 0.58f, 0.69f, 1), "ASM"),
		.(".bf", .(0.25f, 0.47f, 0.76f, 1), "CODE"),
		.(".tscene", .(0.52f, 0.38f, 0.72f, 1), "SCENE"),
		.(".voxels", .(0.58f, 0.44f, 0.30f, 1), "VOXEL"),
		.(".tprefab", .(0.24f, 0.56f, 0.78f, 1), "PREFAB"),
		.(".tui", .(0.20f, 0.60f, 0.62f, 1), "UI"),
		.(".tcss", .(0.20f, 0.48f, 0.70f, 1), "CSS"),
		.(".tnav", .(0.20f, 0.42f, 0.66f, 1), "NAV"),
		.(".tgraph", .(0.50f, 0.34f, 0.66f, 1), "GRAPH"),
		.(".tsgraph", .(0.40f, 0.62f, 0.30f, 1), "SHADER"),
		.(".tbt", .(0.70f, 0.44f, 0.20f, 1), "TREE"),
		.(".tcontroller", .(0.78f, 0.48f, 0.14f, 1), "ANIMATOR"),
		.(".tanim", .(0.30f, 0.55f, 0.75f, 1), "CLIP"),
		.(".tdialogue", .(0.72f, 0.40f, 0.48f, 1), "DIALOGUE"),
		.(".tsequence", .(0.80f, 0.36f, 0.30f, 1), "SEQUENCE"),
		.(".tmat", .(0.62f, 0.36f, 0.66f, 1), "MATERIAL"),
		.(".tdata", .(0.20f, 0.60f, 0.52f, 1), "DATA"),
		.(".tshader", .(0.40f, 0.62f, 0.30f, 1), "SHADER"),
		.(".tcompute", .(0.30f, 0.62f, 0.50f, 1), "COMPUTE"),
		.(".toml", .(0.36f, 0.36f, 0.38f, 1), "CFG"),
		.(".tallow", .(0.36f, 0.36f, 0.38f, 1), "CFG"));

	/// A file's badge, by its extension (models and sounds by their many formats); grey "FILE" for anything else.
	static void FileBadgeOf(StringView name, out Color color, out char8* tag)
	{
		for (let badge in sFileBadges)
		{
			if (name.EndsWith(badge.suffix))
			{
				color = badge.color;
				tag = badge.tag;
				return;
			}
		}
		if (IsModelFile(name))
		{
			color = .(0.30f, 0.62f, 0.44f, 1);
			tag = "MESH";
			return;
		}
		if (IsAudioFile(name))
		{
			color = .(0.35f, 0.72f, 0.80f, 1);
			tag = "AUDIO";
			return;
		}
		color = .(0.42f, 0.42f, 0.44f, 1);
		tag = "FILE";
	}

	void DrawAssetIcon(AssetEntry entry, ImGui.Vec2 min, float size)
	{
		let max = ImGui.Vec2(min.x + size, min.y + size);
		if (entry.isFolder)
		{
			let body = Color(0.83f, 0.68f, 0.33f, 1);
			let tab = Color(0.72f, 0.57f, 0.26f, 1);
			ImGui.DrawRectFilled(.(min.x + size * 0.08f, min.y + size * 0.2f), .(min.x + size * 0.48f, min.y + size * 0.36f), tab, 3);
			ImGui.DrawRectFilled(.(min.x + size * 0.08f, min.y + size * 0.3f), .(max.x - size * 0.08f, max.y - size * 0.16f), body, 4);
			return;
		}
		if (IsImageFile(entry.name))
		{
			// Images show themselves.
			let relative = scope String();
			ToRelative(entry.path, relative);
			let texture = Assets.GetTexture(relative);
			ImGui.DrawImage(texture.idx, .(min.x + size * 0.08f, min.y + size * 0.08f), .(max.x - size * 0.08f, max.y - size * 0.08f), false);
			return;
		}
		// Materials, shaders, models and prefabs show a rendered picture of themselves once it has been made.
		if (AssetPreviews.Wants(entry.name) && AssetPreviews.TryGet(entry.path, let preview))
		{
			ImGui.DrawRectFilled(.(min.x + size * 0.04f, min.y + size * 0.04f), .(max.x - size * 0.04f, max.y - size * 0.04f), .(0.17f, 0.17f, 0.19f, 1), 4);
			ImGui.DrawPicture(preview, .(min.x + size * 0.04f, min.y + size * 0.04f), .(max.x - size * 0.04f, max.y - size * 0.04f), .(0, 0), .(1, 1), false);
			return;
		}
		Color color;
		char8* tag;
		FileBadgeOf(entry.name, out color, out tag);
		// A sheet of paper with a coloured band.
		let left = min.x + size * 0.18f;
		let rightEdge = max.x - size * 0.18f;
		ImGui.DrawRectFilled(.(left, min.y + size * 0.06f), .(rightEdge, max.y - size * 0.06f), .(0.86f, 0.86f, 0.86f, 1), 3);
		ImGui.DrawRectFilled(.(left, min.y + size * 0.52f), .(rightEdge, max.y - size * 0.06f), color, 3);
		let textSize = ImGui.CalcTextSize(tag);
		ImGui.DrawText(.((left + rightEdge) * 0.5f - textSize.x * 0.5f, min.y + size * 0.73f - textSize.y * 0.5f), .White, tag);
	}

	void DrawTileLabel(StringView name, ImGui.Vec2 pos, float width)
	{
		// Up to two centred lines, the rest elided.
		let first = scope String();
		let second = scope String();
		for (let c in name.RawChars)
		{
			let line = second.IsEmpty && ImGui.CalcTextSize(scope String(first)..Append(c).CStr()).x <= width ? first : second;
			line.Append(c);
		}
		while (second.Length > 3 && ImGui.CalcTextSize(second.CStr()).x > width)
		{
			second.RemoveFromEnd(4);
			second.Append("...");
		}
		let lineHeight = ImGui.GetTextLineHeight();
		let w1 = ImGui.CalcTextSize(first.CStr()).x;
		ImGui.DrawText(.(pos.x + (width - w1) * 0.5f, pos.y), EditorTheme.Text, first.CStr());
		if (!second.IsEmpty)
		{
			let w2 = ImGui.CalcTextSize(second.CStr()).x;
			ImGui.DrawText(.(pos.x + (width - w2) * 0.5f, pos.y + lineHeight), EditorTheme.Text, second.CStr());
		}
	}

	void DrawProjectCreateMenu()
	{
		if (ImGui.MenuItem("Folder"))
			BeginNewItem(0, "New Folder");
		// Visual scripts and C# gameplay scripts are created side by side.
		if (ImGui.MenuItem("Visual Script (Graph)"))
			BeginNewItem(3, "NewGraph");
		if (ImGui.MenuItem("Visual Subgraph (reusable node)"))
			BeginNewItem(5, "NewSubgraph");
		if (ImGui.BeginMenu("C# Script (code)"))
		{
			if (ImGui.MenuItem("Basic Component"))
				BeginNewScriptTemplate(.Basic, "NewScript");
			if (ImGui.MenuItem("Movement"))
				BeginNewScriptTemplate(.Movement, "MovementScript");
			if (ImGui.MenuItem("Timed Action"))
				BeginNewScriptTemplate(.Timer, "TimedAction");
			if (ImGui.MenuItem("GUI / HUD"))
				BeginNewScriptTemplate(.Gui, "HudScript");
			if (ImGui.MenuItem("Networked Behaviour"))
				BeginNewScriptTemplate(.Networked, "NetworkBehaviour");
			ImGui.Separator();
			if (ImGui.BeginMenu("ECS"))
			{
				if (ImGui.MenuItem("Data Component (struct)"))
					BeginNewScriptTemplate(.EcsData, "NewData");
				if (ImGui.MenuItem("Synced Data Component"))
					BeginNewScriptTemplate(.EcsSynced, "SyncedData");
				if (ImGui.MenuItem("Script + Data"))
					BeginNewScriptTemplate(.EcsMixed, "MixedBehaviour");
				if (ImGui.MenuItem("GameObject Query Processor"))
					BeginNewScriptTemplate(.EcsQuery, "QueryProcessor");
				if (ImGui.MenuItem("Pure ECS Bulk Entities"))
					BeginNewScriptTemplate(.EcsBulk, "BulkProcessor");
				ImGui.EndMenu();
			}
			ImGui.EndMenu();
		}
		if (ImGui.MenuItem("Assembly Definition"))
			BeginNewItem(18, "NewAssembly");
		if (ImGui.MenuItem("Scene"))
			BeginNewItem(2, "NewScene");
		if (ImGui.MenuItem("Behavior Tree"))
			BeginNewItem(6, "NewTree");
		if (ImGui.MenuItem("Animator Controller"))
			BeginNewItem(7, "NewController");
		if (ImGui.MenuItem("Animation Clip"))
			BeginNewItem(8, "NewClip");
		if (ImGui.MenuItem("Material"))
			BeginNewItem(9, "NewMaterial");
		if (ImGui.MenuItem("Shader Graph (visual shader)"))
			BeginNewItem(12, "NewShaderGraph");
		if (ImGui.MenuItem("Shader Subgraph (reusable shader node)"))
			BeginNewItem(16, "NewShaderSubgraph");
		if (ImGui.MenuItem("Shader (code)"))
			BeginNewItem(10, "NewShader");
		if (ImGui.MenuItem("Compute Shader"))
			BeginNewItem(11, "NewCompute");
		if (ImGui.MenuItem("Compute Graph (visual compute shader)"))
			BeginNewItem(17, "NewComputeGraph");
		if (ImGui.MenuItem("UI Document"))
			BeginNewItem(4, "NewUI");
		if (ImGui.MenuItem("Dialogue"))
			BeginNewItem(14, "NewDialogue");
		if (ImGui.MenuItem("Sequence (cutscene)"))
			BeginNewItem(15, "NewSequence");
		if (ImGui.BeginMenu("Data Asset"))
		{
			let types = scope List<Type>();
			DataAsset.Types(types);
			if (types.IsEmpty)
				ImGui.TextDisabled("No data asset classes yet: write one with [DataAsset] (see the Saving page).");
			for (let type in types)
			{
				let name = type.GetName(.. scope .());
				if (ImGui.MenuItem(name))
				{
					mNewDataType.Set(type.GetFullName(.. scope .()));
					BeginNewItem(13, name);
				}
			}
			ImGui.EndMenu();
		}
	}

	void BeginNewScriptTemplate(ScriptTemplateKind template, StringView defaultName)
	{
		mNewScriptTemplate = template;
		BeginNewItem(1, defaultName);
	}

	void BeginNewItem(int32 kind, StringView defaultName)
	{
		mNewItemKind = kind;
		mNewItemName.Set(defaultName);
		mOpenNewItem = true;
	}

	void BeginRename(StringView path)
	{
		mRenamePath.Set(path);
		mRenameText.Clear();
		Path.GetFileName(path, mRenameText);
		mOpenRename = true;
	}

	void ShowInFileManager(StringView folder)
	{
		Terminal.Open(folder);
	}

	void ActivateAsset(AssetEntry entry)
	{
		if (entry.isFolder)
		{
			mBrowsePath.Set(entry.path);
			mProjectSearch.Clear();
		}
		else if (entry.name.EndsWith(".tscene"))
			OpenScene(entry.path);
		else if (entry.name.EndsWith(".cs") || entry.name.EndsWith(".bf") || entry.name.EndsWith(".tasmdef"))
			OpenScript(entry.path);
		else if (entry.name.EndsWith(".tgraph") || entry.name.EndsWith(".tsgraph"))
			OpenGraph(entry.path);
		else if (entry.name.EndsWith(".tbt"))
			OpenBehavior(entry.path);
		else if (entry.name.EndsWith(".tcontroller"))
			OpenAnimator(entry.path);
		else if (entry.name.EndsWith(".tanim"))
			OpenAnimationClip(entry.path);
		else if (entry.name.EndsWith(".tdialogue"))
			OpenDialogue(entry.path);
		else if (entry.name.EndsWith(".tsequence"))
			OpenSequence(entry.path);
		else if (entry.name.EndsWith(".tmat"))
			OpenMaterial(entry.path);
		else if (entry.name.EndsWith(".tprefab"))
			OpenPrefab(entry.path);
		else if (entry.name.EndsWith(".tshader") || entry.name.EndsWith(".tcompute"))
			OpenScript(entry.path);
		else if (IsAudioFile(entry.name))
			Audio.PlayOneShot2D(entry.path); // double-click to hear it
		else if (entry.name.EndsWith(".tui"))
			OpenUI(entry.path);
		else if (entry.name.EndsWith(".tcss"))
			OpenScript(entry.path);
		else if (entry.name.EndsWith(".tinput"))
			mShowInputActions = true;
		else
		{
			Terminal.Open(entry.path);
		}
	}

	void DrawProjectPopups()
	{
		if (mOpenNewItem)
		{
			ImGui.OpenPopup("Create Asset");
			mOpenNewItem = false;
		}
		if (ImGui.BeginPopupModal("Create Asset", null, ImGui.WindowFlags.AlwaysAutoResize))
		{
			ImGui.Text(mNewItemKind == 0 ? "Folder name" : (mNewItemKind == 1 ? "Script / ECS component type name" : (mNewItemKind == 3 ? "Graph name (becomes the component's class name)" : (mNewItemKind == 6 ? "Behavior tree name" : (mNewItemKind == 7 ? "Animator controller name" : (mNewItemKind == 8 ? "Animation clip name" : (mNewItemKind == 9 ? "Material name" : (mNewItemKind == 10 ? "Shader name" : (mNewItemKind == 11 ? "Compute shader name" : (mNewItemKind == 12 ? "Shader graph name" : (mNewItemKind == 16 ? "Shader subgraph name" : (mNewItemKind == 14 ? "Dialogue name" : (mNewItemKind == 15 ? "Sequence name" : "Scene name")))))))))))));
			ImGui.SetNextItemWidth(300);
			let enter = ImGui.InputText("##newname", mNewItemName, ImGui.InputFlags.EnterReturnsTrue);
			if (mNewItemKind == 1)
				ImGui.TextDisabled("Created in the current Project folder; script changes are detected automatically.");
			if (ImGui.Button("Create", .(120, 0)) || enter)
			{
				CreateAsset();
				ImGui.CloseCurrentPopup();
			}
			ImGui.SameLine();
			if (ImGui.Button("Cancel", .(120, 0)))
				ImGui.CloseCurrentPopup();
			ImGui.EndPopup();
		}

		if (mOpenRename)
		{
			ImGui.OpenPopup("Rename");
			mOpenRename = false;
		}
		if (ImGui.BeginPopupModal("Rename", null, ImGui.WindowFlags.AlwaysAutoResize))
		{
			ImGui.SetNextItemWidth(300);
			let enter = ImGui.InputText("##rename", mRenameText, ImGui.InputFlags.EnterReturnsTrue);
			if (ImGui.Button("Rename", .(120, 0)) || enter)
			{
				let folder = scope String();
				Path.GetDirectoryPath(mRenamePath, folder).IgnoreError();
				let target = scope $"{folder}/{mRenameText}";
				if (!mRenameText.IsEmpty && !mRenameText.Contains('/') && target != mRenamePath && !File.Exists(target) && !Directory.Exists(target))
				{
					let from = scope String(mRenamePath);
					if (!MoveAssetTracked(from, target))
						Log.Error(scope $"Could not rename to {mRenameText}.");
					else
						mSelectedAsset.Set(target);
				}
				RefreshAssetList();
				ImGui.CloseCurrentPopup();
			}
			ImGui.SameLine();
			if (ImGui.Button("Cancel", .(120, 0)))
				ImGui.CloseCurrentPopup();
			ImGui.EndPopup();
		}

		if (mOpenDelete)
		{
			ImGui.OpenPopup("Delete Asset");
			mOpenDelete = false;
			// What still names it, so that deleting something in use is not a surprise.
			ClearAndDeleteItems!(mDeleteUsers);
			let relative = scope String();
			if (AssetDatabase.ToRelative(mDeletePath, relative))
			{
				AssetDatabase.FindReferences(relative, mDeleteUsers);
				for (let user in mDeleteUsers)
				{
					let shown = scope String();
					if (!AssetDatabase.ToRelative(user, shown))
						Path.GetFileName(user, shown);
					user.Set(shown);
				}
				// A folder's own files naming each other do not count.
				mDeleteUsers.RemoveAll(scope (user) => { let inside = user.StartsWith(relative) && user.Length > relative.Length && user[relative.Length] == '/'; if (inside) delete user; return inside; });
			}
		}
		if (ImGui.BeginPopupModal("Delete Asset", null, ImGui.WindowFlags.AlwaysAutoResize))
		{
			let name = scope String();
			Path.GetFileName(mDeletePath, name);
			ImGui.Text(scope $"Delete '{name}'?");
			ImGui.TextDisabled("This removes it from disk and cannot be undone.");
			if (!mDeleteUsers.IsEmpty)
			{
				ImGui.TextColored(.(1, 0.75f, 0.3f, 1), scope $"Still named by {mDeleteUsers.Count} file{(mDeleteUsers.Count == 1) ? "" : "s"}:");
				for (int i < Math.Min(mDeleteUsers.Count, 8))
					ImGui.BulletText(mDeleteUsers[i]);
				if (mDeleteUsers.Count > 8)
					ImGui.TextDisabled(scope $"and {mDeleteUsers.Count - 8} more");
			}
			if (ImGui.Button("Delete", .(120, 0)))
			{
				bool ok = AssetDatabase.Delete(mDeletePath) case .Ok;
				if (!ok)
					Log.Error(scope $"Could not delete {name}.");
				mSelectedAsset.Clear();
				RefreshAssetList();
				ImGui.CloseCurrentPopup();
			}
			ImGui.SameLine();
			if (ImGui.Button("Cancel", .(120, 0)))
				ImGui.CloseCurrentPopup();
			NoteTestRect("delete-asset-cancel");
			ImGui.EndPopup();
		}
	}

	void CreateAsset()
	{
		if (mNewItemName.IsEmpty || mNewItemName.Contains('/'))
			return;
		switch (mNewItemKind)
		{
		case 0:
			if (Directory.CreateDirectory(scope $"{mBrowsePath}/{mNewItemName}") case .Err)
				Log.Error("Could not create the folder.");
		case 1:
			CreateScript(mNewItemName, mNewScriptTemplate);
		case 18:
			if (!ProjectGenerator.IsValidName(mNewItemName))
			{
				Log.Error("Assembly names use letters, digits and underscores.");
				break;
			}
			let definition = scope $"{mBrowsePath}/{mNewItemName}.tasmdef";
			if (File.Exists(definition))
			{
				Log.Error(scope $"{definition} already exists.");
				break;
			}
			let assemblyText = scope String();
			assemblyText.AppendF("{{\"name\":\"{}\",\"references\":[]}}", mNewItemName);
			File.WriteAllText(definition, assemblyText).IgnoreError();
			Log.Info(scope $"Created {definition}.");
		case 2:
			if (!ProjectGenerator.IsValidName(mNewItemName))
			{
				Log.Error("Scene names use letters, digits and underscores.");
				break;
			}
			let path = scope $"{mBrowsePath}/{mNewItemName}.tscene";
			if (File.Exists(path))
			{
				Log.Error(scope $"{path} already exists.");
				break;
			}
			let scene = scope Scene();
			SceneTemplates.BuildDefault(scene);
			scene.Name.Set(mNewItemName);
			SceneSerializer.SaveToFile(scene, path);
		case 3:
			CreateGraphAsset(mNewItemName);
		case 4:
			CreateUIAsset(mNewItemName);
		case 5:
			CreateSubgraphAsset(mNewItemName);
		case 6:
			CreateBehaviorAsset(mNewItemName);
		case 7:
			CreateAnimatorAsset(mNewItemName);
		case 8:
			CreateClipAsset(mNewItemName);
		case 9:
			CreateMaterialAsset(mNewItemName);
		case 10:
			CreateShaderAsset(mNewItemName, false);
		case 11:
			CreateShaderAsset(mNewItemName, true);
		case 12:
			CreateShaderGraphAsset(mNewItemName);
		case 16:
			CreateShaderSubgraphAsset(mNewItemName);
		case 17:
			CreateComputeGraphAsset(mNewItemName);
		case 13:
			let path = scope $"{mBrowsePath}/{mNewItemName}.tdata";
			if (File.Exists(path))
			{
				Log.Error(scope $"{path} already exists.");
				break;
			}
			let asset = DataAsset.Create(DataAsset.TypeNamed(mNewDataType));
			if (asset == null)
			{
				Log.Error("That data asset class could not be made.");
				break;
			}
			let text = scope String();
			asset.WriteText(text);
			delete asset;
			File.WriteAllText(path, text).IgnoreError();
			DataAsset.ClearCache();
		case 14:
			let path = scope $"{mBrowsePath}/{mNewItemName}.tdialogue";
			if (File.Exists(path))
			{
				Log.Error(scope $"{path} already exists.");
				break;
			}
			let text = scope String();
			NewDialogueText(text);
			File.WriteAllText(path, text).IgnoreError();
			OpenDialogue(path);
		case 15:
			let path = scope $"{mBrowsePath}/{mNewItemName}.tsequence";
			if (File.Exists(path))
			{
				Log.Error(scope $"{path} already exists.");
				break;
			}
			let text = scope String();
			NewSequenceText(text);
			File.WriteAllText(path, text).IgnoreError();
			OpenSequence(path);
		default:
		}
		RefreshAssetList();
	}

	/// Copies a file or folder dropped from outside the editor into the folder shown in Project.
	void ImportExternalFile(StringView source)
	{
		// A package is opened in Import Package (docs/packages.md), not copied in as a file.
		if (ImportDroppedPackage(source))
			return;
		let name = scope String();
		Path.GetFileName(source, name);
		if (name.IsEmpty)
			return;
		let target = scope $"{mBrowsePath}/{name}";
		if (File.Exists(target) || Directory.Exists(target))
		{
			Log.Warning(scope $"{name} already exists in this folder; it was not imported.");
			return;
		}
		bool ok = Directory.Exists(source) ? (Directory.Copy(source, target) case .Ok) : (File.Copy(source, target) case .Ok);
		if (ok)
			Log.Info(scope $"Imported {name}");
		else
			Log.Error(scope $"Could not import {source}");
		RefreshAssetList();
	}

	/// Handles an asset dragged from Project onto the Scene view or the Hierarchy.
	/// Whether dragging an asset over the Scene view shows it there before it is dropped: prefabs, models and map pieces.
	static bool PreviewsInScene(StringView relative) => MapPieces.IsPiece(relative) || HasExtension(relative, ".tprefab") || IsModelFile(relative);

	/// While a prefab or model is dragged over the Scene view: makes it (once), and stands it where the mouse points.
	/// It is an ordinary object already, so what is seen is what is dropped; nothing is selected until it is.
	void ShowDropPreview(StringView relative, float u, float v)
	{
		if (mPlay != .Edit || !PreviewsInScene(relative))
			return;
		mDropPreviewSeen = true;
		if (mDropPreview != null && mDropPreview.IsDestroyed)
			mDropPreview = null;
		if (mDropPreview == null || mDropPreviewAsset != relative)
		{
			ClearDropPreview();
			mDropPreviewSeen = true;
			let selected = mSelectedId;
			mDropPreview = MakeDroppedAsset(relative);
			mSelectedId = selected;
			if (mDropPreview == null)
				return;
			mDropPreviewAsset.Set(relative);
		}
		StandAtViewportPoint(mDropPreview, u, v);
	}

	/// Drops the previewed object where it is, and selects it.
	void KeepDropPreview(float u, float v)
	{
		StandAtViewportPoint(mDropPreview, u, v);
		mSelectedId = mDropPreview.Id;
		mDropPreview = null;
		mDropPreviewAsset.Clear();
		MarkDirty();
	}

	void ClearDropPreview()
	{
		if (mDropPreview != null && !mDropPreview.IsDestroyed)
			mScene.DestroyImmediate(mDropPreview);
		mDropPreview = null;
		mDropPreviewAsset.Clear();
	}

	/// Stands an object on whatever surface a point of the Scene view shows (scenery, terrain or the ground plane).
	void StandAtViewportPoint(GameObject gameObject, float u, float v)
	{
		let ray = mSceneCamera.ViewportPointToRay(u, v);
		Vector3 point, normal;
		if (RaycastScene(ray, out point, out normal, gameObject, true, 500))
			PlaceOnSurface(gameObject, point, normal, false);
		else
			gameObject.Transform.Position = ray.GetPoint(10);
	}

	/// Makes the object a prefab, model or map piece becomes in the scene (not yet placed).
	GameObject MakeDroppedAsset(StringView relative)
	{
		if (MapPieces.IsPiece(relative))
		{
			mSelectedId = 0;
			return InstantiateAsset(relative);
		}
		if (HasExtension(relative, ".tprefab"))
		{
			Prefab.ClearCache();
			let made = Prefab.Instantiate(mScene, relative);
			if (made != null)
				mSelectedId = made.Id;
			return made;
		}
		if (!IsModelFile(relative))
			return null;
		let name = scope String();
		Path.GetFileNameWithoutExtension(relative, name);
		mSelectedId = 0;
		if (SkinnedModel.Load(relative) == null)
			return CreateObject(name, relative);
		// Rigged models get a skinned renderer so their skeleton and clips work straight away.
		let made = CreateObject(name);
		let skinned = made.AddComponent<SkinnedMeshRenderer>();
		skinned.model.Set(relative);
		skinned.Refresh();
		return made;
	}

	// The asset tile pressed with the left button, selected when it is let go over it (empty: none, or a drag).
	String mProjectPressed = new .() ~ delete _;

	void DropAssetIntoScene(StringView relative, bool useViewportPoint, float u, float v)
	{
		if (relative.EndsWith(".tscene"))
		{
			OpenScene(scope $"{Assets.ProjectPath}/{relative}");
			return;
		}
		if (IsImageFile(relative))
		{
			MeshRenderer renderer = Selected != null ? Selected.GetComponent<MeshRenderer>() : default;
			if (renderer)
			{
				renderer.texture.Set(relative);
				MarkDirty();
			}
			else
				Log.Info("Select an object with a Mesh Renderer, then drop the image to use it as its texture.");
			return;
		}
		GameObject gameObject = null;
		if (PreviewsInScene(relative))
		{
			gameObject = MakeDroppedAsset(relative);
			if (gameObject == null)
				return;
			MarkDirty();
		}
		else if (HasExtension(relative, ".tui"))
		{
			let name = scope String();
			Path.GetFileNameWithoutExtension(relative, name);
			mSelectedId = 0;
			gameObject = CreateObject(name);
			gameObject.AddComponent<UIDocument>().document.Set(relative);
			MarkDirty();
		}
		else
			return;
		if (useViewportPoint)
			StandAtViewportPoint(gameObject, u, v);
	}
}
