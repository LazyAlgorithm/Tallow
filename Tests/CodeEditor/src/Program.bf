using System;
using System.Collections;
using System.IO;
using Tallow;
using Tallow.Editor;

namespace CodeEditorTests;

/// The script editor's knowledge of code comes from reading source files. This checks that what it reads from the
/// real engine source is right, that completion uses it, and that code added later is found without any change
/// to the editor.
class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	static void EngineRoot(String output, String file = Compiler.CallerFilePath)
	{
		// .../Tests/CodeEditor/src/Program.bf
		var path = (StringView)file;
		for (int i < 4)
		{
			let slash = path.LastIndexOf('/');
			if (slash > 0)
				path = path.Substring(0, slash);
		}
		output.Set(path);
	}

	static bool Has(StringView type, params StringView[] members)
	{
		let entry = ApiIndex.Find(type);
		if (entry == null)
		{
			Console.WriteLine(scope $"      (no type {type})");
			return false;
		}
		for (let member in members)
		{
			if (!entry.Has(member))
			{
				Console.WriteLine(scope $"      ({type} lacks {member})");
				return false;
			}
		}
		return true;
	}

	static bool Lacks(StringView type, params StringView[] members)
	{
		let entry = ApiIndex.Find(type);
		if (entry == null) return false;
		for (let member in members)
		{
			if (entry.Has(member))
			{
				Console.WriteLine(scope $"      ({type} wrongly has {member})");
				return false;
			}
		}
		return true;
	}

	/// True when completion at the end of the text offers every one of the names.
	static bool Offers(StringView text, params StringView[] names)
	{
		let result = scope String();
		ApiIndex.Complete(text, result);
		List<StringView> lines = scope .();
		for (let line in result.Split('\n'))
			lines.Add(line);
		for (let name in names)
		{
			if (!lines.Contains(name))
			{
				Console.WriteLine(scope $"      ('{name}' not offered; got {lines.Count}: {scope String(result.Substring(0, Math.Min(result.Length, 160)))..Replace('\n', ' ')})");
				return false;
			}
		}
		return true;
	}

	static StringView First(StringView text, String buffer)
	{
		buffer.Clear();
		ApiIndex.Complete(text, buffer);
		let end = buffer.IndexOf('\n');
		return end >= 0 ? buffer.Substring(0, end) : buffer;
	}

	public static int Main(String[] args)
	{
		bool ok = true;
		let root = scope String();
		EngineRoot(root);
		let project = "/tmp/tallow-code-editor-test";
		Directory.CreateDirectory(scope $"{project}/src/Scripts").IgnoreError();
		File.WriteAllText(scope $"{project}/src/Scripts/Turret.bf" , """
            using Tallow;
            namespace Game;
            /// A gun. { braces in comments } and "strings with { braces" are not code.
            [Component]
            class Turret : Component
            {
                public float range = 10; // metres
                float mCooldown;
                public bool IsReady => mCooldown <= 0;
                void Fire(Vector3 at)
                {
                    let hidden = 1;
                    if (hidden > 0) { mCooldown = 1; }
                }
                public override void Update()
                {
                }
            }
            enum Ammo { Bullet, Shell = 4, Rocket }
            """).IgnoreError();
		ApiIndex.Build(root, project);
		ok &= Check(ApiIndex.TypeCount > 150, scope $"the engine's source was read ({ApiIndex.TypeCount} types found in {root}/Engine/src)");

		// ---- read from the engine source, not from a list ----
		ok &= Check(Has("AudioSource", "Play", "Stop", "PlayOneShot", "volume", "minDistance", "IsPlaying") && Has("Audio", "Hrtf", "HrtfStrength", "HrtfHeadSize", "PlayOneShot", "SetGroupVolume") && Has("AudioReverbZone", "radius"), "audio: sources, the listener, HRTF settings and reverb zones");
		ok &= Check(Has("VoiceChat", "Enabled", "PushToTalk", "PushToTalkKey", "Talk", "Mute", "IsSpeaking", "Proximity", "TeamOnly", "MicrophoneLevel"), "voice chat");
		ok &= Check(Has("SpawnPoints", "Next", "Random", "TryGet") && Has("SpawnPoint", "team", "startOnly") && Has("Achievements", "Unlock", "SetProgress") && Has("Workshop", "Publish", "Subscribe") && Has("Steam", "AppId"), "spawn points, achievements, Workshop and Steam");
		ok &= Check(Has("CharacterController", "SimpleMove", "Move", "IsGrounded", "SetBox", "stepHeight") && Has("NavigationAgent", "SetDestination", "HasArrived") && Has("BehaviorTreeRunner", "tree") && Has("NetworkScript", "OnTick") && Has("NetworkManager", "SendToServer", "PlayerObject"), "character controller, navigation, behaviour trees and networking");
		ok &= Check(Has("KeyCode", "V", "Space", "Alpha1") && Has("AudioRolloff", "Linear", "Inverse") && Has("AudioGroup", "Voice", "Music"), "enum values");
		ok &= Check(ApiIndex.Find("AudioSource").baseType == "Component" && ApiIndex.Find("VoiceSession") != null && ApiIndex.Find("SpeakingHandler") != null, "base types, nested types and delegates");
		ok &= Check(Lacks("AudioSource", "mSource", "if", "return", "let", "Push", "get", "set") && Lacks("Audio", "tn_audio_init", "sReady") && Lacks("VoiceChat", "tn_voice_encode", "sLocal", "OnVoice"), "private members, native bindings and code inside methods are left out");

		// ---- the project's own scripts ----
		ok &= Check(Has("Turret", "range", "IsReady", "Fire", "Update") && Lacks("Turret", "hidden", "metres", "braces") && Has("Ammo", "Bullet", "Shell", "Rocket") && Lacks("Ammo", "4"), "the game's scripts are read too, including their private members");

		// ---- completion ----
		ok &= Check(Offers("VoiceChat.", "PushToTalkKey", "Enabled", "Mute") && Offers("\t\tAudio.Hr", "Hrtf", "HrtfStrength", "HrtfTreble"), "after a type and a dot, its members are offered");
		let buffer = scope String();
		ok &= Check(First("VoiceChat.Push", buffer) == "PushToTalk" && !Offers("VoiceChat.Push", "Enabled"), "narrowed by what has been typed, closest first");
		ok &= Check(Offers("AudioSource radio;\nradio.", "Play", "volume") && Offers("let radio = GetComponent<AudioSource>();\nradio.Pl", "Play", "PlayOneShot") && Offers("var gun = new Turret();\n\tgun?.", "Fire", "range"), "a variable's type is worked out from its declaration or what it is assigned");
		ok &= Check(Offers("let radio = GetComponent<AudioSource>();\nradio.GetCom", "GetComponent") && Offers("Turret t;\nt.", "Transform", "GameObject", "range"), "members inherited from Component are included");
		ok &= Check(Offers("Transform.", "Position", "Rotation") && Offers("KeyCode key = .Space;\nif (x == KeyCode.", "Space", "V"), "Transform on a component, and enum values");
		ok &= Check(Offers("Audi", "Audio", "AudioSource", "AudioListener") && Offers("\tVoiceC", "VoiceChat") && Offers("Turr", "Turret") && Offers("ret", "return"), "away from a dot: type names, the game's types and keywords");
		ok &= Check(!Offers("float x = 1.", "Play") && First("float x = 1.", buffer).IsEmpty && First("", buffer).IsEmpty, "nothing is offered after a number or on an empty line");

		// ---- code written later ----
		ok &= Check(ApiIndex.Find("Laser") == null && !Offers("Las", "Laser"), "a type that does not exist yet is unknown");
		File.WriteAllText(scope $"{project}/src/Scripts/Laser.bf" , "using Tallow;\nnamespace Game;\n[Component]\nclass Laser : Turret\n{\n\tpublic float heat;\n\tpublic void Overcharge(float amount)\n\t{\n\t}\n}\n").IgnoreError();
		let before = ApiIndex.Revision;
		ApiIndex.RefreshProject();
		ok &= Check(Has("Laser", "heat", "Overcharge") && Offers("Las", "Laser") && Offers("Laser beam;\nbeam.", "Overcharge", "heat", "range", "Fire", "Transform") && ApiIndex.Revision > before, "a script added afterwards is picked up, with what it inherits, and open scripts are told to recolour");
		File.Delete(scope $"{project}/src/Scripts/Laser.bf").IgnoreError();
		ApiIndex.RefreshProject();
		ok &= Check(ApiIndex.Find("Laser") == null && Has("Turret", "range"), "and forgotten when it is deleted");
		{
			// An engine feature that does not exist: the same reader finds it from its source alone.
			let future = scope Dictionary<String, ApiIndex.TypeEntry>();
			ApiIndex.ScanText("namespace Tallow;\n[Component]\nclass WeatherSystem : Component\n{\n\tpublic float rain;\n\tpublic static void Storm(float seconds) { }\n\tpublic enum Kind { Clear, Fog }\n}\n", future, true);
			ok &= Check(future.ContainsKeyAlt<StringView>("WeatherSystem") && future["WeatherSystem"].Has("rain") && future["WeatherSystem"].Has("Storm") && future.ContainsKeyAlt<StringView>("Kind") && future["Kind"].Has("Fog"), "a future engine class is understood from its source with no editor change");
			for (let entry in future.Values)
				delete entry;
		}
		File.Delete(scope $"{project}/src/Scripts/Turret.bf").IgnoreError();
		Directory.Delete(scope $"{project}/src/Scripts").IgnoreError();
		Directory.Delete(scope $"{project}/src").IgnoreError();
		Directory.Delete(project).IgnoreError();
		return ok ? 0 : 1;
	}
}
