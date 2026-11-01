using System;
using Tallow;

namespace {NAMESPACE};

[Component]
class ExhibitionHUD : Component
{
	bool labels = true, diagnostics;
	Color panel = .(0.025f, 0.04f, 0.065f, 0.92f);
	Color muted = .(0.65f, 0.75f, 0.83f);
	public override void OnGUI()
	{
		let w = Exhibition.Active;
		if (w == null) return;
		if (Input.GetKeyDown(.L))
			labels = !labels;
		if (Input.GetKeyDown(.F3))
			diagnostics = !diagnostics;
		GUI.Box(18, 18, 365, 74, panel);
		GUI.Box(18, 18, 4, 74, .(0.1f, 0.8f, 0.95f));
		GUI.Label(34, 30, "T E S S E R A   /   E X H I B I T I O N");
		int visited = 0;
		for (int i < w.exhibits.Count)
		{
			if ((w.Visited & (1u << i)) != 0)
				visited++;
		}
		GUI.Label(34, 57, scope $"Interactive campus    {visited}/{w.exhibits.Count} exhibits visited" , muted);
		let x = GUI.Width - 220;
		GUI.Box(x, 18, 202, 74, panel);
		GUI.Label(x + 14, 30, scope $"{(int)Time.SmoothedFps} FPS    {1000/Math.Max(Time.SmoothedFps,1):0.0} ms");
		GUI.Label(x + 14, 57, w.Scene.Network == null || w.Scene.Network.Mode == .Offline ? "LOCAL EXPLORATION" : scope $"{w.Scene.Network.Mode}  |  {w.Scene.ComponentsOfType(typeof(VisitorAvatar)).Count} visitors" , muted);
		if (labels && !w.Directory && w.camera != null)
		{
			let data = w.camera.GetCameraData(GUI.AspectRatio);
			for (let e in w.exhibits)
			{
				let at = e.at + Vector3(-7.4f, 3.5f, -6.1f);
				let delta = at - w.camera.Transform.Position;
				if (delta.Length > 46 || Vector3.Dot(delta, w.camera.Transform.Forward) <= 0) continue;
				let p = data.WorldToViewportPoint(at);
				if (p.z < 0 || p.z > 1 || p.x < 0.03f || p.x > 0.85f || p.y < 0.13f || p.y > 0.72f) continue;
				let xx = p.x * GUI.Width, yy = p.y * GUI.Height;
				GUI.Box(xx - 8, yy - 5, 200, 27, panel);
				GUI.Label(xx, yy, scope $"{e.index+1:00}  {e.title}" , e.color);
			}
		}
		if (!w.Directory && w.nearest >= 0 && w.nearestDistance < 13)
		{
			let e = w.exhibits[w.nearest];
			let y = GUI.Height - 218;
			GUI.Box(18, y, Math.Min(650, GUI.Width - 36), 137, panel);
			GUI.Box(18, y, 4, 137, e.color);
			GUI.Label(34, y + 13, scope $"{e.index+1:00}  /  {e.title}" , e.color);
			// Descriptions use explicit line wrapping so text remains readable on the desktop window.
			let text = scope String(e.detail);
			int cut = Math.Min(79, text.Length);
			if (cut < text.Length)
			{
				let space = text.LastIndexOf(' ', cut);
				if (space > 35)
					cut = space;
			}
			GUI.Label(34, y + 42, text.Substring(0, cut), muted);
			if (cut < text.Length)
				GUI.Label(34, y + 62, text.Substring(cut), muted);
			if (GUI.Button(34, y + 92, 390, 29, scope $"E  |  {e.action}"))
				w.Use(e.index);
			if (GUI.Button(435, y + 92, 104, 29, "R  |  Reset"))
				w.Reset(e.index);
			if (e.index == 18 && w.Scene.Network != null && w.Scene.Network.Mode != .Offline && GUI.Button(548, y + 92, 105, 29, VoiceChat.Enabled ? "Mute mic" : "Enable mic"))
			{
				VoiceChat.PushToTalk = true;
				VoiceChat.PushToTalkKey = .V;
				VoiceChat.Enabled = !VoiceChat.Enabled;
				w.Notice(VoiceChat.Enabled ? "Microphone enabled: hold V to transmit tour voice chat." : "Microphone disabled.");
			}
		}
		if (!w.Directory && Time.RealTime < w.statusUntil)
		{
			GUI.Box(18, 104, Math.Min(900, GUI.Width - 36), 35, panel);
			GUI.Label(30, 114, w.status, .(0.8f, 0.95f, 1));
		}
		GUI.Box(18, GUI.Height - 62, GUI.Width - 36, 44, panel);
		GUI.Label(32, GUI.Height - 48, "WASD walk   Shift sprint   Space jump/swim   Hold RMB look   LMB push/carve", muted);
		if (GUI.Button(GUI.Width - 324, GUI.Height - 55, 138, 30, "M  |  Directory"))
			w.Directory = !w.Directory;
		if (GUI.Button(GUI.Width - 176, GUI.Height - 55, 144, 30, "Tab  |  Overview"))
		{
			w.Overview = !w.Overview;
			w.Directory = false;
		}
		if (!w.Directory && !w.Overview)
		{
			GUI.Box(GUI.Width / 2 - 1, GUI.Height / 2 - 5, 2, 10, .(1, 1, 1, 0.6f));
			GUI.Box(GUI.Width / 2 - 5, GUI.Height / 2 - 1, 10, 2, .(1, 1, 1, 0.6f));
		}
		if (diagnostics)
		{
			let top = 157f;
			GUI.Box(GUI.Width - 350, top, 332, 170, panel);
			GUI.Label(GUI.Width - 334, top + 14, "LIVE SYSTEMS  /  F3");
			GUI.Label(GUI.Width - 334, top + 43, scope $"NavMesh {w.NavReady}  Flight grid {w.FlightReady}" , muted);
			GUI.Label(GUI.Width - 334, top + 66, scope $"Local tile rebuilds: {w.TileUpdates}" , muted);
			GUI.Label(GUI.Width - 334, top + 89, scope $"Soft bodies {w.softs.Count}  Ropes {w.ropes.Count}" , muted);
			GUI.Label(GUI.Width - 334, top + 112, scope $"Shared console: {w.terminal?.presses}" , muted);
			if (w.Scene.Network != null)
				GUI.Label(GUI.Width - 334, top + 136, scope $"Net app out {w.Scene.Network.BytesSentPerSecond/1024f:0.0} KiB/s" , muted);
		}
		if (w.Directory)
			Directory(w);
	}

	void Directory(Exhibition w)
	{
		let width = Math.Min(1120, GUI.Width - 48);
		let left = (GUI.Width - width) / 2;
		let cols = width >= 1000 ? 4 : width >= 580 ? 2 : 1;
		let rows = (w.exhibits.Count + cols - 1) / cols;
		let h = rows * 62 + 150;
		let top = Math.Max(105, (GUI.Height - h) / 2);
		GUI.Box(left, top, width, h, panel);
		GUI.Label(left + 22, top + 18, "EXHIBITION DIRECTORY  /  choose a destination");
		GUI.Label(left + 22, top + 45, "Walk between exhibits, or select one for instant travel. Multiplayer travel and exhibit actions are handled by the host.", muted);
		for (let e in w.exhibits)
		{
			let col = e.index % cols;
			let row = e.index / cols;
			let cell = (width - 36) / cols;
			let x = left + 18 + col * cell;
			let y = top + 80 + row * 62;
			GUI.Box(x, y, 4, 46, e.color);
			if (GUI.Button(x + 10, y, cell - 20, 46, scope $"{e.index+1:00}  {e.title}"))
				w.Travel(e.index);
		}
		let y = top + 80 + rows * 62;
		if (GUI.Button(left + 22, y, 164, 32, "Screen effects"))
		{
			w.Effects = !w.Effects;
			w.Scene.Environment.bloom = w.Effects ? 0.22f : 0;
			w.Scene.Environment.ambientOcclusion = w.Effects ? 0.35f : 0;
		}
		if (GUI.Button(left + 198, y, 164, 32, "Diagnostics (F3)"))
			diagnostics = !diagnostics;
		if (GUI.Button(left + 374, y, 164, 32, "UI document"))
		{
			w.document.Enabled = true;
			w.Directory = false;
		}
		if (GUI.Button(left + 550, y, 164, 32, "Load saved visit"))
			w.LoadVisit();
		if (GUI.Button(left + 726, y, 164, 32, "Restart campus"))
			SceneManager.Load("Scenes/Campus.tscene");
		if (GUI.Button(left + width - 172, y, 150, 32, "Resume / Escape"))
			w.Directory = false;
		if (GUI.Button(left + width - 172, y + 37, 150, 25, "Quit showcase"))
			Application.Quit();
	}
}
