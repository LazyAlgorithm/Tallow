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

	/// Appends how to start Tallow.Build, ending in "--" (its own options follow): its built DLL when that is newer
	/// than every source of it (skipping `dotnet run`'s up-to-date check, about half a second a compile), otherwise
	/// `dotnet run --project`, which builds it first.
	public static void AppendBuildTool(StringView engineRoot, String command)
	{
		let folder = scope $"{engineRoot}/Managed/Tallow.Build";
		let dll = scope $"{folder}/bin/Debug/net11.0/Tallow.Build.dll";
		bool current = File.Exists(dll);
		if (current && File.GetLastWriteTimeUtc(dll) case .Ok(let built))
		{
			for (let entry in Directory.EnumerateFiles(folder))
			{
				let name = scope String();
				entry.GetFileName(name);
				if ((name.EndsWith(".cs") || name.EndsWith(".csproj")) && entry.GetLastWriteTimeUtc() > built)
				{
					current = false;
					break;
				}
			}
		}
		else
			current = false;
		if (current)
		{
			command.Append("dotnet ");
			Quote(dll, command);
			command.Append(" --");
			return;
		}
		command.Append("dotnet run --project ");
		Quote(scope $"{folder}/Tallow.Build.csproj", command);
		command.Append(" --");
	}

	/// True when Managed/Tallow.ManagedRuntime's Debug build is newer than every source it is built from (its own and
	/// Tallow.API's .cs/.csproj files, generated bindings included, and Managed's shared .props/.targets). The editor
	/// then skips `dotnet build` of it after each game compile: the runtime changes only with the engine, and the
	/// no-op MSBuild run cost about a second on every save. An engine package without the sources counts as current.
	public static bool ManagedRuntimeCurrent(StringView engineRoot)
	{
		let dll = scope $"{engineRoot}/Managed/Tallow.ManagedRuntime/bin/Debug/net11.0/Tallow.ManagedRuntime.dll";
		if (!(File.GetLastWriteTimeUtc(dll) case .Ok(let built)))
			return false;
		if (NewerSource(scope $"{engineRoot}/Managed", built, false))
			return false;
		return !NewerSource(scope $"{engineRoot}/Managed/Tallow.ManagedRuntime", built, true) &&
			!NewerSource(scope $"{engineRoot}/Managed/Tallow.API", built, true);
	}

	static bool NewerSource(StringView folder, DateTime built, bool recurse)
	{
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if ((name.EndsWith(".cs") || name.EndsWith(".csproj") || name.EndsWith(".props") || name.EndsWith(".targets")) &&
				entry.GetLastWriteTimeUtc() > built)
				return true;
		}
		if (!recurse)
			return false;
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (name == "bin" || name == "obj")
				continue;
			if (NewerSource(entry.GetFilePath(.. scope .()), built, true))
				return true;
		}
		return false;
	}

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
		process.WaitFor();
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
