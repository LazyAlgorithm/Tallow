$input v_texcoord0, v_wpos

// One face of one level of a reflection cube (tallowengine.com/docs/reflections): what a surface of that level's roughness
// mirrors, the source cube blurred by the GGX highlight's shape. Level 0 is the source as it is; each level down
// is rougher, to roughness 1 at the last. Samples are spread by importance and read from the source's smaller mip
// levels where they are sparse, so few are needed without speckles.
#include <bgfx_shader.sh>
#include "cube.sh"

#define SAMPLES 64
#define PI 3.14159265

SAMPLERCUBE(s_source, 0);
uniform vec4 u_envFace;    // x: the face, 0 to 5
uniform vec4 u_envFilter;  // x: roughness, y: the source's face size, z: its last mip level

float radicalInverse(float index)
{
	float result = 0.0;
	float fraction = 0.5;
	float n = index;
	for (int bit = 0; bit < 8; bit++)
	{
		result += fraction * mod(n, 2.0);
		n = floor(n * 0.5);
		fraction *= 0.5;
	}
	return result;
}

void main()
{
	vec3 n = cubeDirection(u_envFace.x, v_texcoord0);
	float roughness = u_envFilter.x;
	if (roughness < 0.001)
	{
		gl_FragColor = vec4(textureCubeLod(s_source, n, 0.0).rgb, 1.0);
		return;
	}
	vec3 up = abs(n.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 tangent = normalize(cross(up, n));
	vec3 bitangent = cross(n, tangent);
	float a = roughness * roughness;
	float a2 = a * a;
	// The solid angle of one texel of the source's largest level.
	float texelAngle = 4.0 * PI / (6.0 * u_envFilter.y * u_envFilter.y);
	vec3 sum = vec3_splat(0.0);
	float weight = 0.0;
	for (int i = 0; i < SAMPLES; i++)
	{
		float u = (float(i) + 0.5) / float(SAMPLES);
		float v = radicalInverse(float(i));
		float phi = 2.0 * PI * u;
		float cosTheta = sqrt((1.0 - v) / (1.0 + (a2 - 1.0) * v));
		float sinTheta = sqrt(max(1.0 - cosTheta * cosTheta, 0.0));
		vec3 h = tangent * (cos(phi) * sinTheta) + bitangent * (sin(phi) * sinTheta) + n * cosTheta;
		// Looking straight at the surface (the view along the normal), as the split-sum approximation does.
		vec3 l = 2.0 * dot(n, h) * h - n;
		float ndotl = dot(n, l);
		if (ndotl > 0.0)
		{
			float d = cosTheta * cosTheta * (a2 - 1.0) + 1.0;
			float distribution = a2 / (PI * d * d);
			float pdf = distribution * 0.25;
			float sampleAngle = 1.0 / (float(SAMPLES) * pdf + 1.0e-4);
			float lod = clamp(0.5 * log2(sampleAngle / texelAngle) + 1.0, 0.0, u_envFilter.z);
			sum += textureCubeLod(s_source, l, lod).rgb * ndotl;
			weight += ndotl;
		}
	}
	gl_FragColor = vec4(sum / max(weight, 1.0e-4), 1.0);
}
