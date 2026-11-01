using System;

namespace Tallow;

/// Linear RGBA color with float channels.
[CRepr]
struct Color
{
	public float r;
	public float g;
	public float b;
	public float a;

	public this()
	{
		r = 1;
		g = 1;
		b = 1;
		a = 1;
	}

	public this(float r, float g, float b, float a = 1.0f)
	{
		this.r = r;
		this.g = g;
		this.b = b;
		this.a = a;
	}

	public static Color White => .(1, 1, 1, 1);
	public static Color Black => .(0, 0, 0, 1);
	public static Color Red => .(1, 0, 0, 1);
	public static Color Green => .(0, 1, 0, 1);
	public static Color Blue => .(0, 0, 1, 1);
	public static Color Yellow => .(1, 0.92f, 0.016f, 1);
	public static Color Gray => .(0.5f, 0.5f, 0.5f, 1);
	/// Fully see-through black.
	public static Color Clear => .(0, 0, 0, 0);

	/// A colour from hue (0 to 1 round the colour wheel, red first), saturation and value (brightness), each 0 to 1.
	public static Color FromHSV(float hue, float saturation, float value, float alpha = 1)
	{
		let h = (hue - Math.Floor(hue)) * 6;
		let sector = (int)h % 6;
		let f = h - Math.Floor(h);
		let s = Math.Clamp(saturation, 0, 1), v = Math.Clamp(value, 0, 1);
		let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
		switch (sector)
		{
		case 0: return .(v, t, p, alpha);
		case 1: return .(q, v, p, alpha);
		case 2: return .(p, v, t, alpha);
		case 3: return .(p, q, v, alpha);
		case 4: return .(t, p, v, alpha);
		default: return .(v, p, q, alpha);
		}
	}

	/// The colour's red, green and blue times a number (alpha is kept).
	public static Color operator *(Color c, float s) => .(c.r * s, c.g * s, c.b * s, c.a);
	/// The colour a fraction t of the way from a to b.
	public static Color Lerp(Color a, Color b, float t) =>
		.(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t);

	/// Builds a color from 0..255 sRGB-style bytes, e.g. Color.FromBytes(204, 96, 48).
	public static Color FromBytes(uint8 r, uint8 g, uint8 b, uint8 a = 255) =>
		.(r / 255.0f, g / 255.0f, b / 255.0f, a / 255.0f);

	/// Packs to the 0xAABBGGRR layout bgfx uses for normalized uint8 vertex colors.
	public uint32 ToABGR()
	{
		let rr = (uint32)(Mathf.Clamp01(r) * 255.0f + 0.5f);
		let gg = (uint32)(Mathf.Clamp01(g) * 255.0f + 0.5f);
		let bb = (uint32)(Mathf.Clamp01(b) * 255.0f + 0.5f);
		let aa = (uint32)(Mathf.Clamp01(a) * 255.0f + 0.5f);
		return (aa << 24) | (bb << 16) | (gg << 8) | rr;
	}

	/// Packs to 0xRRGGBBAA, the layout bgfx view clears expect.
	public uint32 ToRGBA()
	{
		let rr = (uint32)(Mathf.Clamp01(r) * 255.0f + 0.5f);
		let gg = (uint32)(Mathf.Clamp01(g) * 255.0f + 0.5f);
		let bb = (uint32)(Mathf.Clamp01(b) * 255.0f + 0.5f);
		let aa = (uint32)(Mathf.Clamp01(a) * 255.0f + 0.5f);
		return (rr << 24) | (gg << 16) | (bb << 8) | aa;
	}
}
