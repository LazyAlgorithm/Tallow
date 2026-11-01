using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

static class Shell
{
	[CLink] static extern int32 system(char8* command);

	/// Runs a shell command and waits for it. Returns the exit status (0 on success).
	public static int32 Run(StringView command) => system(scope String(command).CStr());

	/// Starts a command without waiting for it.
	public static void RunDetached(StringView command)
	{
		let line = scope String();
#if BF_PLATFORM_WINDOWS
		line.AppendF("start \"\" {}", command);
#else
		line.AppendF("({}) >/dev/null 2>&1 &", command);
#endif
		system(line.CStr());
	}

	/// Wraps a path in quotes for the shell.
	public static void Quote(StringView path, String outText)
	{
		outText.Append('"');
		for (let c in path.RawChars)
		{
			if (c == '"' || c == '\\' || c == '$' || c == '`')
				outText.Append('\\');
			outText.Append(c);
		}
		outText.Append('"');
	}
}
