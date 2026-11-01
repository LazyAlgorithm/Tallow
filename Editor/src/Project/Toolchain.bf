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
		var useOwn = File.Exists(beef) && !userBeef && !FindOnPath("BeefBuild", scope .());
#if BF_PLATFORM_WINDOWS
		// Microsoft's libraries that the Hub fetched are set up for its own copy of Beef.
		let crt = scope String(Folder);
		crt.Append("/msvc/crt/lib/x86_64/libcmt.lib");
		useOwn |= File.Exists(beef) && File.Exists(crt);
#endif
		if (useOwn)
			SetEnv("BEEFBUILD", beef);
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
		if (!hasBeef && !FindOnPath("BeefBuild", beef))
			missing.Add(new .("the Beef compiler and its standard libraries"));
		let python = scope String();
		if (!FindOnPath(Terminal.Python, python))
			missing.Add(new .("Python 3.11 or later"));
	}
}
