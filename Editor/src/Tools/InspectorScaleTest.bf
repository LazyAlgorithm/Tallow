using System;
using System.Diagnostics;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// --inspector-scale-test N (benchmark B09): Inspector fields of N C# scripts. Writes src/ScaleProbe.cs (a public, a
/// private [ShowInInspector] and a [HideInInspector] field), builds it, then times: making N objects with the script
/// and editing two fields on each as the Inspector does; saving the scene (and its size); opening it again (and that
/// the values came back); entering Play, where every Awake checks it already sees the saved values (the game logs
/// "SCALE AWAKE checked=... wrong=..."); and stopping. Also checks a prefab of a probe keeps its values and that a
/// probe whose saved value cannot be read does not start (so N Awakes: N probes + the prefab copy - the broken one). Logs "INSPECTOR SCALE TEST PASS: ..." or "... FAIL: ...",
/// then quits. Run on a copy of a C# project (tools/benchmark_inspector_scale.py).
extension EditorApp
{
	int mScaleTestCount = -1;
	int mScaleTestStage;
	int mScaleTestFrame;
	Stopwatch mScaleTestClock = new .() ~ delete _;
	String mScaleTestReport = new .() ~ delete _;

	const String ScaleProbeSource = """
		using Tallow;

		public class ScaleProbe : Script
		{
		    public float Speed = 1f;
		    [ShowInInspector] private int count = 1;
		    [HideInInspector] public string Tag = "hidden";

		    static int sChecked, sWrong;
		    static bool sReported;

		    public override void Awake()
		    {
		        sChecked++;
		        if (Speed != 7.5f || count != 3 || Tag != "hidden")
		            sWrong++;
		    }

		    public override void LocalLateUpdate(float deltaTime)
		    {
		        if (sReported)
		            return;
		        sReported = true;
		        Log.Info($"SCALE AWAKE checked={sChecked} wrong={sWrong}");
		    }
		}

		""";

	void StartInspectorScaleTest(int count)
	{
		mScaleTestCount = count;
		File.WriteAllText(scope $"{Project.Current.Path}/src/ScaleProbe.cs", ScaleProbeSource).IgnoreError();
		mScaleTestStage = 0;
	}

	void FinishInspectorScaleTest(StringView failure)
	{
		mScaleTestCount = -1;
		if (failure.IsEmpty)
			Log.Info(scope $"INSPECTOR SCALE TEST PASS: {mScaleTestReport}");
		else
			Log.Error(scope $"INSPECTOR SCALE TEST FAIL: {failure} ({mScaleTestReport})");
		if (mPlay != .Edit)
			StopPlay();
		mDirty = false;
		Application.Quit();
	}

	double ScaleLap()
	{
		let ms = mScaleTestClock.Elapsed.TotalMilliseconds;
		mScaleTestClock.Restart();
		return ms;
	}

	void UpdateInspectorScaleTest()
	{
		if (mScaleTestCount < 0)
			return;
		mScaleTestFrame++;
		let scenePath = scope $"{Project.Current.Path}/Scenes/ScaleTest.tscene";
		switch (mScaleTestStage)
		{
		case 0:
			// The project's first build ends first; then the probe's.
			if (mScaleTestFrame < 3 || mCheckRunning || mWantRebuild)
				return;
			RequestRebuild();
			mScaleTestClock.Restart();
			mScaleTestStage = 1;
		case 1:
			if (mWantRebuild || mCheckRunning)
			{
				if (mScaleTestClock.Elapsed.TotalSeconds > 180)
					FinishInspectorScaleTest("the probe did not build in 180 s");
				return;
			}
			if (!mCheckSucceeded)
			{
				FinishInspectorScaleTest("the probe did not compile");
				return;
			}
			NewScene();
			mScaleTestClock.Restart();
			int accepted = 0;
			for (int i < mScaleTestCount)
			{
				let gameObject = mScene.CreateGameObject(scope $"Probe {i}");
				gameObject.Transform.Position = .((i % 100) * 2.0f, 0, (i / 100) * 2.0f);
				let script = gameObject.AddComponent<CSharpBehaviour>();
				script.SetScriptType("ScaleProbe");
				CSharpScriptIdentity.Stamp(script);
				if (script.WriteEditorField("Speed", "7.5") && script.WriteEditorField("count", "3"))
					accepted++;
			}
			MarkDirty();
			let made = ScaleLap();
			if (accepted != mScaleTestCount)
			{
				FinishInspectorScaleTest(scope $"{mScaleTestCount - accepted} scripts refused an Inspector edit");
				return;
			}
			Directory.CreateDirectory(scope $"{Project.Current.Path}/Scenes").IgnoreError();
			mScene.Path.Set(scenePath);
			if (!SceneSerializer.SaveToFile(mScene, scenePath))
			{
				FinishInspectorScaleTest("the scene did not save");
				return;
			}
			let saved = ScaleLap();
			int64 size = 0;
			{
				let stream = scope FileStream();
				if (stream.Open(scenePath, .Read) case .Ok)
					size = stream.Length;
			}
			mDirty = false;
			OpenScene(scenePath);
			let opened = ScaleLap();
			int scripts = 0, right = 0;
			let value = scope String();
			for (let component in mScene.Components)
			{
				if (let script = component as CSharpBehaviour)
				{
					scripts++;
					value.Clear();
					script.ReadEditorField("Speed", value);
					let speed = value == "7.5";
					value.Clear();
					script.ReadEditorField("count", value);
					if (speed && value == "3")
						right++;
				}
			}
			mScaleTestReport.AppendF("{} scripts: make+edit {:F0} ms, save {:F0} ms ({} KB, {} bytes a script), open {:F0} ms",
				mScaleTestCount, made, saved, size / 1024, size / Math.Max(1, mScaleTestCount), opened);
			if (scripts != mScaleTestCount || right != mScaleTestCount)
			{
				FinishInspectorScaleTest(scope $"after opening: {scripts} scripts, {right} with the saved values");
				return;
			}
			// Prefabs: a probe saved as a prefab and stamped again keeps its edited values (the copy plays too).
			let prefabPath = scope $"{Project.Current.Path}/Scenes/ScaleProbe.tprefab";
			Prefab.ClearCache();
			let source = mScene.Find("Probe 0");
			GameObject copy = null;
			if (source != null && Prefab.Save(source, prefabPath))
				copy = Prefab.Create(mScene, prefabPath);
			let copied = copy?.GetComponent<CSharpBehaviour>();
			value.Clear();
			copied?.ReadEditorField("Speed", value);
			let prefabOk = copied != null && value == "7.5";
			File.Delete(prefabPath).IgnoreError();
			if (!prefabOk)
			{
				FinishInspectorScaleTest("a prefab copy lost the probe's edited fields");
				return;
			}
			// A value that cannot be read (as an old or hand-edited scene might hold): that one script must not
			// start, with an error naming the object; every other one plays. So Awake runs N times: N + 1 scripts
			// (the prefab copy), one refused.
			let broken = mScene.Find(scope $"Probe {mScaleTestCount - 1}")?.GetComponent<CSharpBehaviour>();
			if (broken == null)
			{
				FinishInspectorScaleTest("no last probe");
				return;
			}
			broken.fieldOverrides.Set("Speed\t7.5\ncount\tbanana\n");
			mScaleTestClock.Restart();
			StartPlay();
			mScaleTestFrame = 0;
			mScaleTestStage = 2;
		case 2:
			if (mPlay == .Edit)
			{
				if (mScaleTestClock.Elapsed.TotalSeconds > 120)
					FinishInspectorScaleTest("Play did not start");
				return;
			}
			// The first frame has run: every Awake, then LateUpdate's report.
			if (mScaleTestFrame < 2)
				return;
			mScaleTestReport.AppendF(", enter Play {:F0} ms", ScaleLap());
			mScaleTestFrame = 0;
			mScaleTestStage = 3;
		case 3:
			if (mScaleTestFrame < 30)
				return;
			mScaleTestClock.Restart();
			StopPlay();
			mScaleTestReport.AppendF(", stop {:F0} ms", ScaleLap());
			if (!HasArg("--keep-scale-scene"))
				File.Delete(scenePath).IgnoreError();
			File.Delete(scope $"{Project.Current.Path}/src/ScaleProbe.cs").IgnoreError();
			FinishInspectorScaleTest("");
		}
	}
}
