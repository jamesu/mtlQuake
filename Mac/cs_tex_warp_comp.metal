#include <metal_stdlib>

using namespace metal;
#include <simd/simd.h>

typedef struct {
	float time;
} PushConsts;

// This matches the turbsin lookup table (gl_warp_sin.h)
float turbsin(float t)
{
	return 8.0f * sin(t * (3.14159f/128.0f));
}

// Copied from gl_warp.c WARPCALC
float warp_calc(float time, float s, float t)
{
	float a = fmod(((t * 2.0f) + (time * (128.0 / 3.14159f))), 256.0f);
	return ((s + turbsin(a)) * (1.0f/64.0f));
}

kernel void cs_tex_warp_comp(constant PushConsts &push_constants [[ buffer(0) ]],
                             texture2d<half, access::sample>  input_tex  [[texture(0)]],
                 texture2d<half, access::write> output_image [[texture(1)]],
                 uint2 gid         [[thread_position_in_grid]])
{
	const float WARPIMAGESIZE_RCP = 1.0f / 512.0f;

	const float posX = float(gid.x) * WARPIMAGESIZE_RCP;
	const float posY = 1.0f - (float(gid.y) * WARPIMAGESIZE_RCP);

	const float texX = warp_calc(push_constants.time, posX * 128.0f, posY * 128.0f);
	const float texY = warp_calc(push_constants.time, posY * 128.0f, posX * 128.0f);
   
   constexpr sampler s(coord::normalized,
                       address::repeat,
                       filter::linear);
   
   half4 value = input_tex.sample(s, float2(texX, texY));
   output_image.write(value, gid);
}
