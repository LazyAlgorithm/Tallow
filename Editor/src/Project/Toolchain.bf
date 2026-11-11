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
		if (FromLoginShell(output))
			return true;
#endif
		return false;
	}

#if BF_PLATFORM_LINUX
	static bool sShellAsked;
	static String sShellBeef = new .() ~ delete _;

	/// Started from a desktop menu or file manager, Tallow does not get the PATH a terminal has (~/.bashrc,
	/// ~/.profile and the like add Beef to it there), so a Beef that works in a terminal would be "missing". The user's
	/// own shell is asked where BeefBuild is, once, with a few seconds' limit.
	static bool FromLoginShell(String output)
	{
		if (!sShellAsked)
		{
			sShellAsked = true;
			let shell = scope String();
			Environment.GetEnvironmentVariable("SHELL", shell).IgnoreError();
			if (shell.IsEmpty || !File.Exists(shell))
				shell.Set("/bin/sh");
			Directory.CreateDirectory(Folder).IgnoreError();
			let answer = scope $"{Folder}/shell-beef.txt";
			File.Delete(answer).IgnoreError();
			let command = scope String("timeout 5 ");
			Terminal.Quote(shell, command);
			command.Append(" -lic 'command -v BeefBuild || command -v BeefBuild.sh' < /dev/null > ");
			Terminal.Quote(answer, command);
			command.Append(" 2> /dev/null");
			Terminal.Run(command);
			let text = scope String();
			if (File.ReadAllText(answer, text) case .Ok)
			{
				// Interactive shells may print greetings first: the path is the last line.
				for (let line in text.Split('\n'))
				{
					let trimmed = scope String(line);
					trimmed.Trim();
					if (trimmed.StartsWith("/") && File.Exists(trimmed))
						sShellBeef.Set(trimmed);
				}
			}
			File.Delete(answer).IgnoreError();
		}
		if (sShellBeef.IsEmpty)
			return false;
		output.Set(sShellBeef);
		return true;
	}

	/// Whether a C++ compiler and the X11 and OpenGL development files are installed: Beef links every project with
	/// them. They come from the system's package manager.
	static bool HasLinuxBuildTools()
	{
		let found = scope String();
		if (!FindOnPath("c++", found) && !FindOnPath("g++", found) && !FindOnPath("clang++", found))
			return false;
		for (let library in StringView[2]("libGL.so", "libX11.so"))
		{
			bool have = false;
			for (let folder in StringView[5]("/usr/lib/x86_64-linux-gnu", "/usr/lib64", "/usr/lib", "/lib/x86_64-linux-gnu", "/usr/local/lib"))
				have |= File.Exists(scope $"{folder}/{library}");
			if (!have)
				return false;
		}
		return true;
	}
#endif

	/// Whether a Python 3.11 or later answers on PATH (an older one, such as Ubuntu 22.04's 3.10, cannot run the
	/// build scripts).
	static bool HasPython()
	{
		let python = scope String();
		if (!FindOnPath(Terminal.Python, python))
			return false;
		let command = scope String();
		Terminal.Quote(python, command);
		command.AppendF(" -c \"import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)\" > {} 2>&1", Terminal.Null);
		return Terminal.Run(command) == 0;
	}

	/// The command that installs the system packages Beef links with, for this system's package manager (Linux), or
	/// nothing when they are installed.
	public static void SystemPackagesCommand(String command)
	{
#if BF_PLATFORM_LINUX
		if (HasLinuxBuildTools())
			return;
		let found = scope String();
		if (FindOnPath("apt-get", found))
			command.Append("sudo apt-get install build-essential libgl-dev libx11-dev lld");
		else if (FindOnPath("dnf", found))
			command.Append("sudo dnf install gcc gcc-c++ mesa-libGL-devel libX11-devel lld");
		else if (FindOnPath("pacman", found))
			command.Append("sudo pacman -S --needed base-devel libglvnd libx11 lld");
		else if (FindOnPath("zypper", found))
			command.Append("sudo zypper install gcc gcc-c++ Mesa-libGL-devel libX11-devel lld");
		else
			command.Append("a C++ compiler (g++ or clang++) and the libGL and libX11 development packages");
#endif
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
		if (!HasPython())
			missing.Add(new .("Python 3.11 or later"));
#if BF_PLATFORM_LINUX
		if (!HasLinuxBuildTools())
			missing.Add(new .("a C++ compiler and the X11 and OpenGL development files (from your package manager)"));
#endif
	}
}
