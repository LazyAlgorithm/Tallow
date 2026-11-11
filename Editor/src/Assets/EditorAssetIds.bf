using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// The editor's side of stable asset IDs (AssetDatabase, docs/asset-ids.md): looking at the project when it opens and
/// whenever its files change, and bringing what the editor has open up to date after assets move.
extension EditorApp
{
	bool mAssetIdsReady;

	/// Called from PollProjectFolders: on the first call and after the folder monitor saw a change.
	void RefreshAssetIds()
	{
		let moves = scope List<(String from, String to)>();
		defer
		{
			for (let move in moves)
			{
				delete move.from;
				delete move.to;
			}
		}
		AssetDatabase.Refresh(true, moves);
		if (!mAssetIdsReady)
		{
			mAssetIdsReady = true;
			Log.Info(scope $"Asset IDs: {AssetDatabase.Count} assets");
		}
		if (moves.Count > 0)
			ApplyAssetMoves(moves);
	}

	/// The IDs are read before anything uses them (a window opened by a start-up switch comes before the first look).
	void EnsureAssetIds()
	{
		if (!mAssetIdsReady)
			RefreshAssetIds();
	}

	/// Moves an asset (full paths) as the Project window does: side files and references go with it.
	bool MoveAssetTracked(StringView from, StringView to)
	{
		let moves = scope List<(String from, String to)>();
		defer
		{
			for (let move in moves)
			{
				delete move.from;
				delete move.to;
			}
		}
		if (AssetDatabase.Move(from, to, moves) case .Err)
			return false;
		let relativeFrom = scope String();
		let relativeTo = scope String();
		if (AssetDatabase.ToRelative(from, relativeFrom) && AssetDatabase.ToRelative(to, relativeTo))
		{
			bool listed = false;
			for (let move in moves)
				listed |= move.from == relativeFrom;
			if (!listed)
				moves.Add((new String(relativeFrom), new String(relativeTo)));
		}
		ApplyAssetMoves(moves);
		return true;
	}

	/// A path (relative, or full inside the Assets folder) after the moves; false if none of them covers it.
	static bool RemapAssetPath(StringView path, Span<(String from, String to)> moves, String outPath)
	{
		if (path.IsEmpty)
			return false;
		// A list of paths separated by ';' (an Animator's clips): each one.
		if (path.Contains(';'))
		{
			bool changed = false;
			bool first = true;
			for (let part in path.Split(';'))
			{
				if (!first)
					outPath.Append(';');
				first = false;
				let replaced = scope String();
				if (RemapAssetPath(part, moves, replaced))
				{
					outPath.Append(replaced);
					changed = true;
				}
				else
					outPath.Append(part);
			}
			return changed;
		}
		let root = Assets.ProjectPath;
		bool full = path.Length > root.Length && path.StartsWith(root) && path[root.Length] == '/';
		let relative = full ? path.Substring(root.Length + 1) : path;
		for (let move in moves)
		{
			if (!relative.StartsWith(move.from))
				continue;
			let rest = relative.Substring(move.from.Length);
			if (!rest.IsEmpty && rest[0] != '/' && rest[0] != '#')
				continue;
			if (full)
				outPath.AppendF("{}/", root);
			outPath.Append(move.to);
			outPath.Append(rest);
			return true;
		}
		return false;
	}

	static void RemapInPlace(String path, Span<(String from, String to)> moves)
	{
		let remapped = scope String();
		if (RemapAssetPath(path, moves, remapped))
			path.Set(remapped);
	}

	/// What the editor has open, after assets moved: the scene's fields (its file was already changed on disk), the
	/// paths of open scenes, prefabs, graphs, scripts and other documents, and the Project window.
	void ApplyAssetMoves(Span<(String from, String to)> moves)
	{
		// Scripts, built-in handle components (Mesh Renderer...) and data components alike.
		let fields = scope List<FieldRef>();
		let handles = scope List<HandleComponents.Info>();
		let data = scope List<DataComponents.Info>();
		for (let gameObject in mScene.Objects)
		{
			for (let component in gameObject.Components)
			{
				fields.Clear();
				ComponentRegistry.GetFields(component, fields);
				for (let field in fields)
					RemapField(field, moves);
			}
			handles.Clear();
			HandleComponents.On(gameObject, handles);
			for (let info in handles)
			{
				fields.Clear();
				HandleComponents.GetFields(gameObject, info, fields);
				for (let field in fields)
					RemapField(field, moves);
			}
			data.Clear();
			DataComponents.On(gameObject, data);
			for (let info in data)
			{
				fields.Clear();
				DataComponents.GetFields(info.type, gameObject.GetData(info.type), fields, gameObject);
				for (let field in fields)
					RemapField(field, moves);
			}
		}
		RemapInPlace(mScene.Environment.colorLookup, moves);
		RemapInPlace(mScene.Environment.lightProbes, moves);
		String[?] open = .(mScene.Path, mPrefabPath, mStashedScenePath, mAnimControllerPath, mClipPath, mDialoguePath,
			mEditedDataPath, mGraphPath, mImportSettingsPath, mMaterialPath, mSeqPath, mTreePath, mUiPath, mRigPath,
			mRiggedPath, mPaletteEditPath, mBrowsePath, mSelectedAsset);
		for (let path in open)
			RemapInPlace(path, moves);
		for (let document in mScripts)
			RemapInPlace(document.path, moves);
		// The Package Manager's records of what each package put in.
		AssetPackages.ApplyMoves(moves);
		let project = Project.Current;
		if (project != null)
		{
			let start = scope String();
			if (RemapAssetPath(project.StartScene, moves, start))
				project.StartScene.Set(start);
		}
		RefreshAssetList();
	}

	/// Project > Find References: the files that name an asset, in the Console.
	void LogAssetReferences(StringView full)
	{
		let relative = scope String();
		if (!AssetDatabase.ToRelative(full, relative))
			return;
		let users = scope List<String>();
		defer { ClearAndDeleteItems!(users); }
		AssetDatabase.FindReferences(relative, users);
		if (users.IsEmpty)
		{
			Log.Info(scope $"Nothing names {relative}.");
			return;
		}
		let text = scope String();
		text.AppendF("{} is named by {} file{}:", relative, users.Count, (users.Count == 1) ? "" : "s");
		for (let user in users)
		{
			let shown = scope String();
			if (!AssetDatabase.ToRelative(user, shown))
				Path.GetFileName(user, shown);
			text.AppendF("\n  {}", shown);
		}
		Log.Info(text);
	}

	static void RemapField(FieldRef field, Span<(String from, String to)> moves)
	{
		if (field.kind == .String)
		{
			// String, SharedString or text owned by handle data: StringFields reads and writes them all.
			let remapped = scope String();
			if (RemapAssetPath(StringFields.Get(field.ptr, field.type), moves, remapped))
				StringFields.Set(field.ptr, field.type, remapped, field.name);
		}
		else if ((field.kind == .List || field.kind == .Array) && field.elementKind == .String)
		{
			let count = FieldLists.Count(field);
			for (int i < count)
				RemapField(FieldLists.Element(field, i), moves);
		}
	}
}
