using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// --csharp-inspector-test: edits a C# script's fields the way the Inspector does (a plain field, a nested
/// [Serializable] field and an [Asset] path), then undoes and redoes them. Open a project whose scene has an
/// InGame.ApiChecks script (tools/test_csharp_ingame.py's copy of Tests/CSharpInGame). Logs
/// "CSHARP INSPECTOR TEST PASS: ..." or "CSHARP INSPECTOR TEST FAIL: ...".
extension EditorApp
{
	CSharpBehaviour FindInspectorTestScript()
	{
		for (let component in mScene.Components)
			if (let script = component as CSharpBehaviour)
				if (script.scriptType == "InGame.ApiChecks")
					return script;
		return null;
	}

	void RunCSharpInspectorTest()
	{
		let report = scope String();
		bool pass = true;
		void Check(bool ok, StringView what)
		{
			if (!report.IsEmpty)
				report.Append("; ");
			report.AppendF("{}: {}", what, ok);
			pass &= ok;
		}
		// The field's text in the scene now (the script is found again: undo rebuilds changed objects).
		bool Is(StringView name, StringView expected)
		{
			let value = scope String();
			if (let found = FindInspectorTestScript())
				found.ReadEditorField(name, value);
			return value == expected;
		}

		let script = FindInspectorTestScript();
		// Field labels, as Unity shows them.
		bool Label(StringView field, StringView expected)
		{
			let label = scope String();
			NiceName(field, label);
			if (label != expected)
				report.AppendF("[{} -> \"{}\"] ", field, label);
			return label == expected;
		}
		Check(Label("_testParam", "Test Param") && Label("m_MoveSpeed", "Move Speed") && Label("kMaxHealth", "Max Health") &&
			Label("speed", "Speed") && Label("jump_height", "Jump Height") && Label("HTTPServer", "HTTP Server") &&
			Label("player2Score", "Player 2 Score") && Label("isOnGround", "Is On Ground") && Label("UIScale", "UI Scale") &&
			Label("kind", "Kind") && Label("__private", "Private"), "field labels drop _ and m_ and split camel case");
		Check(script != null, "the scene has an ApiChecks script");
		if (script != null)
		{
			ResetUndo();
			Check(Is("Stats.Health", "42") && Is("Speed", "3"), "reads the scene's values");
			// One Inspector edit after another, each committed as the Inspector's idle commit does.
			script.WriteEditorField("Stats.Health", "77");
			MarkDirty();
			CommitSceneStep();
			script.WriteEditorField("EnemyPrefab", "Prefabs/Enemy.tprefab");
			script.WriteEditorField("Speed", "8");
			MarkDirty();
			CommitSceneStep();
			Check(Is("Stats.Health", "77") && Is("EnemyPrefab", "Prefabs/Enemy.tprefab"), "edits apply");
			Undo();
			Check(Is("Stats.Health", "77") && Is("EnemyPrefab", "") && Is("Speed", "3"), "undo takes back the last edit");
			Undo();
			Check(Is("Stats.Health", "42"), "a second undo takes back the nested field");
			Redo();
			Redo();
			Check(Is("Stats.Health", "77") && Is("EnemyPrefab", "Prefabs/Enemy.tprefab") && Is("Speed", "8"),
				"redo puts both back");
			mDirty = false;
		}
		if (pass)
			Log.Info(scope $"CSHARP INSPECTOR TEST PASS: {report}");
		else
			Log.Error(scope $"CSHARP INSPECTOR TEST FAIL: {report}");
	}
}
