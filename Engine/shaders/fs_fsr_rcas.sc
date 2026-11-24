$input v_texcoord0, v_wpos

// AMD FidelityFX Super Resolution 1.0, RCAS (robust contrast-adaptive sharpening), ported to bgfx shader language
// from FidelityFX-FSR ffx_fsr1.h (non-packed 32-bit path, noise removal off). Sharpens the upscaled picture
// without ringing: the amount is limited by how much headroom the pixel's neighbours leave.
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

uniform vec4 u_aaParams;  // xy: one texel, zw: the picture's size in texels
uniform vec4 u_fsrParams; // x: sharpness as a linear amount (2 to the power of minus the stops of reduction)

#define RCAS_LIMIT (0.25 - (1.0 / 16.0))

void main()
{
	vec2 uv = v_texcoord0;
	vec2 t = u_aaParams.xy;
	//    b
	//  d e f
	//    h
	vec3 b = texture2DLod(s_color, uv + vec2(0.0, -t.y), 0.0).rgb;
	vec3 d = texture2DLod(s_color, uv + vec2(-t.x, 0.0), 0.0).rgb;
	vec3 e = texture2DLod(s_color, uv, 0.0).rgb;
	vec3 f = texture2DLod(s_color, uv + vec2(t.x, 0.0), 0.0).rgb;
	vec3 h = texture2DLod(s_color, uv + vec2(0.0, t.y), 0.0).rgb;

	// Min and max of the ring.
	vec3 mn4 = min(min(min(b, d), f), h);
	vec3 mx4 = max(max(max(b, d), f), h);
	// How far each channel can go before it clips at either end, as a fraction of the ring.
	vec3 hitMin = min(mn4, e) / max(4.0 * mx4, vec3_splat(1e-5));
	vec3 hitMax = (1.0 - max(mx4, e)) / min(4.0 * mn4 - 4.0, vec3_splat(-1e-5));
	vec3 lobes = max(-hitMin, hitMax);
	float lobe = max(-RCAS_LIMIT, min(max(lobes.r, max(lobes.g, lobes.b)), 0.0)) * u_fsrParams.x;

	float rcpL = 1.0 / (4.0 * lobe + 1.0);
	vec3 pix = (lobe * b + lobe * d + lobe * h + lobe * f + e) * rcpL;
	gl_FragColor = vec4(clamp(pix, 0.0, 1.0), 1.0);
}
