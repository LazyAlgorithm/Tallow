using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Finds the tools Tallow compiles projects with: Beef's compiler and Python 3.11 or later, and on Windows
/// Microsoft's C runtime and Windows SDK libraries. Tallow Hub installs missing ones into a folder of the user's
/// (Folder); Apply points the editor and the build scripts at what it installed there. Tools the user installed
/// themselves are found on PATH as before.
static class Toolchain
{
	static String sFolder = new .() ~ delete _;

	/// Where Tallow Hub keeps the tools it installs.
	public static String Folder
	{
		get
		{
			if (sFolder.IsEmpty)
			{
				let home = scope String();
#if BF_PLATFORM_WINDOWS
				Environment.GetEnvironmentVariable("LOCALAPPDATA", home).IgnoreError();
				home.Replace('\\', '/');
#else
				if (!(Environment.GetEnvironmentVariable("XDG_DATA_HOME", home) case .Ok) || home.IsEmpty)
				{
					home.Clear();
					Environment.GetEnvironmentVariable("HOME", home).IgnoreError();
					home.Append("/.local/share");
				}
#endif
				sFolder.Append(home);
				sFolder.Append("/Tallow/toolchain");
			}
			return sFolder;
		}
	}

	static void OwnBeef(String path)
	{
		path.Append(Folder);
#if BF_PLATFORM_WINDOWS
		path.Append("/beef/bin/BeefBuild.exe");
#else
		path.Append("/beef/IDE/dist/BeefBuild.sh");
#endif
	}

	static void OwnPythonFolder(String path)
	{
		path.Append(Folder);
#if BF_PLATFORM_WINDOWS
		path.Append("/python");
#else
		path.Append("/python/bin");
#endif
	}

#if BF_PLATFORM_WINDOWS
	[CLink] static extern int32 _putenv_s(char8* name, char8* value);
#else
	[CLink] static extern int32 setenv(char8* name, char8* value, int32 overwrite);
#endif

	/// Sets an environment variable for this program and every program it starts (the C library's copy too, which
	/// is the one system() passes on).
	static void SetEnv(StringView name, StringView value)
	{
#if BF_PLATFORM_WINDOWS
		_putenv_s(scope String(name).CStr(), scope String(value).CStr());
#else
		setenv(scope String(name).CStr(), scope String(value).CStr(), 1);
#endif
	}

	/// Finds a program on PATH.
	static bool FindOnPath(StringView program, String outPath)
	{
		let path = scope String();
		Environment.GetEnvironmentVariable("PATH", path).IgnoreError();
#if BF_PLATFORM_WINDOWS
		let separator = ';';
		let suffix = ".exe";
#else
		let separator = ':';
		let suffix = "";
#endif
		for (let folder in path.Split(separator))
		{
			if (folder.IsEmpty)
				continue;
			let candidate = scope String(folder);
			candidate.Append('/');
			candidate.Append(program);
			candidate.Append(suffix);
			// The Microsoft Store's stand-in for Python only offers to install it.
			if (File.Exists(candidate) && !candidate.Contains("WindowsApps"))
			{
				outPath.Set(candidate);
				return true;
			}
		}
		return false;
	}

	/// The flag that has games linked with mold or lld when one is installed (Linux): either links a game in a
	/// fifth of the time GNU ld takes, and every compile ends with a link. Nothing when neither is installed.
	public static void FastLinkerFlag(String output)
	{
#if BF_PLATFORM_LINUX
		let found = scope String();
		if (FindOnPath("ld.mold", found))
			output.Append("-fuse-ld=mold ");
		else if (FindOnPath("ld.lld", found))
			output.Append("-fuse-ld=lld ");
#endif
	}

	/// A Beef folder (the root of a Beef checkout or install) with its standard libraries: its compiler is
	/// IDE/dist/BeefBuild, as Beef's own bin/build.sh makes it, or a BeefBuild.sh beside it.
	static bool BeefIn(StringView root, String output)
	{
		if (!File.Exists(scope $"{root}/BeefLibs/corlib/BeefProj.toml"))
			return false;
		for (let name in StringView[2]("BeefBuild", "BeefBuild.sh"))
		{
			let candidate = scope $"{root}/IDE/dist/{name}";
			if (File.Exists(candidate))
			{
				output.Set(candidate);
				return true;
			}
		}
		return false;
	}

	/// Resolve a user-installed Linux Beef compiler before relying on the managed copy.
	/// A valid compiler location must also contain Beef's standard libraries.
	static bool FindUserBeef(String output)
	{
		if (FindOnPath("BeefBuild", output) || FindOnPath("BeefBuild.sh", output))
			return true;
#if BF_PLATFORM_LINUX
		let home = scope String();
		Environment.GetEnvironmentVariable("HOME", home).IgnoreError();
		if (!home.IsEmpty)
		{
			for (let relative in StringView[4]("Beef", "beef", "dev/Beef", "dev/beef"))
			{
				if (BeefIn(scope $"{home}/{relative}", output))
					return true;
			}
		}
		for (let root in StringView[2]("/opt/beef", "/opt/Beef"))
		{
			if (BeefIn(root, output))
				return true;
		}
#endif
		return false;
	}

	/// Points this program, and the compilers and scripts it starts, at the tools Tallow Hub installed. Call once at
	/// start; a BeefBuild or Python the user installed themselves is used as before.
	public static void Apply()
	{
		let pythonFolder = scope String();
		OwnPythonFolder(pythonFolder);
		if (Directory.Exists(pythonFolder))
		{
#if BF_PLATFORM_WINDOWS
			pythonFolder.Replace('/', '\\');
			let separator = ";";
#else
			let separator = ":";
#endif
			let path = scope String();
			Environment.GetEnvironmentVariable("PATH", path).IgnoreError();
			if (!path.Contains(pythonFolder))
			{
				let joined = scope String(pythonFolder);
				joined.Append(separator);
				joined.Append(path);
				SetEnv("PATH", joined);
			}
		}
		let beef = scope String();
		OwnBeef(beef);
		let current = scope String();
		let userBeef = (Environment.GetEnvironmentVariable("BEEFBUILD", current) case .Ok) && !current.IsEmpty && File.Exists(current);
		var useOwn = File.Exists(beef) && !userBeef && !FindUserBeef(scope .());
#if BF_PLATFORM_WINDOWS
		// Microsoft's libraries that the Hub fetched are set up for its own copy of Beef.
		let crt = scope String(Folder);
		crt.Append("/msvc/crt/lib/x86_64/libcmt.lib");
		useOwn |= File.Exists(beef) && File.Exists(crt);
#endif
		if (useOwn)
			SetEnv("BEEFBUILD", beef);
		else if (!userBeef && !File.Exists(beef))
		{
			let discovered = scope String();
			if (FindUserBeef(discovered))
				SetEnv("BEEFBUILD", discovered);
		}
	}

	/// Names of required tools that cannot be found, for a message pointing at Tallow Hub. Quick enough to run as
	/// the launcher starts.
	public static void FindMissing(List<String> missing)
	{
		let beef = scope String();
		var hasBeef = (Environment.GetEnvironmentVariable("BEEFBUILD", beef) case .Ok) && !beef.IsEmpty && File.Exists(beef);
		let managed = scope String();
		OwnBeef(managed);
		if (hasBeef && beef == managed && !File.Exists(scope $"{Folder}/beef/BeefLibs/corlib/BeefProj.toml"))
			hasBeef = false;
		if (!hasBeef && !FindUserBeef(beef))
			missing.Add(new .("the Beef compiler and its standard libraries"));
		let python = scope String();
		if (!FindOnPath(Terminal.Python, python))
			missing.Add(new .("Python 3.11 or later"));
	}
}
