#include <metal_stdlib>

using namespace metal;
typedef struct
{
   float4 gl_Position [[position]];
   float4 in_texcoord1;
   float4 in_texcoord2;
   float4 in_color;
} RasterizerData;

fragment float4 sky_layer_frag_spv(RasterizerData in [[stage_in]],
          texture2d<half, access::sample> solid_tex [[ texture(0) ]],
          texture2d<half, access::sample> alpha_tex [[ texture(1) ]],
                                   sampler texSampler0 [[sampler(0)]],
                                   sampler texSampler1 [[sampler(1)]]
          )
{
	float4 solid_layer = (float4)solid_tex.sample(texSampler0, in.in_texcoord1.xy);
	float4 alpha_layer = (float4)alpha_tex.sample(texSampler1, in.in_texcoord2.xy);

	return float4((solid_layer.rgb * (1.0f - alpha_layer.a) + alpha_layer.rgb * alpha_layer.a), in.in_color.a);
}
