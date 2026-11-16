using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// --completion-test: C# completion through the whole editor path (code widget -> language service -> list). Writes
/// src/CompletionProbe.cs, opens it and asks for completion as typing would at three places: a type from a namespace
/// not imported (StringBuilder, with its using), members after "Transform." (with descriptions), and the start of a
/// statement (a long list the service cuts short, so narrowing asks again). Logs "COMPLETION TEST PASS: ..." or
/// "... FAIL: ...", then quits. tools/test_csharp_editor.py runs it.
extension EditorApp
{
	[CLink] static extern void tn_code_test_request_completion(void* handle, int32 start, int32 end);
	[CLink] static extern int32 tn_code_test_completions(void* handle, char8* buffer, int32 capacity);

	int mCompletionTestCase = -1;
	int mCompletionTestFrame;
	bool mCompletionTestPass = true;
	Stopwatch mCompletionTestClock = new .() ~ delete _;
	String mCompletionTestReport = new .() ~ delete _;
	String mCompletionTestPath = new .() ~ delete _;

	const String CompletionProbeSource = """
		using Tallow;

		public class CompletionProbe : Script
		{
		    void Go()
		    {
		        
		        var b = new StringBui
		        Transform.Posi
		    }
		}

		""";

	void StartCompletionTest()
	{
		mCompletionTestPath.Set(scope $"{Project.Current.Path}/src/CompletionProbe.cs");
		File.WriteAllText(mCompletionTestPath, CompletionProbeSource).IgnoreError();
		mCompletionTestCase = 0;
	}

	void CompletionTestFail(StringView what)
	{
		mCompletionTestPass = false;
		mCompletionTestReport.AppendF("{}FAILED {}", mCompletionTestReport.IsEmpty ? "" : "; ", what);
	}

	void FinishCompletionTest()
	{
		mCompletionTestCase = -1;
		if (mCompletionTestPass)
			Log.Info(scope $"COMPLETION TEST PASS: {mCompletionTestReport}");
		else
			Log.Error(scope $"COMPLETION TEST FAIL: {mCompletionTestReport}");
		File.Delete(mCompletionTestPath).IgnoreError();
		mDirty = false;
		Application.Quit();
	}

	/// Called every frame from DrawUI while the test runs.
	void UpdateCompletionTest()
	{
		if (mCompletionTestCase < 0)
			return;
		mCompletionTestFrame++;
		if (mCompletionTestFrame < 5)
			return;
		var document = FindScript(mCompletionTestPath);
		if (document == null)
		{
			OpenScript(mCompletionTestPath);
			if (FindScript(mCompletionTestPath) == null)
			{
				CompletionTestFail("the probe script did not open");
				FinishCompletionTest();
			}
			return;
		}
		StringView[3] words = .("StringBui", "Transform.Posi", "    {\n        \n");
		if (mCompletionTestCase >= 3)
		{
			FinishCompletionTest();
			return;
		}
		let source = StringView(tn_code_get_text(document.handle));
		int at = source.IndexOf(words[mCompletionTestCase]);
		if (at < 0)
		{
			CompletionTestFail(scope $"case {mCompletionTestCase}: text not found");
			FinishCompletionTest();
			return;
		}
		// Byte offsets: the probe is ASCII.
		int32 end = (int32)(mCompletionTestCase == 2 ? at + 14 : at + words[mCompletionTestCase].Length);
		int32 start = mCompletionTestCase == 0 ? (int32)at : (mCompletionTestCase == 1 ? (int32)(at + 10) : end);
		if (!mCompletionTestClock.IsRunning)
		{
			// Brings the Scripts window to the front (as typing in it would be): a hidden tab asks nothing.
			OpenScript(mCompletionTestPath);
			tn_code_goto_byte(document.handle, end);
			tn_code_test_request_completion(document.handle, start, end);
			mCompletionTestClock.Restart();
			return;
		}
		let needed = tn_code_test_completions(document.handle, null, 0);
		if (needed == 0)
		{
			// The first request starts the language service (it may build it first).
			if (mCompletionTestClock.Elapsed.TotalSeconds > 120)
			{
				CompletionTestFail(scope $"case {mCompletionTestCase}: no completion after 120 s");
				FinishCompletionTest();
			}
			return;
		}
		char8* buffer = scope char8[needed + 1]*;
		tn_code_test_completions(document.handle, buffer, needed + 1);
		let items = scope String(buffer, needed);
		let took = mCompletionTestClock.Elapsed.TotalMilliseconds;
		mCompletionTestClock.Stop();
		mCompletionTestClock.Reset();
		switch (mCompletionTestCase)
		{
		case 0:
			if (!items.Contains("StringBuilder\x1F") || !items.Contains("\x1FSystem.Text\x1F") || !items.Contains("System.Text;"))
				CompletionTestFail(scope $"StringBuilder is not offered with its using: {items.Substring(0, Math.Min(300, items.Length))}");
			else
				mCompletionTestReport.AppendF("{}StringBuilder with its using ({:F0} ms)", mCompletionTestReport.IsEmpty ? "" : "; ", took);
		case 1:
			if (!items.StartsWith("Position\x1F") || !items.Contains("Vector3 Transform.Position"))
				CompletionTestFail(scope $"Transform.Posi does not offer Position first, described: {items.Substring(0, Math.Min(200, items.Length))}");
			else
				mCompletionTestReport.AppendF("; Transform.Position described ({:F0} ms)", took);
		case 2:
			if (!items.Contains("\x01more"))
				CompletionTestFail("a statement start is not marked as cut short");
			else
				{
				int count = 0;
				for (let c in items.RawChars)
					if (c == '\n')
						count++;
				mCompletionTestReport.AppendF("; statement start cut short, {} items ({:F0} ms)", count - 1, took);
			}
		}
		mCompletionTestCase++;
	}
}
