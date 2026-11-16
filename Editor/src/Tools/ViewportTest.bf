using System;
using Tallow;

namespace Tallow.Editor;

/// Test switch --viewport-test: a window dragged out of the editor. Places a window beside the main one, checks that
/// it gets an OS window of its own with a frame buffer to draw into, then docks it back (closes it) and checks the
/// extra window goes. Logs VIEWPORT-TEST PASS or FAIL and quits. Needs a desktop that can make the windows (X11,
/// Windows, macOS).
extension EditorApp
{
	int mViewportTestFrame = -1;
	String mViewportTestReport = new .() ~ delete _;
	bool mViewportTestPass = true;

	void ViewportTestExpect(bool condition, StringView what)
	{
		mViewportTestReport.AppendF("{}{}: {}", mViewportTestReport.IsEmpty ? "" : "; ", what, condition);
		mViewportTestPass &= condition;
	}

	/// Called from DrawUI each frame while the test runs.
	void UpdateViewportTest()
	{
		if (mViewportTestFrame < 0)
			return;
		mViewportTestFrame++;
		int32 windows = 0, drawn = 0;
		ImGui.tn_imgui_viewport_status(&windows, &drawn);
		if (mViewportTestFrame == 2)
			ViewportTestExpect(ImGui.tn_imgui_viewports_active(), "windows can be dragged out on this desktop");
		if (mViewportTestFrame >= 3 && mViewportTestFrame < 40)
		{
			let main = ImGui.GetMainViewport();
			// Beside the main window, so it cannot stay inside it.
			ImGui.SetNextWindowPos(.(main.pos.x + main.size.x + 40, main.pos.y + 40), 1);
			ImGui.SetNextWindowSize(.(320, 200), 1);
			if (ImGui.Begin("Viewport Test"))
				ImGui.Text("A window of its own.");
			ImGui.End();
		}
		if (mViewportTestFrame == 30)
			ViewportTestExpect(windows >= 2 && drawn >= 1, scope $"a window outside the editor gets an OS window and a frame buffer ({windows} windows, {drawn} drawn)");
		if (mViewportTestFrame == 60)
		{
			ViewportTestExpect(windows == 1 && drawn == 0, scope $"closing it removes its OS window ({windows} windows)");
			Log.Info(scope $"VIEWPORT-TEST {mViewportTestPass ? "PASS" : "FAIL"}: {mViewportTestReport}");
			Close();
		}
	}
}
