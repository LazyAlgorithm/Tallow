using System;
using System.Collections;
using System.IO;

namespace Tallow.Editor;

/// A .NET SDK of Tallow's own, so C# needs no administrator rights or system-wide install: the pinned, released SDK
/// unpacked into a per-user folder that every Tallow version shares (`<data>/Tallow/dotnet/<version>`, data being
/// ~/.local/share, %LOCALAPPDATA% or ~/Library/Application Support; TALLOW_DOTNET_HOME overrides it). Each version
/// is a complete dotnet root, staged next to its final folder and renamed into place only once it was verified,
/// so an interrupted install leaves nothing that looks installed.
///
/// Apply (called as the launcher and editor start) puts that root first on PATH and in DOTNET_ROOT, so `dotnet`
/// builds, the language service, Tallow.Build, the export scripts and the editor's hosted runtime all use it. With
/// nothing installed there, the SDK on PATH is used as before.
static class DotNetSdk
{
	/// The SDK Tallow installs. Changing it is deliberate (a new engine version): projects never roll forward on
	/// their own, and older versions stay in the shared folder for the engines that pinned them.
	public const String PinnedVersion = "11.0.100";
	/// The .NET runtime (Microsoft.NETCore.App) that SDK carries, which the engine's C# is built for and JIT games
	/// bundle. An older or pre-release runtime cannot run it.
	public const String PinnedRuntime = "11.0.0";

	struct Download
	{
		public String rid;
		public String sha512;
	}

	/// SHA-512 of Microsoft's archive for each platform, from the official 11.0 release metadata.
	static Download[?] Downloads = .(
		.() { rid = "linux-x64", sha512 = "1bec9cca2ec689b1e80245b84f2b53c9441d1aa6daccf2ceb27490768bffa95954fa585bd275def31069d874d543d9ba9e6591fe9ade2dbd9f34ec5c0fd0050c" },
		.() { rid = "linux-arm64", sha512 = "cfa248bb1377606e868602fb5b4d66fa16b7546156593937d1982f7f2142e6ded76d71c4a26efdab99f87c46ab40c3c672ab1b57ef7fa25449efe5b140a55af4" },
		.() { rid = "win-x64", sha512 = "9beef28998c50eaa011f4241ff71c8c450c76a8556eda084d1f9857de3d6b5d9b136144a3e1a98b9f9b3e1e2fe50b06fff4c2f3b41208780a800408859084591" },
		.() { rid = "win-arm64", sha512 = "494cce1d758a3a7e28f2014058d67e05f84171dfad39f648103098964468c5c72736e826e88105056f5b26babcc1cabd1d1451dfda91aba4f09c6d45a6e6ab9c" },
		.() { rid = "osx-x64", sha512 = "8e9c8835c4d1ed8e3045f1a00e5831b028fb090161d1acbeb6e8b26882cb783ff18ab04f478134bf51b538f2becbbf999737c18f17c568ef37fb94a91a03d6a5" },
		.() { rid = "osx-arm64", sha512 = "6c8978e0a8f24a04b69a539fe29edf0c68e3247e46e24afb4920ee479e2ce1256b17fdf0626f8835b9c743784c08b40ecb25abdd8dd49fc99d040daf1ddb4de2" }
	);

	/// This machine's runtime identifier (linux-x64, win-arm64, ...).
	public static void Rid(String output)
	{
#if BF_PLATFORM_WINDOWS
		output.Append("win-");
#elif BF_PLATFORM_MACOS
		output.Append("osx-");
#else
		output.Append("linux-");
#endif
#if BF_MACHINE_AARCH64
		output.Append("arm64");
#else
		output.Append("x64");
#endif
	}

	/// The shared folder that holds each installed version.
	public static void Home(String output)
	{
		if (Environment.GetEnvironmentVariable("TALLOW_DOTNET_HOME", output) case .Ok && !output.IsEmpty)
		{
			output.Replace('\\', '/');
			return;
		}
		output.Clear();
		let home = scope String();
#if BF_PLATFORM_WINDOWS
		Environment.GetEnvironmentVariable("LOCALAPPDATA", home).IgnoreError();
		home.Replace('\\', '/');
#elif BF_PLATFORM_MACOS
		Environment.GetEnvironmentVariable("HOME", home).IgnoreError();
		home.Append("/Library/Application Support");
#else
		if (!(Environment.GetEnvironmentVariable("XDG_DATA_HOME", home) case .Ok) || home.IsEmpty)
		{
			home.Clear();
			Environment.GetEnvironmentVariable("HOME", home).IgnoreError();
			home.Append("/.local/share");
		}
#endif
		output.AppendF("{}/Tallow/dotnet", home);
	}

	/// The dotnet root of the pinned version (whether or not it is installed).
	public static void Root(String output)
	{
		Home(output);
		output.AppendF("/{}", PinnedVersion);
	}

	static void Executable(StringView root, String output)
	{
#if BF_PLATFORM_WINDOWS
		output.AppendF("{}/dotnet.exe", root);
#else
		output.AppendF("{}/dotnet", root);
#endif
	}

	/// Whether the pinned SDK is installed in Tallow's folder.
	public static bool Installed()
	{
		let root = Root(.. scope .());
		return File.Exists(Executable(root, .. scope .())) && Directory.Exists(scope $"{root}/sdk/{PinnedVersion}");
	}

#if BF_PLATFORM_WINDOWS
	[CLink] static extern int32 _putenv_s(char8* name, char8* value);
#else
	[CLink] static extern int32 setenv(char8* name, char8* value, int32 overwrite);
#endif

	static void SetEnv(StringView name, StringView value)
	{
#if BF_PLATFORM_WINDOWS
		_putenv_s(scope String(name).CStr(), scope String(value).CStr());
#else
		setenv(scope String(name).CStr(), scope String(value).CStr(), 1);
#endif
	}

	/// Whether the dotnet on PATH already has a released SDK of the pinned major, the pinned version or newer: then
	/// that one is used and Tallow's copy is not needed (one install of .NET is enough).
	public static bool PathHasReleased()
	{
		let listing = scope String();
		if (!DotNetCheck.RunDotNet("--list-sdks", Home(.. scope .()), listing))
			return false;
		let major = scope $"{PinnedVersion.Substring(0, PinnedVersion.IndexOf('.'))}.";
		for (var line in listing.Split('\n'))
		{
			line.Trim();
			let space = line.IndexOf(' ');
			let version = space > 0 ? line.Substring(0, space) : line;
			if (version.StartsWith(major) && !version.Contains('-') && DotNetCheck.CompareVersions(version, PinnedVersion) >= 0)
				return true;
		}
		return false;
	}

	/// When the pinned SDK is installed and the dotnet on PATH has no released one as new: this program and
	/// everything it starts use Tallow's copy (PATH and DOTNET_ROOT).
	/// Returns whether it did.
	public static bool Apply()
	{
		if (!Installed() || PathHasReleased())
			return false;
		let root = Root(.. scope .());
#if BF_PLATFORM_WINDOWS
		root.Replace('/', '\\');
		let separator = ";";
#else
		let separator = ":";
#endif
		let path = scope String();
		Environment.GetEnvironmentVariable("PATH", path).IgnoreError();
		if (!path.StartsWith(scope $"{root}{separator}"))
			SetEnv("PATH", scope $"{root}{separator}{path}");
		SetEnv("DOTNET_ROOT", root);
		// The SDK's first-run telemetry notice and workload checks would only slow the first build down.
		SetEnv("DOTNET_NOLOGO", "1");
		return true;
	}

	/// The archive's SHA-512 as lower-case hex, from the system's own tool (no .NET needed: this installs it).
	static bool Sha512(StringView file, StringView scratch, String output)
	{
		let result = scope $"{scratch}/sha512.txt";
		File.Delete(result).IgnoreError();
		let command = scope String();
#if BF_PLATFORM_WINDOWS
		command.Append("certutil -hashfile ");
		Terminal.Quote(file, command);
		command.Append(" SHA512 > ");
#elif BF_PLATFORM_MACOS
		command.Append("shasum -a 512 ");
		Terminal.Quote(file, command);
		command.Append(" > ");
#else
		command.Append("sha512sum ");
		Terminal.Quote(file, command);
		command.Append(" > ");
#endif
		Terminal.Quote(result, command);
		if (Terminal.Run(command) != 0)
			return false;
		let text = scope String();
		if (File.ReadAllText(result, text) case .Err)
			return false;
		File.Delete(result).IgnoreError();
		// The first run of 128 hex digits (certutil puts it on its second line, sha512sum first, before the name).
		for (var line in text.Split('\n'))
		{
			line.Trim();
			let hex = scope String();
			for (let c in line.RawChars)
			{
				let lower = c.ToLower;
				if ((lower >= '0' && lower <= '9') || (lower >= 'a' && lower <= 'f'))
					hex.Append(lower);
				else if (c != ' ')
					break;
			}
			if (hex.Length >= 128)
			{
				output.Append(hex.Substring(0, 128));
				return true;
			}
		}
		return false;
	}

	/// Installs the pinned SDK into Tallow's folder unless it is there already: downloaded from Microsoft, or taken
	/// from `archive` (an offline package's copy of the same file). The archive must match the pinned SHA-512.
	/// progress gets one line per step; error says what went wrong and what to do.
	public static bool Install(StringView archive, delegate void(StringView) progress, String error)
	{
		if (Installed())
		{
			progress(scope $".NET SDK {PinnedVersion} is already installed in {Root(.. scope .())}.");
			return true;
		}
		let rid = Rid(.. scope .());
		StringView expected = default;
		for (let download in Downloads)
			if (download.rid == rid)
				expected = download.sha512;
		if (expected.IsEmpty)
		{
			error.AppendF("Tallow has no .NET SDK download for {}; install the .NET {} SDK yourself.", rid, DotNetCheck.RequiredMajor);
			return false;
		}
		let home = Home(.. scope .());
		let root = Root(.. scope .());
		// Attempts that were killed part-way leave their staging folder: clear those older than an hour.
		if (Directory.Exists(home))
		{
			for (let entry in Directory.EnumerateDirectories(home))
			{
				let name = entry.GetFileName(.. scope .());
				if (name.StartsWith(".staging-") && (DateTime.UtcNow - entry.GetLastWriteTimeUtc()).TotalHours > 1)
					Directory.DelTree(scope $"{home}/{name}").IgnoreError();
			}
		}
		// A folder per attempt, next to the final one (same disk, so the last step is a rename).
		let staging = scope $"{home}/.staging-{PinnedVersion}-{System.Diagnostics.Process.CurrentId}";
		if (Directory.Exists(staging))
			Directory.DelTree(staging).IgnoreError();
		if (Directory.CreateDirectory(staging) case .Err)
		{
			error.AppendF("Could not create {}. Check that the folder can be written.", staging);
			return false;
		}
		defer { Directory.DelTree(staging).IgnoreError(); }

		let file = scope String();
		if (!archive.IsEmpty)
		{
			file.Set(archive);
			progress(scope $"Using {archive}.");
		}
		else
		{
			file.AppendF("{}/dotnet-sdk-{}-{}.tar.gz", staging, PinnedVersion, rid);
			let url = scope $"https://builds.dotnet.microsoft.com/dotnet/Sdk/{PinnedVersion}/dotnet-sdk-{PinnedVersion}-{rid}.tar.gz";
			progress(scope $"Downloading .NET SDK {PinnedVersion} ({rid}, about 230 MB)...");
			let command = scope String("curl -fL --retry 3 --silent --show-error -o ");
			Terminal.Quote(file, command);
			command.Append(' ');
			Terminal.Quote(url, command);
			if (Terminal.Run(command) != 0 || !File.Exists(file))
			{
				error.AppendF("The .NET SDK download failed ({}). Check the internet connection and try again, or install the .NET {} SDK yourself.", url, DotNetCheck.RequiredMajor);
				return false;
			}
		}
		progress("Checking the archive...");
		let actual = scope String();
		if (!Sha512(file, staging, actual))
		{
			error.Append("Could not compute the archive's SHA-512 (sha512sum, shasum or certutil is needed).");
			return false;
		}
		if (actual != expected)
		{
			error.AppendF("The .NET SDK archive is damaged or not the one Tallow expects (SHA-512 {}...). Nothing was installed; try again.", actual.Substring(0, Math.Min(16, actual.Length)));
			return false;
		}
		progress("Unpacking...");
		let unpacked = scope $"{staging}/root";
		Directory.CreateDirectory(unpacked).IgnoreError();
		let extract = scope String("tar -xzf ");
		Terminal.Quote(file, extract);
		extract.Append(" -C ");
		Terminal.Quote(unpacked, extract);
		if (Terminal.Run(extract) != 0 || !File.Exists(Executable(unpacked, .. scope .())) ||
			!Directory.Exists(scope $"{unpacked}/sdk/{PinnedVersion}"))
		{
			error.Append("Unpacking the .NET SDK failed (is there enough disk space?). Nothing was installed.");
			return false;
		}
		// Another Tallow may have finished the same install meanwhile: keep theirs.
		if (Installed())
			return true;
		if (Directory.Exists(root))
			Directory.DelTree(root).IgnoreError();
		if (Directory.Move(unpacked, root) case .Err)
		{
			error.AppendF("Could not move the SDK into {}.", root);
			return false;
		}
		progress(scope $"Installed .NET SDK {PinnedVersion} in {root}.");
		return true;
	}
}
