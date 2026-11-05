using System;
using System.Collections;
using System.IO;
using Tallow;
using Bgfx;

namespace Tallow.Editor;

/// The Game tab.
extension EditorApp
{
	void DrawGameView()
	{
		ImGui.PushStyleVar(ImGui.StyleVar.WindowPadding, ImGui.Vec2(0, 0));
		let open = ImGui.Begin("Game", null, ImGui.WindowFlags.NoScrollbar | ImGui.WindowFlags.NoScrollWithMouse);
		ImGui.PopStyleVar();
		mGameVisible = false;
		mGameFocused = false;
		if (open)
		{
			let size = ImGui.GetContentRegionAvail();
			let origin = ImGui.GetCursorScreenPos();
			if (size.x > 8 && size.y > 8)
			{
				mGameVisible = true;
				mGameSize = size;
				if (FindGameCamera() && mGameView.Width > 0)
				{
					ImGui.Picture(mGameView.OutputTexture, .(mGameView.Width, mGameView.Height));
					// While the mouse is locked to the view the pointer is hidden and cannot hover: the view keeps the game.
					mGameFocused = (ImGui.IsWindowFocused() && ImGui.IsItemHovered()) || (mPlay == .Playing && Input.CursorLocked);
					if (ImGui.IsItemClicked())
						mLockHeldOff = false;
				}
				else
				{
					ImGui.SetCursorScreenPos(.(origin.x + 12, origin.y + 12));
					if (EditingPrefab)
						ImGui.TextDisabled("A prefab is open. It is edited in the Scene view: right-drag there to fly around it.");
					else
						ImGui.TextDisabled("No camera in the scene. Add one with GameObject > Camera.");
				}
				if (mPlay != .Edit)
					GUI.Run(mScene, origin, size);
				if (mPlay == .Playing && !mGameFocused)
					ImGui.DrawText(.(origin.x + 10, origin.y + size.y - 24), .(1, 1, 1, 0.7f), "Click the Game view to control the game");
				else if (mPlay == .Playing && Input.CursorLocked)
					ImGui.DrawText(.(origin.x + 10, origin.y + size.y - 24), .(1, 1, 1, 0.5f), "Mouse locked to the game. Esc frees it.");
			}
		}
		ImGui.End();
	}
}
