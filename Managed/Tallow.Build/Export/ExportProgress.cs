using System;
using System.IO;
using System.Threading;

namespace Tallow.ManagedBuild.Export;

/// <summary>How a build says how far along it is, for the editor's progress bar: a line "##progress 0.35 Stage" on
/// the console (the editor reads it from the build log and does not show it as text), and a lock for the steps two
/// builds of one project cannot do at once.</summary>
internal static class ExportProgress
{
    public static void Report(double fraction, string stage)
    {
        Console.WriteLine(FormattableString.Invariant($"##progress {Math.Clamp(fraction, 0, 1):0.000} {stage}"));
        Console.Out.Flush();
    }

    /// <summary>Held while the game's C# is compiled and made into the player's code; another build of the project waits
    /// for it. The system frees it if this process is killed.</summary>
    public static IDisposable Gate(string project)
    {
        string folder = Path.Combine(project, "build");
        Directory.CreateDirectory(folder);
        string path = Path.Combine(folder, ".compile.lock");
        bool said = false;
        while (true)
        {
            try
            {
                return new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None, 1, FileOptions.DeleteOnClose);
            }
            catch (IOException)
            {
                if (!said)
                    Report(0.03, "Waiting for the other build to finish compiling");
                said = true;
                Thread.Sleep(500);
            }
        }
    }
}
