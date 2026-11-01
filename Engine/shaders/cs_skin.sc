// GPU skinning (docs/gpu-skinning.md): bends a skinned model's vertices on the graphics card, writing them straight
// into the vertex buffer every pass draws from (the scene, shadows, depth, custom materials), so none of their
// shaders need a skinned version. Runs once per vertex.
#include "bgfx_compute.sh"

// Per vertex, four in a row: its position and normal at rest, its four joints and their four weights.
BUFFER_RO(b_source, vec4, 0);
// Per joint, three in a row: the rows of its skinning matrix (where the joint is now times its inverse rest pose).
BUFFER_RO(b_bones, vec4, 1);
// The mesh's vertices, 11 floats each (position 3, normal 3, colour 1, uv 2, uv2 2); only position and normal change.
BUFFER_RW(b_vertices, float, 2);

uniform vec4 u_skin;          // x: the vertex count

NUM_THREADS(64, 1, 1)
void main()
{
	int v = int(gl_GlobalInvocationID.x);
	if (v >= int(u_skin.x))
	{
		return;
	}
	vec4 position = vec4(b_source[v * 4].xyz, 1.0);
	vec4 normal = vec4(b_source[v * 4 + 1].xyz, 0.0);
	vec4 joints = b_source[v * 4 + 2];
	vec4 weights = b_source[v * 4 + 3];
	vec3 skinned = vec3_splat(0.0);
	vec3 bent = vec3_splat(0.0);
	for (int k = 0; k < 4; k++)
	{
		float weight = weights[k];
		if (weight > 0.0)
		{
			int bone = int(joints[k] + 0.5) * 3;
			vec4 row0 = b_bones[bone];
			vec4 row1 = b_bones[bone + 1];
			vec4 row2 = b_bones[bone + 2];
			skinned += vec3(dot(row0, position), dot(row1, position), dot(row2, position)) * weight;
			bent += vec3(dot(row0, normal), dot(row1, normal), dot(row2, normal)) * weight;
		}
	}
	float length2 = dot(bent, bent);
	if (length2 > 1.0e-12)
	{
		bent = bent * inversesqrt(length2);
	}
	// Into Tallow's left-handed space, as the CPU path does.
	int o = v * 11;
	b_vertices[o] = skinned.x;
	b_vertices[o + 1] = skinned.y;
	b_vertices[o + 2] = -skinned.z;
	b_vertices[o + 3] = bent.x;
	b_vertices[o + 4] = bent.y;
	b_vertices[o + 5] = -bent.z;
}
