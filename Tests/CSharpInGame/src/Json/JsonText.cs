using Newtonsoft.Json;

namespace InGame.Json;

/// Uses a NuGet package (Newtonsoft.Json), listed in this folder's Json.tasmdef.
public static class JsonText
{
    private sealed record Score(string Player, int Points);

    public static string RoundTrip()
    {
        string text = JsonConvert.SerializeObject(new Score("Ada", 42));
        Score? back = JsonConvert.DeserializeObject<Score>(text);
        return $"{text}|{back?.Player}|{back?.Points}";
    }
}
