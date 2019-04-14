#include <metal_stdlib>

using namespace metal;
#include <simd/simd.h>

typedef struct
{
   matrix_float4x4 mvp;
   float4 fog; // color, density
} PushConsts;

typedef struct
{
   matrix_float4x4 model_matrix;
   float4 shade_blend_vector; // blend factor == .a
   float4 light_color;
   float4 entalpha;
   int use_fullbright;
} UBO;

typedef struct
{
   float4 gl_Position [[position]];
   float2 in_texcoord;
   float4 in_color;
   float in_fog_frag_coord;
} RasterizerData;

fragment float4 alias_alphatest_frag_spv(RasterizerData in [[stage_in]],
                               constant PushConsts &push_constants [[ buffer(0) ]],
                               texture2d<half, access::sample> diffuse_tex [[ texture(0) ]],
                               texture2d<half, access::sample> fullbright_tex [[ texture(1) ]],
                               device UBO &ubo [[buffer(1)]],
                               sampler texSampler0 [[sampler(0)]],
                               sampler texSampler1 [[sampler(1)]]
                               )
{
   float4 result = (float4)diffuse_tex.sample(texSampler0, in.in_texcoord.xy);
   if(result.a < 0.666f)
      discard_fragment();
   result *= in.in_color;
   
   if (ubo.use_fullbright)
      result += (float4)fullbright_tex.sample(texSampler1, in.in_texcoord.xy);
   
   result.a = ubo.entalpha.r;
   
   float fog = exp(-push_constants.fog.a * push_constants.fog.a * in.in_fog_frag_coord * in.in_fog_frag_coord);
   fog = clamp(fog, 0.0, 1.0);
   result.rgb = mix(push_constants.fog.rgb, result.rgb, fog);
   
   return result;
}

