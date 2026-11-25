// The body of the depth pass for cluster LOD drawing (vs_cluster_depth*.sc, see vs_cluster.sc for how the vertices are
// found). The files that include it say what the pass outputs: CLOD_VELOCITY adds the motion vector, CLOD_ALBEDO the
// colour and texture coordinates.
#include <bgfx_shader.sh>
#include <bgfx_compute.sh>
#include "clod.sh"
#include "velocity.sh"

BUFFER_RO(b_pool, uint, 8);
BUFFER_RO(b_instances, uint, 9);
BUFFER_RO(b_visible, uint, 10);

uniform mat4 u_depthViewProj;
uniform mat4 u_velCur;
uniform mat4 u_velPrev;

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
	v_depth = 1.0;
#ifdef CLOD_ALBEDO
	v_color0 = vec4_splat(0.0);
	v_texcoord0 = vec2_splat(0.0);
#endif
#ifdef CLOD_VELOCITY
	v_velCur = vec4(0.0, 0.0, 0.0, 1.0);
	v_velPrev = vec4(0.0, 0.0, 0.0, 1.0);
#endif
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
	vec4 world = vec4(c0 * position.x + c1 * position.y + c2 * position.z + c3, 1.0);
	gl_Position = mul(u_depthViewProj, world);
	v_depth = mul(u_view, world).z;
#ifdef CLOD_ALBEDO
	uint packedColor = b_pool[v + 6u];
	vec4 vertexColor = vec4(float(packedColor & 255u), float((packedColor >> 8u) & 255u), float((packedColor >> 16u) & 255u), float(packedColor >> 24u)) / 255.0;
	vec4 tint = vec4(uintBitsToFloat(b_instances[at + 16u]), uintBitsToFloat(b_instances[at + 17u]), uintBitsToFloat(b_instances[at + 18u]), uintBitsToFloat(b_instances[at + 19u]));
	v_color0 = vertexColor * tint;
	v_texcoord0 = vec2(uintBitsToFloat(b_pool[v + 7u]), uintBitsToFloat(b_pool[v + 8u]));
#endif
#ifdef CLOD_VELOCITY
	// last frame's matrix, as its three rows
	vec4 p0 = vec4(uintBitsToFloat(b_instances[at + 20u]), uintBitsToFloat(b_instances[at + 21u]), uintBitsToFloat(b_instances[at + 22u]), uintBitsToFloat(b_instances[at + 23u]));
	vec4 p1 = vec4(uintBitsToFloat(b_instances[at + 24u]), uintBitsToFloat(b_instances[at + 25u]), uintBitsToFloat(b_instances[at + 26u]), uintBitsToFloat(b_instances[at + 27u]));
	vec4 p2 = vec4(uintBitsToFloat(b_instances[at + 28u]), uintBitsToFloat(b_instances[at + 29u]), uintBitsToFloat(b_instances[at + 30u]), uintBitsToFloat(b_instances[at + 31u]));
	vec3 prev = vec3(dot(p0.xyz, position) + p0.w, dot(p1.xyz, position) + p1.w, dot(p2.xyz, position) + p2.w);
	v_velCur = mul(u_velCur, world);
	v_velPrev = mul(u_velPrev, vec4(prev, 1.0));
#endif
}
