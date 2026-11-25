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
	v_texcoord1 = vec2(uintBitsToFloat(b_pool[v + 9u]), uintBitsToFloat(b_pool[v + 10u]));

	uint at = instance * CLOD_INSTANCE_WORDS;
	vec4 i_data0 = vec4(uintBitsToFloat(b_instances[at]), uintBitsToFloat(b_instances[at + 1u]), uintBitsToFloat(b_instances[at + 2u]), uintBitsToFloat(b_instances[at + 3u]));
	vec4 i_data1 = vec4(uintBitsToFloat(b_instances[at + 4u]), uintBitsToFloat(b_instances[at + 5u]), uintBitsToFloat(b_instances[at + 6u]), uintBitsToFloat(b_instances[at + 7u]));
	vec4 i_data2 = vec4(uintBitsToFloat(b_instances[at + 8u]), uintBitsToFloat(b_instances[at + 9u]), uintBitsToFloat(b_instances[at + 10u]), uintBitsToFloat(b_instances[at + 11u]));
	vec4 i_data3 = vec4(uintBitsToFloat(b_instances[at + 12u]), uintBitsToFloat(b_instances[at + 13u]), uintBitsToFloat(b_instances[at + 14u]), uintBitsToFloat(b_instances[at + 15u]));
	vec4 i_data4 = vec4(uintBitsToFloat(b_instances[at + 16u]), uintBitsToFloat(b_instances[at + 17u]), uintBitsToFloat(b_instances[at + 18u]), uintBitsToFloat(b_instances[at + 19u]));

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
	v_depth = gl_Position.w;
}
