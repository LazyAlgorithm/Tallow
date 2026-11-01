using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// The Sequencer tab: edits a `.tsequence` file on a timeline. Tracks on the left, their keys as diamonds along the
/// time ruler, and the selected key's settings underneath. Scrubbing or playing the preview puts the scene's objects
/// where the sequence has them (and the Scene view's camera on its shots, with Look Through Shots), and Stop
/// Preview puts them back.
///   Click the ruler to move the playhead, drag a key to move it (it snaps to the frame rate), double-click a row to
///   add a key there, Delete removes the selected key, K keys the selected object where it stands.
extension EditorApp
{
	SequenceAsset mSeq ~ delete _;
	String mSeqPath = new .() ~ delete _;
	String mSeqRelative = new .() ~ delete _;
	bool mShowSequencer;
	bool mDockSequencer;
	bool mSeqFocus;
	int64 mSeqFocusAfter = 5;
	bool mSeqDirty;
	float mSeqTime;
	float mSeqAppliedTime = -1;
	bool mSeqPlaying;
	bool mSeqLookThrough = true;
	int32 mSeqTrack = -1;
	int32 mSeqKey = -1;
	// 0: the whole sequence fits the width. Ctrl+wheel zooms in; the wheel then scrolls (mSeqScroll, in seconds).
	float mSeqPixelsPerSecond;
	bool mSeqZoomed;
	float mSeqScroll;
	SequenceEvaluator mSeqPreview ~ delete _;
	bool mSeqDragging;

	static readonly StringView[?] SequenceKindLabels = .("Transform", "Camera", "Animation", "Audio", "Show / Hide", "Event", "Subtitle", "Fade");
	static readonly Color[?] SequenceKindColors = .(.(0.36f, 0.62f, 0.9f, 1), .(0.9f, 0.62f, 0.3f, 1), .(0.5f, 0.78f, 0.4f, 1), .(0.75f, 0.5f, 0.85f, 1),
		.(0.85f, 0.85f, 0.4f, 1), .(0.95f, 0.45f, 0.45f, 1), .(0.45f, 0.8f, 0.8f, 1), .(0.6f, 0.6f, 0.6f, 1));

	/// Opens a sequence file (a full path) in the Sequencer tab, saving the one open before.
	void OpenSequence(StringView path)
	{
		StopSequencePreview();
		if (mSeq != null && mSeqDirty)
			SaveSequence();
		delete mSeq;
		mSeq = new SequenceAsset();
		mSeqPath.Set(path);
		mSeqRelative.Clear();
		Assets.MakeRelative(path, mSeqRelative);
		mSeq.path.Set(mSeqRelative);
		let text = scope String();
		if (File.ReadAllText(path, text, true) case .Ok)
			mSeq.Parse(text);
		mSeqTime = 0;
		mSeqPixelsPerSecond = mSeqScroll = 0;
		mSeqZoomed = false;
		mSeqTrack = mSeqKey = -1;
		mSeqDirty = false;
		mShowSequencer = true;
		mDockSequencer = true;
		mSeqFocus = true;
	}

	void SaveSequence()
	{
		if (mSeq == null)
			return;
		let text = scope String();
		mSeq.Write(text);
		if (File.WriteAllText(mSeqPath, text) case .Err)
		{
			Log.Error(scope $"{mSeqPath} could not be written.");
			return;
		}
		SequenceAsset.Forget(mSeqRelative);
		mSeqDirty = false;
	}

	/// What a new sequence file holds: a camera shot and a fade in.
	public static void NewSequenceText(String text)
	{
		text.Append("""
			sequence length 5 framerate 30
			track fade color 0 0 0
				key 0 1
				key 1 0

			""");
	}

	/// The Sequence Player in the scene that plays this file, whose object names are looked for first.
	GameObject SequenceOwner()
	{
		if (mScene == null)
			return null;
		for (let component in mScene.ComponentsOfType(typeof(SequencePlayer)))
		{
			let player = (SequencePlayer)component;
			if (player.sequence == mSeqRelative)
				return player.GameObject;
		}
		return null;
	}

	/// Puts the scene where the sequence is at the playhead (binding first, so Stop Preview can put it back).
	void ApplySequencePreview(bool moments, float from)
	{
		if (mSeq == null || mScene == null || mPlay != .Edit)
			return;
		if (mSeqPreview == null)
		{
			mSeqPreview = new SequenceEvaluator();
			mSeqPreview.FireEvents = false;
			mSeqPreview.Bind(mSeq, mScene, SequenceOwner());
		}
		mSeqPreview.Asset = mSeq;
		mSeqPreview.Apply(mSeqTime, from, moments);
		mSeqAppliedTime = mSeqTime;
		if (mSeqLookThrough && mSeqPreview.ShotPose(mSeqTime, let position, let rotation, ?))
		{
			let euler = rotation.EulerAngles;
			mCamPosition = position;
			mCamPitch = euler.x > 180 ? euler.x - 360 : euler.x;
			mCamYaw = euler.y;
		}
	}

	/// Puts back what the preview moved, showed or hid.
	void StopSequencePreview()
	{
		mSeqPlaying = false;
		if (mSeqPreview == null)
			return;
		mSeqPreview.Silence();
		mSeqPreview.Restore();
		DeleteAndNullify!(mSeqPreview);
		mSeqAppliedTime = -1;
	}

	float SnapSequenceTime(float time)
	{
		let rate = Math.Max(mSeq.frameRate, 1);
		return Math.Max(0, Math.Round(time * rate) / rate);
	}

	void DrawSequencer()
	{
		if (!mShowSequencer)
		{
			if (mSeqPreview != null)
				StopSequencePreview();
			return;
		}
		if (mDockSequencer && mAssetCenterDock != 0)
		{
			ImGui.SetNextWindowDockID(mAssetCenterDock);
			mDockSequencer = false;
		}
		if (mSeqFocus && Time.FrameCount > mSeqFocusAfter)
		{
			ImGui.SetNextWindowFocus();
			mSeqFocus = false;
		}
		let visible = ImGui.Begin("Sequencer", &mShowSequencer);
		if (visible && mSeq == null)
			ImGui.TextDisabled("Create a sequence with Project > + > Sequence, or double-click a .tsequence file.");
		else if (visible)
		{
			// Playing the game takes the scene over: the preview gives it back first.
			if (mPlay != .Edit && mSeqPreview != null)
				StopSequencePreview();
			DrawSequencerToolbar();
			let keysHeight = 120.0f;
			let height = Math.Max(ImGui.GetContentRegionAvail().y - keysHeight, 80);
			ImGui.BeginChild("timeline", .(0, height), 1);
			DrawSequencerTimeline();
			ImGui.EndChild();
			ImGui.BeginChild("key", .(0, 0), 1);
			DrawSequencerKey();
			ImGui.EndChild();
			if (mSeqPlaying)
			{
				let from = mSeqTime;
				mSeqTime += Time.UnscaledDeltaTime;
				if (mSeqTime >= mSeq.End)
				{
					mSeqTime = mSeq.End;
					mSeqPlaying = false;
				}
				ApplySequencePreview(true, from);
			}
			else if (mSeqPreview != null && mSeqTime != mSeqAppliedTime)
				ApplySequencePreview(false, mSeqTime);
		}
		ImGui.End();
		if (!mShowSequencer)
		{
			StopSequencePreview();
			if (mSeqDirty)
				SaveSequence();
		}
	}

	void DrawSequencerToolbar()
	{
		if (ImGui.SmallButton("Save"))
			SaveSequence();
		ImGui.SameLine();
		if (ImGui.SmallButton(mSeqPlaying ? "Pause" : "Play") && mPlay == .Edit)
		{
			mSeqPlaying = !mSeqPlaying;
			if (mSeqPlaying && mSeqTime >= mSeq.End)
				mSeqTime = 0;
			if (mSeqPlaying)
				ApplySequencePreview(true, mSeqTime - 0.0001f);
		}
		ImGui.SameLine();
		if (ImGui.SmallButton("Stop Preview"))
			StopSequencePreview();
		ImGui.SameLine();
		ImGui.SetNextItemWidth(80);
		if (ImGui.DragFloat("##time", ref mSeqTime, 0.01f, 0, mSeq.End, "%.2f s"))
		{
			mSeqTime = Math.Clamp(mSeqTime, 0, mSeq.End);
			ApplySequencePreview(false, mSeqTime);
		}
		ImGui.SameLine();
		ImGui.SetNextItemWidth(80);
		if (ImGui.DragFloat("Length", ref mSeq.length, 0.05f, 0.1f, 3600, "%.2f s"))
		{
			mSeq.length = Math.Max(mSeq.length, 0.1f);
			mSeqDirty = true;
		}
		ImGui.SameLine();
		ImGui.SetNextItemWidth(60);
		if (ImGui.DragFloat("fps", ref mSeq.frameRate, 1, 1, 240, "%.0f"))
		{
			mSeq.frameRate = Math.Clamp(mSeq.frameRate, 1, 240);
			mSeqDirty = true;
		}
		ImGui.SameLine();
		ImGui.Checkbox("Look Through Shots", ref mSeqLookThrough);
		ImGui.SameLine();
		if (ImGui.SmallButton("+ Track"))
			ImGui.OpenPopup("addtrack");
		if (ImGui.BeginPopup("addtrack"))
		{
			let selected = Selected;
			for (int32 k < SequenceKindLabels.Count)
			{
				if (ImGui.MenuItem(scope String(SequenceKindLabels[k]).CStr()))
				{
					let track = new SequenceTrack();
					track.kind = (SequenceTrackKind)k;
					// A track that works on an object starts on the one selected.
					let usesObject = track.kind == .Transform || track.kind == .Animation || track.kind == .Audio || track.kind == .Active;
					if (usesObject && selected != null)
						track.target.Set(selected.Name);
					mSeq.tracks.Add(track);
					mSeqTrack = (int32)mSeq.tracks.Count - 1;
					mSeqKey = -1;
					mSeqDirty = true;
					RebindSequencePreview();
				}
			}
			ImGui.EndPopup();
		}
		ImGui.SameLine(0, 14);
		ImGui.TextDisabled(scope String()..AppendF("{}{}", mSeqRelative, mSeqDirty ? " *" : "").CStr());
		if (!mSeq.problems.IsEmpty)
		{
			ImGui.SameLine(0, 14);
			ImGui.TextColored(EditorTheme.Warning, "Problems (hover)");
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip(mSeq.problems.CStr());
		}
	}

	/// After tracks or their objects change, the preview finds them again (putting back what it moved first).
	void RebindSequencePreview()
	{
		if (mSeqPreview == null)
			return;
		let time = mSeqTime;
		StopSequencePreview();
		mSeqTime = time;
		ApplySequencePreview(false, time);
	}

	void DrawSequencerTimeline()
	{
		let rowHeight = 24.0f;
		let leftWidth = 230.0f;
		let rulerHeight = 22.0f;
		let origin = ImGui.GetCursorScreenPos();
		let avail = ImGui.GetContentRegionAvail();
		// A margin, so keys at the very start are not cut in half.
		let margin = 10.0f;
		let sheetLeft = origin.x + leftWidth;
		let sheetWidth = Math.Max(avail.x - leftWidth - 8, 50);
		let end = Math.Max(mSeq.End, 0.1f);
		let fit = (sheetWidth - margin * 2) / end;
		// Until zoomed in, the whole sequence fits however the tab is sized.
		if (!mSeqZoomed || mSeqPixelsPerSecond < fit)
			mSeqPixelsPerSecond = fit;
		let scale = mSeqPixelsPerSecond;
		let visible = (sheetWidth - margin * 2) / scale;
		mSeqScroll = Math.Clamp(mSeqScroll, 0, Math.Max(end - visible, 0));
		// While playing zoomed in, the view follows the playhead.
		if (mSeqPlaying && (mSeqTime < mSeqScroll || mSeqTime > mSeqScroll + visible))
			mSeqScroll = Math.Clamp(mSeqTime - visible * 0.1f, 0, Math.Max(end - visible, 0));
		let scroll = mSeqScroll;
		float X(float time) => sheetLeft + margin + (time - scroll) * scale;
		float TimeAt(float x) => Math.Clamp((x - sheetLeft - margin) / scale + scroll, 0, end);

		// The ruler: seconds, and the playhead.
		ImGui.SetCursorScreenPos(.(sheetLeft, origin.y));
		ImGui.InvisibleButton("##ruler", .(sheetWidth, rulerHeight));
		if (ImGui.IsItemActive())
		{
			mSeqPlaying = false;
			mSeqTime = SnapSequenceTime(TimeAt(ImGui.GetMousePos().x));
			ApplySequencePreview(false, mSeqTime);
		}
		if (ImGui.IsWindowHovered() && Input.MouseWheel != 0 && ImGui.GetMousePos().x > sheetLeft)
		{
			if (ImGui.IsKeyDown(ImGui.Key.LeftCtrl))
			{
				// Zooms about the time under the mouse.
				let under = TimeAt(ImGui.GetMousePos().x);
				mSeqPixelsPerSecond = Math.Clamp(mSeqPixelsPerSecond * (Input.MouseWheel > 0 ? 1.25f : 0.8f), fit, 2000);
				mSeqZoomed = mSeqPixelsPerSecond > fit * 1.01f;
				mSeqScroll = under - (ImGui.GetMousePos().x - sheetLeft - margin) / mSeqPixelsPerSecond;
			}
			else
				mSeqScroll -= Input.MouseWheel * visible * 0.1f;
		}
		ImGui.DrawRectFilled(.(sheetLeft, origin.y), .(sheetLeft + sheetWidth, origin.y + rulerHeight), .(0.16f, 0.16f, 0.17f, 1));
		let step = scale > 200 ? 0.25f : (scale > 60 ? 1 : (scale > 15 ? 5 : 10));
		ImGui.PushClipRect(.(sheetLeft, origin.y), .(sheetLeft + sheetWidth, origin.y + 4000));
		for (float t = Math.Floor(scroll / step) * step; t <= end + 0.001f; t += step)
		{
			if (X(t) > sheetLeft + sheetWidth)
				break;
			ImGui.DrawLine(.(X(t), origin.y + rulerHeight - 6), .(X(t), origin.y + rulerHeight), .(0.6f, 0.6f, 0.6f, 1));
			ImGui.DrawText(.(X(t) + 3, origin.y + 2), EditorTheme.TextDim, scope String()..AppendF("{}", t).CStr());
		}
		// Past the length: greyed.
		ImGui.DrawRectFilled(.(X(mSeq.length), origin.y), .(X(end) + 1, origin.y + rulerHeight), .(0, 0, 0, 0.3f));
		ImGui.PopClipRect();

		// The rows.
		int32 removeTrack = -1;
		for (int32 t < (int32)mSeq.tracks.Count)
		{
			let track = mSeq.tracks[t];
			let top = origin.y + rulerHeight + t * rowHeight;
			ImGui.PushID(t);
			let selectedRow = t == mSeqTrack;
			ImGui.DrawRectFilled(.(origin.x, top), .(sheetLeft + sheetWidth, top + rowHeight - 1), selectedRow ? Color(0.24f, 0.27f, 0.33f, 1) : Color(0.19f, 0.19f, 0.2f, 1));
			ImGui.DrawRectFilled(.(origin.x, top), .(origin.x + 4, top + rowHeight - 1), SequenceKindColors[(int)track.kind]);
			// The name: its kind and object.
			ImGui.SetCursorScreenPos(.(origin.x + 8, top + 3));
			if (ImGui.SmallButton(track.muted ? "off" : "on"))
			{
				track.muted = !track.muted;
				mSeqDirty = true;
				ApplySequencePreview(false, mSeqTime);
			}
			ImGui.SameLine();
			let label = scope String(SequenceKindLabels[(int)track.kind]);
			if (!track.target.IsEmpty)
				label.AppendF(": {}", track.target);
			else if (track.kind == .Transform || track.kind == .Animation || track.kind == .Active)
				label.Append(": (player's object)");
			if (ImGui.Selectable(label.CStr(), selectedRow, 0, .(leftWidth - 80, rowHeight - 6)))
			{
				mSeqTrack = t;
				mSeqKey = -1;
			}
			if (ImGui.BeginPopupContextItem("track"))
			{
				ImGui.SetNextItemWidth(180);
				if (ImGui.InputText("Object", track.target))
				{
					mSeqDirty = true;
					RebindSequencePreview();
				}
				if (Selected != null && ImGui.MenuItem(scope String()..AppendF("Use Selected ({})", Selected.Name).CStr()))
				{
					track.target.Set(Selected.Name);
					mSeqDirty = true;
					RebindSequencePreview();
				}
				if (track.kind == .Fade)
				{
					if (ImGui.ColorEdit3("Colour", ref track.color))
						mSeqDirty = true;
				}
				if (ImGui.MenuItem("Move Up", null, false, t > 0))
				{
					Swap!(mSeq.tracks[t], mSeq.tracks[t - 1]);
					mSeqTrack = t - 1;
					mSeqDirty = true;
					RebindSequencePreview();
				}
				if (ImGui.MenuItem("Delete Track"))
					removeTrack = t;
				ImGui.EndPopup();
			}
			// The keys.
			ImGui.PushClipRect(.(sheetLeft, top), .(sheetLeft + sheetWidth, top + rowHeight));
			ImGui.SetCursorScreenPos(.(sheetLeft, top));
			ImGui.InvisibleButton("##row", .(sheetWidth, rowHeight - 1));
			if (ImGui.IsItemHovered() && ImGui.IsMouseDoubleClicked(0))
			{
				mSeqTrack = t;
				AddSequenceKey(track, SnapSequenceTime(TimeAt(ImGui.GetMousePos().x)));
			}
			else if (ImGui.IsItemClicked())
			{
				mSeqTrack = t;
				mSeqKey = -1;
			}
			for (int32 k < (int32)track.keys.Count)
			{
				let key = track.keys[k];
				let x = X(key.time);
				let cy = top + rowHeight * 0.5f;
				ImGui.SetCursorScreenPos(.(x - 6, top + 2));
				ImGui.PushID(k);
				ImGui.InvisibleButton("##key", .(12, rowHeight - 4));
				if (ImGui.IsItemClicked())
				{
					mSeqTrack = t;
					mSeqKey = k;
				}
				if (ImGui.IsItemActive() && ImGui.IsMouseDragging(0, 3) && t == mSeqTrack && k == mSeqKey)
				{
					key.time = SnapSequenceTime(TimeAt(ImGui.GetMousePos().x));
					mSeqDragging = true;
					mSeqDirty = true;
				}
				if (ImGui.IsItemHovered())
					ImGui.SetTooltip(scope String()..AppendF("{:0.00} s  {}", key.time, key.text).CStr());
				ImGui.PopID();
				let selectedKey = t == mSeqTrack && k == mSeqKey;
				let size = selectedKey ? 7.0f : 5.5f;
				let color = selectedKey ? Color(1, 0.85f, 0.3f, 1) : SequenceKindColors[(int)track.kind];
				ImGui.DrawQuadFilled(.(x, cy - size), .(x + size, cy), .(x, cy + size), .(x - size, cy), color);
				// Spans: a subtitle's time on screen, a shot's blend, an animation's fade.
				if (key.length > 0 && (track.kind == .Subtitle || track.kind == .Camera || track.kind == .Animation))
					ImGui.DrawLine(.(x, cy + 6), .(X(key.time + key.length), cy + 6), color, 2);
			}
			ImGui.PopClipRect();
			ImGui.PopID();
		}
		// A dragged key settles into time order when let go.
		if (mSeqDragging && !ImGui.IsMouseDown(0))
		{
			mSeqDragging = false;
			if (mSeqTrack >= 0 && mSeqKey >= 0)
			{
				let track = mSeq.tracks[mSeqTrack];
				let moved = track.keys[mSeqKey];
				track.Sort();
				mSeqKey = (int32)track.keys.IndexOf(moved);
			}
			ApplySequencePreview(false, mSeqTime);
		}
		if (removeTrack >= 0)
		{
			delete mSeq.tracks[removeTrack];
			mSeq.tracks.RemoveAt(removeTrack);
			mSeqTrack = mSeqKey = -1;
			mSeqDirty = true;
			RebindSequencePreview();
		}
		// The playhead, over the rows.
		let bottom = origin.y + rulerHeight + Math.Max(mSeq.tracks.Count, 1) * rowHeight;
		let head = X(mSeqTime);
		ImGui.DrawLine(.(head, origin.y), .(head, bottom), .(1, 0.35f, 0.3f, 1), 2);
		ImGui.SetCursorScreenPos(.(origin.x, bottom + 6));
		if (mSeq.tracks.IsEmpty)
			ImGui.TextDisabled("Add a track with + Track. Select an object first to animate it.");
		else
			ImGui.TextDisabled("Double-click a row to add a key, drag keys to move them, right-click a track to change its object. K keys the selected object; Ctrl+wheel zooms.");

		// Keys from the keyboard while the timeline is hovered.
		if (ImGui.IsWindowHovered() && (ImGui.tn_imgui_capture_flags() & 4) == 0)
		{
			if (ImGui.IsKeyPressed(ImGui.Key.Delete) && mSeqTrack >= 0 && mSeqKey >= 0)
			{
				let track = mSeq.tracks[mSeqTrack];
				delete track.keys[mSeqKey];
				track.keys.RemoveAt(mSeqKey);
				mSeqKey = -1;
				mSeqDirty = true;
				ApplySequencePreview(false, mSeqTime);
			}
			if (ImGui.IsKeyPressed(ImGui.Key.K))
				KeySelectedObject();
			if (ImGui.IsKeyPressed(ImGui.Key.Space))
				mSeqPlaying = !mSeqPlaying && mPlay == .Edit;
		}
	}

	/// Adds a key to a track at a time, filled in from the scene where that makes sense.
	void AddSequenceKey(SequenceTrack track, float time)
	{
		let key = track.AddKey(time);
		switch (track.kind)
		{
		case .Transform:
			let target = SequenceEvaluator.Resolve(mScene, SequenceOwner(), track.target);
			if (target != null)
			{
				key.position = target.Transform.LocalPosition;
				key.euler = target.Transform.LocalEulerAngles;
			}
		case .Camera:
			// A new shot where the Scene view's camera is.
			let shot = mScene.CreateGameObject(scope String()..AppendF("Shot {}", track.keys.Count));
			shot.Transform.Position = mCamPosition;
			shot.Transform.Rotation = Quaternion.Euler(mCamPitch, mCamYaw, 0);
			key.text.Set(shot.Name);
			MarkDirty();
		case .Audio:
			key.value = 1;
		case .Active:
			key.value = 1;
		case .Event:
			key.text.Set("Event");
		case .Subtitle:
			key.text.Set("Speaker");
			key.line.Set("...");
		case .Fade:
			key.value = 1;
		default:
		}
		mSeqKey = (int32)track.keys.IndexOf(key);
		mSeqDirty = true;
	}

	/// K: keys the selected object's place on its Transform track at the playhead (making the track if needed).
	void KeySelectedObject()
	{
		let selected = Selected;
		if (selected == null)
			return;
		SequenceTrack track = null;
		for (let each in mSeq.tracks)
		{
			if (each.kind == .Transform && SequenceEvaluator.Resolve(mScene, SequenceOwner(), each.target) == selected)
				track = each;
		}
		if (track == null)
		{
			track = new SequenceTrack();
			track.kind = .Transform;
			track.target.Set(selected.Name);
			mSeq.tracks.Add(track);
			RebindSequencePreview();
		}
		mSeqTrack = (int32)mSeq.tracks.IndexOf(track);
		let at = track.KeyAt(mSeqTime);
		SequenceKey key;
		if (at >= 0 && Math.Abs(track.keys[at].time - mSeqTime) < 0.0005f)
			key = track.keys[at];
		else
			key = track.AddKey(mSeqTime);
		key.position = selected.Transform.LocalPosition;
		key.euler = selected.Transform.LocalEulerAngles;
		if (selected.Transform.LocalScale != Vector3(1, 1, 1) || key.hasScale)
		{
			key.scale = selected.Transform.LocalScale;
			key.hasScale = true;
		}
		mSeqKey = (int32)track.keys.IndexOf(key);
		mSeqDirty = true;
	}

	void DrawSequencerKey()
	{
		if (mSeqTrack < 0 || mSeqTrack >= mSeq.tracks.Count)
		{
			ImGui.TextDisabled("Select a track or a key.");
			return;
		}
		let track = mSeq.tracks[mSeqTrack];
		if (mSeqKey < 0 || mSeqKey >= track.keys.Count)
		{
			ImGui.TextDisabled(scope String()..AppendF("{} track, {} keys. Double-click its row to add one.", SequenceKindLabels[(int)track.kind], track.keys.Count).CStr());
			if (track.kind == .Transform && ImGui.Button("Key Selected Object Here (K)"))
				KeySelectedObject();
			return;
		}
		let key = track.keys[mSeqKey];
		bool changed = false;
		ImGui.SetNextItemWidth(90);
		if (ImGui.DragFloat("Time", ref key.time, 0.01f, 0, 3600, "%.2f s"))
		{
			key.time = Math.Max(key.time, 0);
			track.Sort();
			mSeqKey = (int32)track.keys.IndexOf(key);
			changed = true;
		}
		ImGui.SameLine();
		switch (track.kind)
		{
		case .Transform:
			ImGui.NewLine();
			changed |= ImGui.DragFloat3("Position", ref key.position, 0.05f);
			changed |= ImGui.DragFloat3("Rotation", ref key.euler, 0.5f);
			if (ImGui.Checkbox("Scale", ref key.hasScale))
				changed = true;
			if (key.hasScale)
			{
				ImGui.SameLine();
				changed |= ImGui.DragFloat3("##scale", ref key.scale, 0.02f);
			}
			changed |= DrawSequenceEase(key);
			if (ImGui.Button("Set From Selected Object (K)"))
				KeySelectedObject();
		case .Camera:
			ImGui.SetNextItemWidth(180);
			changed |= ImGui.InputText("Shot object", key.text);
			ImGui.SameLine();
			if (Selected != null && ImGui.SmallButton("Use Selected"))
			{
				key.text.Set(Selected.Name);
				changed = true;
			}
			ImGui.SetNextItemWidth(90);
			changed |= ImGui.DragFloat("Blend from last shot", ref key.length, 0.05f, 0, 30, "%.2f s");
			ImGui.SameLine();
			ImGui.SetNextItemWidth(90);
			changed |= ImGui.DragFloat("Field of view", ref key.value, 0.5f, 0, 120, key.value > 0 ? "%.0f" : "shot's own");
			if (ImGui.Button("Move Shot To Scene View"))
			{
				let shot = SequenceEvaluator.Resolve(mScene, SequenceOwner(), key.text);
				if (shot != null)
				{
					shot.Transform.Position = mCamPosition;
					shot.Transform.Rotation = Quaternion.Euler(mCamPitch, mCamYaw, 0);
					MarkDirty();
				}
			}
		case .Animation:
			ImGui.SetNextItemWidth(180);
			changed |= ImGui.InputText("State or clip", key.text);
			ImGui.SameLine();
			ImGui.SetNextItemWidth(90);
			changed |= ImGui.DragFloat("Fade", ref key.length, 0.01f, 0, 5, "%.2f s");
		case .Audio:
			ImGui.NewLine();
			ImGui.TextDisabled("Sound");
			ImGui.SameLine();
			changed |= DrawAssetPicker(key.text, "audioClip");
			ImGui.SetNextItemWidth(120);
			changed |= ImGui.DragFloat("Volume", ref key.value, 0.01f, 0, 2);
		case .Active:
			var on = key.value > 0.5f;
			if (ImGui.Checkbox("Shown from here", ref on))
			{
				key.value = on ? 1 : 0;
				changed = true;
			}
		case .Event:
			ImGui.SetNextItemWidth(160);
			changed |= ImGui.InputText("Event", key.text);
			ImGui.SameLine();
			ImGui.SetNextItemWidth(80);
			changed |= ImGui.DragFloat("Number", ref key.value, 0.1f);
		case .Subtitle:
			ImGui.SetNextItemWidth(120);
			changed |= ImGui.InputText("Speaker", key.text);
			ImGui.SameLine();
			ImGui.SetNextItemWidth(90);
			changed |= ImGui.DragFloat("Shown for", ref key.length, 0.05f, 0, 60, key.length > 0 ? "%.2f s" : "reading time");
			changed |= ImGui.InputTextMultiline("##line", key.line, .(-1, ImGui.GetFontSize() * 2.6f));
		case .Fade:
			ImGui.SetNextItemWidth(120);
			changed |= ImGui.DragFloat("Covered", ref key.value, 0.01f, 0, 1);
			ImGui.SameLine();
			changed |= DrawSequenceEase(key);
		}
		if (changed)
		{
			mSeqDirty = true;
			ApplySequencePreview(false, mSeqTime);
		}
	}

	bool DrawSequenceEase(SequenceKey key)
	{
		ImGui.SetNextItemWidth(100);
		bool changed = false;
		let names = scope char8*[]("Linear", "Smooth", "Step");
		if (ImGui.BeginCombo("Ease to next", names[(int)key.ease]))
		{
			for (int32 i < 3)
			{
				if (ImGui.Selectable(names[i], (int32)key.ease == i))
				{
					key.ease = (SequenceEase)i;
					changed = true;
				}
			}
			ImGui.EndCombo();
		}
		return changed;
	}

	/// Under a Sequence Player: open its file and, while playing, control it.
	void DrawSequencePlayerTools(SequencePlayer player)
	{
		if (player.sequence.IsEmpty)
		{
			ImGui.TextDisabled("Pick a .tsequence file (Project > + > Sequence makes one).");
			return;
		}
		if (ImGui.Button("Edit Sequence"))
		{
			let full = scope String();
			Assets.ResolvePath(player.sequence, full);
			OpenSequence(full);
		}
		if (mPlay == .Edit)
			return;
		ImGui.SameLine();
		switch (player.State)
		{
		case .Playing:
			if (ImGui.Button("Pause"))
				player.Pause();
		case .Paused:
			if (ImGui.Button("Resume"))
				player.Resume();
		default:
			if (ImGui.Button("Play"))
				player.Play();
		}
		ImGui.SameLine();
		if (ImGui.Button("Skip"))
			player.Skip();
		ImGui.SameLine();
		ImGui.TextDisabled(scope String()..AppendF("{:0.00} / {:0.00} s", player.Time, player.Length).CStr());
	}
}
