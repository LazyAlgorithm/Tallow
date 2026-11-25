using System;

namespace Tallow;

/// One Earth atmosphere (tallowengine.com/docs/day-night), used for the sun and moon light colours and, with Auto
/// Colours on, the ambient and fog colours. Values per metre from Hillaire 2020 (Bevy's Earth defaults): Rayleigh,
/// Mie and ozone. The sky shaders (D1d) use the same numbers. Everything here is linear RGB; doubles on the CPU.
static class Atmosphere
{
	public const double PlanetRadius = 6360000;
	public const double TopRadius = 6460000;
	public const double ViewerAltitude = 200;
	public const double GroundAlbedo = 0.3;
	const double RayleighR = 5.802e-6, RayleighG = 13.558e-6, RayleighB = 33.1e-6;
	const double RayleighHeight = 8000;
	const double MieScattering = 3.996e-6, MieAbsorption = 4.40e-6, MieHeight = 1200, MieG = 0.8;
	const double OzoneR = 0.650e-6, OzoneG = 1.881e-6, OzoneB = 0.085e-6;
	/// Multiple scattering, approximated as a constant on top of single scattering.
	const double MultipleScattering = 1.25;

	/// A linear RGB triple in doubles.
	public struct Rgb
	{
		public double r, g, b;
		public this(double r, double g, double b) { this.r = r; this.g = g; this.b = b; }
		public double Max => Math.Max(r, Math.Max(g, b));
		public double Luminance => 0.2126 * r + 0.7152 * g + 0.0722 * b;
		public static Rgb operator+(Rgb a, Rgb b) => .(a.r + b.r, a.g + b.g, a.b + b.b);
		public static Rgb operator*(Rgb a, Rgb b) => .(a.r * b.r, a.g * b.g, a.b * b.b);
		public static Rgb operator*(Rgb a, double s) => .(a.r * s, a.g * s, a.b * s);
		/// Gamma colour (the engine's Color fields): pow(1/2.2) of each channel.
		public Color Gamma => .((float)Math.Pow(Math.Max(r, 0), 1 / 2.2), (float)Math.Pow(Math.Max(g, 0), 1 / 2.2), (float)Math.Pow(Math.Max(b, 0), 1 / 2.2));
	}

	struct Vec { public double x, y, z; public this(double x, double y, double z) { this.x = x; this.y = y; this.z = z; } }

	static double Length(Vec p) => Math.Sqrt(p.x * p.x + p.y * p.y + p.z * p.z);

	/// Distance along `dir` (unit) from `p` to where it leaves a sphere of `radius` round the planet's centre, or -1.
	static double Exit(Vec p, Vec dir, double radius)
	{
		let b = p.x * dir.x + p.y * dir.y + p.z * dir.z;
		let c = p.x * p.x + p.y * p.y + p.z * p.z - radius * radius;
		let d = b * b - c;
		if (d < 0)
			return -1;
		return -b + Math.Sqrt(d);
	}

	/// Whether the ray from `p` along `dir` hits the ground.
	static bool HitsGround(Vec p, Vec dir)
	{
		let b = p.x * dir.x + p.y * dir.y + p.z * dir.z;
		if (b > 0)
			return false;
		let c = p.x * p.x + p.y * p.y + p.z * p.z - PlanetRadius * PlanetRadius;
		return b * b - c >= 0;
	}

	static double Rayleigh(double h) => Math.Exp(-h / RayleighHeight);
	static double Mie(double h) => Math.Exp(-h / MieHeight);
	static double Ozone(double h) => Math.Max(0, 1 - Math.Abs(h - 25000) / 15000);

	static Rgb Extinction(double odR, double odM, double odO) =>
		.(Math.Exp(-(RayleighR * odR + (MieScattering + MieAbsorption) * odM + OzoneR * odO)),
		Math.Exp(-(RayleighG * odR + (MieScattering + MieAbsorption) * odM + OzoneG * odO)),
		Math.Exp(-(RayleighB * odR + (MieScattering + MieAbsorption) * odM + OzoneB * odO)));

	/// The light that gets through from `p` along `dir` to space (0 if the ground is in the way).
	static Rgb Transmittance(Vec p, Vec dir, int steps)
	{
		if (HitsGround(p, dir))
			return .(0, 0, 0);
		let length = Exit(p, dir, TopRadius);
		if (length <= 0)
			return .(1, 1, 1);
		let ds = length / steps;
		double odR = 0, odM = 0, odO = 0;
		for (int i = 0; i < steps; i++)
		{
			let t = (i + 0.5) * ds;
			let h = Length(.(p.x + dir.x * t, p.y + dir.y * t, p.z + dir.z * t)) - PlanetRadius;
			odR += Rayleigh(h) * ds;
			odM += Mie(h) * ds;
			odO += Ozone(h) * ds;
		}
		return Extinction(odR, odM, odO);
	}

	static Vec Viewer => .(0, PlanetRadius + ViewerAltitude, 0);

	static Vec Toward(double elevationDegrees, double azimuthDegrees = 0)
	{
		let e = elevationDegrees * Math.PI_d / 180;
		let a = azimuthDegrees * Math.PI_d / 180;
		return .(Math.Cos(e) * Math.Cos(a), Math.Sin(e), Math.Cos(e) * Math.Sin(a));
	}

	static double Smoothstep(double a, double b, double x)
	{
		let t = Math.Clamp((x - a) / (b - a), 0, 1);
		return t * t * (3 - 2 * t);
	}

	static Rgb sZenith;
	static bool sZenithDone;

	/// The light that gets through straight up: what a body at the zenith gives (normalises noon to white).
	public static Rgb Zenith
	{
		get
		{
			if (!sZenithDone)
			{
				sZenith = Transmittance(Viewer, .(0, 1, 0), 40);
				sZenithDone = true;
			}
			return sZenith;
		}
	}

	/// The share of a body's light that gets through the air at `elevationDegrees`, divided by straight up's: (1,1,1)
	/// overhead, orange then red near the horizon, 0 once it is below. The edge is softened over the sun's disc.
	public static Rgb SunTransmittance(double elevationDegrees)
	{
		let t = Transmittance(Viewer, Toward(elevationDegrees), 40);
		let z = Zenith;
		let soft = Smoothstep(-0.8, 0.4, elevationDegrees);
		return Rgb(t.r / z.r, t.g / z.g, t.b / z.b) * soft;
	}

	static double PhaseRayleigh(double mu) => 3.0 / (16 * Math.PI_d) * (1 + mu * mu);

	static double PhaseMie(double mu)
	{
		let g2 = MieG * MieG;
		return 3.0 / (8 * Math.PI_d) * (1 - g2) * (1 + mu * mu) / ((2 + g2) * Math.Pow(1 + g2 - 2 * MieG * mu, 1.5));
	}

	/// Single-scattered sky radiance looking along `view` with the sun along `sun`, for a sun whose light outside the
	/// air is 1/Zenith (so noon's sun light is 1). Times the multiple-scattering constant.
	static Rgb SkyRadiance(Vec view, Vec sun, int steps = 16)
	{
		let p = Viewer;
		if (HitsGround(p, view))
			return .(0, 0, 0);
		let length = Exit(p, view, TopRadius);
		let ds = length / steps;
		let mu = view.x * sun.x + view.y * sun.y + view.z * sun.z;
		let pr = PhaseRayleigh(mu);
		let pm = PhaseMie(mu);
		double odR = 0, odM = 0, odO = 0;
		Rgb sum = .(0, 0, 0);
		for (int i = 0; i < steps; i++)
		{
			let t = (i + 0.5) * ds;
			let q = Vec(p.x + view.x * t, p.y + view.y * t, p.z + view.z * t);
			let h = Length(q) - PlanetRadius;
			let dr = Rayleigh(h);
			let dm = Mie(h);
			odR += dr * ds * 0.5;
			odM += dm * ds * 0.5;
			odO += Ozone(h) * ds * 0.5;
			let toViewer = Extinction(odR, odM, odO);
			odR += dr * ds * 0.5;
			odM += dm * ds * 0.5;
			odO += Ozone(h) * ds * 0.5;
			let toSun = Transmittance(q, sun, 12);
			let scatter = Rgb(RayleighR * dr * pr + MieScattering * dm * pm, RayleighG * dr * pr + MieScattering * dm * pm, RayleighB * dr * pr + MieScattering * dm * pm);
			sum = sum + scatter * toSun * toViewer * ds;
		}
		let z = Zenith;
		return Rgb(sum.r / z.r, sum.g / z.g, sum.b / z.b) * MultipleScattering;
	}

	/// The sky's light on a surface facing up (irradiance), with the sun at `sunElevation` degrees and noon sun light 1.
	public static Rgb SkyIrradiance(double sunElevation)
	{
		let sun = Toward(sunElevation);
		Rgb sum = .(0, 0, 0);
		const int Azimuths = 8;
		const int Elevations = 4;
		for (int e = 0; e < Elevations; e++)
		{
			let lo = 90.0 * e / Elevations;
			let hi = 90.0 * (e + 1) / Elevations;
			let mid = (lo + hi) * 0.5;
			// The band's solid angle (2 pi (sin hi - sin lo)) times cos to the up axis (sin of the elevation).
			let weight = 2 * Math.PI_d * (Math.Sin(hi * Math.PI_d / 180) - Math.Sin(lo * Math.PI_d / 180)) / Azimuths * Math.Sin(mid * Math.PI_d / 180);
			for (int a = 0; a < Azimuths; a++)
				sum = sum + SkyRadiance(Toward(mid, (a + 0.5) * 360.0 / Azimuths), sun) * weight;
		}
		return sum;
	}

	/// The sky at the horizon, averaged round it (sun's side weighted 0.6, the far side 0.4).
	public static Rgb HorizonRadiance(double sunElevation)
	{
		let sun = Toward(sunElevation);
		return SkyRadiance(Toward(2, 0), sun) * 0.4 + SkyRadiance(Toward(2, 90), sun) * 0.2 +
			SkyRadiance(Toward(2, -90), sun) * 0.2 + SkyRadiance(Toward(2, 180), sun) * 0.2;
	}

	/// The sun light a new scene starts with (SceneTemplates), and the one the ambient and fog are calibrated at.
	public const float ReferenceSunIntensity = 1.5f;

	static double sSkyScale, sFogScale;

	/// Scales the sky irradiance so the default noon (latitude 40, day 172, 12:00, sun 1.5) gives the old default
	/// ambient sky's (0.42, 0.50, 0.62) brightness, and the horizon the old fog colour's (0.62, 0.76, 0.90).
	public static double SkyScale { get { Calibrate(); return sSkyScale; } }
	public static double FogScale { get { Calibrate(); return sFogScale; } }

	static void Calibrate()
	{
		if (sSkyScale != 0)
			return;
		let env = scope SceneEnvironment();
		env.latitude = 40;
		env.dayOfYear = 172;
		env.timeOfDay = 12;
		let noon = DayNight.SunElevation(env);
		let oldSky = Rgb(Math.Pow(0.42, 2.2), Math.Pow(0.50, 2.2), Math.Pow(0.62, 2.2));
		let oldFog = Rgb(Math.Pow(0.62, 2.2), Math.Pow(0.76, 2.2), Math.Pow(0.90, 2.2));
		sSkyScale = oldSky.Luminance / (SkyIrradiance(noon).Luminance * ReferenceSunIntensity);
		sFogScale = oldFog.Luminance / (HorizonRadiance(noon).Luminance * ReferenceSunIntensity);
	}

	/// The night's floor of ambient light (linear), so the darkest night is not black.
	public static readonly Rgb NightFloor = .(0.004, 0.005, 0.008);
	/// Moonlight's colour (linear): dim and cool.
	public static readonly Rgb MoonColor = .(0.62, 0.72, 1.0);

	/// The ambient sky, ground and fog colours (linear, before Ambient Intensity) for a sun at `sunElevation`.
	public struct Ambient
	{
		public Rgb sky, ground, fog;
	}

	static double sCachedElevation = double.NaN;
	static Rgb sCachedSky, sCachedFog;

	/// The sun's part of the ambient (sky irradiance and horizon), for a noon sun light of 1. Cached: worked out again
	/// only when the sun has moved more than 0.1 degrees.
	static void SunPart(double sunElevation, out Rgb sky, out Rgb fog)
	{
		if (!(Math.Abs(sunElevation - sCachedElevation) <= 0.1))
		{
			sCachedElevation = sunElevation;
			sCachedSky = SkyIrradiance(sunElevation) * SkyScale;
			sCachedFog = HorizonRadiance(sunElevation) * FogScale;
		}
		sky = sCachedSky;
		fog = sCachedFog;
	}

	/// Auto Colours: ambient sky, ground and fog from the sun (and moon) through the air.
	public static Ambient AmbientColors(double sunElevation, float sunIntensity, float moonLight)
	{
		SunPart(sunElevation, var sky, var fog);
		let moon = Rgb(0.05, 0.06, 0.09) * moonLight;
		Ambient result;
		result.sky = sky * sunIntensity + moon + NightFloor;
		let sunUp = Math.Max(Math.Sin(sunElevation * Math.PI_d / 180), 0);
		result.ground = sky * sunIntensity * GroundAlbedo * (0.5 + 0.5 * sunUp) + (moon + NightFloor) * 0.5;
		result.fog = fog * sunIntensity + moon + NightFloor;
		return result;
	}
}
