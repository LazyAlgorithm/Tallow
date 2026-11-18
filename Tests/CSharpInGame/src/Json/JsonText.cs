using Newtonsoft.Json;

namespace InGame.Json;

/// Uses a NuGet package (Newtonsoft.Json), listed in this folder's Json.tasmdef.
public static class JsonText
{
    private sealed record Score(string Player, int Points);

    // NativeAOT: Score is the game's own type (game assemblies and their packages are kept whole), and the export
    // test runs this round trip in the built game.
    [System.Diagnostics.CodeAnalysis.UnconditionalSuppressMessage("Trimming", "IL2026", Justification = "Score and Newtonsoft.Json are kept whole; checked in the NativeAOT export test.")]
    [System.Diagnostics.CodeAnalysis.UnconditionalSuppressMessage("AOT", "IL3050", Justification = "Score and Newtonsoft.Json are kept whole; checked in the NativeAOT export test.")]
    public static string RoundTrip()
    {
        string text = JsonConvert.SerializeObject(new Score("Ada", 42));
        Score? back = JsonConvert.DeserializeObject<Score>(text);
        return $"{text}|{back?.Player}|{back?.Points}";
    }
}
