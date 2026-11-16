using System;
using System.Diagnostics;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// --references-test: Find All References through the whole editor path. Writes src/ReferencesProbe.cs and
/// src/ReferencesUser.cs (the second uses the first's field, and is not open), opens the probe, asks for the field's
/// references at its declaration and expects all four uses in both files, with lines; then opens the last one and
/// checks the caret is on it. Logs "REFERENCES TEST PASS: ..." or "... FAIL: ...", then quits.
extension EditorApp
{
	int mReferencesTestStep = -1;
	int mReferencesTestFrame;
	Stopwatch mReferencesTestClock = new .() ~ delete _;
	String mReferencesTestProbe = new .() ~ delete _;
	String mReferencesTestUser = new .() ~ delete _;

	const String ReferencesProbeSource = """
		using Tallow;

		public class ReferencesProbe : Script
		{
		    public int lives = 3;

		    public void Hit()
		    {
		        lives--;
		    }
		}

		""";

	const String ReferencesUserSource = """
		using Tallow;

		public class ReferencesUser : Script
		{
		    public override void Start()
		    {
		        var probe = GetComponent<ReferencesProbe>();
		        if (probe != null && probe.lives > 0)
		            probe.lives = 0;
		    }
		}

		""";

	void StartReferencesTest()
	{
		mReferencesTestProbe.Set(scope $"{Project.Current.Path}/src/ReferencesProbe.cs");
		mReferencesTestUser.Set(scope $"{Project.Current.Path}/src/ReferencesUser.cs");
		File.WriteAllText(mReferencesTestProbe, ReferencesProbeSource).IgnoreError();
		File.WriteAllText(mReferencesTestUser, ReferencesUserSource).IgnoreError();
		mReferencesTestStep = 0;
	}

	void FinishReferencesTest(StringView failure, StringView report = "")
	{
		mReferencesTestStep = -1;
		if (failure.IsEmpty)
			Log.Info(scope $"REFERENCES TEST PASS: {report}");
		else
			Log.Error(scope $"REFERENCES TEST FAIL: {failure}");
		File.Delete(mReferencesTestProbe).IgnoreError();
		File.Delete(mReferencesTestUser).IgnoreError();
		mDirty = false;
		Application.Quit();
	}

	void UpdateReferencesTest()
	{
		if (mReferencesTestStep < 0)
			return;
		mReferencesTestFrame++;
		if (mReferencesTestFrame < 5)
			return;
		var document = FindScript(mReferencesTestProbe);
		if (document == null)
		{
			OpenScript(mReferencesTestProbe);
			if (FindScript(mReferencesTestProbe) == null)
				FinishReferencesTest("the probe script did not open");
			return;
		}
		switch (mReferencesTestStep)
		{
		case 0:
			if (mSemantic.running)
				return;
			let source = StringView(tn_code_get_text(document.handle));
			let at = source.IndexOf("lives");
			OpenScript(mReferencesTestProbe);
			FindScriptReferences(document, (int32)(at + 2));
			if (!mFoundReferencesOpen || !mSemantic.running)
				return;
			mReferencesTestClock.Restart();
			mReferencesTestStep = 1;
		case 1:
			if (mSemantic.running || mSemantic.operation != "references")
			{
				if (mReferencesTestClock.Elapsed.TotalSeconds > 120)
					FinishReferencesTest("no answer after 120 s");
				return;
			}
			let took = mReferencesTestClock.Elapsed.TotalMilliseconds;
			let found = scope String();
			int inProbe = 0, inUser = 0;
			for (let reference in mFoundReferences)
			{
				found.AppendF("{}:{}:{} ", Path.GetFileName(reference.path, .. scope .()), reference.line + 1, reference.column + 1);
				if (reference.path.EndsWith("ReferencesProbe.cs"))
					inProbe++;
				else if (reference.path.EndsWith("ReferencesUser.cs"))
					inUser++;
			}
			// Declaration (line 5) and lives-- (line 9) in the probe; the read and the write in the other file (line 9, 10).
			if (inProbe != 2 || inUser != 2 || mFoundReferences[0].line != 4 || mFoundReferences[0].column != 15)
			{
				FinishReferencesTest(scope $"expected 2+2 references, got {found}({mSemantic.status})");
				return;
			}
			let last = mFoundReferences[mFoundReferences.Count - 1];
			OpenFoundReference(last);
			let opened = FindScript(mReferencesTestUser);
			if (opened == null || tn_code_cursor_byte(opened.handle) != last.byteStart)
			{
				FinishReferencesTest("clicking a reference did not open its file at the name");
				return;
			}
			FinishReferencesTest("", scope $"{mFoundReferences.Count} references in 2 files ({took:F0} ms): {found}");
		}
	}
}
