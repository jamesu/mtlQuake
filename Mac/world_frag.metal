#include <metal_stdlib>

using namespace metal;
#include <simd/simd.h>

typedef struct
{
   matrix_float4x4 mvp;
   float4 fog; // color, density
   float alpha;
} PushConsts;

typedef struct
{
   float4 gl_Position [[position]];
   float4 in_texcoords;
   float in_fog_frag_coord;
} RasterizerData;

constant bool use_fullbright [[function_constant(0)]];
constant bool use_alpha_test [[function_constant(1)]];
constant bool use_alpha_blend [[function_constant(2)]];

fragment float4 world_frag_spv(RasterizerData in [[stage_in]],
                               constant PushConsts &push_constants [[ buffer(0) ]],
                               texture2d<half, access::sample> diffuse_tex [[ texture(0) ]],
                               texture2d<half, access::sample> lightmap_tex [[ texture(1) ]],
                               texture2d<half, access::sample> fullbright_tex [[ texture(2) ]],
                               sampler texSampler0 [[sampler(0)]],
                               sampler texSampler1 [[sampler(1)]],
                               sampler texSampler2 [[sampler(2)]]
                               )
{
   float4 out_frag_color;
   
	float4 diffuse = (float4)diffuse_tex.sample(texSampler0, in.in_texcoords.xy);
	if (use_alpha_test && diffuse.a < 0.666f)
		discard_fragment();

	float4 light = (float4)lightmap_tex.sample(texSampler1, in.in_texcoords.zw) * 2.0f;
	out_frag_color = diffuse * light;

	if (use_fullbright)
	{
		float4 fullbright = (float4)fullbright_tex.sample(texSampler2, in.in_texcoords.xy);
		out_frag_color += fullbright;
	}

	float fog = exp(-push_constants.fog.a * push_constants.fog.a * in.in_fog_frag_coord * in.in_fog_frag_coord);
	fog = clamp(fog, 0.0, 1.0);
	out_frag_color = mix(float4(push_constants.fog.rgb, 1.0f), out_frag_color, fog);

	if (use_alpha_blend)
		out_frag_color.a = push_constants.alpha;
   
   return out_frag_color;
}
