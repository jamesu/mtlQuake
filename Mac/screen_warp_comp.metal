#include <metal_stdlib>

using namespace metal;
#include <simd/simd.h>

typedef struct {
   float screen_w;
   float screen_h;
	float aspect_ratio;
	float time;
} PushConsts;

kernel void screen_warp_comp(constant PushConsts &push_constants [[ buffer(0) ]],
                 texture2d<half, access::sample>  input_tex  [[texture(0)]],
                 texture2d<half, access::write> output_image [[texture(1)]],
                 uint2 gid         [[thread_position_in_grid]])
{
	const float CYCLE_X = 3.14159f * 5.0f;
	const float CYCLE_Y = CYCLE_X * push_constants.aspect_ratio;
	const float AMP_X = 1.0f / 300.0f;
	const float AMP_Y = AMP_X * push_constants.aspect_ratio;

	const float posX = float(gid.x) * push_constants.screen_w;
	const float posY = float(gid.y) * push_constants.screen_h;

	const float texX = (posX + (sin(posY * CYCLE_X + push_constants.time) * AMP_X)) * (1.0f - AMP_X * 2.0f) + AMP_X;
   const float texY = (posY + (sin(posX * CYCLE_Y + push_constants.time) * AMP_Y)) * (1.0f - AMP_Y * 2.0f) + AMP_Y;
   
   constexpr sampler s(coord::normalized,
                       address::repeat,
                       filter::linear);
   
   //uint2 texPos((uint)(texX * (1.0/push_constants.screen_w)), (uint)(texY * (1.0/push_constants.screen_h)));
   
   half4 value = input_tex.sample(s, float2(texX, texY));
   output_image.write(value, gid);
}
