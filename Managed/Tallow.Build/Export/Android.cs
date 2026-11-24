using System.IO.Compression;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Tallow.ManagedBuild.Export;

/// <summary>What an Android export uses, all from Android Studio: its SDK (build tools, a platform), its own Java,
/// and the SDK's NDK (Tallow installs it into the SDK when it is missing, see <see cref="InstallNdk"/>).</summary>
internal sealed record AndroidTools(string? Studio, string? Sdk, string? Java, string? Ndk, string? BuildTools, string? PlatformJar, int Api)
{
    /// <summary>Everything but the NDK, which Tallow can install itself.</summary>
    public bool HasStudio => Sdk != null && Java != null && BuildTools != null && PlatformJar != null;
    public bool Complete => HasStudio && Ndk != null;
}

/// <summary>
/// Android games (Tallow.Build export --platform android): an APK holding the engine's precompiled Android player
/// (Player/build/Release_Android: libmain.so per ABI and classes.dex, made by tools/android/build_player.sh and
/// carried by every engine package), the game's C# compiled by NativeAOT for linux-bionic, and the game's files.
///
/// Making one needs only Android Studio. Tallow finds it, its SDK and its Java where Studio puts them on Linux,
/// Windows and macOS (or where android-set saved: the Build window's "Android Studio" and "Android SDK" fields), and
/// installs Google's NDK into that SDK the first time (<see cref="InstallNdk"/>; the C# library is linked with it).
/// No Gradle, no Android project: the APK is put together here with the SDK's aapt2, zipalign and apksigner.
///
/// <code>
///   android-status                       what was found (key = value lines, for the editor)
///   android-set [--studio P] [--sdk P]   saves folders Tallow did not find by itself (empty clears)
///   android-install-ndk                  installs the NDK Tallow uses into the SDK
/// </code>
/// </summary>
internal static class Android
{
    /// <summary>Android 10: the oldest with ELF thread-local storage, which the engine's Beef code uses.</summary>
    public const int MinApi = 29;
    /// <summary>Phones and tablets (arm64-v8a) and the emulator on a PC (x86_64).</summary>
    public static readonly string[] Abis = { "arm64-v8a", "x86_64" };

    /// <summary>The NDK Tallow installs: r30, with each system's archive and its SHA-1 (Google's SDK repository).</summary>
    public const string NdkVersion = "30.0.16248370";
    static readonly (string Host, string Archive, string Sha1, long Size)[] NdkArchives =
    {
        ("linux", "android-ndk-r30-linux.zip", "5107f898313790e449e87eee2183d9a20602dee9", 738633529),
        ("macosx", "android-ndk-r30-darwin.zip", "c060be96767eefbb8e0a27796d6f43115fc1a0c4", 974984488),
        ("windows", "android-ndk-r30-windows.zip", "9bf167a1985fa7d4a036186b78f702eab9179408", 727980788),
    };

    public static string Rid(string abi) => abi == "x86_64" ? "linux-bionic-x64" : "linux-bionic-arm64";
    static string Triple(string abi) => abi == "x86_64" ? "x86_64-linux-android" : "aarch64-linux-android";

    public const string StudioHelp = "Android games are made with Android Studio's tools. Install Android Studio " +
        "(https://developer.android.com/studio), open it once so it sets up its SDK, then build again. If it is installed " +
        "somewhere Tallow does not look, choose its folder in the Build window (or run: Tallow.Build android-set --studio <folder>).";

    // ---- Finding Android Studio, its SDK and its Java ----

    static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>Tallow's own data folder (where .NET and Zig go): ~/.local/share/Tallow, %LOCALAPPDATA%\Tallow or
    /// ~/Library/Application Support/Tallow.</summary>
    static string DataFolder()
    {
        if (ExportUtil.HostLinux)
        {
            string? xdg = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
            return Path.Combine(string.IsNullOrEmpty(xdg) ? Path.Combine(Home, ".local", "share") : xdg, "Tallow");
        }
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Tallow");
    }

    static string SettingsFile => Path.Combine(DataFolder(), "android.txt");

    static Dictionary<string, string> Saved() =>
        File.Exists(SettingsFile) ? ExportUtil.ReadSettings(SettingsFile) : new Dictionary<string, string>();

    static string? JavaIn(string? folder)
    {
        if (string.IsNullOrEmpty(folder))
            return null;
        string java = ExportUtil.HostWindows ? "java.exe" : "java";
        foreach (string home in new[] { folder, Path.Combine(folder, "jbr"), Path.Combine(folder, "jre"),
            Path.Combine(folder, "Contents", "jbr", "Contents", "Home"), Path.Combine(folder, "jbr", "Contents", "Home") })
            if (File.Exists(Path.Combine(home, "bin", java)))
                return home;
        return null;
    }

    static bool IsSdk(string? folder) =>
        !string.IsNullOrEmpty(folder) && Directory.Exists(Path.Combine(folder, "platforms")) && Directory.Exists(Path.Combine(folder, "build-tools"));

    /// <summary>Folders Android Studio installs into on this system (its installer, JetBrains Toolbox, snap).</summary>
    static IEnumerable<string> StudioFolders()
    {
        if (ExportUtil.HostMac)
        {
            yield return "/Applications/Android Studio.app";
            yield return Path.Combine(Home, "Applications", "Android Studio.app");
            foreach (string toolbox in Children(Path.Combine(Home, "Applications")).Where(path => Path.GetFileName(path).StartsWith("Android Studio", StringComparison.Ordinal)))
                yield return toolbox;
        }
        else if (ExportUtil.HostWindows)
        {
            foreach (string? root in new[] { Environment.GetEnvironmentVariable("ProgramFiles"), Environment.GetEnvironmentVariable("LOCALAPPDATA") is { } local ? Path.Combine(local, "Programs") : null })
                if (!string.IsNullOrEmpty(root))
                    yield return Path.Combine(root, "Android", "Android Studio");
            if (Environment.GetEnvironmentVariable("LOCALAPPDATA") is { Length: > 0 } appData)
            {
                yield return Path.Combine(appData, "Programs", "Android Studio");
                foreach (string toolbox in Children(Path.Combine(appData, "Programs")).Where(path => Path.GetFileName(path).StartsWith("Android Studio", StringComparison.Ordinal)))
                    yield return toolbox;
            }
        }
        else
        {
            foreach (string folder in new[] { Path.Combine(Home, "Applications", "android-studio"), Path.Combine(Home, "android-studio"),
                "/opt/android-studio", "/usr/local/android-studio", "/snap/android-studio/current", "/opt/google/android-studio" })
                yield return folder;
            foreach (string toolbox in Children(Path.Combine(Home, ".local", "share", "JetBrains", "Toolbox", "apps")).Where(path => Path.GetFileName(path).StartsWith("android-studio", StringComparison.Ordinal)))
                yield return toolbox;
        }
    }

    static IEnumerable<string> Children(string folder) =>
        Directory.Exists(folder) ? Directory.EnumerateDirectories(folder).Order(StringComparer.Ordinal) : Enumerable.Empty<string>();

    /// <summary>The SDK folder Android Studio's settings name (options/android.sdk.path.xml), newest Studio first.</summary>
    static IEnumerable<string> StudioSettingsSdks()
    {
        string config = ExportUtil.HostWindows ? Environment.GetEnvironmentVariable("APPDATA") ?? ""
            : ExportUtil.HostMac ? Path.Combine(Home, "Library", "Application Support")
            : Environment.GetEnvironmentVariable("XDG_CONFIG_HOME") is { Length: > 0 } xdg ? xdg : Path.Combine(Home, ".config");
        foreach (string studio in Children(Path.Combine(config, "Google")).Where(path => Path.GetFileName(path).StartsWith("AndroidStudio", StringComparison.Ordinal)).Reverse())
        {
            string file = Path.Combine(studio, "options", "android.sdk.path.xml");
            if (!File.Exists(file))
                continue;
            Match match = Regex.Match(File.ReadAllText(file), "androidSdkAbsolutePath\" value=\"([^\"]+)\"");
            if (match.Success)
                yield return match.Groups[1].Value.Replace("$USER_HOME$", Home);
        }
    }

    static IEnumerable<string> DefaultSdks()
    {
        if (ExportUtil.HostWindows)
        {
            if (Environment.GetEnvironmentVariable("LOCALAPPDATA") is { Length: > 0 } local)
                yield return Path.Combine(local, "Android", "Sdk");
        }
        else if (ExportUtil.HostMac)
            yield return Path.Combine(Home, "Library", "Android", "sdk");
        else
            yield return Path.Combine(Home, "Android", "Sdk");
    }

    /// <summary>Android Studio, its SDK, its Java and the SDK's newest NDK, wherever they are found.</summary>
    public static AndroidTools Find()
    {
        var saved = Saved();
        string? savedStudio = saved.Get("studio") is { Length: > 0 } s ? s : null;
        string? savedSdk = saved.Get("sdk") is { Length: > 0 } k ? k : null;

        // A Studio folder chosen by hand may be the SDK instead; either is taken.
        if (IsSdk(savedStudio))
        {
            savedSdk ??= savedStudio;
            savedStudio = null;
        }
        string? studio = new[] { savedStudio, Environment.GetEnvironmentVariable("TALLOW_ANDROID_STUDIO") }
            .Concat(StudioFolders()).FirstOrDefault(folder => JavaIn(folder) != null);
        string? sdk = new[] { savedSdk, Environment.GetEnvironmentVariable("TALLOW_ANDROID_SDK"), Environment.GetEnvironmentVariable("ANDROID_HOME"),
            Environment.GetEnvironmentVariable("ANDROID_SDK_ROOT") }.Concat(StudioSettingsSdks()).Concat(DefaultSdks()).FirstOrDefault(IsSdk);
        // Android Studio's own Java first (the one its tools are made for), else JAVA_HOME.
        string? java = JavaIn(studio) ?? JavaIn(Environment.GetEnvironmentVariable("JAVA_HOME"));

        string? buildTools = null, platformJar = null, ndk = null;
        int api = 0;
        if (sdk != null)
        {
            string aapt2 = ExportUtil.HostWindows ? "aapt2.exe" : "aapt2";
            buildTools = Children(Path.Combine(sdk, "build-tools")).Where(folder => File.Exists(Path.Combine(folder, aapt2)) &&
                File.Exists(Path.Combine(folder, "lib", "apksigner.jar"))).OrderBy(folder => Version(Path.GetFileName(folder))).LastOrDefault();
            foreach (string folder in Children(Path.Combine(sdk, "platforms")))
            {
                Match match = Regex.Match(Path.GetFileName(folder), @"^android-(\d+)");
                if (match.Success && File.Exists(Path.Combine(folder, "android.jar")) && int.Parse(match.Groups[1].Value) > api)
                {
                    api = int.Parse(match.Groups[1].Value);
                    platformJar = Path.Combine(folder, "android.jar");
                }
            }
            ndk = Children(Path.Combine(sdk, "ndk")).Where(folder => File.Exists(Path.Combine(folder, "source.properties")) && Clang(folder, Abis[0]) != null)
                .OrderBy(folder => Version(Path.GetFileName(folder))).LastOrDefault();
            if (ndk == null && Path.Combine(sdk, "ndk-bundle") is var bundle && Clang(bundle, Abis[0]) != null)
                ndk = bundle;
        }
        if (Environment.GetEnvironmentVariable("ANDROID_NDK_HOME") is { Length: > 0 } fromEnvironment && Clang(fromEnvironment, Abis[0]) != null)
            ndk = fromEnvironment;
        return new AndroidTools(studio, sdk, java, ndk, buildTools, platformJar, api);
    }

    static Version Version(string name)
    {
        Match match = Regex.Match(name, @"^(\d+)(?:\.(\d+))?(?:\.(\d+))?");
        return match.Success ? new Version(int.Parse(match.Groups[1].Value), match.Groups[2].Success ? int.Parse(match.Groups[2].Value) : 0,
            match.Groups[3].Success ? int.Parse(match.Groups[3].Value) : 0) : new Version(0, 0);
    }

    static string NdkBin(string ndk)
    {
        string host = ExportUtil.HostWindows ? "windows-x86_64" : ExportUtil.HostMac ? "darwin-x86_64" : "linux-x86_64";
        return Path.Combine(ndk, "toolchains", "llvm", "prebuilt", host, "bin");
    }

    /// <summary>The NDK's compiler driver for an ABI at <see cref="MinApi"/> (aarch64-linux-android29-clang).</summary>
    static string? Clang(string ndk, string abi)
    {
        string name = $"{Triple(abi)}{MinApi}-clang" + (ExportUtil.HostWindows ? ".cmd" : "");
        string path = Path.Combine(NdkBin(ndk), name);
        return File.Exists(path) ? path : null;
    }

    static string Tool(string folder, string name) => Path.Combine(folder, name + (ExportUtil.HostWindows ? ".exe" : ""));

    // ---- Commands ----

    public static int Status(string[] args)
    {
        var tools = Find();
        Console.WriteLine($"studio = {tools.Studio}");
        Console.WriteLine($"sdk = {tools.Sdk}");
        Console.WriteLine($"java = {tools.Java}");
        Console.WriteLine($"ndk = {tools.Ndk}");
        Console.WriteLine($"buildTools = {tools.BuildTools}");
        Console.WriteLine($"platform = {(tools.Api > 0 ? tools.Api.ToString() : "")}");
        Console.WriteLine($"ndkLicence = {(tools.Sdk != null && LicenceAccepted(tools.Sdk) ? 1 : 0)}");
        Console.WriteLine($"ready = {(tools.Complete ? 1 : 0)}");
        Console.WriteLine($"message = {Problem(tools) ?? ""}");
        return 0;
    }

    /// <summary>What is missing, in a sentence for the Build window; null when an Android game can be made (an NDK
    /// that is missing is installed by the export).</summary>
    public static string? Problem(AndroidTools tools)
    {
        if (tools.Sdk == null && tools.Java == null)
            return "Android Studio was not found. " + StudioHelp;
        if (tools.Sdk == null)
            return "Android Studio's SDK was not found: open Android Studio once so it installs it, or choose the SDK folder in the Build window.";
        if (tools.Java == null)
            return "Android Studio itself (its Java) was not found: install Android Studio, or choose its folder in the Build window.";
        if (tools.BuildTools == null || tools.PlatformJar == null)
            return $"The Android SDK in {tools.Sdk} has no build tools or platform: open Android Studio's SDK Manager and install the latest " +
                "\"Android SDK Build-Tools\" and an Android platform.";
        if (tools.Ndk == null && !LicenceAccepted(tools.Sdk))
            return "Accept the Android SDK licence in Android Studio (SDK Manager) first: Tallow then installs the NDK it needs into the SDK.";
        return null;
    }

    public static int Set(string[] args)
    {
        var saved = Saved();
        for (int i = 0; i + 1 < args.Length; i += 2)
        {
            switch (args[i])
            {
                case "--studio": saved["studio"] = args[i + 1].Trim(); break;
                case "--sdk": saved["sdk"] = args[i + 1].Trim(); break;
                default:
                    Console.Error.WriteLine("usage: android-set [--studio <folder>] [--sdk <folder>]");
                    return 2;
            }
        }
        Directory.CreateDirectory(DataFolder());
        File.WriteAllText(SettingsFile, string.Concat(saved.Where(entry => entry.Value.Length > 0).Select(entry => $"{entry.Key} = {entry.Value}\n")));
        return Status(Array.Empty<string>());
    }

    public static int InstallNdkCommand(string[] args)
    {
        try
        {
            var tools = Find();
            if (tools.Sdk == null)
                throw new ExportException("Android Studio's SDK was not found. " + StudioHelp);
            Console.WriteLine($"NDK installed: {InstallNdk(tools.Sdk)}");
            return 0;
        }
        catch (ExportException exception)
        {
            Console.Error.WriteLine(exception.Message);
            return 1;
        }
    }

    /// <summary><c>android-run &lt;build folder or apk&gt;</c>: installs a built game on the phone or emulator that adb
    /// sees (USB debugging on, or Android Studio's emulator running) and starts it.</summary>
    public static int RunOnDevice(string[] args)
    {
        try
        {
            if (args.Length != 1)
                throw new ExportException("usage: android-run <build folder or .apk>", true);
            string path = Path.GetFullPath(args[0]);
            string folder = Directory.Exists(path) ? path : Path.GetDirectoryName(path)!;
            string apk = Directory.Exists(path) ? Directory.EnumerateFiles(path, "*.apk").FirstOrDefault() ?? "" : path;
            if (!File.Exists(apk))
                throw new ExportException($"No .apk in {path}: build the game for Android first.");
            string info = Path.Combine(folder, "tallow-android.txt");
            string package = File.Exists(info) ? ExportUtil.ReadSettings(info).Get("package") : "";
            var tools = Find();
            if (tools.Sdk == null)
                throw new ExportException("Android Studio's SDK was not found. " + StudioHelp);
            string adb = Tool(Path.Combine(tools.Sdk, "platform-tools"), "adb");
            if (!File.Exists(adb))
                throw new ExportException("The Android SDK has no platform tools (adb): install \"Android SDK Platform-Tools\" in Android Studio's SDK Manager.");
            var devices = ExportUtil.Run(adb, new[] { "devices" }, true).Output.Split('\n').Skip(1)
                .Where(line => line.TrimEnd().EndsWith("\tdevice", StringComparison.Ordinal)).ToList();
            if (devices.Count == 0)
                throw new ExportException("No Android device found: connect a phone with USB debugging on, or start an emulator in Android Studio (Device Manager).");
            Console.WriteLine($"Installing {Path.GetFileName(apk)}...");
            Check(ExportUtil.Run(adb, new[] { "install", "-r", apk }, true), "adb install");
            if (package.Length > 0)
                Check(ExportUtil.Run(adb, new[] { "shell", "am", "start", "-n", $"{package}/org.tallowengine.player.TallowActivity" }, true), "adb shell am start");
            Console.WriteLine($"Started on {devices[0].Split('\t')[0]}.");
            return 0;
        }
        catch (ExportException exception)
        {
            Console.Error.WriteLine(exception.Message);
            return exception.Usage ? 2 : 1;
        }
    }

    /// <summary>Whether the Android SDK licence was accepted (Android Studio writes licenses/android-sdk-license then):
    /// the NDK comes under the same licence.</summary>
    static bool LicenceAccepted(string sdk) => File.Exists(Path.Combine(sdk, "licenses", "android-sdk-license"));

    /// <summary>Installs <see cref="NdkVersion"/> into sdk/ndk/&lt;version&gt;, as Android Studio's SDK Manager would:
    /// Google's archive for this system, checked against its SHA-1. Returns the NDK's folder.</summary>
    public static string InstallNdk(string sdk)
    {
        string target = Path.Combine(sdk, "ndk", NdkVersion);
        if (Clang(target, Abis[0]) != null)
            return target;
        if (!LicenceAccepted(sdk))
            throw new ExportException("Accept the Android SDK licence in Android Studio (SDK Manager) first: Tallow then installs the NDK.");
        string host = ExportUtil.HostWindows ? "windows" : ExportUtil.HostMac ? "macosx" : "linux";
        var (_, archive, sha1, size) = NdkArchives.First(entry => entry.Host == host);
        string cache = Path.Combine(ExportUtil.CacheFolder(), "android");
        Directory.CreateDirectory(cache);
        string zip = Path.Combine(cache, archive);
        if (!File.Exists(zip) || Sha1(zip) != sha1)
        {
            Console.WriteLine($"Downloading Android's NDK r30 ({size / (1024 * 1024)} MB, once) into {target}...");
            string partial = zip + ".part";
            using (var http = new HttpClient { Timeout = TimeSpan.FromHours(2) })
            using (var response = http.GetAsync("https://dl.google.com/android/repository/" + archive, HttpCompletionOption.ResponseHeadersRead).GetAwaiter().GetResult())
            {
                if (!response.IsSuccessStatusCode)
                    throw new ExportException($"Could not download the Android NDK ({(int)response.StatusCode}).");
                using var input = response.Content.ReadAsStream();
                using var output = File.Create(partial);
                var buffer = new byte[1 << 20];
                long done = 0, shown = 0;
                int got;
                while ((got = input.Read(buffer)) > 0)
                {
                    output.Write(buffer, 0, got);
                    done += got;
                    if (done - shown >= 50L << 20)
                    {
                        Console.WriteLine($"  {done * 100 / size}% ({done / (1024 * 1024)} MB)");
                        shown = done;
                    }
                }
            }
            if (Sha1(partial) != sha1)
            {
                File.Delete(partial);
                throw new ExportException("The Android NDK download was damaged (its SHA-1 did not match); build again to retry.");
            }
            File.Move(partial, zip, true);
        }
        Console.WriteLine("Unpacking the NDK...");
        string unpack = Path.Combine(sdk, "ndk", $".{NdkVersion}-unpacking");
        if (Directory.Exists(unpack))
            Directory.Delete(unpack, true);
        Directory.CreateDirectory(unpack);
        Unzip(zip, unpack);
        // The archive holds one folder (android-ndk-r30): its contents are the NDK.
        string inner = Directory.EnumerateDirectories(unpack).Single();
        if (Directory.Exists(target))
            Directory.Delete(target, true);
        Directory.Move(inner, target);
        Directory.Delete(unpack, true);
        File.Delete(zip);
        if (Clang(target, Abis[0]) == null)
            throw new ExportException($"The NDK in {target} is incomplete.");
        return target;
    }

    static string Sha1(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexStringLower(SHA1.HashData(stream));
    }

    /// <summary>Unpacks a zip with its Unix permissions and symbolic links (the NDK's tools have both; .NET's own
    /// extraction writes a link as a file holding its target).</summary>
    static void Unzip(string zip, string folder)
    {
        using ZipArchive archive = ZipFile.OpenRead(zip);
        string root = Path.GetFullPath(folder) + Path.DirectorySeparatorChar;
        foreach (ZipArchiveEntry entry in archive.Entries)
        {
            string path = Path.GetFullPath(Path.Combine(folder, entry.FullName));
            if (!path.StartsWith(root, StringComparison.Ordinal))
                throw new ExportException($"The NDK archive has an entry outside its folder: {entry.FullName}");
            if (entry.FullName.EndsWith('/'))
            {
                Directory.CreateDirectory(path);
                continue;
            }
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            int mode = (entry.ExternalAttributes >> 16) & 0xFFFF;
            if ((mode & 0xF000) == 0xA000 && !ExportUtil.HostWindows)
            {
                using var reader = new StreamReader(entry.Open());
                File.CreateSymbolicLink(path, reader.ReadToEnd());
                continue;
            }
            entry.ExtractToFile(path, true);
            if (!OperatingSystem.IsWindows() && (mode & 0x49) != 0)
                File.SetUnixFileMode(path, (UnixFileMode)(mode & 0x1FF));
        }
    }

    // ---- Exporting ----

    /// <summary>Android Studio's tools for an export, the NDK installed if it is missing; a clear error otherwise.</summary>
    public static AndroidTools Require()
    {
        var tools = Find();
        if (Problem(tools) is { } problem)
            throw new ExportException(problem);
        if (tools.Ndk == null)
        {
            InstallNdk(tools.Sdk!);
            tools = Find();
        }
        if (!tools.Complete)
            throw new ExportException(Problem(tools) ?? "The Android NDK could not be found after installing it.");
        return tools;
    }

    /// <summary>MSBuild properties that make a NativeAOT publish for <see cref="Rid"/> link with the NDK.</summary>
    public static List<string> LinkProperties(AndroidTools tools, string abi) => new()
    {
        // linux-bionic is built from .NET's runtime packs; .NET calls it unsupported, and it works.
        "-p:DisableUnsupportedError=true", "-p:PublishAotUsingRuntimePack=true",
        "-p:CppCompilerAndLinker=" + Clang(tools.Ndk!, abi), "-p:ObjCopyName=" + Tool(NdkBin(tools.Ndk!), "llvm-objcopy"),
    };

    static string PackageName(Dictionary<string, string> settings, string name)
    {
        string chosen = settings.Get("androidPackage");
        if (chosen.Length > 0)
        {
            if (!Regex.IsMatch(chosen, @"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$"))
                throw new ExportException($"androidPackage in project.tallow ({chosen}) is not a valid Android package name (like com.mycompany.mygame).", true);
            return chosen;
        }
        string Part(string text)
        {
            string part = Regex.Replace(text.ToLowerInvariant(), "[^a-z0-9_]", "");
            return part.Length == 0 || !char.IsLetter(part[0]) ? "game" + part : part;
        }
        string company = settings.Get("company");
        return $"com.{(company.Length > 0 ? Part(company) : "tallowgames")}.{Part(name)}";
    }

    static string Manifest(string package, string name, Dictionary<string, string> settings, int targetApi, bool debuggable)
    {
        string versionCode = settings.Get("androidVersionCode", "1");
        if (!int.TryParse(versionCode, out int code) || code < 1)
            throw new ExportException("androidVersionCode in project.tallow is a whole number of 1 or more.", true);
        string versionName = settings.Get("version", "1.0");
        // landscape (either way round, by default), portrait, or any Android screenOrientation value.
        string orientation = settings.Get("androidOrientation", "sensorLandscape") switch
        {
            "landscape" => "sensorLandscape", "portrait" => "sensorPortrait", var other => other
        };
        var permissions = new List<string> { "android.permission.INTERNET", "android.permission.VIBRATE", "android.permission.ACCESS_NETWORK_STATE" };
        if (settings.Get("voiceChat") == "1")
            permissions.Add("android.permission.RECORD_AUDIO");
        string X(string text) => System.Security.SecurityElement.Escape(text)!;
        return $"""
            <?xml version="1.0" encoding="utf-8"?>
            <manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{X(package)}"
                android:versionCode="{code}" android:versionName="{X(versionName)}" android:installLocation="auto">
                <uses-sdk android:minSdkVersion="{MinApi}" android:targetSdkVersion="{targetApi}" />
                <uses-feature android:glEsVersion="0x00030000" android:required="true" />
                <uses-feature android:name="android.hardware.touchscreen" android:required="false" />
                <uses-feature android:name="android.hardware.gamepad" android:required="false" />
                <uses-feature android:name="android.hardware.bluetooth" android:required="false" />
                <uses-feature android:name="android.hardware.usb.host" android:required="false" />
                <uses-feature android:name="android.hardware.type.pc" android:required="false" />
            {string.Concat(permissions.Select(permission => $"    <uses-permission android:name=\"{permission}\" />\n"))}
                <application android:label="{X(name)}" android:icon="@mipmap/ic_launcher" android:allowBackup="true"
                    android:theme="@android:style/Theme.Black.NoTitleBar.Fullscreen" android:hardwareAccelerated="true"
                    android:extractNativeLibs="true" android:isGame="true" android:appCategory="game"{(debuggable ? " android:debuggable=\"true\"" : "")}>
                    <activity android:name="org.tallowengine.player.TallowActivity" android:label="{X(name)}"
                        android:alwaysRetainTaskState="true" android:launchMode="singleInstance" android:screenOrientation="{X(orientation)}"
                        android:configChanges="layoutDirection|locale|grammaticalGender|fontScale|fontWeightAdjustment|orientation|uiMode|screenLayout|screenSize|smallestScreenSize|keyboard|keyboardHidden|navigation"
                        android:preferMinimalPostProcessing="true" android:exported="true">
                        <intent-filter>
                            <action android:name="android.intent.action.MAIN" />
                            <category android:name="android.intent.category.LAUNCHER" />
                        </intent-filter>
                        <intent-filter>
                            <action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED" />
                        </intent-filter>
                    </activity>
                </application>
            </manifest>

            """;
    }

    /// <summary>The engine's precompiled Android player: libmain.so for each ABI and classes.dex.</summary>
    public static string PlayerFolder(string engine)
    {
        string folder = Path.Combine(engine, "Player", "build", "Release_Android");
        var missing = Abis.Select(abi => Path.Combine(folder, abi, "libmain.so")).Append(Path.Combine(folder, "classes.dex")).Where(path => !File.Exists(path)).ToList();
        if (missing.Count > 0)
            throw new ExportException("This engine does not have the Android platform installed. Add it in the Build window " +
                "(Platforms...), or run: Tallow.Build platform-install android. In an engine source checkout, make it with tools/android/build_player.sh.");
        return folder;
    }

    /// <summary>Puts the APK together: the game folder <paramref name="game"/> as assets (unpacked on first start by
    /// the player), the player and the game's NativeAOT library for each ABI, classes.dex, the manifest and icon;
    /// aligned and signed. Returns the APK's path.</summary>
    public static string Package(AndroidTools tools, string engine, string project, string game, Dictionary<string, string> nativeLibraries,
        string output, string name, Dictionary<string, string> settings, string config)
    {
        string player = PlayerFolder(engine);
        string package = PackageName(settings, name);
        int targetApi = Math.Max(MinApi, tools.Api);
        string work = Directory.CreateTempSubdirectory("tallow-android-").FullName;
        try
        {
            // The game's files under assets/game, and the list the player unpacks (its first line names this build).
            string assets = Path.Combine(work, "assets");
            var files = ExportUtil.Files(game).Select(file => file.Relative).Order(StringComparer.Ordinal).ToList();
            ExportUtil.CopyTree(game, Path.Combine(assets, "game"));
            using (var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
            {
                foreach (string relative in files)
                {
                    hash.AppendData(Encoding.UTF8.GetBytes(relative + "\n"));
                    using var stream = File.OpenRead(Path.Combine(game, relative));
                    hash.AppendData(SHA256.HashData(stream));
                }
                string build = Convert.ToHexStringLower(hash.GetHashAndReset())[..16];
                File.WriteAllText(Path.Combine(assets, "tallow-files.txt"), build + "\n" + string.Join("\n", files) + "\n");
            }

            // The launcher icon: the project's (icon in project.tallow), else Tallow's.
            string icon = settings.Get("icon") is { Length: > 0 } chosen && File.Exists(Path.Combine(project, chosen)) ? Path.Combine(project, chosen)
                : Path.Combine(engine, "icon.png");
            string resources = Path.Combine(work, "res", "mipmap");
            Directory.CreateDirectory(resources);
            File.Copy(icon, Path.Combine(resources, "ic_launcher.png"));
            string aapt2 = Tool(tools.BuildTools!, "aapt2");
            string compiled = Path.Combine(work, "compiled");
            Directory.CreateDirectory(compiled);
            Check(ExportUtil.Run(aapt2, new[] { "compile", "-o", compiled, Path.Combine(resources, "ic_launcher.png") }, true), "aapt2 compile");

            string manifest = Path.Combine(work, "AndroidManifest.xml");
            // A Debug build can be inspected (adb shell run-as reads its files and log.txt); Google Play refuses those.
            File.WriteAllText(manifest, Manifest(package, name, settings, targetApi, config == "Debug"));
            string unaligned = Path.Combine(work, "unaligned.apk");
            var link = new List<string> { "link", "-o", unaligned, "-I", tools.PlatformJar!, "--manifest", manifest, "-A", assets,
                "--min-sdk-version", MinApi.ToString(), "--target-sdk-version", targetApi.ToString(), "--auto-add-overlay" };
            link.AddRange(Directory.EnumerateFiles(compiled, "*.flat").Order(StringComparer.Ordinal));
            // The packs are compressed already, and the player streams them out: store them as they are.
            link.AddRange(new[] { "-0", "tpak", "-0", "ogg", "-0", "png", "-0", "ktx" });
            Check(ExportUtil.Run(aapt2, link, true), "aapt2 link");

            using (ZipArchive apk = ZipFile.Open(unaligned, ZipArchiveMode.Update))
            {
                apk.CreateEntryFromFile(Path.Combine(player, "classes.dex"), "classes.dex", CompressionLevel.Optimal);
                foreach (string abi in Abis)
                {
                    apk.CreateEntryFromFile(Path.Combine(player, abi, "libmain.so"), $"lib/{abi}/libmain.so", CompressionLevel.Optimal);
                    apk.CreateEntryFromFile(nativeLibraries[abi], $"lib/{abi}/{NativeAot.LibraryName(Target.Android)}", CompressionLevel.Optimal);
                }
            }

            string aligned = Path.Combine(work, "aligned.apk");
            Check(ExportUtil.Run(Tool(tools.BuildTools!, "zipalign"), new[] { "-f", "-P", "16", "4", unaligned, aligned }, true), "zipalign");

            Directory.CreateDirectory(output);
            string apkPath = Path.Combine(output, name + ".apk");
            Sign(tools, project, settings, config, aligned, apkPath);
            File.WriteAllText(Path.Combine(output, "tallow-android.txt"),
                $"package = {package}\nversionCode = {settings.Get("androidVersionCode", "1")}\nminSdk = {MinApi}\ntargetSdk = {targetApi}\nabis = {string.Join(' ', Abis)}\n");
            Console.WriteLine($"APK: {apkPath} ({new FileInfo(apkPath).Length / (1024 * 1024)} MB, {package}, Android 10 and later)");
            return apkPath;
        }
        finally
        {
            Directory.Delete(work, true);
        }
    }

    static void Check(ExportUtil.Result result, string what)
    {
        if (result.ExitCode != 0)
            throw new ExportException($"{what} failed:\n{result.All.Trim()}");
    }

    /// <summary>Signs with the project's release key (androidKeystore and androidKeyAlias in project.tallow, its
    /// passwords in TALLOW_ANDROID_KEYSTORE_PASSWORD and TALLOW_ANDROID_KEY_PASSWORD), else with Android Studio's debug
    /// key (made if it is not there yet), which installs on any device but is not for Google Play.</summary>
    static void Sign(AndroidTools tools, string project, Dictionary<string, string> settings, string config, string input, string output)
    {
        string java = Path.Combine(tools.Java!, "bin", ExportUtil.HostWindows ? "java.exe" : "java");
        string keystore, alias, storePassword, keyPassword;
        string chosen = settings.Get("androidKeystore");
        if (chosen.Length > 0)
        {
            keystore = Path.IsPathRooted(chosen) ? chosen : Path.Combine(project, chosen);
            if (!File.Exists(keystore))
                throw new ExportException($"The Android keystore {keystore} (androidKeystore in project.tallow) does not exist.");
            alias = settings.Get("androidKeyAlias");
            if (alias.Length == 0 || string.IsNullOrEmpty(Environment.GetEnvironmentVariable("TALLOW_ANDROID_KEYSTORE_PASSWORD")))
                throw new ExportException("Signing with androidKeystore needs androidKeyAlias in project.tallow and the password in TALLOW_ANDROID_KEYSTORE_PASSWORD.");
            // apksigner reads the passwords from the environment, so they never appear on a command line.
            storePassword = "env:TALLOW_ANDROID_KEYSTORE_PASSWORD";
            keyPassword = string.IsNullOrEmpty(Environment.GetEnvironmentVariable("TALLOW_ANDROID_KEY_PASSWORD")) ? storePassword : "env:TALLOW_ANDROID_KEY_PASSWORD";
        }
        else
        {
            keystore = Path.Combine(Environment.GetEnvironmentVariable("ANDROID_USER_HOME") is { Length: > 0 } user ? user : Path.Combine(Home, ".android"), "debug.keystore");
            alias = "androiddebugkey";
            storePassword = keyPassword = "pass:android";
            if (!File.Exists(keystore))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(keystore)!);
                string keytool = Path.Combine(tools.Java!, "bin", ExportUtil.HostWindows ? "keytool.exe" : "keytool");
                Check(ExportUtil.Run(keytool, new[] { "-genkeypair", "-keystore", keystore, "-storepass", "android", "-keypass", "android",
                    "-alias", alias, "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000", "-dname", "CN=Android Debug,O=Android,C=US" }, true), "keytool");
            }
            if (config == "Release")
                Console.WriteLine("note: signed with the Android debug key. For Google Play, set androidKeystore and androidKeyAlias in project.tallow.");
        }
        Check(ExportUtil.Run(java, new[] { "-jar", Path.Combine(tools.BuildTools!, "lib", "apksigner.jar"), "sign", "--ks", keystore,
            "--ks-key-alias", alias, "--ks-pass", storePassword, "--key-pass", keyPassword, "--out", output, input }, true), "apksigner");
        string idsig = output + ".idsig";
        if (File.Exists(idsig))
            File.Delete(idsig);
    }
}
