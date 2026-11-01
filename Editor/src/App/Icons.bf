using Tallow;

namespace Tallow.Editor;

/// Font Awesome 4 glyphs (merged into the editor font by the native ImGui setup).
static class Icons
{
	public const char8* Cube = "\u{f1b2}";
	public const char8* Folder = "\u{f07b}";
	public const char8* Camera = "\u{f03d}";
	public const char8* Light = "\u{f0eb}";
	public const char8* Transform = "\u{f047}";
	public const char8* Body = "\u{f192}";
	public const char8* Collider = "\u{f132}";
	public const char8* Terrain = "\u{f279}";
	public const char8* Voxel = "\u{f219}";
	public const char8* Particles = "\u{f06d}";
	public const char8* Network = "\u{f1eb}";
	public const char8* Character = "\u{f007}";
	public const char8* Script = "\u{f121}";
	public const char8* Menu = "\u{f142}";

	public const char8* PlayLabel = "\u{f04b}  Play";
	public const char8* StopLabel = "\u{f04d}  Stop";
	public const char8* PauseLabel = "\u{f04c}  Pause";
	public const char8* StepLabel = "\u{f051}  Step";

	public static Color FolderColor => EditorTheme.Folder;
	public static Color ObjectColor => EditorTheme.Object;
	public static Color ComponentColor => EditorTheme.Component;
}
