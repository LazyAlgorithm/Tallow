$input v_texcoord0, v_wpos

// One face of a reflection probe's cube from the scene drawn from the probe that way (tallowengine.com/docs/reflections): each
// texel's direction is found in the picture with the camera that drew it, so the face comes out the right way round
// on every backend.
#include <bgfx_shader.sh>
#include "cube.sh"

SAMPLER2D(s_source, 0);
uniform vec4 u_envFace;      // x: the face, 0 to 5, y: 1 when textures start at the bottom left
uniform mat4 u_envViewProj;  // the camera that drew the picture, at the origin

void main()
{
	vec4 clip = mul(u_envViewProj, vec4(cubeDirection(u_envFace.x, v_texcoord0), 1.0));
	vec2 ndc = clip.xy / clip.w;
	vec2 uv = vec2(ndc.x * 0.5 + 0.5, u_envFace.y > 0.5 ? ndc.y * 0.5 + 0.5 : 0.5 - ndc.y * 0.5);
	gl_FragColor = vec4(texture2DLod(s_source, uv, 0.0).rgb, 1.0);
}
