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
   float4 in_texcoord;
   float4 in_color;
   float in_fog_frag_coord;
} RasterizerData;

struct BasicVertex
{
   float3 in_position  [[attribute(0)]];
   float2 in_texcoord  [[attribute(1)]];
   float4 in_color     [[attribute(2)]];
};

vertex RasterizerData basic_vert_spv(BasicVertex in [[stage_in]],
         constant PushConsts &push_constants [[ buffer(0) ]])
{
   RasterizerData vert;
	vert.gl_Position = push_constants.mvp * float4(in.in_position, 1.0f);
	vert.in_texcoord = float4(in.in_texcoord.xy, 0.0f, 0.0f);
	vert.in_color = in.in_color;
	vert.in_fog_frag_coord = vert.gl_Position.w;
   return vert;
}
