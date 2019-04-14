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
} RasterizerData;

typedef struct
{
   float3 in_position [[attribute(0)]];
} ShowTrisVertex;

vertex RasterizerData showtris_vert_spv(ShowTrisVertex in [[stage_in]],
          constant PushConsts &push_constants [[ buffer(0) ]])
{
   RasterizerData vert;
   vert.gl_Position = push_constants.mvp * float4(in.in_position, 1.0f);
   return vert;
}
