// Motion vectors, written by the depth pass (vs_depth_vel.sc, vs_depth_albedo_vel.sc, fs_depth_sky_vel.sc) for the
// temporal antialiasing and the temporal upscalers.
//
// Convention (RenderView.Velocity, tallowengine.com/docs/temporal): the velocity texture holds, per pixel, where the
// surface seen there was in the PREVIOUS frame, as an offset from the pixel in the scene's render-resolution pixels:
// previousPixel = currentPixel + velocity.xy. x grows to the right and y DOWN the picture, whatever the graphics API's
// texture origin is. The camera's jitter is not in it: both positions are projected without it.
// The z channel is 1 where the vector cannot be trusted (a deforming mesh: cloth, a soft body, a rope, a skinned
// character, a custom vertex shader's movement, which move apart from their object), and 0 elsewhere. The temporal
// antialiasing then keeps less history there; the upscalers read x and y only.

uniform vec4 u_velParams;     // x, y: the scene's size in pixels; z: last frame's time in seconds (for the wind); w: 1 when this draw's motion is not known (below)

vec2 tw_velocity(vec4 tw_cur, vec4 tw_prev)
{
	// Behind the camera last frame (or now): no usable history.
	if (tw_cur.w <= 0.0001 || tw_prev.w <= 0.0001)
		return vec2(0.0, 0.0);
	vec2 tw_d = tw_prev.xy / tw_prev.w - tw_cur.xy / tw_cur.w;
	return vec2(tw_d.x * 0.5 * u_velParams.x, -tw_d.y * 0.5 * u_velParams.y);
}
