using System.Numerics;

namespace Tallow;

/// <summary>
/// The scene's Day / Night clock: the time of day, how fast it runs, where the sun and moon are, and the moments the
/// clock crosses sunrise, sunset and each whole hour. It works on the scene being played, like a script's
/// <see cref="Script.Scene"/>. In a network session the server owns the clock (unless the scene's Network Mode is
/// Offline): every machine works the time out from the server's tick, changes made here on a client are ignored with
/// one warning, and the events fire on the same tick on every machine.
/// </summary>
/// <remarks>
/// The clock only runs while playing, and only when <see cref="Enabled"/> is on. The sky is drawn up to a tick ahead
/// of <see cref="TimeOfDay"/> (it eases between ticks), so a script that draws something at the sun's position should
/// use <see cref="SunDirection"/>, which is where it is drawn.
/// </remarks>
public static class DayNight
{
    private static Action? sOnSunrise;
    private static Action? sOnSunset;
    private static Action<int>? sOnHour;

    private static bool AnyHandler => sOnSunrise != null || sOnSunset != null || sOnHour != null;

    /// <summary>Whether the clock turns the sun and moon at all (the scene's Day / Night setting).</summary>
    public static bool Enabled
    {
        get => Float(0) != 0;
        set => Set(0, value ? 1 : 0);
    }

    /// <summary>The time of day on the shared clock, in hours: 0 to 24, 12 being noon. On a network it follows the
    /// server's tick as this machine knows it, so every machine is on the same time (a client that joined late is on
    /// the server's time at once) and the sky matches it.</summary>
    public static float TimeOfDay
    {
        get => Float(1);
        set => Set(1, value);
    }

    /// <summary>How many real minutes a whole 24-hour day takes while playing. 0 stops the clock.</summary>
    public static float DayLengthMinutes
    {
        get => Float(2);
        set => Set(2, value);
    }

    /// <summary>The same as <see cref="DayLengthMinutes"/>: how long a whole day takes, in real minutes.</summary>
    public static float DayLength
    {
        get => DayLengthMinutes;
        set => DayLengthMinutes = value;
    }

    /// <summary>How fast the clock runs now, in hours a second: 0 when Day / Night is off, paused or the day's
    /// length is 0. Read-only: set <see cref="DayLengthMinutes"/> or <see cref="Paused"/>.</summary>
    public static float Speed => Float(3);

    /// <summary>Whether the clock is stopped where it is (the sun stays where the time puts it). In Edit mode the
    /// clock never runs.</summary>
    public static bool Paused
    {
        get => Float(4) != 0;
        set => Set(4, value ? 1 : 0);
    }

    /// <summary>How far north (+) or south (-) of the equator the scene is, in degrees: how high the sun climbs.</summary>
    public static float Latitude
    {
        get => Float(5);
        set => Set(5, value);
    }

    /// <summary>The planet's axis tilt in degrees (Earth: 23.44): how much the sun's path changes over the year.</summary>
    public static float AxisTilt
    {
        get => Float(6);
        set => Set(6, value);
    }

    /// <summary>Which way north is, in degrees round from +Z, clockwise seen from above.</summary>
    public static float NorthDirection
    {
        get => Float(7);
        set => Set(7, value);
    }

    /// <summary>The day of the year, 1 to 365 (172 is the June solstice, the longest day in the north).</summary>
    public static int DayOfYear
    {
        get => (int)Float(8);
        set => Set(8, value);
    }

    /// <summary>Whether it is night: the sun more than 6 degrees below the horizon (civil twilight over).</summary>
    public static bool IsNight => Float(9) != 0;

    /// <summary>The direction towards the sun as the scene is drawn, from the middle of the world outwards
    /// (normalized). Below the horizon its Y is negative.</summary>
    public static Vector3 SunDirection => Vector(10);

    /// <summary>The sun light's colour now: white high in the sky, orange then red near the horizon, dark after
    /// sunset (the clock sets the sun light to the same colour).</summary>
    public static Color SunColor => Colour(11);

    /// <summary>How bright the sun light is now: <see cref="SceneEnvironment.SunIntensity"/> times what gets through
    /// the air, about 0 after sunset. Read-only.</summary>
    public static float SunIntensity => Float(12);

    /// <summary>The direction towards the moon (normalized); below the horizon its Y is negative.</summary>
    public static Vector3 MoonDirection => Vector(13);

    /// <summary>The moon's age through its cycle, 0 (new) to 1 (new again): about 0.5 is full.</summary>
    public static float MoonPhase => Float(14);

    /// <summary>How much of the moon is lit, 0 (new) to 1 (full).</summary>
    public static float MoonIllumination => Float(15);

    /// <summary>The session tick the event being raised happened on: the tick the shared clock reached the crossing,
    /// the same number on the server and every client. Offline it is the simulation tick it was seen on.</summary>
    public static long LastEventTick { get; private set; }

    /// <summary>Raised once a frame (after LateUpdate) when the clock reaches sunrise: the sun crossing the horizon
    /// upwards. Every machine raises it on the same tick (<see cref="LastEventTick"/>).</summary>
    public static event Action OnSunrise
    {
        add
        {
            Hook();
            sOnSunrise += value;
        }
        remove
        {
            sOnSunrise -= value;
            UnhookIfIdle();
        }
    }

    /// <summary>Raised once a frame (after LateUpdate) when the clock reaches sunset: the sun crossing the horizon
    /// downwards. Every machine raises it on the same tick.</summary>
    public static event Action OnSunset
    {
        add
        {
            Hook();
            sOnSunset += value;
        }
        remove
        {
            sOnSunset -= value;
            UnhookIfIdle();
        }
    }

    /// <summary>Raised once a frame (after LateUpdate) when the clock reaches each whole hour, with that hour (0 to
    /// 23). Every machine raises it on the same tick.</summary>
    public static event Action<int> OnHour
    {
        add
        {
            Hook();
            sOnHour += value;
        }
        remove
        {
            sOnHour -= value;
            UnhookIfIdle();
        }
    }

    /// <summary>A game is unloading: drop its handlers, so nothing keeps its assembly alive.</summary>
    internal static void ClearHandlers()
    {
        GameThread.EachFrame -= Raise;
        sOnSunrise = null;
        sOnSunset = null;
        sOnHour = null;
    }

    private static void Hook()
    {
        // Nothing wanted the old events (the clock crossed them before there was a handler): forget them.
        if (!AnyHandler)
            while (CSharpDayNight.TakeEvent() >= 0) { }
        // Hooked again each time: a game that stopped dropped the hook (GameThread.Stop).
        GameThread.EachFrame -= Raise;
        GameThread.EachFrame += Raise;
    }

    private static void UnhookIfIdle()
    {
        if (!AnyHandler)
            GameThread.EachFrame -= Raise;
    }

    private static void Raise()
    {
        for (long packed; (packed = CSharpDayNight.TakeEvent()) >= 0;)
        {
            LastEventTick = (uint)packed;
            switch ((int)((packed >> 32) & 3))
            {
                case 0: sOnSunrise?.Invoke(); break;
                case 1: sOnSunset?.Invoke(); break;
                default: sOnHour?.Invoke((int)((packed >> 34) & 31)); break;
            }
        }
    }

    private static float Float(int which)
    {
        Span<float> values = stackalloc float[4];
        return CSharpDayNight.Get(which, values) ? values[0] : 0f;
    }

    private static Vector3 Vector(int which)
    {
        Span<float> values = stackalloc float[4];
        return CSharpDayNight.Get(which, values) ? new Vector3(values[0], values[1], values[2]) : default;
    }

    private static Color Colour(int which)
    {
        Span<float> values = stackalloc float[4];
        return CSharpDayNight.Get(which, values) ? new Color(values[0], values[1], values[2], values[3]) : default;
    }

    private static void Set(int which, float value)
    {
        if (!CSharpDayNight.Set(which, value))
            throw new InvalidOperationException("Day / Night cannot be changed (no scene being played, or a value that is not finite).");
    }
}
