using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Test switch --drag-test: drives the editor with a queued mouse (as a person would, frame by frame) through the
/// drags of docs/drag-and-drop.md: a Hierarchy row and an object in the Scene view dragged into an Inspector
/// field without selecting them, clicks that still select, the Inspector lock, and a prefab dragged over the Scene
/// view shown there before it is dropped (and gone again when the drag leaves). Logs DRAG-TEST PASS or FAIL and quits.
extension EditorApp
{
	/// One step of the test: the mouse moved to a point (over several frames), a button pressed or let go, frames
	/// waited, or a check.
	class DragTestStep
	{
		public enum Kind { Move, Press, Release, Wait, Run, Key }
		public Kind kind;
		public delegate ImGui.Vec2() at ~ delete _;
		public delegate void() run ~ delete _;
		public int frames = 1;
		/// For Key: the ImGui.Key pressed (down on the first frame, up on the second).
		public int32 key;
	}

	List<DragTestStep> mDragTest ~ { if (_ != null) DeleteContainerAndItems!(_); };
	int mDragStep;
	int mDragFrame;
	ImGui.Vec2 mDragMouse;
	ImGui.Vec2 mDragFrom;
	// Where the last test-noted items were drawn ("row:<id>", "field:<name>", "lock", "asset:<path>").
	Dictionary<String, (ImGui.Vec2 min, ImGui.Vec2 max)> mTestRects ~ { if (_ != null) DeleteDictionaryAndKeys!(_); };
	String mDragReport ~ delete _;
	bool mDragPass = true;
	// What the checks compare with: objects and undo steps before a drop, and where its preview stood.
	int mDragObjects, mDragUndo;
	Vector3 mDragPreviewAt;
	// The object selected when an asset is clicked, which Delete in the Project panel must leave.
	uint32 mDragKeptId;

	/// Remembers where the item just drawn is, while --drag-test runs.
	void NoteTestRect(StringView key)
	{
		if (mTestRects == null)
			return;
		let min = ImGui.GetItemRectMin(), max = ImGui.GetItemRectMax();
		if (mTestRects.TryGetAlt(key, let existing, ?))
			mTestRects[existing] = (min, max);
		else
			mTestRects[new String(key)] = (min, max);
	}

	ImGui.Vec2 TestRectCenter(StringView key)
	{
		for (let pair in mTestRects)
		{
			if (pair.key == key || (key.StartsWith("asset:") && pair.key.StartsWith("asset:") && pair.key.EndsWith(key.Substring(6))))
				return .((pair.value.min.x + pair.value.max.x) * 0.5f, (pair.value.min.y + pair.value.max.y) * 0.5f);
		}
		return .(-1, -1);
	}

	/// Where a point of the world is drawn in the Scene view, on the screen.
	ImGui.Vec2 ScenePoint(Vector3 point)
	{
		let viewport = mSceneCamera.WorldToViewportPoint(point);
		return .(mSceneOrigin.x + viewport.x * mSceneSize.x, mSceneOrigin.y + viewport.y * mSceneSize.y);
	}

	/// The scene's own objects, leaving out generated ones (voxel chunks streaming in as the test runs).
	int SceneObjects()
	{
		int count = 0;
		for (let gameObject in mScene.Objects)
		{
			if (!gameObject.Transient)
				count++;
		}
		return count;
	}

	void DragExpect(bool condition, StringView what)
	{
		mDragReport.AppendF("{}{}: {}", mDragReport.IsEmpty ? "" : "; ", what, condition ? "yes" : "NO");
		mDragPass &= condition;
	}

	void StartDragTest()
	{
		mDragTest = new .();
		mTestRects = new .();
		mDragReport = new .();
		mSelectedId = 0;
		let holder = mScene.CreateGameObject("Drag Holder");
		let look = holder.AddComponent<LookAtIK>();
		let target = mScene.CreateGameObject("Drag Target");
		target.AddComponent<MeshRenderer>().mesh.Set("builtin:cube");
		let forward = Quaternion.Euler(mCamPitch, mCamYaw, 0) * Vector3.Forward;
		target.Transform.Position = mCamPosition + forward * 4;
		let other = mScene.CreateGameObject("Drag Other");
		mBrowsePath.Set(scope $"{Assets.ProjectPath}/Prefabs");

		void Add(DragTestStep.Kind kind, delegate ImGui.Vec2() at = null, delegate void() run = null, int frames = 1)
		{
			let step = new DragTestStep();
			step.kind = kind;
			step.at = at;
			step.run = run;
			step.frames = frames;
			mDragTest.Add(step);
		}
		// A click: there, down, up.
		void Click(delegate ImGui.Vec2() at)
		{
			Add(.Move, at, null, 2);
			Add(.Press);
			Add(.Release);
			Add(.Wait, null, null, 3);
		}
		// A drag: down at one place, across in small moves, up at the other.
		void Drag(delegate ImGui.Vec2() from, delegate ImGui.Vec2() to, delegate void() whileHeld = null)
		{
			Add(.Move, from, null, 2);
			Add(.Press);
			Add(.Move, to, null, 12);
			Add(.Wait, null, null, 3);
			if (whileHeld != null)
				Add(.Run, null, whileHeld);
			Add(.Release);
			Add(.Wait, null, null, 4);
		}

		Add(.Wait, null, null, 20);
		// The editor must take the queued mouse: under X11 the SDL backend reads the real pointer every frame instead.
		Add(.Move, new () => ImGui.Vec2(mSceneOrigin.x + 20, mSceneOrigin.y + 20), null, 2);
		Add(.Wait, null, null, 2);
		Add(.Run, null, new () =>
			{
				let at = ImGui.GetMousePos();
				if (Math.Abs(at.x - mDragMouse.x) > 2 || Math.Abs(at.y - mDragMouse.y) > 2)
				{
					Log.Info("DRAG-TEST FAIL: the editor follows the real mouse, not the test's (on X11 run it with SDL_VIDEO_DRIVER=wayland)");
					Close();
				}
			});
		Click(new () => TestRectCenter(scope $"row:{holder.Id}"));
		Add(.Run, null, new () => DragExpect(mSelectedId == holder.Id && InspectedObject == holder, "a click on a Hierarchy row selects it"));
		Drag(new () => TestRectCenter(scope $"row:{target.Id}"), new () => TestRectCenter("field:target"));
		Add(.Run, null, new () =>
			{
				DragExpect(look.target == target.Transform, "a Hierarchy row dragged into an Inspector field fills it");
				DragExpect(mSelectedId == holder.Id, "and leaves the selection (and the Inspector) as it was");
				look.target = null;
			});

		// Dragged out of the Scene view.
		Drag(new () => ScenePoint(target.Transform.Position), new () => TestRectCenter("field:target"));
		Add(.Run, null, new () =>
			{
				DragExpect(look.target == target.Transform, "an object dragged from the Scene view into a field fills it");
				DragExpect(mSelectedId == holder.Id && !target.IsDestroyed, "and is not selected or moved");
				look.target = null;
			});
		Click(new () => ScenePoint(target.Transform.Position));
		Add(.Run, null, new () => DragExpect(mSelectedId == target.Id, "a click in the Scene view still selects"));

		// The lock: the Inspector stays on the holder while other objects are selected.
		Click(new () => TestRectCenter(scope $"row:{holder.Id}"));
		Click(new () => TestRectCenter("lock"));
		Add(.Run, null, new () => DragExpect(mInspectorLock == holder.Id, "the lock button locks the Inspector"));
		Click(new () => TestRectCenter(scope $"row:{other.Id}"));
		Add(.Run, null, new () => DragExpect(mSelectedId == other.Id && InspectedObject == holder, "locked, selecting another object leaves the Inspector on the locked one"));
		Drag(new () => TestRectCenter(scope $"row:{target.Id}"), new () => TestRectCenter("field:target"));
		Add(.Run, null, new () => DragExpect(look.target == target.Transform && mSelectedId == other.Id, "and other objects can be dragged into its fields"));
		Click(new () => TestRectCenter("lock"));
		Add(.Run, null, new () => DragExpect(mInspectorLock == 0 && InspectedObject == other, "unlocked, it follows the selection again"));

		// A prefab dragged over the Scene view is there before it is dropped.
		Add(.Run, null, new () =>
			{
				mDragObjects = SceneObjects();
				mDragUndo = mUndoStack.Count;
				DragExpect(TestRectCenter("asset:Prefabs/character.tprefab").x >= 0, "the Project panel shows the prefab");
			});
		Drag(new () => TestRectCenter("asset:Prefabs/character.tprefab"), new () => ImGui.Vec2(mSceneOrigin.x + mSceneSize.x * 0.3f, mSceneOrigin.y + mSceneSize.y * 0.6f), new () =>
			{
				DragExpect(mDropPreview != null && SceneObjects() > mDragObjects && mSelectedId == other.Id, "dragged over the Scene view, the prefab is shown there, not yet selected");
				if (mDropPreview != null)
					mDragPreviewAt = mDropPreview.Transform.Position;
			});
		Add(.Run, null, new () =>
			{
				let dropped = Selected;
				DragExpect(mDropPreview == null && dropped != null && dropped.Name.Contains("character", true), "dropped, it stays, selected");
				DragExpect(dropped != null && (dropped.Transform.Position - mDragPreviewAt).Length < 0.01f, "where the preview was");
			});
		Add(.Wait, null, null, 5);
		Add(.Run, null, new () =>
			{
				DragExpect(mUndoStack.Count == mDragUndo + 1, "as one undo step");
				mDragObjects = SceneObjects();
			});
		// Dragged over the view and away again, then let go over the Project panel: nothing is left.
		Add(.Move, new () => TestRectCenter("asset:Prefabs/character.tprefab"), null, 2);
		Add(.Press);
		Add(.Move, new () => ImGui.Vec2(mSceneOrigin.x + mSceneSize.x * 0.6f, mSceneOrigin.y + mSceneSize.y * 0.5f), null, 12);
		Add(.Wait, null, null, 3);
		Add(.Run, null, new () => DragExpect(mDropPreview != null, "a second drag shows a preview"));
		Add(.Move, new () => TestRectCenter("asset:Prefabs/character.tprefab"), null, 12);
		Add(.Release);
		Add(.Wait, null, null, 4);
		Add(.Run, null, new () => DragExpect(mDropPreview == null && SceneObjects() == mDragObjects, "dragged away and let go elsewhere, the preview is gone"));

		// Delete belongs to the panel it is pressed in.
		void PressKey(int32 key)
		{
			let step = new DragTestStep();
			step.kind = .Key;
			step.key = key;
			step.frames = 2;
			mDragTest.Add(step);
			Add(.Wait, null, null, 4);
		}
		Click(new () => TestRectCenter("asset:Prefabs/character.tprefab"));
		Add(.Run, null, new () => mDragKeptId = mSelectedId);
		PressKey(ImGui.Key.Delete);
		Add(.Run, null, new () =>
			{
				DragExpect(mDragKeptId != 0 && mScene.FindById(mDragKeptId) != null, "Delete in the Project panel leaves the selected object");
				DragExpect(mDeletePath.EndsWith("character.tprefab"), "and asks to delete the selected asset");
			});
		Click(new () => TestRectCenter("delete-asset-cancel"));
		Add(.Run, null, new () => DragExpect(File.Exists(scope $"{Assets.ProjectPath}/Prefabs/character.tprefab"), "Cancel keeps it"));
		// By id: an object deleted by mistake must fail the check, not be read after it is gone.
		let holderId = holder.Id;
		Click(new () => TestRectCenter(scope $"row:{holderId}"));
		Click(new () => TestRectCenter("lock"));
		PressKey(ImGui.Key.Delete);
		Add(.Run, null, new () => DragExpect(mScene.FindById(holderId) != null, "Delete in the Inspector leaves the object it shows"));
		Add(.Run, null, new () =>
			{
				if (mScene.FindById(holderId) == null)
				{
					Log.Info(scope $"DRAG-TEST FAIL: {mDragReport}");
					Close();
				}
			});
		Click(new () => TestRectCenter("lock"));
		let otherId = other.Id;
		Click(new () => TestRectCenter(scope $"row:{otherId}"));
		PressKey(ImGui.Key.Delete);
		Add(.Run, null, new () => DragExpect(mScene.FindById(otherId) == null, "Delete in the Hierarchy deletes the selected object"));
		Add(.Run, null, new () =>
			{
				Log.Info(scope $"DRAG-TEST {mDragPass ? "PASS" : "FAIL"}: {mDragReport}");
				Close();
			});
	}

	/// Each frame of --drag-test: queues this frame's mouse input, or runs a check.
	void TickDragTest()
	{
		if (mDragTest == null || mDragStep >= mDragTest.Count)
			return;
		let step = mDragTest[mDragStep];
		switch (step.kind)
		{
		case .Move:
			if (mDragFrame == 0)
				mDragFrom = mDragMouse;
			let to = step.at();
			let t = (mDragFrame + 1) / (float)step.frames;
			mDragMouse = .(mDragFrom.x + (to.x - mDragFrom.x) * t, mDragFrom.y + (to.y - mDragFrom.y) * t);
			ImGui.QueueMousePos(mDragMouse.x, mDragMouse.y);
		case .Press:
			ImGui.QueueMouseButton(0, true);
		case .Release:
			ImGui.QueueMouseButton(0, false);
		case .Run:
			step.run();
		case .Key:
			ImGui.QueueKey(step.key, mDragFrame == 0);
		case .Wait:
		}
		if (++mDragFrame >= step.frames)
		{
			mDragFrame = 0;
			mDragStep++;
		}
	}
}
