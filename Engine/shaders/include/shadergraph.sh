#ifndef TALLOW_SHADERGRAPH_SH
#define TALLOW_SHADERGRAPH_SH

// Functions the shader graph's nodes call (Editor/src/Graph/NodeLibrary.bf). Included by the mesh shaders, so a
// hand-written .tshader can use them too; the ones a shader does not call cost nothing. Needs u_surface (time in
// y) declared first.

// A random number from 0 to 1 for each point of a grid.
float tsg_hash(vec2 p)
{
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

vec2 tsg_hash2(vec2 p)
{
	return vec2(tsg_hash(p), tsg_hash(p + vec2(41.0, 289.0)));
}

// Smooth value noise, 0 to 1: random heights at the corners of a grid of unit squares, blended smoothly.
float tsg_noise(vec2 p)
{
	vec2 cell = floor(p);
	vec2 f = fract(p);
	vec2 s = f * f * (3.0 - 2.0 * f);
	float a = tsg_hash(cell);
	float b = tsg_hash(cell + vec2(1.0, 0.0));
	float c = tsg_hash(cell + vec2(0.0, 1.0));
	float d = tsg_hash(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
}

// Voronoi cells: x the distance to the nearest cell's centre, y a random number for that cell. The centres drift
// with time times speed.
vec2 tsg_cells(vec2 p, float speed)
{
	vec2 cell = floor(p);
	vec2 f = fract(p);
	float nearest = 8.0;
	float id = 0.0;
	for (int y = -1; y <= 1; y++)
	{
		for (int x = -1; x <= 1; x++)
		{
			vec2 offset = vec2(float(x), float(y));
			vec2 random = tsg_hash2(cell + offset);
			vec2 centre = offset + 0.5 + 0.5 * sin(u_surface.y * speed + 6.2831 * random);
			float d = length(centre - f);
			if (d < nearest)
			{
				nearest = d;
				id = random.x;
			}
		}
	}
	return vec2(nearest, id);
}

// Texture coordinates turned round a centre, in degrees.
vec2 tsg_rotate(vec2 uv, vec2 centre, float degrees)
{
	float a = radians(degrees);
	float c = cos(a);
	float s = sin(a);
	vec2 d = uv - centre;
	return centre + vec2(d.x * c - d.y * s, d.x * s + d.y * c);
}

// The distance from a centre and the angle round it (0 to 1, a whole turn).
vec2 tsg_polar(vec2 uv, vec2 centre)
{
	vec2 d = uv - centre;
	return vec2(length(d), atan2(d.y, d.x) / 6.2831 + 0.5);
}

// How much each of the three planes counts in a triplanar sample, from the surface's facing; sharper weights
// blend over a narrower band.
vec3 tsg_triplanarWeights(vec3 n, float sharpness)
{
	vec3 w = pow(abs(n), vec3_splat(max(sharpness, 1.0)));
	return w / max(w.x + w.y + w.z, 0.00001);
}

// A texture laid onto a surface from the three directions of the world, blended by facing: for ground, rock and
// anything without good texture coordinates. A macro, as samplers cannot be passed to functions on every backend.
#define tsg_triplanar(tex, p, n, sharpness) (texture2D(tex, (p).zy) * tsg_triplanarWeights(n, sharpness).x \
	+ texture2D(tex, (p).xz) * tsg_triplanarWeights(n, sharpness).y + texture2D(tex, (p).xy) * tsg_triplanarWeights(n, sharpness).z)

// A normal map's colour as a normal in the surface's own directions, its bumps scaled by strength.
vec3 tsg_unpackNormal(vec3 rgb, float strength)
{
	vec3 n = rgb * 2.0 - 1.0;
	return normalize(vec3(n.xy * strength, max(n.z, 0.0001)));
}

#if BGFX_SHADER_TYPE_FRAGMENT
// A normal from how a height changes across the surface (per unit of the texture coordinates uv), its bumps scaled
// by strength. Only in surface code: it reads how values change from pixel to pixel.
vec3 tsg_heightNormal(float height, vec2 uv, float strength)
{
	vec2 uvx = dFdx(uv);
	vec2 uvy = dFdy(uv);
	float hx = dFdx(height);
	float hy = dFdy(height);
	float det = uvx.x * uvy.y - uvx.y * uvy.x;
	if (abs(det) < 1.0e-12)
	{
		return vec3(0.0, 0.0, 1.0);
	}
	vec2 slope = vec2(hx * uvy.y - hy * uvx.y, uvx.x * hy - uvy.x * hx) / det;
	return normalize(vec3(-slope * strength, 1.0));
}
#endif

#endif // TALLOW_SHADERGRAPH_SH
