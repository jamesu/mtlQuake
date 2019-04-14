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

typedef struct
{
   float3 in_position   [[attribute(0)]];
   float2 in_texcoord1  [[attribute(1)]];
   float2 in_texcoord2  [[attribute(2)]];
} WorldVertex;

vertex RasterizerData world_vert_spv(WorldVertex in [[stage_in]],
                                     constant PushConsts &push_constants [[ buffer(0) ]]
                                    )
{
   RasterizerData vert;
	vert.in_texcoords.xy = in.in_texcoord1.xy;
	vert.in_texcoords.zw = in.in_texcoord2.xy;
	vert.gl_Position = push_constants.mvp * float4(in.in_position, 1.0f);

	vert.in_fog_frag_coord = vert.gl_Position.w;
   return vert;
}
