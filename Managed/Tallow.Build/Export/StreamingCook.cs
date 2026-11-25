namespace Tallow.ManagedBuild.Export;

/// <summary>
/// The files a game streams from its pack (tallowengine.com/docs/streaming): the engine's player cooks them with no
/// window (<c>TallowPlayer --cook-streaming</c>, Engine/src/Streaming/StreamingCook.bf), so that the cooking code is
/// the one the game reads them with: <c>.tmips</c> (mip levels) and <c>.tvt</c> (virtual texture tiles) beside the
/// big pictures materials use, and <c>.cache/clod/*.tclod</c> / <c>.tclodp</c> (cluster hierarchies and their pages)
/// for big models. Desktop builds only: the web, Android and iOS builds load textures whole and keep their models'
/// pages in memory (no ranged reads from their packs).
/// </summary>
internal static class StreamingCook
{
    /// <summary>Cooks into the staging folder. Returns a message to print, or null when there was nothing to say.
    /// Never fails the build: a game without these files loads whole.</summary>
    public static string? Run(string player, string staging)
    {
        string assets = Path.Combine(staging, "Assets");
        if (!Directory.Exists(assets))
            return null;
        string kinds = Path.Combine(staging, "cook-kinds.txt");
        File.WriteAllText(kinds, string.Concat(Textures.MaterialPictures(assets).Select(entry => $"{entry.Path}\t{entry.Kind}\n")));
        try
        {
            var run = ExportUtil.TryRun(player, new[] { "--cook-streaming", staging, "--cook-kinds", kinds });
            string output = run.Output.Trim().Split('\n').LastOrDefault(line => line.StartsWith("cook-streaming:", StringComparison.Ordinal)) ?? "";
            return run.ExitCode == 0 ? "Streaming: " + output.Replace("cook-streaming: ", "") : $"Note: cooking the streamed files failed ({run.ExitCode}); the game loads them whole. {run.Error.Trim()}";
        }
        finally
        {
            File.Delete(kinds);
        }
    }
}
