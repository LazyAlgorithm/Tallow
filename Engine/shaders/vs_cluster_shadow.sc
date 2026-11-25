
// The shadow pass for cluster LOD drawing (vs_cluster.sc says how the vertices are found): as vs_shadow.sc.
#include <bgfx_shader.sh>
#include <bgfx_compute.sh>
#include "clod.sh"

BUFFER_RO(b_pool, uint, 8);
BUFFER_RO(b_instances, uint, 9);
BUFFER_RO(b_visible, uint, 10);

uniform mat4 u_shadowViewProj;

void main()
{
	// A bin's draw reads its own stretch of the index buffer, whose numbers are the bin and the corner (GpuDriven.bf).
	uint bin = uint(gl_VertexID) / 384u;
	uint corner0 = uint(gl_VertexID) - bin * 384u;
	uint entry = CLOD_VISIBLE_HEADER + (b_visible[bin] + uint(gl_InstanceID)) * 2u;
	uint instance = b_visible[entry];
	uint cluster = b_visible[entry + 1u];
	uint tri = corner0 / 3u;
	uint corner = corner0 - tri * 3u;
	// A triangle the cluster does not have repeats its first vertex three times: nothing to draw.
	if (tri >= b_pool[cluster + 3u])
	{
		tri = 0u;
		corner = 0u;
	}
	uint byteAt = b_pool[cluster + 2u] + tri * 3u + corner;
	uint local = (b_pool[byteAt >> 2u] >> ((byteAt & 3u) * 8u)) & 255u;
	uint v = b_pool[b_pool[cluster] + local];
	vec3 position = vec3(uintBitsToFloat(b_pool[v]), uintBitsToFloat(b_pool[v + 1u]), uintBitsToFloat(b_pool[v + 2u]));
	uint at = instance * CLOD_INSTANCE_WORDS;
	vec3 c0 = vec3(uintBitsToFloat(b_instances[at]), uintBitsToFloat(b_instances[at + 1u]), uintBitsToFloat(b_instances[at + 2u]));
	vec3 c1 = vec3(uintBitsToFloat(b_instances[at + 4u]), uintBitsToFloat(b_instances[at + 5u]), uintBitsToFloat(b_instances[at + 6u]));
	vec3 c2 = vec3(uintBitsToFloat(b_instances[at + 8u]), uintBitsToFloat(b_instances[at + 9u]), uintBitsToFloat(b_instances[at + 10u]));
	vec3 c3 = vec3(uintBitsToFloat(b_instances[at + 12u]), uintBitsToFloat(b_instances[at + 13u]), uintBitsToFloat(b_instances[at + 14u]));
	gl_Position = mul(u_shadowViewProj, vec4(c0 * position.x + c1 * position.y + c2 * position.z + c3, 1.0));
}
