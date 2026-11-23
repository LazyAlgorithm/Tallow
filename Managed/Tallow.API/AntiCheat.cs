namespace Tallow;

/// <summary>A kind of cheating the anti-cheat looks for (tallowengine.com/docs/anti-cheat).</summary>
public enum CheatKind
{
    /// <summary>Controls no honest game sends: an impossible view angle.</summary>
    InvalidInput,
    /// <summary>The player's game is running faster than the server's.</summary>
    SpeedHack,
    /// <summary>Far more messages than a game sends.</summary>
    MessageFlood,
    /// <summary>The player's game files are not the server's.</summary>
    ModifiedFiles,
    /// <summary>The player's game does not answer the anti-cheat's questions.</summary>
    NoResponse,
    /// <summary>A debugger is attached to the player's game.</summary>
    Debugger,
    /// <summary>A library has been forced into the player's game.</summary>
    InjectedCode,
    /// <summary>The clock the player's game runs on is being stretched.</summary>
    ClockTampering,
    /// <summary>A guarded value was changed from outside the game (a memory editor).</summary>
    MemoryTampering,
    /// <summary>Aim no hand produces, over many shots.</summary>
    SuspiciousAim,
}

/// <summary>What is done about a kind of cheating.</summary>
public enum CheatAction
{
    /// <summary>Not looked for.</summary>
    Ignore,
    /// <summary>Written to the log, kept in Violations and raised as OnViolation.</summary>
    Log,
    /// <summary>The same, and the player is told why and removed from the session.</summary>
    Kick,
}

/// <summary>One thing the anti-cheat found: the player (their client id), the kind, what was seen, and the game
/// time it was found at.</summary>
public readonly record struct CheatViolation(int ClientId, CheatKind Kind, string Detail, float Time);

/// <summary>
/// The anti-cheat: watches network sessions for cheating once it is on (Project Settings > Anti-Cheat, or
/// <see cref="Enabled"/>), with no further code. The server-side checks are the part that holds; read
/// tallowengine.com/docs/anti-cheat for what it can and cannot see.
/// </summary>
public static class AntiCheat
{
    private static Action<CheatViolation>? sOnViolation;
    private static long sSeen;

    /// <summary>The master switch. Off, nothing is checked, asked or sent.</summary>
    public static bool Enabled
    {
        get => CSharpAntiCheat.GetEnabled();
        set => CSharpAntiCheat.SetEnabled(value);
    }

    /// <summary>Sets what is done about a kind. By default a player is removed for what only a changed game does,
    /// and what honest players can also trip (a debugger, a preloaded library, an odd clock, remarkable aim) is
    /// only logged.</summary>
    public static void SetAction(CheatKind kind, CheatAction action) => CSharpAntiCheat.SetAction((int)kind, (int)action);

    /// <summary>What is done about a kind now.</summary>
    public static CheatAction GetAction(CheatKind kind) => (CheatAction)CSharpAntiCheat.GetAction((int)kind);

    /// <summary>Server: reports something the game caught itself (a shot through a wall, a purchase with no money),
    /// handled like the anti-cheat's own findings, by the action set for its kind.</summary>
    public static void Report(Scene scene, int clientId, CheatKind kind, string detail) =>
        CSharpAntiCheat.Report(scene.SessionId, clientId, (int)kind, detail ?? "");

    /// <summary>Server: a player fired. With <see cref="ReportHit"/> this lets the anti-cheat judge their aim.</summary>
    public static void ReportShot(Scene scene, int clientId) => CSharpAntiCheat.ReportShot(scene.SessionId, clientId);

    /// <summary>Server: a player's shot hit another player.</summary>
    public static void ReportHit(Scene scene, int clientId, bool headshot) => CSharpAntiCheat.ReportHit(scene.SessionId, clientId, headshot);

    /// <summary>The numbers behind the aim check for one player: shots, hits, head shots, and hits straight after
    /// an instant turn.</summary>
    public static (int Shots, int Hits, int Headshots, int SnapHits) AimStats(Scene scene, int clientId) => (
        CSharpAntiCheat.AimStat(scene.SessionId, clientId, 0), CSharpAntiCheat.AimStat(scene.SessionId, clientId, 1),
        CSharpAntiCheat.AimStat(scene.SessionId, clientId, 2), CSharpAntiCheat.AimStat(scene.SessionId, clientId, 3));

    /// <summary>The last things found on this machine as a server, oldest first (at most 256 are kept).</summary>
    public static CheatViolation[] Violations
    {
        get
        {
            var all = new CheatViolation[CSharpAntiCheat.ViolationCount()];
            for (int i = 0; i < all.Length; i++)
                all[i] = Violation(i);
            return all;
        }
    }

    private static CheatViolation Violation(int index)
    {
        long packed = CSharpAntiCheat.ViolationAt(index);
        string detail = ActionText.Read(buffer => CSharpAntiCheat.ViolationDetail(index, buffer)) ?? "";
        return new CheatViolation((int)(uint)packed, (CheatKind)(int)(packed >> 32), detail, CSharpAntiCheat.ViolationTime(index));
    }

    /// <summary>Server: raised once a frame (after LateUpdate) for each thing found since the last frame, unless its
    /// action is Ignore: show it, keep it, or ban the player.</summary>
    public static event Action<CheatViolation> OnViolation
    {
        add
        {
            if (sOnViolation == null)
                sSeen = CSharpAntiCheat.ViolationTotal();
            // Hooked again each time: a game that stopped dropped the hook (GameThread.Stop).
            GameThread.EachFrame -= RaiseNew;
            GameThread.EachFrame += RaiseNew;
            sOnViolation += value;
        }
        remove
        {
            sOnViolation -= value;
            if (sOnViolation == null)
                GameThread.EachFrame -= RaiseNew;
        }
    }

    internal static void ClearHandlers()
    {
        GameThread.EachFrame -= RaiseNew;
        sOnViolation = null;
    }

    private static void RaiseNew()
    {
        long total = CSharpAntiCheat.ViolationTotal();
        if (total == sSeen)
            return;
        int kept = CSharpAntiCheat.ViolationCount();
        int fresh = (int)Math.Min(total - sSeen, kept);
        sSeen = total;
        for (int i = kept - fresh; i < kept; i++)
            sOnViolation?.Invoke(Violation(i));
    }

    /// <summary>On a player's machine: why the server's anti-cheat removed it, or empty. Show it instead of
    /// "connection lost".</summary>
    public static string KickReason => ActionText.Read(CSharpAntiCheat.KickReason) ?? "";

    /// <summary>Bans whatever the game knows a player by (a Steam ID, an account name, an address).</summary>
    public static void Ban(string key) => CSharpAntiCheat.Ban(key ?? "");
    /// <summary>Lifts a ban.</summary>
    public static void Unban(string key) => CSharpAntiCheat.Unban(key ?? "");
    /// <summary>Whether a key is banned: ask when someone joins, and <see cref="Network.Kick"/> them.</summary>
    public static bool IsBanned(string key) => CSharpAntiCheat.IsBanned(key ?? "");
    /// <summary>The ban list as text, to keep in a file.</summary>
    public static string BansToText() => ActionText.Read(CSharpAntiCheat.BansToText) ?? "";
    /// <summary>Adds the bans in text written by BansToText.</summary>
    public static void BansFromText(string text) => CSharpAntiCheat.BansFromText(text ?? "");

    internal static void ReportLocal(CheatKind kind, string detail) => CSharpAntiCheat.ReportLocal((int)kind, detail);
}

/// <summary>
/// A whole number kept scrambled, with a check beside it, for numbers a player's machine is trusted with (a
/// single-player game, or where the server does not decide them). A memory editor does not find it by searching for
/// its value, and a write from outside is noticed: the anti-cheat is told and the real value comes back.
/// </summary>
public struct GuardedInt
{
    private static uint sKeySource = 0x6B8B4567;
    private int _scrambled, _check, _key;

    /// <summary>Guards a value.</summary>
    public GuardedInt(int value)
    {
        sKeySource = unchecked(sKeySource * 1103515245 + 12345);
        _key = (int)sKeySource | 0x10001;
        _scrambled = value ^ _key;
        _check = unchecked(~(value * 31 + _key));
    }

    /// <summary>The number. Reading one that was changed from outside reports it and gives the real value.</summary>
    public int Value
    {
        readonly get
        {
            if (_key == 0)
                return 0;
            int value = _scrambled ^ _key;
            if (_check != unchecked(~(value * 31 + _key)))
            {
                AntiCheat.ReportLocal(CheatKind.MemoryTampering, "a guarded number was changed");
                return unchecked((~_check - _key) / 31);
            }
            return value;
        }
        set => this = new GuardedInt(value);
    }

    /// <summary>Whether the stored number still matches its check, without reporting anything.</summary>
    public readonly bool Intact => _key == 0 || _check == unchecked(~((_scrambled ^ _key) * 31 + _key));

    /// <summary>The number.</summary>
    public static implicit operator int(GuardedInt guarded) => guarded.Value;
    /// <summary>Guards a number.</summary>
    public static implicit operator GuardedInt(int value) => new(value);
    /// <summary>Adds to it.</summary>
    public static GuardedInt operator +(GuardedInt a, int b) => new(a.Value + b);
    /// <summary>Takes from it.</summary>
    public static GuardedInt operator -(GuardedInt a, int b) => new(a.Value - b);
    /// <inheritdoc/>
    public override readonly string ToString() => Value.ToString();
}

/// <summary>A <see cref="GuardedInt"/> for a number with a fraction.</summary>
public struct GuardedFloat
{
    private GuardedInt _bits;

    /// <summary>Guards a value.</summary>
    public GuardedFloat(float value) => _bits = new GuardedInt(BitConverter.SingleToInt32Bits(value));

    /// <summary>The number. Reading one that was changed from outside reports it and gives the real value.</summary>
    public float Value
    {
        readonly get => BitConverter.Int32BitsToSingle(_bits.Value);
        set => _bits = new GuardedInt(BitConverter.SingleToInt32Bits(value));
    }

    /// <summary>Whether the stored number still matches its check, without reporting anything.</summary>
    public readonly bool Intact => _bits.Intact;

    /// <summary>The number.</summary>
    public static implicit operator float(GuardedFloat guarded) => guarded.Value;
    /// <summary>Guards a number.</summary>
    public static implicit operator GuardedFloat(float value) => new(value);
    /// <summary>Adds to it.</summary>
    public static GuardedFloat operator +(GuardedFloat a, float b) => new(a.Value + b);
    /// <summary>Takes from it.</summary>
    public static GuardedFloat operator -(GuardedFloat a, float b) => new(a.Value - b);
    /// <inheritdoc/>
    public override readonly string ToString() => Value.ToString(System.Globalization.CultureInfo.InvariantCulture);
}
