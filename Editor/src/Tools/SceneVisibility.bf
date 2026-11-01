using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Scene visibility and picking, as Unity's: an eye beside each object in the Hierarchy hides it from the Scene view
/// alone (it is not disabled: the game and the Game view still have it), and a lock makes it unclickable in the
/// Scene view (the Hierarchy still selects it). Pressing one and dragging over other rows sets each row passed over
/// the same way; a parent takes its children with it. Kept per user and per scene, never in the scene file, in
/// scene_visibility_<project>.txt in the editor's settings folder.
class SceneVisibilityState
{
	public HashSet<uint32> hidden = new .() ~ delete _;
	public HashSet<uint32> locked = new .() ~ delete _;
}

extension EditorApp
{
	enum VisibilityDrag
	{
		None,
		Hide,
		Lock
	}

	Dictionary<String, SceneVisibilityState> mSceneVisibility ~ DeleteDictionaryAndKeysAndValues!(_);
	SceneVisibilityState mVisibility;
	String mVisibilityScene = new .() ~ delete _;
	VisibilityDrag mVisibilityDrag;
	// What the drag sets each row it passes over to (hidden, or locked), and the rows it has set already.
	bool mVisibilityDragValue;
	HashSet<uint32> mVisibilityDragged = new .() ~ delete _;
	// Where the Hierarchy's eye and lock column starts on screen, this frame.
	float mHierarchyGutter;

	// The settings file to use instead (--visibility-test leaves the user's own alone).
	String mVisibilityFileOverride ~ delete _;

	void SceneVisibilityFile(String file)
	{
		if (mVisibilityFileOverride != null)
		{
			file.Set(mVisibilityFileOverride);
			return;
		}
		RecentProjects.GetConfigFolder(file);
		file.AppendF("scene_visibility_{}.txt", Path.GetFileName(scope String(Assets.ProjectPath)..TrimEnd('/'), .. scope .()));
	}

	/// The eyes and locks of the scene open now, loaded the first time they are needed.
	SceneVisibilityState Visibility
	{
		get
		{
			if (mSceneVisibility == null)
				LoadSceneVisibility();
			if (mVisibility == null || mVisibilityScene != mScene.Path)
			{
				mVisibilityScene.Set(mScene.Path);
				if (!mSceneVisibility.TryGetValue(mVisibilityScene, out mVisibility))
				{
					mVisibility = new .();
					mSceneVisibility[new String(mVisibilityScene)] = mVisibility;
				}
				mSceneView.hiddenHere = mVisibility.hidden;
			}
			return mVisibility;
		}
	}

	void LoadSceneVisibility()
	{
		mSceneVisibility = new .();
		let text = scope String();
		if (File.ReadAllText(SceneVisibilityFile(.. scope .()), text) case .Err)
			return;
		SceneVisibilityState state = null;
		for (let line in text.Split('\n'))
		{
			// scene <path> / hide <ids> / lock <ids>
			var trimmed = line;
			trimmed.Trim();
			if (trimmed.StartsWith("scene "))
			{
				let path = new String(trimmed.Substring(6));
				if (mSceneVisibility.ContainsKey(path))
				{
					state = mSceneVisibility[path];
					delete path;
				}
				else
				{
					state = new .();
					mSceneVisibility[path] = state;
				}
				continue;
			}
			if (state == null || trimmed.Length < 5)
				continue;
			let set = trimmed.StartsWith("hide ") ? state.hidden : (trimmed.StartsWith("lock ") ? state.locked : null);
			if (set == null)
				continue;
			for (let number in trimmed.Substring(5).Split(' ', .RemoveEmptyEntries))
			{
				if (uint32.Parse(number) case .Ok(let id))
					set.Add(id);
			}
		}
	}

	void SaveSceneVisibility()
	{
		if (mSceneVisibility == null)
			return;
		let text = scope String();
		for (let (path, state) in mSceneVisibility)
		{
			if (state.hidden.Count == 0 && state.locked.Count == 0)
				continue;
			text.AppendF("scene {}\n", path);
			WriteVisibilityIds(text, "hide", state.hidden);
			WriteVisibilityIds(text, "lock", state.locked);
		}
		File.WriteAllText(SceneVisibilityFile(.. scope .()), text).IgnoreError();
	}

	static void WriteVisibilityIds(String text, StringView label, HashSet<uint32> ids)
	{
		if (ids.Count == 0)
			return;
		// Sorted, so the file does not change when nothing has.
		let sorted = scope List<uint32>();
		for (let id in ids)
			sorted.Add(id);
		sorted.Sort();
		text.Append(label);
		for (let id in sorted)
			text.AppendF(" {}", id);
		text.Append('\n');
	}

	/// Whether the Scene view hides the object (by its own eye or by one of its parents').
	bool SceneHidden(GameObject gameObject) => Visibility.hidden.Contains(gameObject.Id);
	/// Whether clicking in the Scene view passes the object by.
	bool PickLocked(GameObject gameObject) => Visibility.locked.Contains(gameObject.Id);
	/// Whether a click in the Scene view can select the object: not hidden by its eye, nor locked.
	bool PickableInScene(GameObject gameObject) => !SceneHidden(gameObject) && !PickLocked(gameObject);

	/// Hides or shows an object and everything under it in the Scene view.
	void SetSceneHidden(GameObject gameObject, bool hidden)
	{
		SetVisibilityTree(Visibility.hidden, gameObject, hidden);
		SaveSceneVisibility();
	}

	/// Locks or unlocks an object and everything under it against clicks in the Scene view.
	void SetPickLocked(GameObject gameObject, bool locked)
	{
		SetVisibilityTree(Visibility.locked, gameObject, locked);
		SaveSceneVisibility();
	}

	static void SetVisibilityTree(HashSet<uint32> set, GameObject gameObject, bool on)
	{
		if (on)
			set.Add(gameObject.Id);
		else
			set.Remove(gameObject.Id);
		for (let child in gameObject.Transform.Children)
			SetVisibilityTree(set, child.GameObject, on);
	}

	/// Width of the eye and lock column at the left of the Hierarchy.
	float VisibilityGutterWidth => ImGui.GetFrameHeight() * 2;

	/// Draws a row's eye and lock in the column at the left of the Hierarchy, and handles pressing and dragging over
	/// them. Leaves the cursor where it was, for the row itself.
	void DrawVisibilityButtons(GameObject gameObject, float gutterLeft)
	{
		let rowStart = ImGui.GetCursorScreenPos();
		let size = ImGui.GetFrameHeight();
		let hidden = SceneHidden(gameObject);
		let locked = PickLocked(gameObject);
		let rowHovered = ImGui.IsWindowHovered() && ImGui.GetMousePos().y >= rowStart.y && ImGui.GetMousePos().y < rowStart.y + size;
		for (int column < 2)
		{
			let min = ImGui.Vec2(gutterLeft + column * size, rowStart.y);
			let max = ImGui.Vec2(min.x + size, min.y + size);
			let on = column == 0 ? hidden : locked;
			let mouse = ImGui.GetMousePos();
			let over = rowHovered && mouse.x >= min.x && mouse.x < max.x;
			// Shown while set, or while the pointer is on the row, as Unity's.
			if (on || over || rowHovered)
			{
				let icon = column == 0 ? (hidden ? "\u{f070}" : "\u{f06e}") : (locked ? "\u{f023}" : "\u{f09c}");
				let color = on ? EditorTheme.Accent : (over ? EditorTheme.Text : EditorTheme.TextDim);
				ImGui.DrawText(.(min.x + size * 0.2f, min.y + size * 0.15f), color, icon);
			}
			if (over && ImGui.IsMouseClicked(0))
			{
				mVisibilityDrag = column == 0 ? .Hide : .Lock;
				mVisibilityDragValue = !on;
				mVisibilityDragged.Clear();
			}
			// Pressed here, or dragged onto it from another row's button in the same column.
			let dragging = mVisibilityDrag == (column == 0 ? VisibilityDrag.Hide : VisibilityDrag.Lock);
			if (dragging && ImGui.IsMouseDown(0) && ImGui.IsWindowHovered() && mouse.y >= min.y && mouse.y < max.y && !mVisibilityDragged.Contains(gameObject.Id))
			{
				mVisibilityDragged.Add(gameObject.Id);
				if (on != mVisibilityDragValue)
				{
					if (column == 0)
						SetSceneHidden(gameObject, mVisibilityDragValue);
					else
						SetPickLocked(gameObject, mVisibilityDragValue);
				}
			}
		}
		ImGui.SetCursorScreenPos(rowStart);
	}

	/// Ends a drag over the eyes or locks once the mouse button is let go.
	void EndVisibilityDrag()
	{
		if (mVisibilityDrag != .None && !ImGui.IsMouseDown(0))
		{
			mVisibilityDrag = .None;
			mVisibilityDragged.Clear();
		}
	}

	/// Whether the pointer is over the eye and lock column, where a click is not a click on the row.
	bool OverVisibilityGutter(float gutterLeft) => ImGui.GetMousePos().x < gutterLeft + VisibilityGutterWidth;

	/// Test switch --visibility-test: hides an object and its children from the Scene view alone, locks another,
	/// checks clicks pass both by, that the Game view still draws them, and that both come back after the editor
	/// starts again (in a settings file of the test's own), then logs VISIBILITY-TEST PASS or FAIL.
	void RunVisibilityTest()
	{
		bool pass = true;
		let report = scope String();
		void Expect(bool condition, StringView what)
		{
			report.AppendF("{}{}: {}", report.IsEmpty ? "" : "; ", what, condition);
			pass &= condition;
		}
		let file = scope String();
		RecentProjects.GetConfigFolder(file);
		file.Append("visibility-test.txt");
		File.Delete(file).IgnoreError();
		mVisibilityFileOverride = new String(file);
		DeleteDictionaryAndKeysAndValues!(mSceneVisibility);
		mSceneVisibility = null;
		mVisibility = null;

		// A parent with children, and another object, both drawn.
		GameObject parent = null, other = null;
		for (let renderer in mScene.Renderers)
		{
			let gameObject = renderer.GameObject;
			if (gameObject.Transient)
				continue;
			let top = (gameObject.Transform.Parent != null && !gameObject.Transform.Parent.GameObject.Transient) ? gameObject.Transform.Parent.GameObject : null;
			if (parent == null && top != null)
				parent = top;
			else if (other == null && gameObject != parent && (parent == null || gameObject.Transform.Parent?.GameObject != parent))
				other = gameObject;
		}
		Expect(parent != null && other != null, "the scene has a parent with drawn children and another drawn object");
		if (parent != null && other != null)
		{
			let child = parent.Transform.Children[0].GameObject;
			SetSceneHidden(parent, true);
			mSceneView.hiddenHere = Visibility.hidden;
			Expect(mSceneView.HidesHere(parent) && mSceneView.HidesHere(child), "an eye hides the object and its children from the Scene view");
			Expect(!mGameView.HidesHere(parent) && !mGameView.HidesHere(child) && parent.ActiveInHierarchy, "the Game view still draws them, and they stay enabled");
			Expect(!PickableInScene(child), "clicks in the Scene view pass a hidden object by");
			SetPickLocked(other, true);
			Expect(!PickableInScene(other) && !mSceneView.HidesHere(other), "a locked object is drawn but not clickable");

			// As the editor starting again: everything is read back from the file.
			DeleteDictionaryAndKeysAndValues!(mSceneVisibility);
			mSceneVisibility = null;
			mVisibility = null;
			Expect(SceneHidden(parent) && SceneHidden(child) && PickLocked(other) && !PickLocked(parent), "eyes and locks are kept for the next time");
			let text = scope String();
			File.ReadAllText(file, text).IgnoreError();
			Expect(text.Contains("hide ") && text.Contains("lock ") && !SceneSerializer.Save(mScene, .. scope .()).Contains("hide "), "they are kept per user, not in the scene");

			SetSceneHidden(parent, false);
			SetPickLocked(other, false);
			Expect(!SceneHidden(child) && PickableInScene(child) && PickableInScene(other), "shown and unlocked again, parent and children alike");
		}
		File.Delete(file).IgnoreError();
		DeleteAndNullify!(mVisibilityFileOverride);
		DeleteDictionaryAndKeysAndValues!(mSceneVisibility);
		mSceneVisibility = null;
		mVisibility = null;
		Log.Info(scope $"VISIBILITY-TEST {pass ? "PASS" : "FAIL"}: {report}");
	}
}
