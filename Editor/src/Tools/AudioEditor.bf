using System;
using Tallow;

namespace Tallow.Editor;

extension EditorApp
{
	/// Buttons under an Audio Source in the Inspector, for hearing it without pressing Play. Outside play mode the
	/// Scene view's camera is the listener, so fly around to judge distance and occlusion.
	void DrawAudioTools(AudioSource source)
	{
		if (ImGui.Button(source.IsPlaying ? "Restart" : "Preview"))
			source.Play();
		ImGui.SameLine();
		if (ImGui.Button("Stop"))
			source.Stop();
		ImGui.SameLine();
		if (source.audioClip.IsEmpty)
			ImGui.TextDisabled("Choose an Audio Clip: WAV, OGG, MP3 or FLAC.");
		else if (source.IsPlaying)
			ImGui.TextDisabled(scope String()..AppendF("{:0.0} / {:0.0} s{}", source.Time, source.Length, source.Occlusion > 0.5f ? "   occluded" : "").CStr());
		else if (!Audio.Ready && !source.audioClip.IsEmpty)
			ImGui.TextDisabled("Preview plays from the Scene view's camera.");
	}
}
