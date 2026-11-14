using Tallow;

namespace Gameplay;

/// Verifies a UI gameplay script compiles against generated GUI bindings.
/// Native host tests do not invoke OnGUI without a real GUI context.
[Component]
public sealed class GuiApiSmoke : Script
{
    public override void OnGUI()
    {
        if (GUI.Button(GUI.Width - 130f, 12f, 120f, 30f, "Click"))
            Log.Info("Tallow GUI button clicked");
    }
}
