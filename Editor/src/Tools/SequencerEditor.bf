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
		for (let player in mScene.FindComponents<SequencePlayer>(.. scope .()))
		{
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
			let availableHeight = ImGui.GetContentRegionAvail().y;
			let keyHeight = Math.Clamp(availableHeight * 0.34f, 92, 190);
			if (ImGui.BeginChild("timeline", .(0, Math.Max(availableHeight - keyHeight - 8, 60)), 1, ImGui.WindowFlags.NoScrollWithMouse))
				DrawSequencerTimeline();
			ImGui.EndChild();
			if (ImGui.BeginChild("key", .(0, 0), 1))
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

	void ToggleSequencePlayback()
	{
		if (mPlay != .Edit)
			return;
		mSeqPlaying = !mSeqPlaying;
		if (!mSeqPlaying)
			return;
		if (mSeqTime >= mSeq.End)
			mSeqTime = 0;
		ApplySequencePreview(true, mSeqTime - 0.0001f);
	}

	void DrawSequencerToolbar()
	{
		let fileName = Path.GetFileName(mSeqRelative, .. scope .());
		ImGui.Text(scope String()..AppendF("{}{}", fileName, mSeqDirty ? " *" : ""));
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip(mSeqRelative.CStr());
		if (!mSeq.problems.IsEmpty)
		{
			ImGui.SameLine();
			ImGui.TextColored(EditorTheme.Warning, "File problems");
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip(mSeq.problems.CStr());
		}

		ImGui.BeginDisabled(mPlay != .Edit);
		if (AnimIconButton("##playSequence", 3, mSeqPlaying, mSeqPlaying ? "Pause sequence (Space)" : "Play sequence (Space)"))
			ToggleSequencePlayback();
		ImGui.SameLine();
		let previewing = mSeqPreview != null;
		if (previewing)
			ImGui.PushStyleColor(ImGui.Col.Button, EditorTheme.Accent);
		if (ImGui.Button("Stop Preview"))
			StopSequencePreview();
		if (previewing)
			ImGui.PopStyleColor();
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("End the preview and restore the scene objects it changed.");
		ImGui.SameLine();
		ImGui.SetNextItemWidth(86);
		if (ImGui.DragFloat("##playhead", ref mSeqTime, 0.01f, 0, mSeq.End, "%.2f s"))
		{
			mSeqTime = Math.Clamp(mSeqTime, 0, mSeq.End);
			ApplySequencePreview(false, mSeqTime);
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Playhead time");
		ImGui.EndDisabled();
		ImGui.SameLine(0, 12);
		if (ImGui.Button("Frame All"))
		{
			mSeqZoomed = false;
			mSeqScroll = 0;
		}
		ImGui.SameLine();
		if (ImGui.Button("Save"))
			SaveSequence();

		if (ImGui.Button("+ Track"))
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
		ImGui.SameLine();
		ImGui.SetNextItemWidth(74);
		if (ImGui.DragFloat("Length", ref mSeq.length, 0.05f, 0.1f, 3600, "%.2f s"))
		{
			mSeq.length = Math.Max(mSeq.length, 0.1f);
			mSeqDirty = true;
		}
		ImGui.SameLine();
		ImGui.SetNextItemWidth(46);
		if (ImGui.DragFloat("fps", ref mSeq.frameRate, 1, 1, 240, "%.0f"))
		{
			mSeq.frameRate = Math.Clamp(mSeq.frameRate, 1, 240);
			mSeqDirty = true;
		}
		let shotLabel = "Look Through Shots";
		if (ImGui.GetContentRegionAvail().x + ImGui.GetCursorScreenPos().x - ImGui.GetItemRectMax().x > ImGui.CalcTextSize(shotLabel).x + ImGui.GetFrameHeight() + 16)
			ImGui.SameLine();
		ImGui.Checkbox(shotLabel, ref mSeqLookThrough);
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

	struct SequenceTimeline
	{
		public ImGui.Vec2 origin;
		public float left, right, rowHeight, rulerHeight, scale, scroll, end;

		public float Width => right - left;
		public float RowsTop => origin.y + rulerHeight;
		public float X(float time) => left + 10 + (time - scroll) * scale;
		public float TimeAt(float x) => Math.Clamp((x - left - 10) / scale + scroll, 0, end);
	}

	void DrawSequencerTimeline()
	{
		let origin = ImGui.GetCursorScreenPos();
		let avail = ImGui.GetContentRegionAvail();
		let fontHeight = ImGui.GetTextLineHeight();
		SequenceTimeline view = .();
		view.origin = origin;
		view.left = origin.x + Math.Min(250, avail.x * 0.43f);
		view.right = origin.x + avail.x;
		view.rowHeight = Math.Max(ImGui.GetFrameHeight() + 4, fontHeight * 2 + 8);
		view.rulerHeight = fontHeight + 14;
		view.end = Math.Max(mSeq.End, 0.1f);
		if (view.Width <= 24)
			return;

		let mouse = ImGui.GetMousePos();
		let overSheet = ImGui.IsWindowHovered() && mouse.x >= view.left && mouse.x < view.right;
		let fit = (view.Width - 20) / view.end;
		if (!mSeqZoomed || mSeqPixelsPerSecond < fit)
			mSeqPixelsPerSecond = fit;
		view.scale = mSeqPixelsPerSecond;
		view.scroll = mSeqScroll;
		let wheel = Input.MouseWheel;
		if (ImGui.IsWindowHovered() && wheel != 0)
		{
			if (overSheet && ImGui.IsKeyDown(ImGui.Key.ModCtrl))
			{
				let underMouse = view.TimeAt(mouse.x);
				view.scale = Math.Clamp(view.scale * Math.Pow(1.2f, wheel), fit, Math.Max(fit, 2000));
				mSeqZoomed = view.scale > fit;
				view.scroll = underMouse - (mouse.x - view.left - 10) / view.scale;
			}
			else if (overSheet && view.scale > fit)
				view.scroll -= wheel * (view.Width - 20) / view.scale * 0.1f;
			else
				ImGui.SetScrollY(ImGui.GetScrollY() - wheel * view.rowHeight * 2);
		}
		mSeqPixelsPerSecond = view.scale;
		let visibleTime = (view.Width - 20) / view.scale;
		if (mSeqPlaying && (mSeqTime < view.scroll || mSeqTime > view.scroll + visibleTime))
			view.scroll = mSeqTime - visibleTime * 0.1f;
		view.scroll = mSeqScroll = Math.Clamp(view.scroll, 0, Math.Max(view.end - visibleTime, 0));

		let rowsBottom = view.RowsTop + Math.Max(mSeq.tracks.Count, 1) * view.rowHeight;
		let bottom = Math.Max(origin.y + avail.y, rowsBottom);
		ImGui.DrawRectFilled(origin, .(view.right, bottom), AnimPanel);
		ImGui.DrawRectFilled(.(view.left, view.RowsTop), .(view.right, bottom), AnimSheet);
		ImGui.DrawRectFilled(origin, .(view.right, view.RowsTop), AnimUi(ImGui.Col.FrameBg));
		ImGui.DrawText(.(origin.x + 8, origin.y + 4), EditorTheme.TextDim, "Scene tracks");
		ImGui.DrawLine(.(view.left - 1, origin.y), .(view.left - 1, bottom), AnimGap);
		ImGui.DrawLine(.(origin.x, view.RowsTop - 1), .(view.right, view.RowsTop - 1), AnimGap);
		DrawSequenceRuler(view, bottom);

		int32 removeTrack = -1;
		for (int32 t < (int32)mSeq.tracks.Count)
		{
			let top = view.RowsTop + t * view.rowHeight;
			ImGui.PushID(t);
			if (DrawSequenceTrack(view, t, top))
				removeTrack = t;
			DrawSequenceKeys(view, t, top);
			ImGui.PopID();
		}
		FinishSequenceTrackEdits(removeTrack);

		let head = view.X(mSeqTime);
		ImGui.PushClipRect(.(view.left, origin.y), .(view.right, bottom));
		ImGui.DrawLine(.(head, origin.y), .(head, bottom), AnimInk(0.9f));
		ImGui.DrawRectFilled(.(head - 2, origin.y), .(head + 3, origin.y + 9), AnimInk(0.95f), 1);
		ImGui.PopClipRect();
		ImGui.SetCursorScreenPos(.(origin.x, rowsBottom - view.rowHeight));
		ImGui.Dummy(.(1, view.rowHeight));
		if (mSeq.tracks.IsEmpty)
			ImGui.DrawText(.(view.left + 10, view.RowsTop + 10), EditorTheme.TextDim, "Add a track to schedule a scene cue.");

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
				ToggleSequencePlayback();
		}
	}

	void DrawSequenceRuler(SequenceTimeline view, float bottom)
	{
		let top = view.origin.y;
		ImGui.SetCursorScreenPos(.(view.left, top));
		ImGui.InvisibleButton("##ruler", .(view.Width, view.rulerHeight));
		if (ImGui.IsItemActive())
		{
			mSeqPlaying = false;
			mSeqTime = Math.Min(SnapSequenceTime(view.TimeAt(ImGui.GetMousePos().x)), mSeq.End);
			ApplySequencePreview(false, mSeqTime);
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Drag to scrub  |  Ctrl+wheel to zoom  |  Wheel to scroll");

		ImGui.PushClipRect(.(view.left, top), .(view.right, bottom));
		let lengthX = Math.Clamp(view.X(mSeq.length), view.left, view.right);
		ImGui.DrawRectFilled(.(lengthX, top), .(view.right, bottom), AnimInk(0.055f));
		float[?] steps = .(0.05f, 0.1f, 0.25f, 0.5f, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800);
		float step = steps[steps.Count - 1];
		for (let candidate in steps)
		{
			if (candidate * view.scale >= 67)
			{
				step = candidate;
				break;
			}
		}
		let firstTick = (int32)Math.Floor(view.scroll / step);
		for (int32 tick = firstTick; tick * step <= view.end + 0.001f; tick++)
		{
			let time = tick * step;
			let x = view.X(time);
			if (x >= view.right)
				break;
			ImGui.DrawLine(.(x, view.RowsTop - 9), .(x, bottom), AnimInk(0.13f));
			if (x >= view.left)
			{
				let label = scope String()..AppendF("{:0.##} s", time);
				let labelX = Math.Min(x + 4, view.right - ImGui.CalcStringSize(label).x - 4);
				ImGui.DrawText(.(labelX, top + 3), EditorTheme.TextDim, label.CStr());
			}
			for (int32 minor = 1; minor < 5 && time + minor * step / 5 <= view.end; minor++)
			{
				let minorX = view.X(time + minor * step / 5);
				ImGui.DrawLine(.(minorX, view.RowsTop - 4), .(minorX, view.RowsTop), AnimInk(0.24f));
			}
		}
		ImGui.PopClipRect();
	}

	static char8* SequenceTrackTarget(SequenceTrack track)
	{
		if (!track.target.IsEmpty)
			return track.target.CStr();
		switch (track.kind)
		{
		case .Transform, .Animation, .Active: return "Sequence Player object";
		case .Audio: return "Non-positional audio";
		default: return null;
		}
	}

	bool DrawSequenceTrack(SequenceTimeline view, int32 index, float top)
	{
		let track = mSeq.tracks[index];
		let left = view.origin.x;
		let bottom = top + view.rowHeight;
		let selected = index == mSeqTrack;
		let color = SequenceKindColors[(int)track.kind];
		if (index % 2 == 1)
			ImGui.DrawRectFilled(.(left, top), .(view.right, bottom), AnimInk(0.028f));
		if (selected)
		{
			ImGui.DrawRectFilled(.(left, top), .(view.left - 1, bottom), AnimUi(ImGui.Col.Header));
			ImGui.DrawRectFilled(.(view.left, top), .(view.right, bottom), AnimInk(0.06f));
		}
		ImGui.DrawLine(.(left, bottom - 1), .(view.right, bottom - 1), AnimInk(0.08f));
		ImGui.DrawRectFilled(.(left + 2, top + 4), .(left + 5, bottom - 4), track.muted ? EditorTheme.TextDim : color, 1);

		let height = ImGui.GetFrameHeight();
		let buttonWidth = ImGui.CalcTextSize("Off").x + 12;
		ImGui.SetCursorScreenPos(.(left + 10, top + (view.rowHeight - height) * 0.5f));
		if (ImGui.Button(track.muted ? "Off##mute" : "On##mute", .(buttonWidth, height)))
		{
			track.muted = !track.muted;
			mSeqDirty = true;
			ApplySequencePreview(false, mSeqTime);
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip(track.muted ? "Enable track" : "Mute track");

		let labelX = left + buttonWidth + 18;
		if (view.left <= labelX + 2)
			return false;
		ImGui.SetCursorScreenPos(.(labelX, top));
		ImGui.InvisibleButton("##track", .(view.left - labelX - 2, view.rowHeight));
		if (ImGui.IsItemClicked())
		{
			mSeqTrack = index;
			mSeqKey = -1;
		}
		let label = scope String(SequenceKindLabels[(int)track.kind]);
		let target = SequenceTrackTarget(track);
		if (ImGui.IsItemHovered())
		{
			if (!selected)
				ImGui.DrawRectFilled(.(labelX - 4, top), .(view.left - 1, bottom), AnimInk(0.07f));
			if (target != null)
				ImGui.SetTooltip(target);
		}
		let lineHeight = ImGui.GetTextLineHeight();
		let textY = top + (view.rowHeight - lineHeight * (target == null ? 1 : 2)) * 0.5f;
		ImGui.PushClipRect(.(labelX, top), .(view.left - 4, bottom));
		ImGui.DrawText(.(labelX, textY), track.muted ? EditorTheme.TextDim : EditorTheme.Text, label.CStr());
		if (target != null)
			ImGui.DrawText(.(labelX, textY + lineHeight), EditorTheme.TextDim, target);
		ImGui.PopClipRect();

		bool remove = false;
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
			if (track.kind == .Fade && ImGui.ColorEdit3("Colour", ref track.color))
				mSeqDirty = true;
			if (ImGui.MenuItem("Move Up", null, false, index > 0))
			{
				Swap!(mSeq.tracks[index], mSeq.tracks[index - 1]);
				if (mSeqTrack != index)
					mSeqKey = -1;
				mSeqTrack = index - 1;
				mSeqDirty = true;
				RebindSequencePreview();
			}
			remove = ImGui.MenuItem("Delete Track");
			ImGui.EndPopup();
		}
		return remove;
	}

	void DrawSequenceKeys(SequenceTimeline view, int32 index, float top)
	{
		let track = mSeq.tracks[index];
		let cy = top + view.rowHeight * 0.5f;
		let color = track.muted ? EditorTheme.TextDim : SequenceKindColors[(int)track.kind];
		ImGui.PushClipRect(.(view.left, top), .(view.right, top + view.rowHeight));

		if (track.kind == .Subtitle || track.kind == .Camera || track.kind == .Animation)
		{
			for (let key in track.keys)
			{
				let x = view.X(key.time);
				let end = view.X(key.time + key.length);
				if (key.length <= 0 || end <= view.left || x >= view.right)
					continue;
				let fill = Color.Lerp(AnimSheet, color, 0.28f);
				ImGui.DrawRectFilled(.(x, cy - 8), .(end, cy + 8), fill, 3);
				ImGui.DrawLine(.(x, cy + 8), .(end, cy + 8), color);
				if (!key.text.IsEmpty && x + 18 + ImGui.CalcStringSize(key.text).x <= Math.Min(end, view.right))
					ImGui.DrawText(.(x + 12, cy - ImGui.GetTextLineHeight() * 0.5f), EditorTheme.Text, key.text.CStr());
			}
		}

		// Submit keys before the lane so the lane only receives clicks in empty space.
		for (int32 k < (int32)track.keys.Count)
		{
			let key = track.keys[k];
			let x = view.X(key.time);
			let hitLeft = Math.Max(view.left, x - 8);
			let hitRight = Math.Min(view.right, x + 8);
			let wasSelected = index == mSeqTrack && k == mSeqKey;
			if (hitRight > hitLeft || (mSeqDragging && wasSelected))
			{
				ImGui.SetCursorScreenPos(.(Math.Clamp(hitLeft, view.left, view.right - 1), cy - 9));
				ImGui.PushID(k);
				ImGui.InvisibleButton("##key", .(Math.Max(1, hitRight - hitLeft), 18));
				if (ImGui.IsItemClicked())
				{
					mSeqTrack = index;
					mSeqKey = k;
				}
				if (ImGui.IsItemActive() && ImGui.IsMouseDragging(0, 3) && index == mSeqTrack && k == mSeqKey)
				{
					key.time = SnapSequenceTime(view.TimeAt(ImGui.GetMousePos().x));
					mSeqDragging = true;
					mSeqDirty = true;
				}
				if (ImGui.IsItemHovered())
					ImGui.SetTooltip(scope String()..AppendF("{:0.00} s  {}", key.time, key.text).CStr());
				ImGui.PopID();
			}
			let selected = index == mSeqTrack && k == mSeqKey;
			DrawKeyDiamond(.(x, cy), selected ? 8 : 6.5f, selected ? EditorTheme.Text : AnimGap);
			DrawKeyDiamond(.(x, cy), selected ? 5.5f : 5, color);
		}

		ImGui.SetCursorScreenPos(.(view.left, top));
		ImGui.InvisibleButton("##lane", .(view.Width, view.rowHeight - 1));
		if (ImGui.IsItemHovered() && ImGui.IsMouseDoubleClicked(0))
		{
			mSeqTrack = index;
			AddSequenceKey(track, SnapSequenceTime(view.TimeAt(ImGui.GetMousePos().x)));
		}
		else if (ImGui.IsItemClicked())
		{
			mSeqTrack = index;
			mSeqKey = -1;
		}
		ImGui.PopClipRect();
	}

	void FinishSequenceTrackEdits(int32 removeTrack)
	{
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
		ImGui.TextDisabled("Key Properties");
		if (mSeqTrack < 0 || mSeqTrack >= mSeq.tracks.Count)
		{
			ImGui.Separator();
			ImGui.TextWrapped("Select a diamond to edit its cue. Double-click an empty part of a track to add one.");
			return;
		}
		let track = mSeq.tracks[mSeqTrack];
		let hasKey = mSeqKey >= 0 && mSeqKey < track.keys.Count;
		ImGui.SameLine(0, 12);
		ImGui.TextColored(Color.Lerp(SequenceKindColors[(int)track.kind], EditorTheme.Text, 0.48f),
			scope String(SequenceKindLabels[(int)track.kind]).CStr());
		ImGui.SameLine(0, 10);
		if (hasKey)
			ImGui.TextDisabled(scope String()..AppendF("Key {} of {}", mSeqKey + 1, track.keys.Count).CStr());
		else
			ImGui.TextDisabled(scope String()..AppendF("{} {}", track.keys.Count, track.keys.Count == 1 ? "key" : "keys").CStr());
		ImGui.Separator();
		if (!hasKey)
		{
			ImGui.TextWrapped("Double-click an empty part of this track to add a key.");
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
		let wide = ImGui.GetContentRegionAvail().x >= 560;
		switch (track.kind)
		{
		case .Transform:
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
			if (Selected != null)
			{
				if (wide)
					ImGui.SameLine();
				if (ImGui.SmallButton("Use Selected"))
				{
					key.text.Set(Selected.Name);
					changed = true;
				}
			}
			ImGui.SetNextItemWidth(90);
			changed |= ImGui.DragFloat("Blend from last shot", ref key.length, 0.05f, 0, 30, "%.2f s");
			if (wide)
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
			if (wide)
				ImGui.SameLine();
			ImGui.SetNextItemWidth(90);
			changed |= ImGui.DragFloat("Fade", ref key.length, 0.01f, 0, 5, "%.2f s");
		case .Audio:
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
			if (wide)
				ImGui.SameLine();
			ImGui.SetNextItemWidth(80);
			changed |= ImGui.DragFloat("Number", ref key.value, 0.1f);
		case .Subtitle:
			ImGui.SetNextItemWidth(120);
			changed |= ImGui.InputText("Speaker", key.text);
			if (wide)
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
