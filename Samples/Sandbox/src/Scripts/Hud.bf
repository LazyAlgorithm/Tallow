using System;
using Tallow;

namespace Sandbox;

/// Example in-game interface drawn with the GUI class.
[Component]
class Hud : Script
{
	bool mShowHelp = true;

	public override void OnGUI()
	{
		GUI.Box(12, 12, 250, mShowHelp ? 118 : 34, .(0, 0, 0, 0.45f));
		GUI.Label(22, 20, scope $"{(int)Time.SmoothedFps} fps");
		if (GUI.Button(170, 16, 82, 24, mShowHelp ? "Hide help" : "Help"))
			mShowHelp = !mShowHelp;
		if (mShowHelp)
		{
			GUI.Label(22, 48, "WASD move, Space jump");
			GUI.Label(22, 66, "Hold right mouse to look");
			GUI.Label(22, 84, "Left mouse digs, middle builds");
			GUI.Label(22, 102, "Dig through the boulder to break it");
		}
		let network = Scene.Network;
		if (network != null && network.Mode != .Offline)
			GUI.Label(GUI.Width - 220, 20, scope $"{network.Mode}  tick {network.Tick}");
	}
}
