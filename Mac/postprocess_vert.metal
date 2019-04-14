
#include <metal_stdlib>

using namespace metal;
#include <simd/simd.h>

typedef struct
{
   float4 gl_Position [[position]];
   float2 in_texcoord;
} RasterizerData;

vertex RasterizerData postprocess_vert_spv(uint vertexID [[vertex_id]])
{
   float4 positions[3] = {
      float4(-1.0f, -1.0f, 0.0f, 1.0f),
      float4(3.0f, -1.0f, 0.0f, 1.0f),
      float4(-1.0f, 3.0f, 0.0f, 1.0f)
   };
   float2 texCoords[3] = {
      float2(0.0f, 0.0f),
      float2(2.0f, 0.0f),
      float2(0.0f, 2.0f)
   };
   
   RasterizerData vert;
   vert.gl_Position = positions[vertexID % 3];
   vert.in_texcoord = texCoords[vertexID % 3];
   return vert;
}


