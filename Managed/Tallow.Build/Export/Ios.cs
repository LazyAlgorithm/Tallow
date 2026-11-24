using System.Text;
using System.Text.RegularExpressions;

namespace Tallow.ManagedBuild.Export;

/// <summary>
/// iOS games (Tallow.Build export --platform ios [--ios-simulator]), on a Mac with Xcode: an app bundle holding the
/// engine's precompiled iOS player (Player/build/Release_iOS/&lt;sdk&gt;/TallowPlayer, made by tools/ios/build_player.sh),
/// the game's C# compiled by NativeAOT into Frameworks/TallowGame.framework (iOS runs no JIT, and loads code only from
/// frameworks signed into the app) and the game's files, which iOS keeps as ordinary files in the bundle.
///
/// --ios-simulator makes an app for the iOS Simulator (this Mac's processor), signed ad hoc. Otherwise the app is for
/// iPhones and iPads (arm64), signed with the identity and provisioning profile in project.tallow (iosSigningIdentity,
/// iosProvisioningProfile) when given, and also packed as &lt;Name&gt;.ipa.
///
/// <code>
///   ios-run &lt;build folder&gt; [--device &lt;name or id&gt;]   installs a Simulator build on a Simulator (booted if needed)
///                                                   and starts it with its console here
/// </code>
/// </summary>
internal static class Ios
{
    /// <summary>The oldest iOS a game runs on.</summary>
    public const string MinimumOs = "15.0";

    public static bool HostArm => System.Runtime.InteropServices.RuntimeInformation.OSArchitecture == System.Runtime.InteropServices.Architecture.Arm64;

    public static string Sdk(bool simulator) => simulator ? "iphonesimulator" : "iphoneos";
    public static string Rid(bool simulator) => simulator ? (HostArm ? "iossimulator-arm64" : "iossimulator-x64") : "ios-arm64";

    /// <summary>Xcode, with the iOS SDK: what an iOS export needs. Null when it is usable, else why not.</summary>
    public static string? Problem(bool simulator)
    {
        if (!ExportUtil.HostMac)
            return "iOS games are built on a Mac with Xcode (Apple's tools for iOS only run there).";
        var sdk = ExportUtil.TryRun("xcrun", new[] { "--sdk", Sdk(simulator), "--show-sdk-path" });
        if (sdk.ExitCode != 0)
            return sdk.All.Contains("license", StringComparison.OrdinalIgnoreCase)
                ? "Accept Xcode's licence first (in Terminal: sudo xcodebuild -license accept)."
                : "Xcode with the iOS SDK was not found: install Xcode from the App Store, open it once, and choose it in Terminal: sudo xcode-select -s /Applications/Xcode.app";
        return null;
    }

    public static string PlayerPath(string engine, bool simulator) =>
        Path.Combine(engine, "Player", "build", "Release_iOS", Sdk(simulator), "TallowPlayer");

    public static string BundleId(Dictionary<string, string> settings, string name)
    {
        string chosen = settings.Get("iosBundleId");
        if (chosen.Length > 0)
        {
            if (!Regex.IsMatch(chosen, @"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"))
                throw new ExportException($"iosBundleId in project.tallow ({chosen}) is not a valid bundle identifier (like com.mycompany.mygame).", true);
            return chosen;
        }
        string Part(string text) => Regex.Replace(text, "[^A-Za-z0-9-]", "-").Trim('-') is { Length: > 0 } part ? part : "game";
        string company = settings.Get("company");
        return $"com.{(company.Length > 0 ? Part(company).ToLowerInvariant() : "tallowgames")}.{Part(name)}";
    }

    /// <summary>MSBuild properties for a NativeAOT build of the game as a shared library for iOS.</summary>
    public static List<string> AotProperties() => new() { "-p:PublishAotUsingRuntimePack=true" };

    static string X(string text) => System.Security.SecurityElement.Escape(text)!;

    static string AppPlist(string executable, string bundleId, string name, Dictionary<string, string> settings, bool simulator, string sdkVersion)
    {
        string versionCode = settings.Get("iosBuildNumber", settings.Get("androidVersionCode", "1"));
        string version = settings.Get("version", "1.0");
        bool portrait = settings.Get("androidOrientation", settings.Get("orientation", "landscape")).StartsWith("portrait", StringComparison.OrdinalIgnoreCase);
        string orientations = portrait
            ? "<string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationPortraitUpsideDown</string>"
            : "<string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string>";
        string platform = simulator ? "iPhoneSimulator" : "iPhoneOS";
        return $"""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleDevelopmentRegion</key><string>en</string>
                <key>CFBundleExecutable</key><string>{X(executable)}</string>
                <key>CFBundleIdentifier</key><string>{X(bundleId)}</string>
                <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
                <key>CFBundleName</key><string>{X(name)}</string>
                <key>CFBundleDisplayName</key><string>{X(settings.Get("displayName", name))}</string>
                <key>CFBundlePackageType</key><string>APPL</string>
                <key>CFBundleShortVersionString</key><string>{X(version)}</string>
                <key>CFBundleVersion</key><string>{X(versionCode)}</string>
                <key>CFBundleSupportedPlatforms</key><array><string>{platform}</string></array>
                <key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><dict>
                    <key>CFBundleIconFiles</key><array><string>AppIcon60x60</string></array>
                    <key>CFBundleIconName</key><string>AppIcon</string>
                </dict></dict>
                <key>CFBundleIcons~ipad</key><dict><key>CFBundlePrimaryIcon</key><dict>
                    <key>CFBundleIconFiles</key><array><string>AppIcon60x60</string><string>AppIcon76x76</string></array>
                    <key>CFBundleIconName</key><string>AppIcon</string>
                </dict></dict>
                <key>DTPlatformName</key><string>{Sdk(simulator)}</string>
                <key>DTSDKName</key><string>{Sdk(simulator)}{X(sdkVersion)}</string>
                <key>LSRequiresIPhoneOS</key><true/>
                <key>MinimumOSVersion</key><string>{MinimumOs}</string>
                <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
                <key>UILaunchScreen</key><dict><key>UIColorName</key><string></string></dict>
                <key>UIRequiresFullScreen</key><true/>
                <key>UIStatusBarHidden</key><true/>
                <key>UIApplicationSupportsIndirectInputEvents</key><true/>
                <key>UISupportedInterfaceOrientations</key><array>{orientations}</array>
                <key>UISupportedInterfaceOrientations~ipad</key><array>{orientations}</array>
                <key>GCSupportsControllerUserInteraction</key><true/>
                <key>GCSupportedGameControllers</key><array><dict><key>ProfileName</key><string>ExtendedGamepad</string></dict></array>
                <key>ITSAppUsesNonExemptEncryption</key><false/>{(settings.Get("voiceChat") == "1" ? "\n    <key>NSMicrophoneUsageDescription</key><string>Voice chat with other players.</string>" : "")}
            </dict>
            </plist>

            """;
    }

    static string FrameworkPlist(string bundleId, bool simulator) => $"""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key><string>TallowGame</string>
            <key>CFBundleIdentifier</key><string>{X(bundleId)}.TallowGame</string>
            <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
            <key>CFBundleName</key><string>TallowGame</string>
            <key>CFBundlePackageType</key><string>FMWK</string>
            <key>CFBundleShortVersionString</key><string>1.0</string>
            <key>CFBundleVersion</key><string>1</string>
            <key>CFBundleSupportedPlatforms</key><array><string>{(simulator ? "iPhoneSimulator" : "iPhoneOS")}</string></array>
            <key>MinimumOSVersion</key><string>{MinimumOs}</string>
        </dict>
        </plist>

        """;

    static void Check(ExportUtil.Result result, string what)
    {
        if (result.ExitCode != 0)
            throw new ExportException($"{what} failed:\n{result.All.Trim()}");
    }

    /// <summary>Puts &lt;Name&gt;.app together from the game folder <paramref name="game"/> and the NativeAOT library, and
    /// signs it. Returns the app's path.</summary>
    public static string Package(string engine, string project, string game, string library, string output, string name,
        Dictionary<string, string> settings, bool simulator)
    {
        string player = PlayerPath(engine, simulator);
        if (!File.Exists(player))
            throw new ExportException($"This engine has no iOS player for the {(simulator ? "Simulator" : "device")} ({player}). " +
                "Engine packages carry it; in an engine source checkout make it on a Mac with tools/ios/build_player.sh.");
        string bundleId = BundleId(settings, name);
        string sdkVersion = ExportUtil.Run("xcrun", new[] { "--sdk", Sdk(simulator), "--show-sdk-version" }, true).Output.Trim();
        Directory.CreateDirectory(output);
        string app = Path.Combine(output, name + ".app");
        if (Directory.Exists(app))
            Directory.Delete(app, true);
        // The game's files are the bundle's own (SDL_GetBasePath is the bundle).
        ExportUtil.CopyTree(game, app);
        File.Copy(player, Path.Combine(app, name), true);
        ExportUtil.MakeExecutable(Path.Combine(app, name));
        File.WriteAllText(Path.Combine(app, "Info.plist"), AppPlist(name, bundleId, name, settings, simulator, sdkVersion));
        File.WriteAllText(Path.Combine(app, "PkgInfo"), "APPL????");

        // The launcher icons, from the project's icon (icon in project.tallow) or Tallow's, sized with sips.
        string icon = settings.Get("icon") is { Length: > 0 } chosen && File.Exists(Path.Combine(project, chosen)) ? Path.Combine(project, chosen)
            : Path.Combine(engine, "icon.png");
        foreach (var (file, size) in new[] { ("AppIcon60x60@2x.png", 120), ("AppIcon60x60@3x.png", 180), ("AppIcon76x76@2x~ipad.png", 152) })
            Check(ExportUtil.Run("sips", new[] { "-z", size.ToString(), size.ToString(), "-s", "format", "png", icon, "--out", Path.Combine(app, file) }, true), "sips");

        // The game's C# as a framework: the library renamed to the framework's executable, with an install name to match.
        string framework = Path.Combine(app, "Frameworks", "TallowGame.framework");
        Directory.CreateDirectory(framework);
        string binary = Path.Combine(framework, "TallowGame");
        File.Copy(library, binary, true);
        Check(ExportUtil.Run("install_name_tool", new[] { "-id", "@rpath/TallowGame.framework/TallowGame", binary }, true), "install_name_tool");
        File.WriteAllText(Path.Combine(framework, "Info.plist"), FrameworkPlist(bundleId, simulator));

        Sign(app, framework, project, settings, simulator);
        File.WriteAllText(Path.Combine(output, "tallow-ios.txt"),
            $"bundleId = {bundleId}\nsdk = {Sdk(simulator)}\nminimumOS = {MinimumOs}\napp = {name}.app\n");
        if (!simulator)
        {
            // An .ipa (Payload/<Name>.app, zipped) for Apple Configurator, Transporter or the Xcode Devices window.
            string ipa = Path.Combine(output, name + ".ipa");
            string payload = Path.Combine(output, "Payload");
            if (Directory.Exists(payload))
                Directory.Delete(payload, true);
            Directory.CreateDirectory(payload);
            Check(ExportUtil.Run("ditto", new[] { app, Path.Combine(payload, name + ".app") }, true), "ditto");
            File.Delete(ipa);
            Check(ExportUtil.Run("ditto", new[] { "-c", "-k", "--keepParent", payload, ipa }, true), "ditto -c");
            Directory.Delete(payload, true);
        }
        Console.WriteLine($"iOS app: {app} ({bundleId}, iOS {MinimumOs} and later, {(simulator ? "Simulator" : "iPhone and iPad")})");
        return app;
    }

    /// <summary>Signs the framework, then the app: ad hoc for the Simulator; for a device with the identity and
    /// provisioning profile in project.tallow, or ad hoc with a note (such an app installs only once it is signed).</summary>
    static void Sign(string app, string framework, string project, Dictionary<string, string> settings, bool simulator)
    {
        string identity = simulator ? "-" : settings.Get("iosSigningIdentity", "-");
        string profile = settings.Get("iosProvisioningProfile");
        var entitlements = new List<string>();
        if (!simulator && profile.Length > 0)
        {
            string path = Path.IsPathRooted(profile) ? profile : Path.Combine(project, profile);
            if (!File.Exists(path))
                throw new ExportException($"The provisioning profile {path} (iosProvisioningProfile in project.tallow) does not exist.");
            File.Copy(path, Path.Combine(app, "embedded.mobileprovision"), true);
            // The profile's entitlements are the app's.
            string decoded = ExportUtil.Run("security", new[] { "cms", "-D", "-i", path }, true).Output;
            Match match = Regex.Match(decoded, @"<key>Entitlements</key>\s*(<dict>.*?</dict>)", RegexOptions.Singleline);
            if (match.Success)
            {
                string file = Path.Combine(Path.GetTempPath(), $"tallow-entitlements-{Environment.ProcessId}.plist");
                File.WriteAllText(file, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n" + match.Groups[1].Value + "\n</plist>\n");
                entitlements.AddRange(new[] { "--entitlements", file });
            }
        }
        Check(ExportUtil.Run("codesign", new[] { "--force", "--sign", identity, "--timestamp=none", framework }, true), "codesign (framework)");
        Check(ExportUtil.Run("codesign", new[] { "--force", "--sign", identity, "--timestamp=none" }.Concat(entitlements).Append(app), true), "codesign (app)");
        if (!simulator && identity == "-")
            Console.WriteLine("note: this iPhone build is signed ad hoc, which a device does not install. Set iosSigningIdentity and " +
                "iosProvisioningProfile in project.tallow (Xcode makes both with your Apple ID), or build with --ios-simulator.");
    }

    /// <summary><c>ios-run &lt;build folder&gt; [--device D]</c>: a Simulator build installed on a Simulator (the given
    /// one, the booted one, or a new iPhone) and started, its console shown here.</summary>
    public static int Run(string[] args)
    {
        try
        {
            if (args.Length == 0)
                throw new ExportException("usage: ios-run <build folder> [--device <name or id>]", true);
            string folder = Path.GetFullPath(args[0]);
            string info = Path.Combine(folder, "tallow-ios.txt");
            if (!File.Exists(info))
                throw new ExportException($"{folder} is not an iOS build (no tallow-ios.txt).");
            var settings = ExportUtil.ReadSettings(info);
            if (settings.Get("sdk") != "iphonesimulator")
                throw new ExportException("ios-run starts Simulator builds (export with --ios-simulator); install device builds from Xcode's Devices window.");
            string app = Path.Combine(folder, settings.Get("app"));
            int at = Array.IndexOf(args, "--device");
            string device = at >= 0 && at + 1 < args.Length ? args[at + 1] : "";
            if (device.Length == 0)
            {
                string list = ExportUtil.Run("xcrun", new[] { "simctl", "list", "devices", "available" }, true).Output;
                Match booted = Regex.Match(list, @"^\s+(.+?) \(([0-9A-F-]{36})\) \(Booted\)", RegexOptions.Multiline);
                Match iphone = Regex.Match(list, @"^\s+(iPhone[^(]*?) \(([0-9A-F-]{36})\)", RegexOptions.Multiline);
                if (booted.Success)
                    device = booted.Groups[2].Value;
                else if (iphone.Success)
                    device = iphone.Groups[2].Value;
                else
                    throw new ExportException("No iOS Simulator is installed: run xcodebuild -downloadPlatform iOS (or add one in Xcode > Settings > Components).");
            }
            ExportUtil.TryRun("xcrun", new[] { "simctl", "boot", device });
            ExportUtil.TryRun("open", new[] { "-a", "Simulator" });
            Check(ExportUtil.Run("xcrun", new[] { "simctl", "install", device, app }, true), "simctl install");
            Console.WriteLine($"Starting {settings.Get("bundleId")} on {device}...");
            return ExportUtil.Run("xcrun", new[] { "simctl", "launch", "--console-pty", "--terminate-running-process", device, settings.Get("bundleId") }).ExitCode;
        }
        catch (ExportException exception)
        {
            Console.Error.WriteLine(exception.Message);
            return exception.Usage ? 2 : 1;
        }
    }
}
