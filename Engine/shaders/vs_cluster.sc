$output v_wpos, v_normal, v_color0, v_texcoord0, v_depth, v_texcoord1, v_surface

// Lit mesh vertex shader for cluster LOD drawing: as vs_mesh.sc, but with no vertex or instance data of its own. One
// instance of the draw is one cluster (up to 128 triangles) and vertex n is corner n of its triangles; the cluster,
// its instance, its triangle and its vertex are read from the buffers in include/clod.sh. A triangle the cluster
// does not have is squeezed out of the picture.
#include <bgfx_shader.sh>
#include <bgfx_compute.sh>
#include "clod.sh"

BUFFER_RO(b_pool, uint, 8);
BUFFER_RO(b_instances, uint, 9);
BUFFER_RO(b_visible, uint, 10);

#ifdef TW_DEBUG
// vs_cluster_debug (tools/compile_shaders.py): the debug views (GpuDriven.DebugView) colour the surface by what the
// cluster is, in place of its material. x: 1 clusters, 2 LOD level, 3 triangles, 6 residency.
uniform vec4 u_clodDebug;

vec3 debugHash(uint n)
{
	n = (n ^ 61u) ^ (n >> 16u);
	n *= 9u;
	n = n ^ (n >> 4u);
	n *= 0x27d4eb2du;
	n = n ^ (n >> 15u);
	return vec3(float(n & 255u), float((n >> 8u) & 255u), float((n >> 16u) & 255u)) / 255.0 * 0.75 + vec3_splat(0.2);
}

vec3 debugRamp(float t)
{
	// Blue (finest) to red (coarsest).
	t = clamp(t, 0.0, 1.0);
	return clamp(vec3(t * 2.0 - 0.6, 1.0 - abs(t * 2.0 - 1.0) * 1.2, 1.4 - t * 2.0), 0.0, 1.0);
}
#endif


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
	vec3 a_position = vec3(uintBitsToFloat(b_pool[v]), uintBitsToFloat(b_pool[v + 1u]), uintBitsToFloat(b_pool[v + 2u]));
	vec3 normal = vec3(uintBitsToFloat(b_pool[v + 3u]), uintBitsToFloat(b_pool[v + 4u]), uintBitsToFloat(b_pool[v + 5u]));
	uint packedColor = b_pool[v + 6u];
	vec4 a_color0 = vec4(float(packedColor & 255u), float((packedColor >> 8u) & 255u), float((packedColor >> 16u) & 255u), float(packedColor >> 24u)) / 255.0;
	v_texcoord0 = vec2(uintBitsToFloat(b_pool[v + 7u]), uintBitsToFloat(b_pool[v + 8u]));

	uint at = instance * CLOD_INSTANCE_WORDS;
	vec4 i_data0 = vec4(uintBitsToFloat(b_instances[at]), uintBitsToFloat(b_instances[at + 1u]), uintBitsToFloat(b_instances[at + 2u]), uintBitsToFloat(b_instances[at + 3u]));
	vec4 i_data1 = vec4(uintBitsToFloat(b_instances[at + 4u]), uintBitsToFloat(b_instances[at + 5u]), uintBitsToFloat(b_instances[at + 6u]), uintBitsToFloat(b_instances[at + 7u]));
	vec4 i_data2 = vec4(uintBitsToFloat(b_instances[at + 8u]), uintBitsToFloat(b_instances[at + 9u]), uintBitsToFloat(b_instances[at + 10u]), uintBitsToFloat(b_instances[at + 11u]));
	vec4 i_data3 = vec4(uintBitsToFloat(b_instances[at + 12u]), uintBitsToFloat(b_instances[at + 13u]), uintBitsToFloat(b_instances[at + 14u]), uintBitsToFloat(b_instances[at + 15u]));
	vec4 i_data4 = vec4(uintBitsToFloat(b_instances[at + 16u]), uintBitsToFloat(b_instances[at + 17u]), uintBitsToFloat(b_instances[at + 18u]), uintBitsToFloat(b_instances[at + 19u]));

	// fs_cluster has no lightmap: its second UV carries the cluster's simplification error in world units, the
	// distance the drawn surface may lie off the true one, which the shadow lookups step over (include/lighting.sh).
	v_texcoord1 = vec2(uintBitsToFloat(b_pool[cluster + 12u]) * uintBitsToFloat(b_instances[at + 39u]), 0.0);

	mat4 model = mtxFromCols(vec4(i_data0.xyz, 0.0), vec4(i_data1.xyz, 0.0), vec4(i_data2.xyz, 0.0), i_data3);
	v_surface = vec3(i_data0.w, i_data1.w, i_data2.w);
	vec4 wpos = mul(model, vec4(a_position, 1.0));
	gl_Position = mul(u_viewProj, wpos);
	v_wpos = wpos.xyz;
	vec3 co0 = cross(i_data1.xyz, i_data2.xyz);
	vec3 co1 = cross(i_data2.xyz, i_data0.xyz);
	vec3 co2 = cross(i_data0.xyz, i_data1.xyz);
	float orientation = dot(i_data0.xyz, co0) < 0.0 ? -1.0 : 1.0;
	v_normal = (co0 * normal.x + co1 * normal.y + co2 * normal.z) * orientation;
	v_color0 = a_color0 * i_data4;
#ifdef TW_DEBUG
	vec3 debugColor = vec3_splat(1.0);
	if (u_clodDebug.x < 1.5)
	{
		debugColor = debugHash(cluster);
	}
	else if (u_clodDebug.x < 2.5)
	{
		debugColor = debugRamp(float(b_pool[b_pool[cluster + 14u] + 6u]) / max(u_clodDebug.y, 1.0));
	}
	else if (u_clodDebug.x < 3.5)
	{
		debugColor = debugHash(cluster * 128u + tri);
	}
	else if (u_clodDebug.x > 6.5)
	{
		debugColor = vec3_splat(0.25);
	}
	else
	{
		// A cluster whose finer group is not in the pool yet is what the screen may be showing in its place (orange); a
		// cluster at full detail or whose finer group is resident is green.
		uint refined = b_pool[cluster + 15u];
		bool coarse = refined != 0xFFFFFFFFu && b_pool[refined + CLOD_GROUP_RESIDENT] == 0u;
		debugColor = coarse ? vec3(1.0, 0.35, 0.05) : vec3(0.1, 0.8, 0.2);
	}
	v_color0 = vec4(debugColor, 1.0);
#endif
	v_depth = gl_Position.w;
}
