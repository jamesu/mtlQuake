#include <metal_stdlib>
   
using namespace metal;
typedef struct
{
   float gamma;
   float contrast;
} PushConsts;

typedef struct
{
   float4 gl_Position [[position]];
   float2 in_texcoord;
} RasterizerData;

fragment float4 postprocess_frag_spv(RasterizerData in [[stage_in]],
                                     texture2d<float> normal [[texture(0)]],
                                   constant PushConsts &push_constants [[ buffer(0) ]]
                                   )
{
   constexpr sampler ssampler(coord::normalized);
   float3 frag = normal.sample(ssampler, in.in_texcoord).rgb;
   return float4(pow(frag.rgb * push_constants.contrast, float3(push_constants.gamma)), 1.0);
}
