using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Running other programs through the system's command interpreter: sh on Linux and macOS, cmd on Windows.
static class Terminal
{
	[CLink] static extern int32 system(char8* command);

#if BF_PLATFORM_WINDOWS
	/// How Python is started.
	public const String Python = "python";
	/// Where unwanted output is sent.
	public const String Null = "NUL";
#else
	public const String Python = "python3";
	public const String Null = "/dev/null";
#endif

	/// Runs a command and waits for it. Returns the exit status (0 on success).
	public static int32 Run(StringView command)
	{
#if BF_PLATFORM_WINDOWS
		// Run the compiler/build shell without creating an external Windows console.
		// /s strips the outer quotes, preserving quoted executable paths and redirection inside.
		let start = scope ProcessStartInfo();
		start.SetFileName("cmd.exe");
		start.SetArguments(scope $"/d /s /c \"{command}\"");
		start.UseShellExecute = false;
		start.CreateNoWindow = true;
		let process = scope SpawnedProcess();
		if (process.Start(start) case .Err)
			return -1;
		return (int32)process.ExitCode;
#else
		return system(scope String(command).CStr());
#endif
	}

	/// Starts a command without waiting for it.
	public static void RunDetached(StringView command)
	{
		let line = scope String();
#if BF_PLATFORM_WINDOWS
		line.AppendF("start \"\" {}", command);
#else
		line.AppendF("({}) >/dev/null 2>&1 &", command);
#endif
#if BF_PLATFORM_WINDOWS
		Run(line);
#else
		system(line.CStr());
#endif
	}

	/// Wraps a path in quotes for the command interpreter.
	public static void Quote(StringView path, String outText)
	{
		outText.Append('"');
		for (let c in path.RawChars)
		{
#if BF_PLATFORM_WINDOWS
			// cmd has no escape inside quotes, and a file name cannot hold a quote.
			if (c == '"')
				continue;
			// Programs started by cmd take either slash; cmd's own commands only this one.
			if (c == '/')
			{
				outText.Append('\\');
				continue;
			}
#else
			if (c == '"' || c == '\\' || c == '$' || c == '`')
				outText.Append('\\');
#endif
			outText.Append(c);
		}
		outText.Append('"');
	}

	/// Opens a file or folder with whatever the desktop uses for it (a folder opens in the file manager).
	public static void Open(StringView path)
	{
#if BF_PLATFORM_WINDOWS
		let command = scope String("explorer ");
		#elif BF_PLATFORM_MACOS
		let command = scope String("open ");
		#else
		let command = scope String("xdg-open ");
#endif
		Quote(path, command);
		RunDetached(command);
	}
}
