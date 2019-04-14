#ifndef mtl_renderstate_h
#define mtl_renderstate_h

#include <simd/simd.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "SDL.h"

#define MAX_BOUND_TEXTURES 4
#define NUM_COMMAND_QUEUES 2

typedef struct MetalRenderPipeline_s
{
   id<MTLRenderPipelineState> state;
   id<MTLDepthStencilState> depthState;
} MetalRenderPipeline_t;

struct MetalRenderState
{
   id<MTLDevice> device;
   
   CAMetalLayer* metal_layer;
   
   SDL_Renderer* current_renderer;
   SDL_Window* current_window;
   
   MTLPixelFormat color_format;
   MTLPixelFormat depth_format;
   
   uint32_t staging_buffer_size;
   
   
   MetalRenderPipeline_t                     basic_alphatest_pipeline[2];
   MetalRenderPipeline_t                     basic_blend_pipeline[2];
   MetalRenderPipeline_t                     basic_notex_blend_pipeline[2];
   MetalRenderPipeline_t                     basic_poly_blend_pipeline;
   MetalRenderPipeline_t                     world_pipelines[WORLD_PIPELINE_COUNT];
   id<MTLFunction>                                world_pipelines_frag_shaders[WORLD_PIPELINE_COUNT];
   MetalRenderPipeline_t                     water_pipeline;
   MetalRenderPipeline_t                     water_blend_pipeline;
   MetalRenderPipeline_t                     raster_tex_warp_pipeline;
   MetalRenderPipeline_t                     particle_pipeline;
   MetalRenderPipeline_t                     sprite_pipeline;
   MetalRenderPipeline_t                     sky_color_pipeline;
   MetalRenderPipeline_t                     sky_box_pipeline;
   MetalRenderPipeline_t                     sky_layer_pipeline;
   MetalRenderPipeline_t                     alias_pipeline;
   MetalRenderPipeline_t                     alias_blend_pipeline;
   MetalRenderPipeline_t                     alias_alphatest_pipeline;
   MetalRenderPipeline_t                     postprocess_pipeline;
   MetalRenderPipeline_t                     screen_warp_pipeline;
   MetalRenderPipeline_t                     cs_tex_warp_pipeline;
   MetalRenderPipeline_t                     showtris_pipeline;
   MetalRenderPipeline_t                     showtris_depth_test_pipeline;
   
   id<MTLComputePipelineState>               screen_warp_compute_pipeline;
   id<MTLComputePipelineState>               cs_tex_warp_compute_pipeline;
   
   id<MTLSamplerState> point_sampler;
   id<MTLSamplerState> point_aniso_sampler;
   
   id<MTLSamplerState> linear_sampler;
   id<MTLSamplerState> linear_aniso_sampler;
   
   id<MTLCommandBuffer> last_submitted_command_buffer;
   id<MTLRenderCommandEncoder> render_encoder;
   id<MTLComputeCommandEncoder> compute_encoder;
   id<MTLBlitCommandEncoder> blit_encoder;
   
   id<MTLSamplerState> current_samplers[MAX_BOUND_TEXTURES];
   id<MTLTexture> current_textures[MAX_BOUND_TEXTURES];
   MetalRenderPipeline_t* current_pipeline;
   
   id<MTLTexture> color_buffers[2];
   id<MTLTexture> depth_buffer;
   dispatch_semaphore_t frame_semaphore;
   
   id<MTLCommandQueue> command_queue;
   id<MTLCommandBuffer> current_command_buffer;
   
   int non_solid_fill;
   
   uint32_t max_texture_dimension;
   uint32_t vbo_alignment;
   
   id<MTLBuffer> fan_index_buffer;
   
   // Matrices
   float                        projection_matrix[16];
   float                        view_matrix[16];
   float                        view_projection_matrix[16];
   
   // Global per-object values
   float push_constants[24];
   
   
   float color_clear_value[4];
   
   
   MTLViewport scene_viewport;
   
   qboolean                     device_idle;
   qboolean                     validation;
   qboolean                     push_constants_dirty;
};

// This prevents objc stuff leaking more into the game code
typedef struct gltexture_metal_s
{
   id<MTLTexture> texture;
   id<MTLSamplerState> sampler;
} gltexture_metal_t;

typedef struct glmodel_metal_s
{
   id<MTLBuffer> vertex_buffer;
   id<MTLBuffer> index_buffer;
} glmodel_metal_t;

extern struct MetalRenderState r_metalstate;

gltexture_metal_t* TexMgr_GetPrivateData(gltexture_t *tex);
glmodel_metal_t* GLMesh_GetPrivateData(qmodel_t *model);

byte * R_VertexAllocate(int size, id<MTLBuffer> * buffer, uint32_t * buffer_offset);
byte * R_IndexAllocate(int size, id<MTLBuffer> * buffer, uint32_t * buffer_offset);
byte * R_UniformAllocate(int size, id<MTLBuffer> * buffer, uint32_t * buffer_offset/*, VkDescriptorSet * descriptor_set*/);


static inline void R_BindPipeline(MetalRenderPipeline_t* pipeline) {
   if(r_metalstate.current_pipeline != pipeline) {
      [r_metalstate.render_encoder setRenderPipelineState:pipeline->state];
      [r_metalstate.render_encoder setDepthStencilState:pipeline->depthState];
      r_metalstate.current_pipeline = pipeline;
   }
}

enum MTLVertexBufferSlots
{
   VBO_PushBuffer=0,
   VBO_UBO=1,
   VBO_Vertex_Start=1,
   VBO_Alias_Vertex_Start=2,
};

void R_UpdatePushConstants(void);

#endif /* mtl_renderstate_h */
