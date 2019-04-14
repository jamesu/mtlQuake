#include <metal_stdlib>

using namespace metal;
#include <simd/simd.h>

typedef struct
{
   matrix_float4x4 view_projection_matrix;
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

typedef struct
{
   float2 in_texcoord            [[attribute(0)]];
   float4 in_pose1_position      [[attribute(1)]];
   float3 in_pose1_normal        [[attribute(2)]];
   float4 in_pose2_position      [[attribute(3)]];
   float3 in_pose2_normal        [[attribute(4)]];
} AliasVertex;

float r_avertexnormal_dot(float3 vertexnormal, float3 shade_vector) // from MH
{
   float _dot = dot(vertexnormal, shade_vector);
   // wtf - this reproduces anorm_dots within as reasonable a degree of tolerance as the >= 0 case
   if (_dot < 0.0)
      return 1.0 + _dot * (13.0 / 44.0);
   else
      return 1.0 + _dot;
}

vertex RasterizerData alias_vert_spv(AliasVertex in [[stage_in]],
          constant PushConsts &push_constants [[ buffer(0) ]],
          device UBO &ubo [[buffer(1)]]
          )
{
   RasterizerData vert;
   vert.in_texcoord = in.in_texcoord;
   
   float4 lerped_position = mix(float4(in.in_pose1_position.xyz, 1.0f), float4(in.in_pose2_position.xyz, 1.0f), ubo.shade_blend_vector.a);
   float4 model_space_position = ubo.model_matrix * lerped_position;
   vert.gl_Position = push_constants.view_projection_matrix * model_space_position;
   
   float dot1 = r_avertexnormal_dot(in.in_pose1_normal, ubo.shade_blend_vector.xyz);
   float dot2 = r_avertexnormal_dot(in.in_pose2_normal, ubo.shade_blend_vector.xyz);
   vert.in_color = float4(ubo.light_color.rgb * mix(dot1, dot2, ubo.shade_blend_vector.a), 1.0);
   
   vert.in_fog_frag_coord = vert.gl_Position.w;
   return vert;
}
