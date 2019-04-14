#include <metal_stdlib>

using namespace metal;
#include <simd/simd.h>

typedef struct {
   matrix_float4x4 mvp;
   float4 fog; // color, density
} PushConsts;

typedef struct
{
   float4 gl_Position [[position]];
   float4 in_texcoord1;
   float4 in_texcoord2;
   float4 in_color;
} RasterizerData;

typedef struct
{
   float3 in_position  [[attribute(0)]];
   float2 in_texcoord1 [[attribute(1)]];
   float2 in_texcoord2 [[attribute(2)]];
   float4 in_color     [[attribute(3)]];
} SkyLayerVertex;

vertex RasterizerData sky_layer_vert_spv(SkyLayerVertex in [[stage_in]],
                           constant PushConsts &push_constants [[ buffer(0) ]])
{
   RasterizerData out;
	out.gl_Position = push_constants.mvp * float4(in.in_position, 1.0f);
	out.in_texcoord1 = float4(in.in_texcoord1.xy, 0.0f, 0.0f);
	out.in_texcoord2 = float4(in.in_texcoord2.xy, 0.0f, 0.0f);
	out.in_color = in.in_color;
   return out;
}
