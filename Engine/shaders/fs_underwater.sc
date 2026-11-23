$input v_texcoord0, v_wpos

// A camera in the water (tallowengine.com/docs/water): over a copy of the picture (s_color), every pixel whose part of the near
// plane is under the surface sees through the water: its colour, thicker with the distance through it (to what is
// seen, or up to the surface), darker with depth, and caustics on what is under the surface. The test is made per
// pixel against the waves, so with the camera half in the water the picture is cut exactly at the waterline.
#include <bgfx_shader.sh>
#include "post.sh"
#include "water.sh"

SAMPLER2D(s_color, 0);
SAMPLER2D(s_depth, 2);

uniform mat4 u_waterInverse;  // the world to the water's rectangle (x, z from -0.5 to 0.5)
uniform vec4 u_waterUnder;    // rgb: the underwater colour (lit), w: visibility (metres)
uniform vec4 u_waterUnderParams; // x: the camera's near distance, y: 1 endless, z: time, w: 1 caustics
uniform vec4 u_sunDir;

void main()
{
	vec2 uv = v_texcoord0;
	vec3 eye = u_postEye.xyz;
	vec3 nearPoint = worldPosition(uv, u_waterUnderParams.x);
	if (u_waterUnderParams.y < 0.5)
	{
		vec3 local = mul(u_waterInverse, vec4(nearPoint, 1.0)).xyz;
		if (abs(local.x) > 0.5 || abs(local.z) > 0.5)
			discard;
	}
	vec3 normal;
	float surface = waterHeight(nearPoint.xz, normal);
	if (nearPoint.y > surface || nearPoint.y < u_waterLevel.y)
		discard;

	float time = u_waterUnderParams.z;
	float visibility = max(u_waterUnder.w, 0.1);
	float depth = texture2D(s_depth, uv).x;
	vec3 ray = normalize(worldPosition(uv, 1.0) - eye);
	float sceneDistance = isSky(depth) || isViewmodel(depth) ? 100000.0 : length(worldPosition(uv, depth) - eye);
	// Looking up, the view leaves the water at the surface: no thicker than that.
	float exitDistance = 100000.0;
	if (ray.y > 0.001)
		exitDistance = max((surface - eye.y) / ray.y, 0.0);
	float distance = min(sceneDistance, exitDistance);

	// The picture wavers a little.
	vec2 waver = vec2(sin(uv.y * 38.0 + time * 2.1), cos(uv.x * 31.0 + time * 1.7)) * 0.0012;
	vec3 scene = texture2D(s_color, uv + waver).rgb;
	if (u_waterUnderParams.w > 0.5 && sceneDistance < exitDistance && sceneDistance < 10000.0)
	{
		vec3 hit = eye + ray * sceneDistance;
		float below = max(surface - hit.y, 0.0);
		scene *= 1.0 + waterCaustics(hit.xz - u_waterLevel.zw * time, time) * 1.4 * clamp(u_sunDir.y, 0.0, 1.0) * exp(-below / visibility);
	}
	// Light fades going down: the water's colour is darker the deeper the camera is.
	float light = exp(-max(surface - eye.y, 0.0) / (visibility * 1.5));
	vec3 water = u_waterUnder.rgb * light;
	float fog = 1.0 - exp(-3.0 * distance / visibility);
	vec3 color = mix(scene * mix(vec3_splat(1.0), u_waterUnder.rgb * 2.5, 0.35), water, fog);
	// The waterline across the lens: a thin darker edge where the surface crosses it.
	color *= mix(0.45, 1.0, smoothstep(0.0, 0.025, surface - nearPoint.y));
	gl_FragColor = vec4(color, 1.0);
}
