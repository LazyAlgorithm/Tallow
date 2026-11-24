$input v_texcoord0, v_wpos

// AMD FidelityFX Super Resolution 1.0, EASU (edge-adaptive spatial upsampling), ported to bgfx shader language
// from FidelityFX-FSR ffx_fsr1.h (non-packed 32-bit path). The fast reciprocal and square-root approximations are
// exact here and the 2x2 gathers are plain reads, so it runs on WebGL 2 and OpenGL ES 3.0 as well.
// Reads the tonemapped (perceptual) picture at render size, writes it at the output size.
//
// Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
#include <bgfx_shader.sh>

SAMPLER2D(s_color, 0);

uniform vec4 u_aaParams; // xy: one texel of the input, zw: the input's size in texels

vec3 tap(vec2 fp, float x, float y)
{
	return texture2DLod(s_color, (fp + vec2(x, y) + 0.5) * u_aaParams.xy, 0.0).rgb;
}

// Luma times two, in two multiply-adds.
float lumaOf(vec3 c)
{
	return c.b * 0.5 + (c.r * 0.5 + c.g);
}

// Gradient direction and length, accumulated with a bilinear weight (a to e: the plus shape round c).
void accumulate(inout vec2 dir, inout float len, vec2 pp, float w, float lA, float lB, float lC, float lD, float lE)
{
	float dc = lD - lC;
	float cb = lC - lB;
	float lenX = max(abs(dc), abs(cb));
	lenX = 1.0 / max(lenX, 1e-20);
	float dirX = lD - lB;
	dir.x += dirX * w;
	lenX = clamp(abs(dirX) * lenX, 0.0, 1.0);
	lenX *= lenX;
	len += lenX * w;

	float ec = lE - lC;
	float ca = lC - lA;
	float lenY = max(abs(ec), abs(ca));
	lenY = 1.0 / max(lenY, 1e-20);
	float dirY = lE - lA;
	dir.y += dirY * w;
	lenY = clamp(abs(dirY) * lenY, 0.0, 1.0);
	lenY *= lenY;
	len += lenY * w;
}

// One tap's weight (an approximation of Lanczos 2 with a negative lobe) added to the sum.
void addTap(inout vec3 aC, inout float aW, vec2 off, vec2 dir, vec2 len, float lob, float clp, vec3 c)
{
	vec2 v;
	v.x = off.x * dir.x + off.y * dir.y;
	v.y = off.x * -dir.y + off.y * dir.x;
	v *= len;
	float d2 = v.x * v.x + v.y * v.y;
	d2 = min(d2, clp);
	float wB = 2.0 / 5.0 * d2 - 1.0;
	float wA = lob * d2 - 1.0;
	wB *= wB;
	wA *= wA;
	wB = 25.0 / 16.0 * wB - (25.0 / 16.0 - 1.0);
	float w = wB * wA;
	aC += c * w;
	aW += w;
}

void main()
{
	// Where this output pixel is in the input, with texel centres at whole numbers; f is the texel it falls in.
	vec2 pp = v_texcoord0 * u_aaParams.zw - 0.5;
	vec2 fp = floor(pp);
	pp -= fp;

	// The 12-tap kernel:
	//    b c
	//  e f g h
	//  i j k l
	//    n o
	vec3 b = tap(fp, 0.0, -1.0);
	vec3 c = tap(fp, 1.0, -1.0);
	vec3 e = tap(fp, -1.0, 0.0);
	vec3 f = tap(fp, 0.0, 0.0);
	vec3 g = tap(fp, 1.0, 0.0);
	vec3 h = tap(fp, 2.0, 0.0);
	vec3 i = tap(fp, -1.0, 1.0);
	vec3 j = tap(fp, 0.0, 1.0);
	vec3 k = tap(fp, 1.0, 1.0);
	vec3 l = tap(fp, 2.0, 1.0);
	vec3 n = tap(fp, 0.0, 2.0);
	vec3 o = tap(fp, 1.0, 2.0);

	float bL = lumaOf(b);
	float cL = lumaOf(c);
	float eL = lumaOf(e);
	float fL = lumaOf(f);
	float gL = lumaOf(g);
	float hL = lumaOf(h);
	float iL = lumaOf(i);
	float jL = lumaOf(j);
	float kL = lumaOf(k);
	float lL = lumaOf(l);
	float nL = lumaOf(n);
	float oL = lumaOf(o);

	// Accumulate for bilinear interpolation (s t / u v are the four texels round the pixel: f g / j k).
	vec2 dir = vec2(0.0, 0.0);
	float len = 0.0;
	accumulate(dir, len, pp, (1.0 - pp.x) * (1.0 - pp.y), bL, eL, fL, gL, jL);
	accumulate(dir, len, pp, pp.x * (1.0 - pp.y), cL, fL, gL, hL, kL);
	accumulate(dir, len, pp, (1.0 - pp.x) * pp.y, fL, iL, jL, kL, nL);
	accumulate(dir, len, pp, pp.x * pp.y, gL, jL, kL, lL, oL);

	// Normalise the direction, and clean up close to zero.
	vec2 dir2 = dir * dir;
	float dirR = dir2.x + dir2.y;
	bool zro = dirR < 1.0 / 32768.0;
	dirR = inversesqrt(max(dirR, 1e-20));
	dirR = zro ? 1.0 : dirR;
	dir.x = zro ? 1.0 : dir.x;
	dir *= dirR;
	// {0 to 2} to {0 to 1}, and shaped with a square.
	len = len * 0.5;
	len *= len;
	// Stretch the kernel: 1 along the axes, sqrt(2) on a diagonal.
	float stretch = (dir.x * dir.x + dir.y * dir.y) / max(max(abs(dir.x), abs(dir.y)), 1e-20);
	// Anisotropic length after rotation: x from 1 to the stretch on edges, y from 1 to 2x on edges.
	vec2 len2 = vec2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);
	// The window shifts with the amount of edge, from sqrt(2) to slightly past 2.
	float lob = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len;
	float clp = 1.0 / lob;

	// The nearest four, to limit ringing.
	vec3 min4 = min(min(min(f, g), j), k);
	vec3 max4 = max(max(max(f, g), j), k);

	vec3 aC = vec3(0.0, 0.0, 0.0);
	float aW = 0.0;
	addTap(aC, aW, vec2(0.0, -1.0) - pp, dir, len2, lob, clp, b);
	addTap(aC, aW, vec2(1.0, -1.0) - pp, dir, len2, lob, clp, c);
	addTap(aC, aW, vec2(-1.0, 1.0) - pp, dir, len2, lob, clp, i);
	addTap(aC, aW, vec2(0.0, 1.0) - pp, dir, len2, lob, clp, j);
	addTap(aC, aW, vec2(0.0, 0.0) - pp, dir, len2, lob, clp, f);
	addTap(aC, aW, vec2(-1.0, 0.0) - pp, dir, len2, lob, clp, e);
	addTap(aC, aW, vec2(1.0, 1.0) - pp, dir, len2, lob, clp, k);
	addTap(aC, aW, vec2(2.0, 1.0) - pp, dir, len2, lob, clp, l);
	addTap(aC, aW, vec2(2.0, 0.0) - pp, dir, len2, lob, clp, h);
	addTap(aC, aW, vec2(1.0, 0.0) - pp, dir, len2, lob, clp, g);
	addTap(aC, aW, vec2(1.0, 2.0) - pp, dir, len2, lob, clp, o);
	addTap(aC, aW, vec2(0.0, 2.0) - pp, dir, len2, lob, clp, n);

	// Normalise and de-ring.
	vec3 pix = min(max4, max(min4, aC / aW));
	gl_FragColor = vec4(pix, 1.0);
}
