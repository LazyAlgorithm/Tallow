#ifndef TALLOW_CLOUDS_SH
#define TALLOW_CLOUDS_SH
uniform vec4 u_cloudParams; // coverage, density, scale, enabled
uniform vec4 u_cloudWeather; // wind offset XY, altitude, softness
uniform vec4 u_cloudColor;

float cloudHash(vec2 p)
{
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float cloudNoise(vec2 p)
{
    vec2 i = floor(p), f = fract(p);
    vec2 u = f*f*(3.0-2.0*f);
    return mix(mix(cloudHash(i), cloudHash(i+vec2(1.0,0.0)), u.x),
               mix(cloudHash(i+vec2(0.0,1.0)), cloudHash(i+vec2(1.0,1.0)), u.x), u.y);
}
float cloudFBM(vec2 p)
{
    float value = 0.0, amplitude = 0.5;
    for (int i=0; i<5; ++i) {
        value += cloudNoise(p)*amplitude;
        p *= 2.03; amplitude *= 0.5;
    }
    return value / 0.96875;
}
float cloudOpacity(vec2 uv)
{
    float field = cloudFBM(uv) - cloudFBM(uv*3.0)*0.12;
    float threshold = 1.0-u_cloudParams.x;
    return smoothstep(threshold, threshold+max(u_cloudWeather.w,0.001), field)*u_cloudParams.y;
}
vec3 applyProceduralClouds(vec3 sky, vec3 direction, vec3 origin)
{
    if (u_cloudParams.w < 0.5 || direction.y <= 0.001) return sky;
    float t = (u_cloudWeather.z-origin.y)/direction.y;
    if (t <= 0.0) return sky;
    vec2 uv = (origin.xz+direction.xz*t+u_cloudWeather.xy)*u_cloudParams.z;
    float opacity = cloudOpacity(uv)*smoothstep(0.01,0.12,direction.y);
    float sunlight = max(dot(direction,u_sunDir.xyz),0.0);
    vec3 light = u_cloudColor.rgb*(0.55+sunlight*0.45);
    return mix(sky,light,clamp(opacity,0.0,1.0));
}
#endif