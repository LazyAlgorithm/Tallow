using System;
using System.Collections;

namespace Tallow;

/// One timed piece of a subtitle file: shown from start to end seconds into its sound.
struct SubtitleCue
{
	public float start;
	public float end;
	/// Who speaks (from "NAME: text" in the file), or empty.
	public StringView speaker;
	public StringView text;
	/// A sound described rather than speech ("[door creaks]"): shown only with Subtitles.Captions on.
	public bool caption;
}

/// The cues of a subtitle (.srt) file.
class SubtitleTrack
{
	public List<SubtitleCue> cues = new .() ~ delete _;
	List<String> mText = new .() ~ DeleteContainerAndItems!(_);

	/// Reads SubRip (.srt) text: numbered blocks of "00:00:01,500 --> 00:00:04,000" and the text under it. A line
	/// "NAME: text" names its speaker, and text in [square brackets] is a caption for a sound.
	public void Parse(StringView source)
	{
		cues.Clear();
		ClearAndDeleteItems(mText);
		SubtitleCue cue = default;
		bool inCue = false;
		let body = scope String();
		void Finish()
		{
			if (inCue && !body.IsEmpty)
			{
				var text = StringView(body)..Trim();
				let colon = text.IndexOf(':');
				// "NAME: text", where the name is short and has no spaces at either end.
				if (colon > 0 && colon <= 32 && !text.StartsWith('[') && text[colon - 1] != ' ')
				{
					let speaker = new String(text.Substring(0, colon)..Trim());
					mText.Add(speaker);
					cue.speaker = speaker;
					text = text.Substring(colon + 1)..Trim();
				}
				let owned = new String(text);
				mText.Add(owned);
				cue.text = owned;
				cue.caption = owned.StartsWith('[') && owned.EndsWith(']');
				cues.Add(cue);
			}
			inCue = false;
			body.Clear();
			cue = default;
		}
		for (let rawLine in source.Split('\n'))
		{
			var line = StringView(rawLine)..Trim();
			let arrow = line.IndexOf("-->");
			if (arrow > 0)
			{
				Finish();
				cue.start = ReadTime(line.Substring(0, arrow));
				cue.end = ReadTime(line.Substring(arrow + 3));
				inCue = true;
			}
			else if (line.IsEmpty)
				Finish();
			else if (inCue)
			{
				if (!body.IsEmpty)
					body.Append('\n');
				body.Append(line);
			}
		}
		Finish();
	}

	/// "hh:mm:ss,mmm" (or with a dot) as seconds.
	static float ReadTime(StringView text)
	{
		var trimmed = text;
		trimmed.Trim();
		float seconds = 0;
		for (let part in trimmed.Split(':'))
		{
			let number = scope String(part)..Replace(',', '.');
			seconds = seconds * 60 + (float.Parse(number) case .Ok(let value) ? value : 0);
		}
		return seconds;
	}

	/// The cue showing at a time into the sound, or -1.
	public int CueAt(float time)
	{
		for (int i < cues.Count)
		{
			if (time >= cues[i].start && time < cues[i].end)
				return i;
		}
		return -1;
	}
}

/// Subtitles and captions along the bottom of the screen, drawn over the game. Dialogue lines show here by
/// themselves (DialogueRunner), and so does any sound an Audio Source plays that has a subtitle file beside it
/// (`Voice/intro.ogg` with `Voice/intro.srt`). From code:
///
///   let id = Subtitles.Show("Radio", "Bravo team, move in.", 3);   // for three seconds
///   Subtitles.Caption("[distant explosion]", 2);                     // only with Captions on
///   Subtitles.Hide(id);
///
/// The settings below are the player's: give them a menu, and save them with the game's other settings.
static class Subtitles
{
	/// Shows speech at all.
	public static bool Enabled = true;
	/// Also shows descriptions of sounds ("[door creaks]"), for players who cannot hear them.
	public static bool Captions = false;
	/// Shows who speaks before their line.
	public static bool SpeakerNames = true;
	/// Text size, as a multiple of the interface's own (0.5 to 3).
	public static float Size = 1.25f;
	/// How dark the box behind the text is, 0 (none) to 1.
	public static float Background = 0.6f;
	/// The most lines shown at once; older ones make way.
	public static int MaxLines = 3;
	/// A font file for subtitles (empty: the interface's own font).
	public static String Font = new .() ~ delete _;

	/// Everything back to the defaults.
	public static void Reset()
	{
		Enabled = true;
		Captions = false;
		SpeakerNames = true;
		Size = 1.25f;
		Background = 0.6f;
		MaxLines = 3;
		Font.Clear();
	}

	public struct Entry
	{
		public int32 id;
		public String speaker;
		public String text;
		public Color color;
		/// When it goes (Time.RealTime); 0: until hidden.
		public float until;
		public bool caption;
	}

	static List<Entry> sEntries = new .() ~ { for (let entry in _) Free(entry); delete _; };
	static int32 sNextId = 1;

	struct Tracked
	{
		public AudioSource source;
		/// The source's voice: it is forgotten when this goes (AudioSourceState.Unload).
		public AudioSourceState state;
		public SubtitleTrack track;
		public int32 shown;
		public int32 cue;
	}

	static List<Tracked> sTracked = new .() ~ delete _;
	static Dictionary<String, SubtitleTrack> sTracks = new .() ~ DeleteDictionaryAndKeysAndValues!(_);

	static void Free(Entry entry)
	{
		delete entry.speaker;
		delete entry.text;
	}

	/// What is up now, oldest first (for a game's own subtitle drawing).
	public static List<Entry> Showing => sEntries;

	/// Shows a line of speech for some seconds (0: until Hide). Returns its id, for Hide.
	public static int32 Show(StringView speaker, StringView text, float seconds = 0, Color color = .(1, 0.85f, 0.45f, 1)) => Add(speaker, text, seconds, color, false);

	/// Shows a description of a sound ("[glass breaks]"), only when Captions is on.
	public static int32 Caption(StringView text, float seconds = 2) => Add("", text, seconds, .White, true);

	static int32 Add(StringView speaker, StringView text, float seconds, Color color, bool caption)
	{
		Entry entry;
		entry.id = sNextId++;
		entry.speaker = new String(speaker);
		entry.text = new String(text);
		entry.color = color;
		entry.until = seconds > 0 ? Time.RealTime + seconds : 0;
		entry.caption = caption;
		sEntries.Add(entry);
		while (sEntries.Count > Math.Max(MaxLines, 1))
		{
			Free(sEntries[0]);
			sEntries.RemoveAt(0);
		}
		return entry.id;
	}

	/// Takes a line down early. Ids already gone are ignored.
	public static void Hide(int32 id)
	{
		for (int i < sEntries.Count)
		{
			if (sEntries[i].id == id)
			{
				Free(sEntries[i]);
				sEntries.RemoveAt(i);
				return;
			}
		}
	}

	/// Whether a line is still up.
	public static bool IsShowing(int32 id)
	{
		for (let entry in sEntries)
		{
			if (entry.id == id)
				return true;
		}
		return false;
	}

	/// Takes everything down and forgets the sounds being followed.
	public static void Clear()
	{
		for (let entry in sEntries)
			Free(entry);
		sEntries.Clear();
		sTracked.Clear();
	}

	/// The subtitle file beside a sound (the same name, ending .srt), read once; null when there is none.
	public static SubtitleTrack TrackFor(StringView clip)
	{
		if (clip.IsEmpty)
			return null;
		if (sTracks.TryGetValueAlt(clip, let found))
			return found;
		let path = scope String(clip);
		let dot = path.LastIndexOf('.');
		if (dot > path.LastIndexOf('/'))
			path.RemoveToEnd(dot);
		path.Append(".srt");
		let text = scope String();
		SubtitleTrack track = null;
		if (Assets.FileExists(path) && Assets.ReadText(path, text))
		{
			track = new SubtitleTrack();
			track.Parse(text);
		}
		sTracks[new String(clip)] = track;
		return track;
	}

	/// Shows a sound's subtitles while it plays (AudioSource.Play does this when the clip has a file beside it).
	public static void Follow(AudioSource source, StringView clip)
	{
		Unfollow(source);
		let track = TrackFor(clip);
		if (track == null || track.cues.IsEmpty)
			return;
		Tracked tracked;
		tracked.source = source;
		tracked.state = ComponentState<AudioSourceState>.Get(source.Scene.World, source.GameObject.Entity);
		tracked.track = track;
		tracked.shown = 0;
		tracked.cue = -1;
		sTracked.Add(tracked);
	}

	/// Stops showing a sound's subtitles.
	public static void Unfollow(AudioSource source)
	{
		for (int i = sTracked.Count - 1; i >= 0; i--)
		{
			if (sTracked[i].source == source)
			{
				Hide(sTracked[i].shown);
				sTracked.RemoveAt(i);
			}
		}
	}

	/// Moves the followed sounds' subtitles on and takes down lines whose time is up. Called each frame.
	public static void Update()
	{
		for (int i = sTracked.Count - 1; i >= 0; i--)
		{
			var tracked = ref sTracked[i];
			let source = tracked.source;
			if (!source.IsPlaying)
			{
				Hide(tracked.shown);
				sTracked.RemoveAt(i);
				continue;
			}
			// A spatial sound too far away to hear shows nothing.
			let heard = !source.spatial || (source.Transform.Position - Audio.ListenerPosition).Length <= source.maxDistance;
			let cue = heard ? (int32)tracked.track.CueAt(source.Time) : -1;
			if (cue == tracked.cue)
				continue;
			Hide(tracked.shown);
			tracked.shown = 0;
			tracked.cue = cue;
			if (cue >= 0)
			{
				let entry = tracked.track.cues[cue];
				tracked.shown = entry.caption ? Caption(entry.text, 0) : Show(entry.speaker, entry.text, 0);
			}
		}
		for (int i = sEntries.Count - 1; i >= 0; i--)
		{
			if (sEntries[i].until > 0 && Time.RealTime >= sEntries[i].until)
			{
				Free(sEntries[i]);
				sEntries.RemoveAt(i);
			}
		}
	}

	/// Forgets an Audio Source's voice that is going away.
	public static void Forget(AudioSourceState state)
	{
		for (int i = sTracked.Count - 1; i >= 0; i--)
		{
			if (sTracked[i].state == state)
			{
				Hide(sTracked[i].shown);
				sTracked.RemoveAt(i);
			}
		}
	}

	/// Draws what is up along the bottom of the game view (from GUI.Run, after every component's OnGUI).
	public static void Draw()
	{
		Update();
		if (!Enabled || sEntries.IsEmpty)
			return;
		let size = ImGui.GetFontSize() * Math.Clamp(Size, 0.5f, 3);
		UIFonts.Push(Font, size);
		defer ImGui.PopFont();
		let wrap = Math.Max(GUI.Width * 0.7f, 200);
		let padding = size * 0.4f;
		float y = GUI.Height - size * 2.2f;
		for (int i = sEntries.Count - 1; i >= 0; i--)
		{
			let entry = sEntries[i];
			if (entry.caption && !Captions)
				continue;
			let line = scope String();
			let named = SpeakerNames && !entry.speaker.IsEmpty;
			if (named)
				line.AppendF("{}: ", entry.speaker);
			line.Append(entry.text);
			let measured = ImGui.CalcTextSizeWrapped(line.CStr(), wrap);
			let x = (GUI.Width - measured.x) * 0.5f;
			let top = y - measured.y;
			if (Background > 0)
				GUI.Box(x - padding, top - padding * 0.5f, measured.x + padding * 2, measured.y + padding, .(0, 0, 0, Math.Clamp(Background, 0, 1)));
			let origin = GUI.Origin;
			ImGui.DrawTextWrapped(.(origin.x + x + 1, origin.y + top + 1), .(0, 0, 0, 0.8f), line.CStr(), wrap);
			ImGui.DrawTextWrapped(.(origin.x + x, origin.y + top), entry.caption ? Color(0.8f, 0.8f, 0.8f, 1) : Color.White, line.CStr(), wrap);
			if (named)
			{
				// The name again, over the white, in the speaker's colour.
				let name = scope String()..AppendF("{}:", entry.speaker);
				ImGui.DrawText(.(origin.x + x, origin.y + top), entry.color, name.CStr());
			}
			y = top - padding * 1.5f;
		}
	}
}
