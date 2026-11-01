// Cube map faces for the reflection passes (docs/reflections.md). Include after bgfx_shader.sh.
#ifndef TALLOW_CUBE_SH
#define TALLOW_CUBE_SH

// The direction a cube face's texel looks along: face 0 to 5 is +X, -X, +Y, -Y, +Z, -Z, and uv the texel's place in
// the face as stored (a fullscreen pass's v_texcoord0). The inverse of how the graphics card picks a texel for a
// direction, on every backend.
vec3 cubeDirection(float face, vec2 uv)
{
	vec2 st = uv * 2.0 - 1.0;
	vec3 dir;
	if (face < 0.5)
		dir = vec3(1.0, -st.y, -st.x);
	else if (face < 1.5)
		dir = vec3(-1.0, -st.y, st.x);
	else if (face < 2.5)
		dir = vec3(st.x, 1.0, st.y);
	else if (face < 3.5)
		dir = vec3(st.x, -1.0, -st.y);
	else if (face < 4.5)
		dir = vec3(st.x, -st.y, 1.0);
	else
		dir = vec3(-st.x, -st.y, -1.0);
	return normalize(dir);
}

#endif
