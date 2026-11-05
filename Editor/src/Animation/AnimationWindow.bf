using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// The Animation window: a timeline for making and editing animation clips (.tanim) on the selected object, laid
/// out like Unity's.
///   Left, top: Preview, Record, first / previous key, play, next / last key, and the frame number. Below that the
///   clip, its sample rate, Add Key and Auto Key. Then the animated children, each unfolding to Position, Rotation
///   and Scale with their values at the time marker; typing a value writes a key.
///   Right: a ruler in seconds:frames, a summary row holding every key, and one row of key diamonds per property.
///   Click or drag the ruler to move the marker; scroll to zoom, middle-drag to pan. Drag a diamond to retime it
///   (it snaps to frames), right-click or press Delete to remove it.
///   With Record or Auto Key on, moving, turning or scaling a child in the Scene view or Inspector writes a key at
///   the marker; Auto Key stays on between sessions.
/// Keys are stored as offsets from the pose the object has in the scene, so one clip suits any character whose
/// children have the same names.
extension EditorApp
{
	bool mShowAnimation;
	bool mDockAnimation = true;
	bool mAnimationFocus;
	AnimationClip mClip;
	String mClipPath = new .() ~ delete _;
	float mClipTime;
	bool mClipRecord;
	/// Auto Key: keys whatever is moved, whenever a clip is open, without arming Record each time. Remembered.
	bool mClipAutoKey;
	bool mClipAutoKeyLoaded;
	bool mClipPlaying;
	bool mClipPreview;
	bool mClipDirty;
	int mClipKeyTrack = -1, mClipKeyIndex = -1;
	bool mClipKeyDragging;
	uint32 mClipAnimatorId;
	float mClipPosedTime = -1;
	/// Preview switched off by hand: the object stays in its scene pose until the marker is moved again.
	bool mClipPreviewOff;
	float mAnimLeftWidth = 330;
	/// Zoom and scroll of the timeline. Zero pixels per second means "fit the clip", done when a clip is opened.
	float mAnimPixelsPerSecond;
	bool mAnimFit;
	float mAnimViewStart;
	float mAnimPanLastX;
	List<String> mAnimExpanded = new .() ~ DeleteContainerAndItems!(_);
	int mAnimMenuTrack = -1, mAnimMenuKey = -1;
	int mAnimDeleteTrack = -1, mAnimDeleteKey = -1;
	bool mAnimOpenKeyMenu;

	/// Opens a clip file in the Animation window. The path is a file on disk.
	public void OpenAnimationClip(StringView fullPath)
	{
		let relative = scope String();
		Assets.MakeRelative(fullPath, relative);
		let clip = AnimationClip.Load(relative);
		if (clip == null)
			return;
		mClip = clip;
		mClipPath.Set(relative);
		mClipTime = 0;
		mClipKeyTrack = mClipKeyIndex = -1;
		mAnimPixelsPerSecond = 0;
		mShowAnimation = true;
		mAnimationFocus = true;
	}

	void CreateClipAsset(StringView name)
	{
		if (!ProjectGenerator.IsValidName(name))
		{
			Log.Error("Clip names use letters, digits and underscores, and start with a letter.");
			return;
		}
		let path = scope $"{mBrowsePath}/{name}.tanim";
		if (File.Exists(path))
		{
			Log.Error(scope $"{path} already exists.");
			return;
		}
		let relative = scope String();
		Assets.MakeRelative(path, relative);
		let clip = AnimationClip.Create(relative, name);
		clip.Save(path);
		OpenAnimationClip(path);
	}

	void SaveClip()
	{
		if (mClip == null || mClipPath.IsEmpty)
			return;
		let full = scope String();
		Assets.ResolvePath(mClipPath, full);
		mClip.Save(full);
		mClipDirty = false;
	}

	/// Puts the animated object back in the pose it has in the scene. Called when previewing stops, so that the
	/// previewed pose is never what gets saved with the scene.
	void EndClipPreview()
	{
		if (!mClipPreview)
			return;
		mClipPreview = false;
		mClipPosedTime = -1;
		let object = mScene != null ? mScene.FindById(mClipAnimatorId) : null;
		let animator = object != null ? object.GetComponent<Animator>() : Animator();
		if (animator.IsValid)
		{
			let rest = scope AnimationClip();
			animator.SampleClip(rest, 0);
		}
	}

	static void Descendants(Transform parent, List<Transform> output)
	{
		for (let child in parent.Children)
		{
			output.Add(child);
			Descendants(child, output);
		}
	}

	/// Makes a clip named after the animated object, beside the project's other animations, and gives it to the
	/// Animator so that it can be played.
	void CreateClipFor(Animator animator)
	{
		let folder = scope String();
		folder.AppendF("{}/Animations", Assets.ProjectPath);
		Directory.CreateDirectory(folder).IgnoreError();
		let baseName = scope String();
		NodeLibrary.Identifier(animator.GameObject.Name, baseName);
		let path = scope String();
		for (int n = 1; n < 1000; n++)
		{
			path.Clear();
			path.AppendF("{}/{}_{}.tanim", folder, baseName, n);
			if (!File.Exists(path))
				break;
		}
		let relative = scope String();
		Assets.MakeRelative(path, relative);
		let name = scope String();
		Path.GetFileNameWithoutExtension(path, name);
		let clip = AnimationClip.Create(relative, name);
		clip.Save(path);
		OpenAnimationClip(path);
		if (mPlay == .Edit && !animator.clips.Contains(relative))
		{
			if (!animator.clips.IsEmpty)
				animator.clips.Append(';');
			animator.clips.Append(relative);
			MarkDirty();
		}
		mAnimClipChoicesFrame = -1000;
	}

	// The window's colours, from the editor's theme: panels a shade off the window, the sheet a little darker, lines
	// and ink in the theme's text colour.
	static Color AnimUi(int32 col) => ImGui.GetStyleColor(col);
	static Color AnimShade(float amount) => Color.Lerp(AnimUi(ImGui.Col.WindowBg), .(0, 0, 0, 1), amount);
	static Color AnimInk(float alpha) => .(EditorTheme.Text.r, EditorTheme.Text.g, EditorTheme.Text.b, alpha);
	static Color AnimPanel => Color.Lerp(AnimUi(ImGui.Col.WindowBg), EditorTheme.Text, 0.05f);
	static Color AnimSheet => AnimShade(EditorTheme.IsLight ? 0.06f : 0.25f);
	static Color AnimGap => AnimShade(EditorTheme.IsLight ? 0.25f : 0.55f);

	static void DrawKeyDiamond(ImGui.Vec2 center, float radius, Color color)
	{
		ImGui.DrawQuadFilled(.(center.x - radius, center.y), .(center.x, center.y - radius), .(center.x + radius, center.y), .(center.x, center.y + radius), color);
	}

	/// A toolbar button with a drawn picture: 0 record, 1 first key, 2 previous key, 3 play / pause, 4 next key,
	/// 5 last key, 6 add key.
	bool AnimIconButton(char8* id, int icon, bool active, char8* tip)
	{
		let height = ImGui.GetFrameHeight();
		let min = ImGui.GetCursorScreenPos();
		let size = ImGui.Vec2(26, height);
		let pressed = ImGui.InvisibleButton(id, size);
		let hovered = ImGui.IsItemHovered();
		if (hovered)
			ImGui.SetTooltip(tip);
		Color back = hovered ? AnimInk(0.13f) : AnimInk(0.05f);
		if (active)
			back = icon == 0 ? Color.Lerp(AnimPanel, EditorTheme.Error, 0.6f) : EditorTheme.Accent;
		ImGui.DrawRectFilled(min, .(min.x + size.x, min.y + size.y), back, 2);
		let c = ImGui.Vec2(min.x + 13, min.y + height * 0.5f);
		let ink = AnimInk(0.85f);
		const float r = 4.5f;
		void Left(float x) => ImGui.DrawTriangleFilled(.(x + r * 0.7f, c.y - r), .(x + r * 0.7f, c.y + r), .(x - r * 0.7f, c.y), ink);
		void Right(float x) => ImGui.DrawTriangleFilled(.(x - r * 0.7f, c.y - r), .(x + r * 0.7f, c.y), .(x - r * 0.7f, c.y + r), ink);
		void Bar(float x) => ImGui.DrawRectFilled(.(x - 1, c.y - r), .(x + 1, c.y + r), ink);
		switch (icon)
		{
		case 0: ImGui.DrawCircleFilled(c, 5, EditorTheme.Error);
		case 1:
			Bar(c.x - 7);
			Left(c.x - 2.5f);
			Left(c.x + 4);
		case 2:
			Bar(c.x - 4.5f);
			Left(c.x + 1);
		case 3:
			if (active)
			{
				ImGui.DrawRectFilled(.(c.x - 4, c.y - r), .(c.x - 1.5f, c.y + r), ink);
				ImGui.DrawRectFilled(.(c.x + 1.5f, c.y - r), .(c.x + 4, c.y + r), ink);
			}
			else
				ImGui.DrawTriangleFilled(.(c.x - 4, c.y - 5.5f), .(c.x + 5.5f, c.y), .(c.x - 4, c.y + 5.5f), ink);
		case 4:
			Right(c.x - 1);
			Bar(c.x + 4.5f);
		case 5:
			Right(c.x - 4);
			Right(c.x + 2.5f);
			Bar(c.x + 7);
		default:
			DrawKeyDiamond(.(c.x - 2, c.y + 1), 4.5f, ink);
			ImGui.DrawLine(.(c.x + 3, c.y - 4.5f), .(c.x + 9, c.y - 4.5f), ink, 1.5f);
			ImGui.DrawLine(.(c.x + 6, c.y - 7.5f), .(c.x + 6, c.y - 1.5f), ink, 1.5f);
		}
		return pressed;
	}

	/// The rotation angles of a track at a time, for showing in the property list.
	static Vector3 SampleEuler(AnimationClip.Track track, float time)
	{
		let keys = track.keys;
		if (keys.Count == 0)
			return .Zero;
		if (time <= keys[0].time || keys.Count == 1)
			return keys[0].euler;
		for (int i = 1; i < keys.Count; i++)
		{
			if (time <= keys[i].time)
			{
				let t = (time - keys[i - 1].time) / Math.Max(keys[i].time - keys[i - 1].time, 1.0e-5f);
				return Vector3.Lerp(keys[i - 1].euler, keys[i].euler, t);
			}
		}
		return keys.Back.euler;
	}

	bool AnimIsExpanded(StringView bone)
	{
		for (let name in mAnimExpanded)
		{
			if (name == bone)
				return true;
		}
		return false;
	}

	void AnimToggleExpanded(StringView bone)
	{
		for (int i < mAnimExpanded.Count)
		{
			if (mAnimExpanded[i] == bone)
			{
				delete mAnimExpanded[i];
				mAnimExpanded.RemoveAt(i);
				return;
			}
		}
		mAnimExpanded.Add(new String(bone));
	}

	/// One row of key diamonds for a track. Several rows may show the same track, so each has its own id base.
	void DrawTrackKeys(AnimationClip clip, int t, float y, float rowHeight, float sheetLeft, float sheetRight, int32 idBase)
	{
		let track = clip.tracks[t];
		ImGui.PushClipRect(.(sheetLeft, y), .(sheetRight, y + rowHeight));
		for (int k < track.keys.Count)
		{
			let x = sheetLeft + (track.keys[k].time - mAnimViewStart) * mAnimPixelsPerSecond;
			if (x < sheetLeft + 1 || x > sheetRight)
				continue;
			let selected = mClipKeyTrack == t && mClipKeyIndex == k;
			ImGui.SetCursorScreenPos(.(Math.Max(x - 6, sheetLeft), y + 2));
			ImGui.PushID(idBase + (int32)k);
			ImGui.InvisibleButton("##key", .(12, rowHeight - 4));
			let hovered = ImGui.IsItemHovered();
			if (ImGui.IsItemClicked(0))
			{
				mClipKeyTrack = t;
				mClipKeyIndex = k;
				mClipTime = track.keys[k].time;
				mClipPlaying = false;
				mClipPreviewOff = false;
			}
			if (ImGui.IsItemActive() && ImGui.IsMouseDragging(0, 3) && selected)
				mClipKeyDragging = true;
			if (ImGui.IsItemClicked(1))
			{
				mAnimMenuTrack = t;
				mAnimMenuKey = k;
				mAnimOpenKeyMenu = true;
			}
			ImGui.PopID();
			let center = ImGui.Vec2(x, y + rowHeight * 0.5f);
			DrawKeyDiamond(center, 6, AnimGap);
			DrawKeyDiamond(center, 4.5f, selected ? EditorTheme.Accent : hovered ? AnimInk(1) : AnimInk(0.75f));
		}
		ImGui.PopClipRect();
	}

	/// Text and, optionally, a button in the middle of the window, as Unity shows when there is nothing to edit.
	bool AnimationMessage(char8* text, char8* button)
	{
		let avail = ImGui.GetContentRegionAvail();
		let pos = ImGui.GetCursorScreenPos();
		let size = ImGui.CalcTextSize(text);
		ImGui.SetCursorScreenPos(.(pos.x + Math.Max((avail.x - size.x) * 0.5f, 8), pos.y + Math.Max(avail.y * 0.5f - 26, 8)));
		ImGui.TextDisabled(text);
		if (button == null)
			return false;
		ImGui.SetCursorScreenPos(.(pos.x + Math.Max((avail.x - 96) * 0.5f, 8), pos.y + Math.Max(avail.y * 0.5f, 34)));
		return ImGui.Button(button, .(96, 0));
	}

	/// Where the Animation window's parts are this frame, and how time maps onto the dopesheet.
	struct Timeline
	{
		public ImGui.Vec2 origin;
		public ImGui.Vec2 avail;
		public ImGui.Vec2 mouse;
		public float rowHeight;
		public float footerHeight;
		public float leftWidth;
		public float sheetLeft;
		public float sheetRight;
		public float sheetWidth;
		public float bottom;
		/// The clip's frames per second.
		public float rate;
		public float pixelsPerSecond;
		public float viewStart;
		/// The ruler's labelled frames: every `step`th, from `firstFrame`.
		public int32 step;
		public int32 firstFrame;

		public float TimeToX(float time) => sheetLeft + (time - viewStart) * pixelsPerSecond;
		public float XToTime(float x) => viewStart + (x - sheetLeft) / pixelsPerSecond;
		/// A time moved onto the nearest frame.
		public float Snap(float time) => (float)Math.Round(Math.Max(time, 0) * rate) / rate;
		public float RowsTop => origin.y + rowHeight * 2;
		public float RowsHeight => Math.Max(avail.y - rowHeight * 2 - footerHeight, 20);
	}

	void DrawAnimation()
	{
		if (!mShowAnimation)
		{
			EndClipPreview();
			return;
		}
		// Along the bottom with Project and Console the first time, like a timeline; it can be moved from there.
		if (mDockAnimation && mBottomDock != 0)
		{
			ImGui.SetNextWindowDockID(mBottomDock);
			mDockAnimation = false;
			mAnimationFocus = true;
		}
		if (mAnimationFocus && Time.FrameCount > 30)
		{
			ImGui.SetNextWindowFocus();
			mAnimationFocus = false;
		}
		// The timeline runs edge to edge.
		ImGui.PushStyleVar(ImGui.StyleVar.WindowPadding, ImGui.Vec2(0, 0));
		let open = ImGui.Begin("Animation", &mShowAnimation, ImGui.WindowFlags.NoScrollbar | ImGui.WindowFlags.NoScrollWithMouse);
		ImGui.PopStyleVar();
		let drewTimeline = open && DrawAnimationContents();
		ImGui.End();
		if (drewTimeline && mClipDirty && !ImGui.IsMouseDown(0))
			SaveClip();
	}

	/// The window's contents. False when there was no timeline to show (no Animator or clip), or another clip was
	/// just chosen.
	bool DrawAnimationContents()
	{
		let editing = mPlay == .Edit;
		let animator = SelectedAnimator();
		if (!animator.IsValid)
		{
			DrawNoAnimator(editing);
			return false;
		}
		FollowAnimator(animator);
		if (mClip == null)
		{
			DrawNoClip(animator);
			return false;
		}

		let clip = mClip;
		var view = LayoutTimeline(clip);
		let recording = mClipRecord && editing;
		List<float> keyTimes = scope .();
		CollectKeyTimes(clip, keyTimes);
		DrawTimelineBackground(view, recording);
		ImGui.PushStyleVar(ImGui.StyleVar.ItemSpacing, ImGui.Vec2(2, 2));
		DrawTransportBar(view, keyTimes, editing);
		let sameClip = DrawClipBar(view, animator, clip, editing);
		ImGui.PopStyleVar();
		// Another clip was chosen: start over with it next frame.
		if (!sameClip)
			return false;
		DrawRuler(ref view, clip, keyTimes, editing);

		List<Transform> children = scope .();
		Descendants(animator.Transform, children);
		RecordMovedChildren(animator, clip, children, editing);
		PoseAtMarker(animator, clip, editing);
		let removeTrack = DrawTrackRows(view, animator, clip, children, editing);
		DrawMarkerHead(view, clip, recording);
		DragSelectedKey(view, clip, editing);
		DeleteKeys(clip, editing, removeTrack);
		DrawTimelineFooter(view, animator, clip);
		return true;
	}

	/// No Animator on the selection: says so, and offers to make an Animator and a clip.
	void DrawNoAnimator(bool editing)
	{
		EndClipPreview();
		let selected = Selected;
		if (selected == null)
		{
			AnimationMessage("No animatable object selected.", null);
			return;
		}
		let text = scope String();
		text.AppendF("To begin animating {}, create an Animator and an Animation Clip.", selected.Name);
		ImGui.BeginDisabled(!editing);
		if (AnimationMessage(text.CStr(), "Create"))
		{
			CreateClipFor(selected.AddComponent<Animator>());
			MarkDirty();
		}
		ImGui.EndDisabled();
	}

	/// A different object: drops the pose previewed on the last one, and opens a clip of its own.
	void FollowAnimator(Animator animator)
	{
		if (animator.GameObject.Id == mClipAnimatorId)
			return;
		EndClipPreview();
		mClipAnimatorId = animator.GameObject.Id;
		if (animator.clips.IsEmpty || (!mClipPath.IsEmpty && animator.clips.Contains(mClipPath)))
			return;
		for (var path in animator.clips.Split(';'))
		{
			path.Trim();
			let full = scope String();
			Assets.ResolvePath(path, full);
			if (path.IsEmpty || !File.Exists(full))
				continue;
			if (mClipDirty)
				SaveClip();
			let focus = mAnimationFocus;
			OpenAnimationClip(full);
			mAnimationFocus = focus;
			break;
		}
	}

	/// An Animator with no clip open: offers to make one, or to open one of the project's.
	void DrawNoClip(Animator animator)
	{
		let text = scope String();
		text.AppendF("To begin animating {}, create an Animation Clip.", animator.GameObject.Name);
		if (AnimationMessage(text.CStr(), "Create"))
			CreateClipFor(animator);
		let avail = ImGui.GetContentRegionAvail();
		let pos = ImGui.GetCursorScreenPos();
		ImGui.SetCursorScreenPos(.(pos.x + Math.Max((avail.x - 240) * 0.5f, 8), pos.y + 6));
		ImGui.SetNextItemWidth(240);
		if (mClip == null && ImGui.BeginCombo("##openclip", "or open a clip..."))
		{
			RefreshClipChoices();
			for (let choice in mAnimClipChoices)
			{
				if (ImGui.Selectable(choice.CStr(), false))
				{
					let full = scope String();
					Assets.ResolvePath(choice, full);
					OpenAnimationClip(full);
				}
			}
			ImGui.EndCombo();
		}
	}

	/// The window's layout, with the view zoomed by the wheel and panned by a middle-drag over the dopesheet.
	Timeline LayoutTimeline(AnimationClip clip)
	{
		Timeline view = default;
		view.rate = Mathf.Clamp(clip.frameRate, 1, 240);
		view.origin = ImGui.GetCursorScreenPos();
		view.avail = ImGui.GetContentRegionAvail();
		view.mouse = ImGui.GetMousePos();
		view.rowHeight = ImGui.GetFrameHeight() + 2;
		view.footerHeight = view.rowHeight + 4;
		mAnimLeftWidth = Mathf.Clamp(mAnimLeftWidth, 330, Math.Max(view.avail.x - 160, 330));
		view.leftWidth = mAnimLeftWidth;
		view.sheetLeft = view.origin.x + view.leftWidth + 3;
		view.sheetRight = view.origin.x + view.avail.x;
		view.sheetWidth = Math.Max(view.sheetRight - view.sheetLeft, 40);
		view.bottom = view.origin.y + view.avail.y;
		if (mAnimPixelsPerSecond <= 0 || mAnimFit)
		{
			// The whole clip stays in view, whatever the window's size, until the view is zoomed or panned.
			mAnimFit = true;
			mAnimPixelsPerSecond = (view.sheetWidth - 24) / Math.Max(clip.duration * 1.12f, 0.25f);
			mAnimViewStart = -12 / mAnimPixelsPerSecond;
		}
		let mouse = view.mouse;
		let overSheet = ImGui.IsWindowHovered(ImGui.HoveredFlags.ChildWindows) && mouse.x >= view.sheetLeft && mouse.x <= view.sheetRight
			&& mouse.y >= view.origin.y && mouse.y <= view.bottom - view.footerHeight;
		if (overSheet && Input.MouseWheel != 0)
		{
			let at = mAnimViewStart + (mouse.x - view.sheetLeft) / mAnimPixelsPerSecond;
			mAnimPixelsPerSecond = Mathf.Clamp(mAnimPixelsPerSecond * Math.Pow(1.18f, Input.MouseWheel), 8, 8000);
			mAnimViewStart = at - (mouse.x - view.sheetLeft) / mAnimPixelsPerSecond;
			mAnimFit = false;
		}
		if (overSheet && ImGui.IsMouseClicked(2))
		{
			mAnimPanLastX = mouse.x;
			mAnimFit = false;
		}
		else if (ImGui.IsMouseDown(2) && mAnimPanLastX != 0)
		{
			mAnimViewStart -= (mouse.x - mAnimPanLastX) / mAnimPixelsPerSecond;
			mAnimPanLastX = mouse.x;
		}
		else
			mAnimPanLastX = 0;
		mAnimViewStart = Math.Max(mAnimViewStart, -view.sheetWidth * 0.5f / mAnimPixelsPerSecond);
		view.pixelsPerSecond = mAnimPixelsPerSecond;
		view.viewStart = mAnimViewStart;
		return view;
	}

	/// Every time that has a key, in order: the summary row, and where previous / next key go.
	static void CollectKeyTimes(AnimationClip clip, List<float> keyTimes)
	{
		for (let track in clip.tracks)
		{
			for (let key in track.keys)
			{
				int at = 0;
				bool have = false;
				while (at < keyTimes.Count && keyTimes[at] <= key.time + 0.0001f)
				{
					have |= Math.Abs(keyTimes[at] - key.time) < 0.0002f;
					at++;
				}
				if (!have)
					keyTimes.Insert(at, key.time);
			}
		}
	}

	static void DrawTimelineBackground(Timeline view, bool recording)
	{
		let origin = view.origin;
		let rowHeight = view.rowHeight;
		let panel = AnimPanel;
		ImGui.DrawRectFilled(origin, .(origin.x + view.leftWidth, origin.y + rowHeight * 2), panel);
		ImGui.DrawRectFilled(.(view.sheetLeft, origin.y), .(view.sheetRight, origin.y + rowHeight), recording ? Color.Lerp(AnimUi(ImGui.Col.FrameBg), EditorTheme.Error, 0.35f) : AnimUi(ImGui.Col.FrameBg));
		ImGui.DrawRectFilled(.(view.sheetLeft, origin.y + rowHeight), .(view.sheetRight, origin.y + rowHeight * 2), AnimSheet);
		ImGui.DrawRectFilled(.(origin.x, view.bottom - view.footerHeight), .(view.sheetRight, view.bottom), panel);
		ImGui.DrawRectFilled(.(origin.x + view.leftWidth, origin.y), .(view.sheetLeft, view.bottom - view.footerHeight), AnimGap);
		ImGui.DrawLine(.(origin.x, origin.y + rowHeight * 2 - 1), .(view.sheetRight, origin.y + rowHeight * 2 - 1), AnimGap);
	}

	/// The toolbar's first row: preview, record, the transport buttons and the frame at the marker.
	void DrawTransportBar(Timeline view, List<float> keyTimes, bool editing)
	{
		let origin = view.origin;
		ImGui.BeginDisabled(!editing);
		ImGui.SetCursorScreenPos(.(origin.x + 4, origin.y + 1));
		let previewing = mClipPreview && !mClipPreviewOff;
		if (previewing)
			ImGui.PushStyleColor(ImGui.Col.Button, EditorTheme.Accent);
		if (ImGui.Button("Preview", .(0, ImGui.GetFrameHeight())))
		{
			if (previewing)
			{
				EndClipPreview();
				mClipPreviewOff = true;
				mClipRecord = false;
				mClipPlaying = false;
			}
			else
				mClipPreviewOff = false;
		}
		if (previewing)
			ImGui.PopStyleColor();
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Show the clip's pose on the object. Off puts the object back in its scene pose.");
		ImGui.SameLine();
		if (AnimIconButton("##record", 0, mClipRecord, "Record: moving, turning or scaling a child writes a key at the time marker."))
		{
			mClipRecord = !mClipRecord;
			mClipPreviewOff = false;
		}
		ImGui.SameLine(0, 8);
		float jump = -1;
		if (AnimIconButton("##first", 1, false, "Go to the first key") && keyTimes.Count > 0)
			jump = keyTimes[0];
		ImGui.SameLine();
		if (AnimIconButton("##previous", 2, false, "Go to the previous key"))
		{
			for (let time in keyTimes)
			{
				if (time < mClipTime - 0.0005f)
					jump = time;
			}
		}
		ImGui.SameLine();
		if (AnimIconButton("##play", 3, mClipPlaying, "Play the clip"))
		{
			mClipPlaying = !mClipPlaying;
			mClipPreviewOff = false;
		}
		ImGui.SameLine();
		if (AnimIconButton("##next", 4, false, "Go to the next key"))
		{
			for (let time in keyTimes)
			{
				if (time > mClipTime + 0.0005f)
				{
					jump = time;
					break;
				}
			}
		}
		ImGui.SameLine();
		if (AnimIconButton("##last", 5, false, "Go to the last key") && keyTimes.Count > 0)
			jump = keyTimes.Back;
		if (jump >= 0)
		{
			mClipTime = jump;
			mClipPlaying = false;
			mClipPreviewOff = false;
		}
		ImGui.SetCursorScreenPos(.(origin.x + view.leftWidth - 60, origin.y + 1));
		ImGui.SetNextItemWidth(56);
		int32 frame = (int32)Math.Round(mClipTime * view.rate);
		if (ImGui.DragInt("##frame", ref frame, 0.25f, 0, 1000000))
		{
			mClipTime = Math.Max(frame, 0) / view.rate;
			mClipPlaying = false;
			mClipPreviewOff = false;
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Frame at the time marker");
		ImGui.EndDisabled();
	}

	/// The toolbar's second row: the clip, its sample rate, Add Key, Key IK and Auto Key. False when another clip
	/// was chosen (or made), which is drawn from the next frame.
	bool DrawClipBar(Timeline view, Animator animator, AnimationClip clip, bool editing)
	{
		let origin = view.origin;
		ImGui.SetCursorScreenPos(.(origin.x + 4, origin.y + view.rowHeight + 1));
		ImGui.SetNextItemWidth(Math.Max(view.leftWidth - (40 + 26 + 58 + 66 + 8 * 4) - 12, 60));
		let clipLabel = scope String();
		Path.GetFileNameWithoutExtension(mClipPath, clipLabel);
		bool createClip = false;
		if (ImGui.BeginCombo("##clip", clipLabel.CStr()))
		{
			RefreshClipChoices();
			for (let choice in mAnimClipChoices)
			{
				if (ImGui.Selectable(choice.CStr(), choice == mClipPath))
				{
					if (mClipDirty)
						SaveClip();
					let full = scope String();
					Assets.ResolvePath(choice, full);
					OpenAnimationClip(full);
				}
			}
			ImGui.Separator();
			createClip = ImGui.Selectable("Create New Clip...", false);
			ImGui.EndCombo();
		}
		if (createClip)
		{
			if (mClipDirty)
				SaveClip();
			CreateClipFor(animator);
		}
		if (mClip != clip)
			return false;
		ImGui.BeginDisabled(!editing);
		LoadAutoKeyChoice();
		// Samples, Add Key, Key IK and Auto Key end at the left panel's edge, never over the timeline.
		let spacing = 8;
		let barWidth = 40 + 26 + 58 + 66 + spacing * 3;
		ImGui.SetCursorScreenPos(.(origin.x + view.leftWidth - barWidth - 4, origin.y + view.rowHeight + 1));
		ImGui.SetNextItemWidth(40);
		int32 samples = (int32)view.rate;
		if (ImGui.DragInt("##samples", ref samples, 0.25f, 1, 240))
		{
			clip.frameRate = Mathf.Clamp(samples, 1, 240);
			mClipDirty = true;
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Samples: frames per second. Keys sit on these frames.");
		ImGui.SameLine();
		if (AnimIconButton("##addkey", 6, false, "Add a key at the time marker for the selected child,\nor for every animated child when the Animator's object is selected."))
			KeySelectedChild(animator);
		ImGui.SameLine();
		if (ImGui.Button("Key IK", .(58, ImGui.GetFrameHeight())))
			KeyIK(animator);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Writes the pose IK is making now into the clip, as keys at the time marker on every bone IK moves:\na hand held on a target, curled fingers, a turned head. The clip then plays that pose without the IK.");
		ImGui.SameLine();
		if (mClipAutoKey)
			ImGui.PushStyleColor(ImGui.Col.Button, EditorTheme.Warning);
		let wasAutoKey = mClipAutoKey;
		if (ImGui.Button("Auto Key", .(66, ImGui.GetFrameHeight())))
		{
			mClipAutoKey = !mClipAutoKey;
			File.WriteAllText(AutoKeyFile(.. scope .()), mClipAutoKey ? "1" : "0").IgnoreError();
		}
		if (wasAutoKey)
			ImGui.PopStyleColor();
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Key anything you move, turn or scale at the time marker, every time a clip is open.\nRecord does the same until you turn it off or close the window.");
		ImGui.EndDisabled();
		return true;
	}

	/// Where the Auto Key choice is kept between sessions, with the editor's other settings.
	static void AutoKeyFile(String file)
	{
		RecentProjects.GetConfigFolder(file);
		file.Append("animation_autokey.txt");
	}

	void LoadAutoKeyChoice()
	{
		if (mClipAutoKeyLoaded)
			return;
		mClipAutoKeyLoaded = true;
		let saved = scope String();
		mClipAutoKey = (File.ReadAllText(AutoKeyFile(.. scope .()), saved) case .Ok) && saved.StartsWith("1");
	}

	/// The ruler (click or drag it to move the time marker) and the summary row of every key; also moves the marker
	/// on while the clip plays. Fills in the view's ruler steps, which the rows below line up with.
	void DrawRuler(ref Timeline view, AnimationClip clip, List<float> keyTimes, bool editing)
	{
		let origin = view.origin;
		let rowHeight = view.rowHeight;
		let rate = view.rate;
		ImGui.SetCursorScreenPos(.(view.sheetLeft, origin.y));
		ImGui.InvisibleButton("##ruler", .(view.sheetWidth, rowHeight * 2 - 1));
		if (ImGui.IsItemActive())
		{
			mClipTime = view.Snap(view.XToTime(view.mouse.x));
			mClipPlaying = false;
			mClipPreviewOff = false;
		}
		mClipTime = Math.Max(mClipTime, 0);
		if (mClipPlaying && editing)
		{
			mClipTime += Time.UnscaledDeltaTime;
			if (mClipTime > clip.duration)
				mClipTime = clip.loop ? mClipTime % clip.duration : clip.duration;
			if (mClipTime >= clip.duration && !clip.loop)
				mClipPlaying = false;
		}
		// Labels are seconds:frames. The gap between them follows the zoom.
		int32[?] steps = .(1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200, 3600, 7200);
		view.step = steps[steps.Count - 1];
		for (let candidate in steps)
		{
			if (candidate / rate * view.pixelsPerSecond >= 64)
			{
				view.step = candidate;
				break;
			}
		}
		let step = view.step;
		int32 minor = step >= 5 && step % 5 == 0 ? step / 5 : (step > 1 ? (int32)1 : (int32)0);
		view.firstFrame = (int32)Math.Floor(Math.Max(view.viewStart, 0) * rate / step) * step;
		let wholeRate = Math.Max((int32)Math.Round(rate), 1);
		ImGui.PushClipRect(.(view.sheetLeft, origin.y), .(view.sheetRight, origin.y + rowHeight * 2));
		for (int32 f = view.firstFrame; view.TimeToX(f / rate) < view.sheetRight; f += step)
		{
			let x = view.TimeToX(f / rate);
			ImGui.DrawLine(.(x, origin.y + rowHeight * 0.35f), .(x, origin.y + rowHeight), AnimInk(0.42f));
			let label = scope String();
			label.AppendF("{}:{:00}", f / wholeRate, f % wholeRate);
			ImGui.DrawText(.(x + 4, origin.y + 1), AnimInk(0.55f), label.CStr());
			if (minor <= 0)
				continue;
			for (int32 m = f + minor; m < f + step; m += minor)
			{
				let minorX = view.TimeToX(m / rate);
				ImGui.DrawLine(.(minorX, origin.y + rowHeight * 0.68f), .(minorX, origin.y + rowHeight), AnimInk(0.22f));
			}
		}
		for (let time in keyTimes)
		{
			let center = ImGui.Vec2(view.TimeToX(time), origin.y + rowHeight * 1.5f);
			DrawKeyDiamond(center, 6, AnimGap);
			DrawKeyDiamond(center, 4.5f, AnimInk(0.75f));
		}
		ImGui.PopClipRect();
	}

	/// Recording (Record or Auto Key): a child moved by hand since it was posed becomes a key at the marker.
	void RecordMovedChildren(Animator animator, AnimationClip clip, List<Transform> children, bool editing)
	{
		if (!editing || !(mClipRecord || mClipAutoKey) || !mClipPreview || mClipPlaying || mClipPosedTime != mClipTime || ImGui.IsMouseDown(0))
			return;
		for (let child in children)
		{
			Vector3 restPosition, restScale;
			Quaternion restRotation;
			if (!animator.RestPose(child, out restPosition, out restRotation, out restScale))
				continue;
			Vector3 position = .Zero, scale = .(1, 1, 1);
			Quaternion rotation = .Identity;
			let track = clip.FindTrack(child.GameObject.Name);
			if (track != null)
				track.Sample(mClipTime, out position, out rotation, out scale);
			let expectedPosition = restPosition + position;
			let expectedRotation = (restRotation * rotation).Normalized;
			let expectedScale = Vector3(restScale.x * scale.x, restScale.y * scale.y, restScale.z * scale.z);
			// A bone that IK moves is judged by the pose under the IK: only moving it by hand makes a key, not IK
			// bending it. (Key IK writes what IK makes of it, when that is what is wanted.)
			var nowPosition = child.LocalPosition;
			var nowRotation = child.LocalRotation;
			Vector3 underPosition;
			Quaternion underRotation;
			if (IKSystem.InputPose(child, out underPosition, out underRotation))
			{
				nowPosition = underPosition;
				nowRotation = underRotation;
			}
			let turned = Math.Abs(Quaternion.Dot(expectedRotation, nowRotation)) < 0.99999f;
			if ((nowPosition - expectedPosition).Length > 0.0005f || (child.LocalScale - expectedScale).Length > 0.0005f || turned)
				KeyChild(animator, child);
		}
	}

	/// Poses the object as the clip has it at the marker (with IK on top), when the marker moved.
	void PoseAtMarker(Animator animator, AnimationClip clip, bool editing)
	{
		if (!editing)
		{
			mClipPreview = false;
			return;
		}
		if (mClipPreviewOff || (mClipPosedTime == mClipTime && mClipPreview))
			return;
		animator.SampleClip(clip, mClipTime);
		// IK on top of the clip's pose at once, so that the view never shows a frame without it.
		IKSystem.Solve(mScene);
		mClipPosedTime = mClipTime;
		mClipPreview = true;
	}

	/// The property list and the dopesheet, scrolling together. Returns the track whose row was asked to be
	/// removed, or -1.
	int DrawTrackRows(Timeline view, Animator animator, AnimationClip clip, List<Transform> children, bool editing)
	{
		int removeTrack = -1;
		let origin = view.origin;
		let rowsTop = view.RowsTop;
		let rowsHeight = view.RowsHeight;
		ImGui.SetCursorScreenPos(.(origin.x, rowsTop));
		ImGui.BeginChild("##rows", .(view.avail.x, rowsHeight), 0, ImGui.WindowFlags.NoScrollWithMouse);
		let start = ImGui.GetCursorScreenPos();
		let rowsBottom = rowsTop + rowsHeight;
		if (ImGui.IsWindowHovered() && view.mouse.x < view.sheetLeft && Input.MouseWheel != 0)
			ImGui.SetScrollY(Mathf.Clamp(ImGui.GetScrollY() - Input.MouseWheel * view.rowHeight * 2, 0, ImGui.GetScrollMaxY()));
		ImGui.DrawRectFilled(.(origin.x, rowsTop), .(origin.x + view.leftWidth, rowsBottom), AnimPanel);
		ImGui.DrawRectFilled(.(origin.x + view.leftWidth, rowsTop), .(view.sheetLeft, rowsBottom), AnimGap);
		ImGui.DrawRectFilled(.(view.sheetLeft, rowsTop), .(view.sheetRight, rowsBottom), AnimSheet);
		// The divider between the two halves can be dragged.
		ImGui.SetCursorScreenPos(.(origin.x + view.leftWidth, rowsTop));
		ImGui.InvisibleButton("##split", .(3, rowsHeight));
		if (ImGui.IsItemActive())
			mAnimLeftWidth = view.mouse.x - origin.x;
		// Faint lines down the sheet at the ruler's labelled frames.
		ImGui.PushClipRect(.(view.sheetLeft, rowsTop), .(view.sheetRight, rowsBottom));
		for (int32 f = view.firstFrame; view.TimeToX(f / view.rate) < view.sheetRight; f += view.step)
			ImGui.DrawLine(.(view.TimeToX(f / view.rate), rowsTop), .(view.TimeToX(f / view.rate), rowsBottom), AnimInk(0.05f));
		ImGui.PopClipRect();

		float y = start.y;
		int row = 0;
		for (int t < clip.tracks.Count)
		{
			ImGui.PushID((int32)t + 500);
			if (DrawTrackRow(view, clip, t, children, editing, ref y, ref row))
				removeTrack = t;
			ImGui.PopID();
		}
		DrawAddProperty(view, animator, clip, children, editing, y);

		// Past the end of the clip is darker, and the time marker runs over every row.
		ImGui.PushClipRect(.(view.sheetLeft, rowsTop), .(view.sheetRight, rowsBottom));
		ImGui.DrawRectFilled(.(Math.Max(view.TimeToX(clip.duration), view.sheetLeft), rowsTop), .(view.sheetRight, rowsBottom), .(0, 0, 0, EditorTheme.IsLight ? 0.1f : 0.28f));
		if (view.TimeToX(0) > view.sheetLeft)
			ImGui.DrawRectFilled(.(view.sheetLeft, rowsTop), .(view.TimeToX(0), rowsBottom), .(0, 0, 0, EditorTheme.IsLight ? 0.1f : 0.28f));
		ImGui.DrawLine(.(view.TimeToX(mClipTime), rowsTop), .(view.TimeToX(mClipTime), rowsBottom), AnimInk(0.95f), 1);
		ImGui.PopClipRect();
		ImGui.EndChild();
		return removeTrack;
	}

	/// One animated child's row (and, unfolded, its Position, Rotation and Scale rows) at `y`, moving `y` and `row`
	/// on past them. True when its menu asked for the row to be removed.
	bool DrawTrackRow(Timeline view, AnimationClip clip, int t, List<Transform> children, bool editing, ref float y, ref int row)
	{
		let origin = view.origin;
		let rowHeight = view.rowHeight;
		let leftWidth = view.leftWidth;
		let lineOffset = (rowHeight - ImGui.GetTextLineHeight()) * 0.5f;
		let track = clip.tracks[t];
		bool remove = false;
		// A row whose child is missing from this object is shown dimmed: the clip still has it for others.
		Transform childTransform = null;
		for (let child in children)
		{
			if (child.GameObject.Name == track.bone)
				childTransform = child;
		}
		let expanded = AnimIsExpanded(track.bone);
		let isSelected = childTransform != null && Selected == childTransform.GameObject;
		ImGui.SetCursorScreenPos(.(origin.x, y));
		ImGui.InvisibleButton("##row", .(leftWidth, rowHeight));
		if (ImGui.IsItemClicked(0))
		{
			if (view.mouse.x < origin.x + 22 || ImGui.IsMouseDoubleClicked(0))
				AnimToggleExpanded(track.bone);
			else if (childTransform != null)
				mSelectedId = childTransform.GameObject.Id;
		}
		let rowHovered = ImGui.IsItemHovered();
		if (ImGui.BeginPopupContextItem("rowmenu"))
		{
			if (ImGui.MenuItem("Remove Properties"))
				remove = true;
			ImGui.EndPopup();
		}
		if (isSelected)
			ImGui.DrawRectFilled(.(origin.x, y), .(origin.x + leftWidth, y + rowHeight), AnimUi(ImGui.Col.Header));
		else if (rowHovered)
			ImGui.DrawRectFilled(.(origin.x, y), .(origin.x + leftWidth, y + rowHeight), AnimInk(0.05f));
		let arrow = ImGui.Vec2(origin.x + 12, y + rowHeight * 0.5f);
		let arrowColor = AnimInk(0.75f);
		if (expanded)
			ImGui.DrawTriangleFilled(.(arrow.x - 4, arrow.y - 2.5f), .(arrow.x + 4, arrow.y - 2.5f), .(arrow.x, arrow.y + 3.5f), arrowColor);
		else
			ImGui.DrawTriangleFilled(.(arrow.x - 2.5f, arrow.y - 4), .(arrow.x + 3.5f, arrow.y), .(arrow.x - 2.5f, arrow.y + 4), arrowColor);
		ImGui.DrawText(.(origin.x + 24, y + lineOffset), childTransform != null ? EditorTheme.Text : EditorTheme.TextDim, track.bone.CStr());
		if (row % 2 == 1)
			ImGui.DrawRectFilled(.(view.sheetLeft, y), .(view.sheetRight, y + rowHeight), .(1, 1, 1, 0.025f));
		DrawTrackKeys(clip, t, y, rowHeight, view.sheetLeft, view.sheetRight, 0);
		y += rowHeight;
		row++;
		if (!expanded)
			return remove;

		Vector3 position, scale;
		Quaternion rotation;
		track.Sample(mClipTime, out position, out rotation, out scale);
		var euler = SampleEuler(track, mClipTime);
		bool changed = false;
		for (int32 p < 3)
		{
			ImGui.DrawText(.(origin.x + 40, y + lineOffset), EditorTheme.TextDim, p == 0 ? "Position" : p == 1 ? "Rotation" : "Scale");
			let fieldWidth = Mathf.Clamp(leftWidth - 118, 120, 220);
			ImGui.SetCursorScreenPos(.(origin.x + leftWidth - fieldWidth - 4, y + 1));
			ImGui.SetNextItemWidth(fieldWidth);
			ImGui.PushID(p);
			ImGui.BeginDisabled(!editing);
			if (p == 0)
				changed |= ImGui.DragFloat3("##value", ref position, 0.01f);
			else if (p == 1)
				changed |= ImGui.DragFloat3("##value", ref euler, 0.5f, 0, 0, "%.1f");
			else
				changed |= ImGui.DragFloat3("##value", ref scale, 0.01f);
			ImGui.EndDisabled();
			ImGui.PopID();
			if (row % 2 == 1)
				ImGui.DrawRectFilled(.(view.sheetLeft, y), .(view.sheetRight, y + rowHeight), .(1, 1, 1, 0.025f));
			DrawTrackKeys(clip, t, y, rowHeight, view.sheetLeft, view.sheetRight, (p + 1) * 100000);
			y += rowHeight;
			row++;
		}
		if (changed)
		{
			// A typed value is a key at the marker, as in Unity.
			mClipTime = view.Snap(mClipTime);
			int index;
			clip.AutoKey(track.bone, mClipTime, position, euler, scale, out index);
			mClipKeyTrack = t;
			mClipKeyIndex = index;
			mClipPosedTime = -1;
			mClipPreviewOff = false;
			mClipDirty = true;
		}
		return remove;
	}

	/// The Add Property button under the rows: a key for a child the clip does not animate yet.
	void DrawAddProperty(Timeline view, Animator animator, AnimationClip clip, List<Transform> children, bool editing, float y)
	{
		let origin = view.origin;
		ImGui.SetCursorScreenPos(.(origin.x + Math.Max((view.leftWidth - 140) * 0.5f, 4), y + 8));
		ImGui.BeginDisabled(!editing);
		if (ImGui.Button("Add Property", .(140, 0)))
			ImGui.OpenPopup("addproperty");
		ImGui.EndDisabled();
		if (ImGui.BeginPopup("addproperty"))
		{
			bool any = false;
			for (let child in children)
			{
				if (clip.FindTrack(child.GameObject.Name) != null)
					continue;
				any = true;
				if (ImGui.Selectable(scope String(child.GameObject.Name).CStr(), false))
				{
					KeyChild(animator, child);
					AnimToggleExpanded(child.GameObject.Name);
				}
			}
			if (!any)
				ImGui.TextDisabled(children.Count == 0 ? "This object has no children to animate.\nClips move the objects beneath the Animator." : "Every child is already animated.");
			ImGui.EndPopup();
		}
		ImGui.SetCursorScreenPos(.(origin.x, y + view.rowHeight + 18));
		ImGui.Dummy(.(1, 1));
	}

	/// The divider beside the toolbar rows, and the time marker's head in the ruler.
	void DrawMarkerHead(Timeline view, AnimationClip clip, bool recording)
	{
		let origin = view.origin;
		ImGui.SetCursorScreenPos(.(origin.x + view.leftWidth, origin.y));
		ImGui.InvisibleButton("##splittop", .(3, view.rowHeight * 2));
		if (ImGui.IsItemActive())
			mAnimLeftWidth = view.mouse.x - origin.x;
		ImGui.PushClipRect(.(view.sheetLeft, origin.y), .(view.sheetRight, view.RowsTop));
		let x = view.TimeToX(mClipTime);
		let headColor = recording ? EditorTheme.Error : AnimInk(0.95f);
		ImGui.DrawRectFilled(.(Math.Max(view.TimeToX(clip.duration), view.sheetLeft), origin.y + view.rowHeight), .(view.sheetRight, view.RowsTop), .(0, 0, 0, EditorTheme.IsLight ? 0.1f : 0.28f));
		ImGui.DrawLine(.(x, origin.y), .(x, view.RowsTop), headColor, 1);
		ImGui.DrawRectFilled(.(x - 1, origin.y), .(x + 2, origin.y + view.rowHeight * 0.45f), headColor);
		ImGui.PopClipRect();
	}

	/// The selected key follows the mouse while it is dragged, frame by frame, and stays this key even as it passes
	/// its neighbours.
	void DragSelectedKey(Timeline view, AnimationClip clip, bool editing)
	{
		if (!ImGui.IsMouseDown(0))
			mClipKeyDragging = false;
		if (!mClipKeyDragging || !editing || mClipKeyTrack < 0 || mClipKeyTrack >= clip.tracks.Count || mClipKeyIndex < 0 || mClipKeyIndex >= clip.tracks[mClipKeyTrack].keys.Count)
			return;
		let track = clip.tracks[mClipKeyTrack];
		var key = track.keys[mClipKeyIndex];
		let time = view.Snap(view.XToTime(view.mouse.x));
		if (time == key.time)
			return;
		key.time = time;
		track.keys.RemoveAt(mClipKeyIndex);
		int at = 0;
		while (at < track.keys.Count && track.keys[at].time <= key.time)
			at++;
		track.keys.Insert(at, key);
		mClipKeyIndex = at;
		if (time > clip.duration)
			clip.duration = time;
		mClipTime = time;
		mClipPosedTime = -1;
		mClipDirty = true;
	}

	/// Removes the key chosen from a key's menu or with Delete, and the row asked for from a row's menu.
	void DeleteKeys(AnimationClip clip, bool editing, int removeTrack)
	{
		if (mAnimOpenKeyMenu)
		{
			mAnimOpenKeyMenu = false;
			ImGui.OpenPopup("keymenu");
		}
		if (ImGui.BeginPopup("keymenu"))
		{
			if (ImGui.MenuItem("Delete Key", "Del"))
			{
				mAnimDeleteTrack = mAnimMenuTrack;
				mAnimDeleteKey = mAnimMenuKey;
			}
			ImGui.EndPopup();
		}
		if (editing && mClipKeyTrack >= 0 && mClipKeyIndex >= 0 && !ImGui.IsAnyItemActive() && ImGui.IsWindowFocused(ImGui.HoveredFlags.ChildWindows) && ImGui.IsKeyPressed(ImGui.Key.Delete))
		{
			mAnimDeleteTrack = mClipKeyTrack;
			mAnimDeleteKey = mClipKeyIndex;
		}
		if (mAnimDeleteTrack >= 0)
		{
			if (mAnimDeleteTrack < clip.tracks.Count && mAnimDeleteKey >= 0 && mAnimDeleteKey < clip.tracks[mAnimDeleteTrack].keys.Count)
			{
				clip.tracks[mAnimDeleteTrack].keys.RemoveAt(mAnimDeleteKey);
				mClipPosedTime = -1;
				mClipDirty = true;
			}
			mClipKeyTrack = mClipKeyIndex = -1;
			mAnimDeleteTrack = mAnimDeleteKey = -1;
		}
		if (removeTrack >= 0)
		{
			delete clip.tracks[removeTrack];
			clip.tracks.RemoveAt(removeTrack);
			clip.TracksChanged();
			mClipKeyTrack = mClipKeyIndex = -1;
			mClipPosedTime = -1;
			mClipDirty = true;
		}
	}

	/// The footer: the clip's length and looping, Frame All, and a hint at the controls.
	void DrawTimelineFooter(Timeline view, Animator animator, AnimationClip clip)
	{
		ImGui.SetCursorScreenPos(.(view.origin.x + 6, view.bottom - view.footerHeight + 3));
		ImGui.AlignTextToFramePadding();
		ImGui.TextDisabled("Length");
		ImGui.SameLine();
		ImGui.SetNextItemWidth(64);
		if (ImGui.DragFloat("##length", ref clip.duration, 0.01f, 0.05f, 600, "%.2f s"))
		{
			clip.duration = Math.Max(clip.duration, 0.05f);
			mClipDirty = true;
		}
		ImGui.SameLine(0, 12);
		if (ImGui.Checkbox("Loop", ref clip.loop))
			mClipDirty = true;
		ImGui.SameLine(0, 12);
		if (ImGui.Button("Frame All", .(0, ImGui.GetFrameHeight())))
			mAnimPixelsPerSecond = 0;
		ImGui.SameLine(0, 12);
		let buttonsEnd = DrawRigButtons(animator, ImGui.GetCursorScreenPos().x, ImGui.GetCursorScreenPos().y);
		let hint = "Scroll to zoom    Middle-drag to pan    Drag keys to retime    Right-click a key to delete";
		ImGui.DrawText(.(Math.Max(view.sheetLeft, buttonsEnd) + 8, view.bottom - view.footerHeight + (view.footerHeight - ImGui.GetTextLineHeight()) * 0.5f), AnimInk(0.32f), hint);
	}

	/// Key IK: a key at the marker on every bone below the Animator that an IK component moves, holding the pose IK
	/// gives it now.
	void KeyIK(Animator animator)
	{
		if (mClip == null)
			return;
		IKSystem.Solve(mScene);
		List<Transform> children = scope .();
		Descendants(animator.Transform, children);
		int keyed = 0;
		for (let child in children)
		{
			if (!IKSystem.Drives(child))
				continue;
			KeyChild(animator, child, true);
			keyed++;
		}
		if (keyed == 0)
			Log.Warning("Key IK: no bone below the Animator is moved by an enabled IK component.");
	}

	/// Writes a key at the marker from where a child is now. A bone IK moves is keyed with its own pose, from under
	/// the IK, unless solved is set, which keys the pose IK has given it.
	void KeyChild(Animator animator, Transform child, bool solved = false)
	{
		if (mClip == null)
			return;
		Vector3 restPosition, restScale;
		Quaternion restRotation;
		if (!animator.RestPose(child, out restPosition, out restRotation, out restScale))
			return;
		var localPosition = child.LocalPosition;
		var localRotation = child.LocalRotation;
		Vector3 underPosition;
		Quaternion underRotation;
		if (!solved && IKSystem.InputPose(child, out underPosition, out underRotation))
		{
			localPosition = underPosition;
			localRotation = underRotation;
		}
		let position = localPosition - restPosition;
		let euler = (restRotation.Conjugate * localRotation).Normalized.EulerAngles;
		let scale = Vector3(restScale.x != 0 ? child.LocalScale.x / restScale.x : 1, restScale.y != 0 ? child.LocalScale.y / restScale.y : 1, restScale.z != 0 ? child.LocalScale.z / restScale.z : 1);
		int index;
		let track = mClip.AutoKey(child.GameObject.Name, mClipTime, position, euler, scale, out index);
		mClipKeyIndex = index;
		mClipKeyTrack = mClip.tracks.IndexOf(track);
		mClipPosedTime = -1;
		mClipDirty = true;
	}

	/// Add Key: the selected child, or every child the clip already moves when the Animator itself is selected.
	void KeySelectedChild(Animator animator)
	{
		let selected = Selected;
		if (selected != null && selected != animator.GameObject)
		{
			KeyChild(animator, selected.Transform);
			return;
		}
		List<Transform> children = scope .();
		Descendants(animator.Transform, children);
		for (let child in children)
		{
			if (mClip.FindTrack(child.GameObject.Name) != null)
				KeyChild(animator, child);
		}
	}
}
