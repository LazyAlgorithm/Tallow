using System;
using System.IO;
using System.Threading;

namespace Tallow.Editor;

/// Zig, which Tallow.Build links Linux NativeAOT games with on any machine (Managed/Tallow.Build/Export/Zig.cs):
/// without it, only Linux itself can (with the system's clang). Like Tallow's .NET (DotNetSdk), the pinned version
/// is unpacked into a per-user folder every Tallow version shares (`<data>/Tallow/zig/<version>`; TALLOW_ZIG_HOME
/// overrides it), staged beside its final folder and renamed into place once verified. Zig is a program per system
/// and chip, so this machine's own download is the one installed; each of them links for Linux.
static class ZigToolchain
{
	/// The Zig Tallow installs; Tallow.Build's Zig.Version must say the same.
	public const String PinnedVersion = "0.17.1";

	struct Download
	{
		public String host;
		public String archive;
		public String sha256;
		public int megabytes;
	}

	/// ziglang.org's archives and their SHA-256, from https://ziglang.org/download/index.json.
	static Download[?] Downloads = .(
		.() { host = "x86_64-linux", archive = "tar.xz", sha256 = "3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a", megabytes = 55 },
		.() { host = "aarch64-linux", archive = "tar.xz", sha256 = "a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795", megabytes = 51 },
		.() { host = "x86_64-windows", archive = "zip", sha256 = "b03f477a1943673e02aca0f570e8030dffd536ce1f45cbc4d3326ec31159562e", megabytes = 96 },
		.() { host = "aarch64-windows", archive = "zip", sha256 = "4789895bdb1e312a2ea73b2a7c0a0cc8d2ab62ba6976e834a7c54cf443377c15", megabytes = 92 },
		.() { host = "x86_64-macos", archive = "tar.xz", sha256 = "9af07b20319fbd0c92ee46ad23e81d6a782b1aaea2cfb8dcbff35f1d2c7ddbb7", megabytes = 57 },
		.() { host = "aarch64-macos", archive = "tar.xz", sha256 = "75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d", megabytes = 52 }
	);

	/// This machine as Zig names its downloads (x86_64-linux, aarch64-macos, ...).
	public static void Host(String output)
	{
#if BF_MACHINE_AARCH64
		output.Append("aarch64-");
#else
		output.Append("x86_64-");
#endif
#if BF_PLATFORM_WINDOWS
		output.Append("windows");
#elif BF_PLATFORM_MACOS
		output.Append("macos");
#else
		output.Append("linux");
#endif
	}

	/// The shared folder that holds each installed version (beside Tallow's .NET).
	public static void Home(String output)
	{
		if (Environment.GetEnvironmentVariable("TALLOW_ZIG_HOME", output) case .Ok && !output.IsEmpty)
		{
			output.Replace('\\', '/');
			return;
		}
		output.Clear();
		DotNetSdk.DataFolder(output);
		output.Append("/zig");
	}

	/// The folder of the pinned version (whether or not it is installed).
	public static void Root(String output)
	{
		Home(output);
		output.AppendF("/{}", PinnedVersion);
	}

	static void Executable(StringView root, String output)
	{
#if BF_PLATFORM_WINDOWS
		output.AppendF("{}/zig.exe", root);
#else
		output.AppendF("{}/zig", root);
#endif
	}

	/// Whether the pinned Zig is installed in Tallow's folder (or TALLOW_ZIG names one).
	public static bool Installed()
	{
		let chosen = scope String();
		if (Environment.GetEnvironmentVariable("TALLOW_ZIG", chosen) case .Ok && !chosen.IsEmpty)
			return File.Exists(chosen);
		return File.Exists(Executable(Root(.. scope .()), .. scope .()));
	}

	static Monitor sLock = new .() ~ delete _;
	static String sStatus = new .() ~ delete _;
	static bool sInstalling;
	static bool sFailed;

	/// Whether StartInstall's download is still running.
	public static bool Installing => Volatile.Read(ref sInstalling);

	/// What the last StartInstall did or is doing (empty before one), and whether it failed.
	public static bool GetStatus(String output)
	{
		using (sLock.Enter())
			output.Append(sStatus);
		return Volatile.Read(ref sFailed);
	}

	/// Installs Zig on a thread of its own, so the window keeps drawing: the project selector's and the Build
	/// window's button. Installing and GetStatus say how it goes.
	public static void StartInstall()
	{
		if (Installing)
			return;
		Volatile.Write(ref sInstalling, true);
		Volatile.Write(ref sFailed, false);
		using (sLock.Enter())
			sStatus.Set("Installing Zig...");
		let thread = new Thread(new () =>
			{
				let error = scope String();
				let ok = Install(scope (line) =>
					{
						using (sLock.Enter())
							sStatus.Set(line);
					}, error);
				if (!ok)
				{
					using (sLock.Enter())
						sStatus.Set(error);
					Volatile.Write(ref sFailed, true);
				}
				Volatile.Write(ref sInstalling, false);
			});
		thread.Start(true);
	}

	/// The size of this machine's download, in megabytes (0 when Tallow has none for it).
	public static int DownloadMegabytes()
	{
		let host = Host(.. scope .());
		for (let download in Downloads)
			if (download.host == host)
				return download.megabytes;
		return 0;
	}

	/// Installs the pinned Zig into Tallow's folder unless it is there already, downloaded from ziglang.org and checked
	/// against the pinned SHA-256. progress gets one line per step; error says what went wrong and what to do.
	public static bool Install(delegate void(StringView) progress, String error)
	{
		if (Installed())
		{
			progress(scope $"Zig {PinnedVersion} is already installed in {Root(.. scope .())}.");
			return true;
		}
		let host = Host(.. scope .());
		Download? found = null;
		for (let download in Downloads)
			if (download.host == host)
				found = download;
		if (found == null)
		{
			error.AppendF("Tallow has no Zig download for {}.", host);
			return false;
		}
		let download = found.Value;
		let home = Home(.. scope .());
		let root = Root(.. scope .());
		Directory.CreateDirectory(home).IgnoreError();
		// Attempts that were killed part-way leave their staging folder: clear those older than an hour.
		for (let entry in Directory.EnumerateDirectories(home))
		{
			let name = entry.GetFileName(.. scope .());
			if (name.StartsWith(".staging-") && (DateTime.UtcNow - entry.GetLastWriteTimeUtc()).TotalHours > 1)
				Directory.DelTree(scope $"{home}/{name}").IgnoreError();
		}
		let staging = scope $"{home}/.staging-{PinnedVersion}-{System.Diagnostics.Process.CurrentId}";
		if (Directory.Exists(staging))
			Directory.DelTree(staging).IgnoreError();
		if (Directory.CreateDirectory(staging) case .Err)
		{
			error.AppendF("Could not create {}. Check that the folder can be written.", staging);
			return false;
		}
		defer { Directory.DelTree(staging).IgnoreError(); }

		let name = scope $"zig-{host}-{PinnedVersion}";
		let file = scope $"{staging}/{name}.{download.archive}";
		let url = scope $"https://ziglang.org/download/{PinnedVersion}/{name}.{download.archive}";
		progress(scope $"Downloading Zig {PinnedVersion} ({host}, about {download.megabytes} MB)...");
		let command = scope String("curl -fL --retry 3 --silent --show-error -o ");
		Terminal.Quote(file, command);
		// Not Terminal.Quote: on Windows that turns '/' into '\', which breaks a URL.
		command.AppendF(" \"{}\"", url);
		if (Terminal.Run(command) != 0 || !File.Exists(file))
		{
			error.AppendF("The Zig download failed ({}). Check the internet connection and try again.", url);
			return false;
		}
		progress("Checking the archive...");
		let actual = scope String();
		if (!DotNetSdk.FileHash(file, staging, 256, actual))
		{
			error.Append("Could not compute the archive's SHA-256 (sha256sum, shasum or certutil is needed).");
			return false;
		}
		if (actual != download.sha256)
		{
			error.AppendF("The Zig archive is damaged or not the one Tallow expects (SHA-256 {}...). Nothing was installed; try again.", actual.Substring(0, Math.Min(16, actual.Length)));
			return false;
		}
		progress("Unpacking...");
		// tar reads both: .tar.xz on Linux and macOS, and .zip with Windows' own tar (not another one on PATH, such as
		// Git's, which cannot read a zip).
#if BF_PLATFORM_WINDOWS
		let extract = scope String("\"%SystemRoot%\\System32\\tar.exe\" -xf ");
#else
		let extract = scope String("tar -xf ");
#endif
		Terminal.Quote(file, extract);
		extract.Append(" -C ");
		Terminal.Quote(staging, extract);
		let unpacked = scope $"{staging}/{name}";
		if (Terminal.Run(extract) != 0 || !File.Exists(Executable(unpacked, .. scope .())))
		{
			error.Append("Unpacking Zig failed (is there enough disk space?). Nothing was installed.");
			return false;
		}
		// Another Tallow may have finished the same install meanwhile: keep theirs.
		if (Installed())
			return true;
		if (Directory.Exists(root))
			Directory.DelTree(root).IgnoreError();
		if (Directory.Move(unpacked, root) case .Err)
		{
			error.AppendF("Could not move Zig into {}.", root);
			return false;
		}
		progress(scope $"Installed Zig {PinnedVersion} in {root}.");
		return true;
	}
}
