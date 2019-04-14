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
   float4 gl_Position [[position]];
   float2 in_texcoord;
   float4 in_color;
   float in_fog_frag_coord;
} RasterizerData;

fragment float4 basic_notex_frag_spv(RasterizerData in [[stage_in]],
                               constant PushConsts &push_constants [[ buffer(0) ]]
                               )
{
   float4 out_frag_color = in.in_color;
   
   float fog = exp(-push_constants.fog.a * push_constants.fog.a * in.in_fog_frag_coord * in.in_fog_frag_coord);
   fog = clamp(fog, 0.0, 1.0);
   out_frag_color = mix(float4(push_constants.fog.rgb, 1.0f), out_frag_color, fog);
   return out_frag_color;
}

