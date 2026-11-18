using System;
using System.Collections;
using System.IO;

namespace Tallow.Editor;

/// What C# gameplay needs on this machine: a .NET SDK and runtime of the major
/// version the engine targets, and an up-to-date build of Tallow's own managed
/// runtime. Quick enough for the launcher to run as it starts (two short
/// `dotnet` calls); nothing here needs Python or BeefBuild.
static class DotNetCheck
{
	/// The .NET major version Tallow.API and generated game projects target (net11.0).
	public const int32 RequiredMajor = 11;
	public const String DownloadUrl = "https://dotnet.microsoft.com/download/dotnet/11.0";

	public enum ProblemKind
	{
		/// No dotnet executable, or it has no SDK at all.
		MissingSdk,
		/// SDKs exist, but none of the required major version.
		OldSdk,
		/// The SDK exists but its Microsoft.NETCore.App runtime is missing.
		MissingRuntime,
		/// Tallow.ManagedRuntime has not been built, or is older than its sources.
		StaleManagedRuntime,
		/// Only a preview SDK: works, but releases should use a supported one.
		PreviewSdk,
		/// The SDK or runtime is not the version the engine targets (DotNetSdk.PinnedVersion / PinnedRuntime) or
		/// newer: a pre-release or an older one, which cannot run the engine's C# tools.
		WrongVersion
	}

	public class Problem
	{
		public ProblemKind kind;
		public String message = new .() ~ delete _;
		/// Blocking problems stop C# from compiling or running; warnings do not.
		public bool blocking;
	}

	public class Report
	{
		public List<Problem> problems = new .() ~ DeleteContainerAndItems!(_);
		/// Highest SDK of the required major version, or empty.
		public String sdkVersion = new .() ~ delete _;
		public String runtimeVersion = new .() ~ delete _;

		public bool HasBlocking
		{
			get
			{
				for (let problem in problems)
					if (problem.blocking)
						return true;
				return false;
			}
		}

		public bool Has(ProblemKind kind)
		{
			for (let problem in problems)
				if (problem.kind == kind)
					return true;
			return false;
		}

		public void Add(ProblemKind kind, bool blocking, StringView message)
		{
			let problem = new Problem();
			problem.kind = kind;
			problem.blocking = blocking;
			problem.message.Set(message);
			problems.Add(problem);
		}
	}

	/// The command that installs the SDK on this system, for the message.
	public static void InstallHint(String output)
	{
#if BF_PLATFORM_WINDOWS
		output.AppendF("winget install Microsoft.DotNet.SDK.{}", RequiredMajor);
#elif BF_PLATFORM_MACOS
		output.AppendF("brew install --cask dotnet-sdk (or the installer from {})", DownloadUrl);
#else
		if (File.Exists("/usr/bin/dnf"))
			output.AppendF("sudo dnf install dotnet-sdk-{}.0", RequiredMajor);
		else if (File.Exists("/usr/bin/apt") || File.Exists("/usr/bin/apt-get"))
			output.AppendF("sudo apt install dotnet-sdk-{}.0", RequiredMajor);
		else if (File.Exists("/usr/bin/pacman"))
			output.Append("sudo pacman -S dotnet-sdk");
		else
			output.AppendF("the installer from {}", DownloadUrl);
#endif
	}

	/// The major number of a "11.0.100-rc.1..." style version, or -1.
	static int32 Major(StringView version)
	{
		let dot = version.IndexOf('.');
		if (dot <= 0)
			return -1;
		if (int32.Parse(version.Substring(0, dot)) case .Ok(let value))
			return value;
		return -1;
	}

	static int64 Number(StringView text)
	{
		if (int64.Parse(text) case .Ok(let value))
			return value;
		return 0;
	}

	/// Compares dotted numeric versions; a pre-release ("-rc.1") sorts before its release.
	public static int CompareVersions(StringView a, StringView b)
	{
		let aDash = a.IndexOf('-');
		let bDash = b.IndexOf('-');
		let aParts = scope List<StringView>();
		let bParts = scope List<StringView>();
		for (let part in (aDash >= 0 ? a.Substring(0, aDash) : a).Split('.'))
			aParts.Add(part);
		for (let part in (bDash >= 0 ? b.Substring(0, bDash) : b).Split('.'))
			bParts.Add(part);
		for (int i < Math.Max(aParts.Count, bParts.Count))
		{
			let aValue = i < aParts.Count ? Number(aParts[i]) : 0;
			let bValue = i < bParts.Count ? Number(bParts[i]) : 0;
			if (aValue != bValue)
				return aValue < bValue ? -1 : 1;
		}
		if ((aDash >= 0) != (bDash >= 0))
			return aDash >= 0 ? -1 : 1;
		return scope String(a).CompareTo(scope String(b));
	}

	/// Runs `dotnet <arguments>` and reads what it printed. False when dotnet is missing or fails.
	public static bool RunDotNet(StringView arguments, StringView scratchFolder, String output)
	{
		Directory.CreateDirectory(scratchFolder).IgnoreError();
		let file = scope $"{scratchFolder}/dotnet-check.txt";
		File.Delete(file).IgnoreError();
		let command = scope String();
		command.AppendF("dotnet {} > ", arguments);
		Terminal.Quote(file, command);
		command.Append(" 2>&1");
		let status = Terminal.Run(command);
		File.ReadAllText(file, output).IgnoreError();
		File.Delete(file).IgnoreError();
		return status == 0;
	}

	/// The newest released version (no "-rc..." part) on lines "<prefix><version> [path]" of the required major
	/// that is `minimum` or newer, or false.
	static bool NewestReleased(StringView listing, StringView prefix, StringView minimum, String newest)
	{
		for (var line in listing.Split('\n'))
		{
			line.Trim();
			if (!line.StartsWith(prefix))
				continue;
			var rest = line.Substring(prefix.Length);
			let space = rest.IndexOf(' ');
			let version = space > 0 ? rest.Substring(0, space) : rest;
			if (Major(version) != RequiredMajor || version.Contains('-') || CompareVersions(version, minimum) < 0)
				continue;
			if (newest.IsEmpty || CompareVersions(version, newest) > 0)
				newest.Set(version);
		}
		return !newest.IsEmpty;
	}

	/// The newest version on lines "<prefix><version> [path]" whose major is RequiredMajor.
	static bool NewestMatching(StringView listing, StringView prefix, String newest, out bool anyVersion)
	{
		anyVersion = false;
		for (var line in listing.Split('\n'))
		{
			line.Trim();
			if (!line.StartsWith(prefix))
				continue;
			var rest = line.Substring(prefix.Length);
			let space = rest.IndexOf(' ');
			let version = space > 0 ? rest.Substring(0, space) : rest;
			if (Major(version) < 0)
				continue;
			anyVersion = true;
			if (Major(version) != RequiredMajor)
				continue;
			if (newest.IsEmpty || CompareVersions(version, newest) > 0)
				newest.Set(version);
		}
		return !newest.IsEmpty;
	}

	/// The newest modification time of the .cs/.csproj sources under a folder, skipping bin and obj.
	static DateTime NewestSource(StringView folder, int depth = 0)
	{
		DateTime newest = default;
		if (depth > 16 || !Directory.Exists(folder))
			return newest;
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (!name.EndsWith(".cs") && !name.EndsWith(".csproj"))
				continue;
			let time = entry.GetLastWriteTimeUtc();
			if (time > newest)
				newest = time;
		}
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (name == "bin" || name == "obj" || name.StartsWith('.'))
				continue;
			let time = NewestSource(scope $"{folder}/{name}", depth + 1);
			if (time > newest)
				newest = time;
		}
		return newest;
	}

	/// Where the engine loads its managed runtime from (see CSharpRuntime.StartTrustedGame).
	public static void ManagedRuntimePath(StringView engineRoot, String output)
	{
		output.AppendF("{}/Managed/Tallow.ManagedRuntime/bin/Debug/net{}.0/Tallow.ManagedRuntime.dll", engineRoot, RequiredMajor);
	}

	static DateTime Modified(StringView path)
	{
		if (File.GetLastWriteTimeUtc(path) case .Ok(let time))
			return time;
		return default;
	}

	/// Written after Tallow builds the runtime itself: MSBuild leaves an identical
	/// assembly untouched, so the DLL's own time can trail an edited source.
	static void StampPath(StringView engineRoot, String output)
	{
		output.AppendF("{}/Managed/Tallow.ManagedRuntime/bin/Debug/net{}.0/.tallow-runtime-built", engineRoot, RequiredMajor);
	}

	/// True when the managed runtime needs building: missing, or an assembly older than its sources.
	/// A packaged engine without the managed sources only needs the built files.
	public static bool ManagedRuntimeStale(StringView engineRoot)
	{
		let runtime = scope String();
		ManagedRuntimePath(engineRoot, runtime);
		let folder = scope String();
		Path.GetDirectoryPath(runtime, folder).IgnoreError();
		let config = scope $"{folder}/Tallow.ManagedRuntime.runtimeconfig.json";
		let api = scope $"{folder}/Tallow.API.dll";
		if (!File.Exists(runtime) || !File.Exists(config) || !File.Exists(api))
			return true;
		let stamp = Modified(StampPath(engineRoot, .. scope .()));
		let runtimeBuilt = Math.Max(Modified(runtime), stamp);
		let apiBuilt = Math.Max(Modified(api), stamp);
		if (NewestSource(scope $"{engineRoot}/Managed/Tallow.API") > apiBuilt)
			return true;
		return NewestSource(scope $"{engineRoot}/Managed/Tallow.ManagedRuntime") > runtimeBuilt;
	}

	/// Builds Tallow.ManagedRuntime (and Tallow.API with it) with the .NET SDK. Returns the SDK's output in log.
	public static bool BuildManagedRuntime(StringView engineRoot, StringView scratchFolder, String log)
	{
		Directory.CreateDirectory(scratchFolder).IgnoreError();
		let file = scope $"{scratchFolder}/managed-runtime-build.log";
		let command = scope String("dotnet build ");
		Terminal.Quote(scope $"{engineRoot}/Managed/Tallow.ManagedRuntime/Tallow.ManagedRuntime.csproj", command);
		command.Append(" --configuration Debug --nologo --verbosity minimal > ");
		Terminal.Quote(file, command);
		command.Append(" 2>&1");
		let ok = Terminal.Run(command) == 0;
		File.ReadAllText(file, log).IgnoreError();
		if (!ok)
			return false;
		File.WriteAllText(StampPath(engineRoot, .. scope .()), "Built by the Tallow launcher.\n").IgnoreError();
		return !ManagedRuntimeStale(engineRoot);
	}

	/// Checks everything C# gameplay needs. scratchFolder holds short-lived output files.
	public static void Check(StringView engineRoot, StringView scratchFolder, Report report)
	{
		let hint = scope String();
		InstallHint(hint);
		let sdks = scope String();
		if (!RunDotNet("--list-sdks", scratchFolder, sdks) || sdks.IsWhiteSpace)
		{
			report.Add(.MissingSdk, true, scope $"The .NET {RequiredMajor} SDK is not installed. C# scripts cannot compile without it. Install it with: {hint}");
			return;
		}
		bool anySdk = false;
		if (!NewestMatching(sdks, "", report.sdkVersion, out anySdk))
		{
			report.Add(anySdk ? .OldSdk : .MissingSdk, true,
				scope $"Tallow needs the .NET {RequiredMajor} SDK; this machine only has other versions. Install it with: {hint}");
			return;
		}
		// The engine targets a released SDK and runtime (DotNetSdk.PinnedVersion / PinnedRuntime) or newer: its C#
		// tools are built for that runtime and do not start on a pre-release or older one.
		let released = scope String();
		if (NewestReleased(sdks, "", DotNetSdk.PinnedVersion, released))
			report.sdkVersion.Set(released);
		else
			report.Add(.WrongVersion, true,
				scope $"This engine targets .NET SDK {DotNetSdk.PinnedVersion} (runtime {DotNetSdk.PinnedRuntime}), but this machine has .NET SDK {report.sdkVersion}{report.sdkVersion.Contains('-') ? " (a preview)" : ""}. Download .NET {DotNetSdk.PinnedVersion} or newer, or install it for Tallow (the launcher's Install button, or TallowLauncher --install-dotnet).");

		let runtimes = scope String();
		RunDotNet("--list-runtimes", scratchFolder, runtimes);
		bool anyRuntime = false;
		if (!NewestMatching(runtimes, "Microsoft.NETCore.App ", report.runtimeVersion, out anyRuntime))
			report.Add(.MissingRuntime, true,
				scope $"The .NET {RequiredMajor} runtime (Microsoft.NETCore.App) is missing, so C# gameplay cannot start. Reinstall the SDK with: {hint}");
		else
		{
			let releasedRuntime = scope String();
			if (NewestReleased(runtimes, "Microsoft.NETCore.App ", DotNetSdk.PinnedRuntime, releasedRuntime))
				report.runtimeVersion.Set(releasedRuntime);
			else if (!report.Has(.WrongVersion))
				report.Add(.WrongVersion, true,
					scope $"This engine targets the .NET runtime {DotNetSdk.PinnedRuntime}, but this machine has {report.runtimeVersion}{report.runtimeVersion.Contains('-') ? " (a preview)" : ""}. Download .NET {DotNetSdk.PinnedVersion} or newer, or install it for Tallow (the launcher's Install button, or TallowLauncher --install-dotnet).");
		}

		if (!engineRoot.IsEmpty && ManagedRuntimeStale(engineRoot))
			report.Add(.StaleManagedRuntime, true,
				"Tallow's C# runtime is not built, or is older than the engine's C# sources. Rebuild it before playing.");
	}
}
