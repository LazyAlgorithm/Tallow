$input v_texcoord0, v_wpos

// SMAA 3 of 3: neighbourhood blending. Mixes each pixel with the neighbour the weights name, using the bilinear
// filter to do it in one read. See smaa.sh for the licence.
#include <bgfx_shader.sh>
#include "smaa.sh"

SAMPLER2D(s_color, 0);
SAMPLER2D(s_blend, 1);

void main()
{
	vec2 texcoord = v_texcoord0;
	vec4 offset = u_aaParams.xyxy * vec4(1.0, 0.0, 0.0, 1.0) + texcoord.xyxy;
	// The blending weights of this pixel: right, top, bottom, left.
	vec4 a;
	a.x = smaaLod(s_blend, offset.xy).a;
	a.y = smaaLod(s_blend, offset.zw).g;
	a.wz = smaaLod(s_blend, texcoord).xz;

	if (dot(a, vec4(1.0, 1.0, 1.0, 1.0)) < 1e-5)
	{
		gl_FragColor = vec4(smaaLod(s_color, texcoord).rgb, 1.0);
		return;
	}
	bool h = max(a.x, a.z) > max(a.y, a.w); // the horizontal weights are the larger
	vec4 blendingOffset = vec4(0.0, a.y, 0.0, a.w);
	vec2 blendingWeight = a.yw;
	if (h)
	{
		blendingOffset = vec4(a.x, 0.0, a.z, 0.0);
		blendingWeight = a.xz;
	}
	blendingWeight /= dot(blendingWeight, vec2(1.0, 1.0));
	vec4 blendingCoord = blendingOffset * vec4(u_aaParams.xy, -u_aaParams.xy) + texcoord.xyxy;
	vec4 color = blendingWeight.x * smaaLod(s_color, blendingCoord.xy);
	color += blendingWeight.y * smaaLod(s_color, blendingCoord.zw);
	gl_FragColor = vec4(color.rgb, 1.0);
}
