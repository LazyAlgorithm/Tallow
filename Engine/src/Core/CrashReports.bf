using System;

namespace Tallow;

/// How a crash is reported. On Windows the launcher, editor and player are GUI programs, so Beef's crash catcher shows
/// a message box and waits for someone to close it. Nobody is there for a headless run, a command-line switch or a CI
/// job: the process would wait forever (a CI job then sits until its time limit). Those runs print the crash to the
/// console and exit instead.
static class CrashReports
{
	/// Call first thing in Main. Unattended means: the CI or TALLOW_NO_CRASH_DIALOG environment variable is set, or the
	/// command line has --headless or one of the launcher's command switches (--graph-compile, --write-..., tests).
	public static void UseConsoleWhenUnattended(Span<String> args)
	{
#if BF_PLATFORM_WINDOWS
		if (IsUnattended(args))
			Runtime.SetCrashReportKind(.Console);
#endif
	}

	public static bool IsUnattended(Span<String> args)
	{
		if (IsSet("CI") || IsSet("TALLOW_NO_CRASH_DIALOG"))
			return true;
		for (let arg in args)
		{
			if (arg == "--headless" || arg.EndsWith("-test") || arg.StartsWith("--graph-compile") ||
				arg.StartsWith("--write-") || arg.StartsWith("--csharp-") || arg == "--build-native-project")
				return true;
		}
		return false;
	}

	static bool IsSet(StringView name)
	{
		let value = scope String();
		if (Environment.GetEnvironmentVariable(name, value) case .Err)
			return false;
		return !value.IsEmpty && value != "0";
	}
}
