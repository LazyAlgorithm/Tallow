using System;
using System.Collections;

namespace Tallow;

/// Plays a dialogue (a `.tdialogue` file, see DialogueAsset and docs/dialogue.md): each line as a subtitle with its
/// voice recording, the answers as buttons the player picks with the mouse, the number keys or a controller, and
/// `event` steps handed to the game.
///
///   let talk = GetComponent<DialogueRunner>();
///   talk.OnEvent.Add(new (name, value) => { if (name == "OpenGate") gate.Open(); });
///   talk.Play();                 // from Start Node; or Play("shop")
///
/// Shared: in a network session the server runs the conversation and every player sees the same lines and answers;
/// any player (or, with Only Owner Chooses, the object's owner) can move it on. Otherwise each machine runs its own.
[Component]
class DialogueRunner : Component
{
	/// The dialogue file.
	public String dialogue = new .() ~ delete _;
	/// The node Play starts at.
	public String startNode = new .("start") ~ delete _;
	/// Starts the conversation when the scene starts.
	public bool playOnStart = false;
	/// Lines move on by themselves when their recording ends (or, without one, after time to read them). Off: the
	/// player moves them on.
	public bool autoAdvance = false;
	/// How fast players read, in characters a second: how long a line without a recording or a time stays up.
	[Range(5, 40)]
	public float readingSpeed = 15;
	/// Moving lines on and picking answers with Space, Enter, E, the mouse, the number keys and a controller (or the
	/// "Dialogue Advance" input action, if the project has one). Off: the game calls Advance and Choose.
	public bool acceptInput = true;
	/// Draws the answers as buttons. Off: the game draws its own from Choices.
	public bool showChoices = true;
	/// Shows each line as a subtitle (Subtitles). Off: the game draws its own from Line.
	public bool showLines = true;
	/// In a network session, one conversation on every machine, run by the server (the object gets a Network
	/// Identity by itself).
	public bool shared = false;
	/// Shared: only the player who owns the object may move the conversation on. Off: any player may.
	public bool onlyOwnerChooses = false;

	// What a shared conversation shows, set by the server.
	[Sync, HideInInspector] public int32 syncSerial;
	[Sync, HideInInspector] public int32 syncNode = -1;
	[Sync, HideInInspector] public int32 syncStep;
	[Sync, HideInInspector] public int32 syncView;
	/// The offered choices' step numbers, separated by commas.
	[Sync, HideInInspector] public String syncChoices = new .() ~ delete _;

	// Kept in saves: the dialogue variables and where the conversation was.
	[Saved, HideInInspector] public String savedVariables = new .() ~ delete _;
	[Saved, HideInInspector] public int32 savedNode = -1;
	[Saved, HideInInspector] public int32 savedStep;

	/// An `event` step was reached: its name and number. On the server only in a shared conversation, where the game
	/// decides what happens; otherwise on the machine running it.
	public Event<delegate void(StringView name, float value)> OnEvent ~ _.Dispose();
	/// A line is shown (on every machine showing the conversation).
	public Event<delegate void(DialogueStep line)> OnLine ~ _.Dispose();
	/// Answers are offered.
	public Event<delegate void()> OnChoices ~ _.Dispose();
	/// The conversation finished or was stopped.
	public Event<delegate void()> OnEnded ~ _.Dispose();

	DialogueConversation mConversation = new .() ~ delete _;
	int32 mAppliedSerial;
	int32 mSubtitle;
	float mLineStarted;
	int64 mShownFrame = -1;
	int32 mSelected;
	AudioSource mVoice;
	AudioSource mOwnVoice;
	DialogueView mLastView;

	/// The conversation's state: what it shows, where it is.
	public DialogueConversation Conversation => mConversation;
	public DialogueView View => mConversation.View;
	public bool IsPlaying => mConversation.IsRunning;
	/// The line shown, or null.
	public DialogueStep Line => mConversation.View == .Line ? mConversation.Line : null;
	/// The answers offered (empty unless View is Choices).
	public List<DialogueStep> Choices => mConversation.Choices;
	/// The answer the keyboard or controller has picked out (for a game's own answer list).
	public int32 Selected => mSelected;

	/// The speaker of the line shown, or null (a narrator, or no line).
	public DialogueSpeaker Speaker => Line != null && mConversation.Asset != null ? mConversation.Asset.FindSpeaker(Line.speaker) : null;

	public override void Awake()
	{
		mConversation.OnEvent.Add(new => ConversationEvent);
	}

	public override void Start()
	{
		if (playOnStart && Mine)
			Play();
	}

	public override void OnDisable() => HideLine();

	/// True where this conversation is run: always unless it is shared in a session, then on the server.
	bool Mine => !shared || !NetworkSync.InSession(Scene) || (Scene.Network != null && Scene.Network.IsServer);

	/// Starts the dialogue at Start Node. False when the file or node cannot be found.
	public bool Play() => Play(startNode);

	/// Starts the dialogue at a node.
	public bool Play(StringView node)
	{
		if (!Mine)
		{
			NetworkSync.DialogueRequest(this, 2, 0, node);
			return true;
		}
		let asset = DialogueAsset.Load(dialogue);
		if (asset == null)
			return false;
		if (!mConversation.Start(asset, node))
		{
			Log.Warning(scope $"{dialogue}: there is no node called '{node}'.");
			Changed();
			return false;
		}
		Changed();
		return true;
	}

	/// Moves on from the line shown.
	public void Advance()
	{
		if (!Mine)
		{
			NetworkSync.DialogueRequest(this, 0, syncSerial, "");
			return;
		}
		if (mConversation.View != .Line)
			return;
		mConversation.Advance();
		Changed();
	}

	/// Picks an answer (0 is the first of Choices).
	public void Choose(int index)
	{
		if (!Mine)
		{
			NetworkSync.DialogueRequest(this, 1, syncSerial, "", (int32)index);
			return;
		}
		if (mConversation.Choose(index))
			Changed();
	}

	/// Ends the conversation.
	public void Stop()
	{
		if (!Mine)
		{
			NetworkSync.DialogueRequest(this, 3, syncSerial, "");
			return;
		}
		if (mConversation.View == .None || mConversation.View == .Ended)
			return;
		mConversation.Stop();
		Changed();
	}

	/// Server: a client asked to move a shared conversation on. Ignored when it was about a line already gone.
	public void ApplyRequest(int32 action, int32 serial, StringView node, int32 index)
	{
		switch (action)
		{
		case 0: if (serial == syncSerial) Advance();
		case 1: if (serial == syncSerial) Choose(index);
		case 2: Play(node.IsEmpty ? (StringView)startNode : node);
		case 3: if (serial == syncSerial) Stop();
		}
	}

	void ConversationEvent(StringView name, float value) => OnEvent(name, value);

	/// After the conversation moved: what it shows is written for the other machines and shown here.
	void Changed()
	{
		syncSerial++;
		syncNode = mConversation.NodeIndex;
		syncStep = mConversation.StepIndex;
		syncView = (int32)mConversation.View;
		syncChoices.Clear();
		if (mConversation.View == .Choices)
		{
			let node = mConversation.Node;
			for (let choice in mConversation.Choices)
			{
				if (!syncChoices.IsEmpty)
					syncChoices.Append(',');
				syncChoices.AppendF("{}", node.steps.IndexOf(choice));
			}
		}
		mAppliedSerial = syncSerial;
		Present();
	}

	/// A client of a shared conversation: shows what the server last sent.
	void Follow()
	{
		mAppliedSerial = syncSerial;
		let asset = DialogueAsset.Load(dialogue);
		let view = (DialogueView)syncView;
		mConversation.Asset = asset;
		mConversation.NodeIndex = syncNode;
		mConversation.StepIndex = syncStep;
		mConversation.Choices.Clear();
		mConversation.Line = null;
		let node = mConversation.Node;
		if (node == null || (view != .Line && view != .Choices))
			mConversation.View = view == .None ? .None : .Ended;
		else if (view == .Line && syncStep < node.steps.Count)
		{
			mConversation.View = .Line;
			mConversation.Line = node.steps[syncStep];
		}
		else
		{
			for (let part in syncChoices.Split(',', .RemoveEmptyEntries))
			{
				if (int32.Parse(part) case .Ok(let step) && step >= 0 && step < node.steps.Count)
					mConversation.Choices.Add(node.steps[step]);
			}
			mConversation.View = mConversation.Choices.IsEmpty ? .Ended : .Choices;
		}
		Present();
	}

	/// Shows what the conversation is at: its line's subtitle and voice, or its answers.
	void Present()
	{
		HideLine();
		mShownFrame = Time.FrameCount;
		mSelected = 0;
		let view = mConversation.View;
		if (view == .Line)
		{
			let line = mConversation.Line;
			mLineStarted = Time.Time;
			let speaker = Speaker;
			if (showLines)
				mSubtitle = Subtitles.Show(speaker != null ? (StringView)speaker.name : "", line.text, 0, speaker != null ? speaker.color : Color(1, 0.85f, 0.45f, 1));
			PlayVoice(line, speaker);
			OnLine(line);
		}
		else if (view == .Choices)
			OnChoices();
		else if ((view == .Ended || view == .None) && (mLastView == .Line || mLastView == .Choices))
			OnEnded();
		mLastView = view;
	}

	void HideLine()
	{
		if (mSubtitle != 0)
			Subtitles.Hide(mSubtitle);
		mSubtitle = 0;
		if (mVoice && mVoice.IsPlaying && (mVoice.localOnly || Mine))
			mVoice.Stop();
		mVoice = default;
	}

	/// Plays a line's recording: from the speaker's object when it has an Audio Source, otherwise from this object.
	void PlayVoice(DialogueStep line, DialogueSpeaker speaker)
	{
		if (line.audio.IsEmpty)
			return;
		AudioSource source = default;
		if (speaker != null && !speaker.objectName.IsEmpty)
		{
			if (let speakerObject = Scene.Find(speaker.objectName))
				source = speakerObject.GetComponent<AudioSource>();
		}
		if (!source)
			source = GetComponent<AudioSource>();
		if (!source)
		{
			if (!mOwnVoice)
			{
				mOwnVoice = GameObject.AddComponent<AudioSource>();
				mOwnVoice.playOnStart = false;
				mOwnVoice.spatial = false;
				mOwnVoice.group = .Voice;
				mOwnVoice.localOnly = true;
			}
			source = mOwnVoice;
		}
		mVoice = source;
		// A source that is heard over the network is started by the server alone: the others hear it from there.
		if (!source.localOnly && !Mine)
			return;
		source.Play(line.audio);
		// The line is already a subtitle; a file beside the recording would show it twice.
		Subtitles.Unfollow(source);
	}

	/// How long the line shown stays up when lines move on by themselves.
	public float LineDuration
	{
		get
		{
			let line = Line;
			if (line == null)
				return 0;
			if (line.time > 0)
				return line.time;
			return Math.Max(1.5f, 0.8f + line.text.Length / Math.Max(readingSpeed, 1));
		}
	}

	public override void OnLocalUpdate()
	{
		if (!Mine && syncSerial != mAppliedSerial)
			Follow();
		let view = mConversation.View;
		if (view == .Line && autoAdvance && Mine)
		{
			let voicing = mVoice && mVoice.IsPlaying;
			if (!voicing && Time.Time - mLineStarted >= (Line.audio.IsEmpty || !mVoice ? LineDuration : 0.4f))
				Advance();
		}
		if (acceptInput && Time.FrameCount != mShownFrame && (view == .Line || view == .Choices))
			ReadInput(view);
	}

	void ReadInput(DialogueView view)
	{
		let action = InputActions.Find("Dialogue Advance");
		let confirm = action != null ? InputActions.Pressed("Dialogue Advance")
			: Input.GetKeyDown(.Space) || Input.GetKeyDown(.Return) || Input.GetKeyDown(.E) || Gamepad.GetButtonDown(.South) || (Input.GetMouseButtonDown(0) && !GUI.MouseOverControl && view == .Line);
		if (view == .Line)
		{
			if (confirm)
				Advance();
			return;
		}
		let count = (int32)Choices.Count;
		for (int32 i < Math.Min(count, 9))
		{
			if (Input.GetKeyDown((KeyCode)((int32)KeyCode.Alpha1 + i)))
			{
				Choose(i);
				return;
			}
		}
		if (Input.GetKeyDown(.DownArrow) || Input.GetKeyDown(.S) || Gamepad.GetButtonDown(.DpadDown))
			mSelected = (mSelected + 1) % count;
		if (Input.GetKeyDown(.UpArrow) || Input.GetKeyDown(.W) || Gamepad.GetButtonDown(.DpadUp))
			mSelected = (mSelected + count - 1) % count;
		if (confirm)
			Choose(mSelected);
	}

	public override void OnGUI()
	{
		if (!showChoices || mConversation.View != .Choices)
			return;
		let choices = Choices;
		let size = ImGui.GetFontSize() * Math.Clamp(Subtitles.Size, 0.5f, 3);
		UIFonts.Push(Subtitles.Font, size);
		defer ImGui.PopFont();
		let width = Math.Min(GUI.Width * 0.6f, size * 26);
		let height = size * 1.9f;
		let gap = size * 0.35f;
		let x = (GUI.Width - width) * 0.5f;
		var y = GUI.Height - size * 3 - (height + gap) * choices.Count;
		for (int32 i < (int32)choices.Count)
		{
			if (i == mSelected)
				GUI.Box(x - 4, y - 4, width + 8, height + 8, .(1, 0.85f, 0.45f, 0.9f));
			let label = scope String()..AppendF("{}.  {}", i + 1, choices[i].text);
			if (GUI.Button(x, y, width, height, label))
				Choose(i);
			y += height + gap;
		}
	}

	public override void OnSaving()
	{
		savedVariables.Clear();
		DialogueVariables.ToText(savedVariables);
		savedNode = mConversation.IsRunning ? mConversation.NodeIndex : -1;
		savedStep = mConversation.StepIndex;
	}

	public override void OnLoaded()
	{
		DialogueVariables.FromText(savedVariables);
		if (savedNode >= 0 && Mine && mConversation.Restore(DialogueAsset.Load(dialogue), savedNode, savedStep))
			Changed();
	}
}
