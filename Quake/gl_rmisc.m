/*
Copyright (C) 1996-2001 Id Software, Inc.
Copyright (C) 2002-2009 John Fitzgibbons and others
Copyright (C) 2007-2008 Kristian Duske
Copyright (C) 2010-2014 QuakeSpasm developers
Copyright (C) 2016 Axel Gneiting
Copyright (C) 2019 James S Urquhart

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

*/
// r_misc.c

#include "quakedef.h"
#include "float.h"
#include "mtl_renderstate.h"

#include <assert.h>

//johnfitz -- new cvars
extern cvar_t r_clearcolor;
extern cvar_t r_drawflat;
extern cvar_t r_flatlightstyles;
extern cvar_t gl_fullbrights;
extern cvar_t gl_farclip;
extern cvar_t r_waterquality;
extern cvar_t r_waterwarp;
extern cvar_t r_waterwarpcompute;
extern cvar_t r_oldskyleaf;
extern cvar_t r_drawworld;
extern cvar_t r_showtris;
extern cvar_t r_showbboxes;
extern cvar_t r_lerpmodels;
extern cvar_t r_lerpmove;
extern cvar_t r_nolerp_list;
extern cvar_t r_noshadow_list;
//johnfitz
extern cvar_t gl_zfix; // QuakeSpasm z-fighting fix

extern gltexture_t *playertextures[MAX_SCOREBOARD]; //johnfitz

int num_metal_tex_allocations = 0;
int num_metal_bmodel_allocations = 0;
int num_metal_mesh_allocations = 0;
int num_metal_misc_allocations = 0;
int num_metal_dynbuf_allocations = 0;

/*
================
Staging
================
*/
#define NUM_STAGING_BUFFERS		2

typedef struct
{
	//VkBuffer			buffer;
	//VkCommandBuffer		command_buffer;
	//VkFence				fence;
	int					current_offset;
	qboolean			submitted;
	unsigned char *		data;
} stagingbuffer_t;

static stagingbuffer_t	staging_buffers[NUM_STAGING_BUFFERS];
static int				current_staging_buffer = 0;

/*
================
Dynamic vertex/index & uniform buffer
================
*/
#define DYNAMIC_VERTEX_BUFFER_SIZE_KB	2048
#define DYNAMIC_INDEX_BUFFER_SIZE_KB	4096
#define DYNAMIC_UNIFORM_BUFFER_SIZE_KB	1024
#define NUM_DYNAMIC_BUFFERS				4
#define MAX_UNIFORM_ALLOC				2048

typedef struct
{
	id<MTLBuffer>			buffer;
	uint32_t			current_offset;
	unsigned char *		data;
} dynbuffer_t;

static dynbuffer_t		dyn_vertex_buffers[NUM_DYNAMIC_BUFFERS];
static dynbuffer_t		dyn_index_buffers[NUM_DYNAMIC_BUFFERS];
static dynbuffer_t		dyn_uniform_buffers[NUM_DYNAMIC_BUFFERS];
static int				current_dyn_buffer_index = 0;

void R_VulkanMemStats_f (void);

/*
====================
GL_Fullbrights_f -- johnfitz
====================
*/
static void GL_Fullbrights_f (cvar_t *var)
{
	TexMgr_ReloadNobrightImages ();
}

/*
====================
R_SetClearColor_f -- johnfitz
====================
*/
static void R_SetClearColor_f (cvar_t *var)
{
	byte	*rgb;
	int		s;

	s = (int)r_clearcolor.value & 0xFF;
	rgb = (byte*)(d_8to24table + s);
	r_metalstate.color_clear_value[0] = rgb[0]/255;
	r_metalstate.color_clear_value[1] = rgb[1]/255;
	r_metalstate.color_clear_value[2] = rgb[2]/255;
	r_metalstate.color_clear_value[3] = 0.0f;
}

/*
====================
R_Novis_f -- johnfitz
====================
*/
static void R_VisChanged (cvar_t *var)
{
	extern int vis_changed;
	vis_changed = 1;
}

/*
===============
R_Model_ExtraFlags_List_f -- johnfitz -- called when r_nolerp_list or r_noshadow_list cvar changes
===============
*/
static void R_Model_ExtraFlags_List_f (cvar_t *var)
{
	int i;
	for (i=0; i < MAX_MODELS; i++)
		Mod_SetExtraFlags (cl.model_precache[i]);
}

/*
====================
R_SetWateralpha_f -- ericw
====================
*/
static void R_SetWateralpha_f (cvar_t *var)
{
	map_wateralpha = var->value;
}

/*
====================
R_SetLavaalpha_f -- ericw
====================
*/
static void R_SetLavaalpha_f (cvar_t *var)
{
	map_lavaalpha = var->value;
}

/*
====================
R_SetTelealpha_f -- ericw
====================
*/
static void R_SetTelealpha_f (cvar_t *var)
{
	map_telealpha = var->value;
}

/*
====================
R_SetSlimealpha_f -- ericw
====================
*/
static void R_SetSlimealpha_f (cvar_t *var)
{
	map_slimealpha = var->value;
}

/*
====================
GL_WaterAlphaForSurfface -- ericw
====================
*/
float GL_WaterAlphaForSurface (msurface_t *fa)
{
	if (fa->flags & SURF_DRAWLAVA)
		return map_lavaalpha > 0 ? map_lavaalpha : map_wateralpha;
	else if (fa->flags & SURF_DRAWTELE)
		return map_telealpha > 0 ? map_telealpha : map_wateralpha;
	else if (fa->flags & SURF_DRAWSLIME)
		return map_slimealpha > 0 ? map_slimealpha : map_wateralpha;
	else
		return map_wateralpha;
}

/*
===============
R_CreateStagingBuffers
===============
*/
static void R_CreateStagingBuffers()
{
	int i;
	const int align_mod = r_metalstate.staging_buffer_size % r_metalstate.vbo_alignment;
	const int aligned_size = ((r_metalstate.staging_buffer_size % r_metalstate.vbo_alignment) == 0)
	? r_metalstate.staging_buffer_size
	: (r_metalstate.staging_buffer_size + r_metalstate.vbo_alignment - align_mod);
	
	
	for (i = 0; i < NUM_STAGING_BUFFERS; ++i)
	{
		staging_buffers[i].current_offset = 0;
		staging_buffers[i].submitted = false;
		staging_buffers[i].data = malloc(aligned_size);
	}
	
}

/*
===============
R_DestroyStagingBuffers
===============
*/
static void R_DestroyStagingBuffers()
{
	int i;

	for (i = 0; i < NUM_STAGING_BUFFERS; ++i)
	{
		free(staging_buffers[i].data);
	}
}

/*
===============
R_InitStagingBuffers
===============
*/
void R_InitStagingBuffers()
{
	// In this case, init buffers{
	int i;
	
	Con_Printf("Initializing staging\n");
	
	R_CreateStagingBuffers();
	
	for (i = 0; i < NUM_STAGING_BUFFERS; ++i)
	{
		
	}
}

/*
===============
R_SubmitStagingBuffer
===============
*/
static void R_SubmitStagingBuffer(int index)
{
	// In this case, submit buffers to GPU
	staging_buffers[index].submitted = true;
	current_staging_buffer = (current_staging_buffer + 1) % NUM_STAGING_BUFFERS;
}

/*
===============
R_SubmitStagingBuffers
===============
*/
void R_SubmitStagingBuffers()
{
	int i;
	for (i = 0; i<NUM_STAGING_BUFFERS; ++i)
	{
		if (!staging_buffers[i].submitted && staging_buffers[i].current_offset > 0)
			R_SubmitStagingBuffer(i);
	}
}

/*
===============
R_FlushStagingBuffer
===============
*/
static void R_FlushStagingBuffer(stagingbuffer_t * staging_buffer)
{
	// In this case, ensures staging buffer is ready to be reused
	staging_buffer->current_offset = 0;
	staging_buffer->submitted = false;
}

/*
===============
R_StagingAllocate
===============
*/
byte * R_StagingAllocate(int size, int alignment, int * buffer_offset)
{
	if (size > r_metalstate.staging_buffer_size)
	{
		R_SubmitStagingBuffers();
		
		for (int i = 0; i < NUM_STAGING_BUFFERS; ++i)
			R_FlushStagingBuffer(&staging_buffers[i]);
		
		r_metalstate.staging_buffer_size = size;
		
		R_DestroyStagingBuffers();
		R_CreateStagingBuffers();
	}
	
	stagingbuffer_t * staging_buffer = &staging_buffers[current_staging_buffer];
	const int align_mod = staging_buffer->current_offset % alignment;
	staging_buffer->current_offset = ((staging_buffer->current_offset % alignment) == 0)
		? staging_buffer->current_offset
		: (staging_buffer->current_offset + alignment - align_mod);
	
	if ((staging_buffer->current_offset + size) >= r_metalstate.staging_buffer_size && !staging_buffer->submitted)
		R_SubmitStagingBuffer(current_staging_buffer);
	
	staging_buffer = &staging_buffers[current_staging_buffer];
		R_FlushStagingBuffer(staging_buffer);
	
	//if (command_buffer)
	//	*command_buffer = staging_buffer->command_buffer;
	//if (buffer)
	//	*buffer = staging_buffer->buffer;
	if (buffer_offset)
		*buffer_offset = staging_buffer->current_offset;
	
	unsigned char *data = staging_buffer->data + staging_buffer->current_offset;
	staging_buffer->current_offset += size;
	
	return data;
}

/*
===============
R_InitDynamicVertexBuffers
===============
*/
static void R_InitDynamicVertexBuffers()
{
	int i;
	
	Con_Printf("Initializing dynamic vertex buffers\n");
	
	NSError* err = nil;
	
	for (i = 0; i < NUM_DYNAMIC_BUFFERS; ++i)
	{
		dyn_vertex_buffers[i].current_offset = 0;
		dyn_vertex_buffers[i].buffer = [r_metalstate.device newBufferWithLength:DYNAMIC_VERTEX_BUFFER_SIZE_KB * 1024 options:
		 MTLResourceCPUCacheModeDefaultCache];
		
		if (!dyn_vertex_buffers[i].buffer)
			Sys_Error("vkCreateBuffer failed");
		
		dyn_vertex_buffers[i].data = dyn_vertex_buffers[i].buffer.contents;
		dyn_vertex_buffers[i].buffer.label = @"Dynamic Vertex Buffer";
		num_metal_dynbuf_allocations += 1;
	}
}

/*
===============
R_InitDynamicIndexBuffers
===============
*/
static void R_InitDynamicIndexBuffers()
{
	int i;

	Con_Printf("Initializing dynamic index buffers\n");
	
	NSError* err = nil;
	
	for (i = 0; i < NUM_DYNAMIC_BUFFERS; ++i)
	{
		dyn_index_buffers[i].current_offset = 0;
		dyn_index_buffers[i].buffer = [r_metalstate.device newBufferWithLength:DYNAMIC_INDEX_BUFFER_SIZE_KB * 1024 options:
												  MTLResourceCPUCacheModeDefaultCache];
		
		if (!dyn_index_buffers[i].buffer)
			Sys_Error("vkCreateBuffer failed");
		
		dyn_index_buffers[i].data = dyn_index_buffers[i].buffer.contents;
		dyn_index_buffers[i].buffer.label = @"Dynamic Index Buffer";
		num_metal_dynbuf_allocations += 1;
	}
}

/*
===============
R_InitDynamicUniformBuffers
===============
*/
static void R_InitDynamicUniformBuffers()
{
	int i;

	Con_Printf("Initializing dynamic uniform buffers\n");
	
	NSError* err = nil;
	
	for (i = 0; i < NUM_DYNAMIC_BUFFERS; ++i)
	{
		dyn_uniform_buffers[i].current_offset = 0;
		dyn_uniform_buffers[i].buffer = [r_metalstate.device newBufferWithLength:DYNAMIC_UNIFORM_BUFFER_SIZE_KB * 1024 options:
												 MTLResourceCPUCacheModeDefaultCache];
		
		if (!dyn_uniform_buffers[i].buffer)
			Sys_Error("vkCreateBuffer failed");
		
		dyn_uniform_buffers[i].buffer.label = @"Dynamic Uniform Buffer";
		dyn_uniform_buffers[i].data = dyn_uniform_buffers[i].buffer.contents;
		num_metal_dynbuf_allocations += 1;
	}
}

/*
===============
R_InitFanIndexBuffer
===============
*/
static void R_InitFanIndexBuffer()
{
	const int bufferSize = sizeof(uint16_t) * FAN_INDEX_BUFFER_SIZE;
	r_metalstate.fan_index_buffer = [r_metalstate.device newBufferWithLength:bufferSize options:
							  MTLResourceCPUCacheModeDefaultCache];
	
	if (!r_metalstate.fan_index_buffer )
		Sys_Error("vkCreateBuffer failed");
	
	r_metalstate.fan_index_buffer.label = @"Quad index buffer";

	{
		//VkBuffer staging_buffer;
		//VkCommandBuffer command_buffer;
		int staging_offset;
		int current_index = 0;
		int i;
		uint16_t * staging_memory = (uint16_t*)R_StagingAllocate(bufferSize, 1, &staging_offset);

		for (i = 0; i < FAN_INDEX_BUFFER_SIZE / 3; ++i)
		{
			staging_memory[current_index++] = 0;
			staging_memory[current_index++] = 1 + i;
			staging_memory[current_index++] = 2 + i;
		}

		void* bufferData = r_metalstate.fan_index_buffer.contents;
		memcpy(bufferData, staging_memory, bufferSize);
		num_metal_dynbuf_allocations += 1;
		//[r_metalstate.fan_index_buffer didModifyRange:NSMakeRange(0, bufferSize)];
	}
}

/*
===============
R_SwapDynamicBuffers
===============
*/
void R_SwapDynamicBuffers()
{
	current_dyn_buffer_index = (current_dyn_buffer_index + 1) % NUM_DYNAMIC_BUFFERS;
	dyn_vertex_buffers[current_dyn_buffer_index].current_offset = 0;
	dyn_index_buffers[current_dyn_buffer_index].current_offset = 0;
	dyn_uniform_buffers[current_dyn_buffer_index].current_offset = 0;
}

/*
===============
R_FlushDynamicBuffers
===============
*/
void R_FlushDynamicBuffers()
{
	int i;
	
	return; // not needed
	
	for (i=0; i<NUM_DYNAMIC_BUFFERS; i++)
	{
		if (dyn_index_buffers[current_dyn_buffer_index].current_offset != 0)
		{
			[dyn_index_buffers[current_dyn_buffer_index].buffer didModifyRange:NSMakeRange(0, dyn_index_buffers[current_dyn_buffer_index].current_offset)];
		}
		if (dyn_vertex_buffers[current_dyn_buffer_index].current_offset != 0)
		{
			[dyn_vertex_buffers[current_dyn_buffer_index].buffer didModifyRange:NSMakeRange(0, dyn_vertex_buffers[current_dyn_buffer_index].current_offset)];
		}
		if (dyn_uniform_buffers[current_dyn_buffer_index].current_offset != 0)
		{
			[dyn_uniform_buffers[current_dyn_buffer_index].buffer didModifyRange:NSMakeRange(0, dyn_uniform_buffers[current_dyn_buffer_index].current_offset)];
		}
	}
}

/*
===============
R_VertexAllocate
===============
*/
byte * R_VertexAllocate(int size, id<MTLBuffer> * buffer, uint32_t * buffer_offset)
{
	dynbuffer_t *dyn_vb = &dyn_vertex_buffers[current_dyn_buffer_index];

	if ((dyn_vb->current_offset + size) > (DYNAMIC_VERTEX_BUFFER_SIZE_KB * 1024))
		Sys_Error("Out of dynamic vertex buffer space, increase DYNAMIC_VERTEX_BUFFER_SIZE_KB");

	*buffer = dyn_vb->buffer;
	*buffer_offset = dyn_vb->current_offset;

	unsigned char *data = dyn_vb->data + dyn_vb->current_offset;
	dyn_vb->current_offset += size;

	return data;
}

/*
===============
R_IndexAllocate
===============
*/
byte * R_IndexAllocate(int size, id<MTLBuffer> * buffer, uint32_t * buffer_offset)
{
	// Align to 4 bytes because we allocate both uint16 and uint32
	// index buffers and alignment must match index size
	const int align_mod = size % 4;
	const int aligned_size = ((size % 4) == 0) ? size : (size + 4 - align_mod);

	dynbuffer_t *dyn_ib = &dyn_index_buffers[current_dyn_buffer_index];

	if ((dyn_ib->current_offset + aligned_size) > (DYNAMIC_INDEX_BUFFER_SIZE_KB * 1024))
		Sys_Error("Out of dynamic index buffer space, increase DYNAMIC_INDEX_BUFFER_SIZE_KB");

	*buffer = dyn_ib->buffer;
	*buffer_offset = dyn_ib->current_offset;

	unsigned char *data = dyn_ib->data + dyn_ib->current_offset;
	dyn_ib->current_offset += aligned_size;

	return data;
}

/*
===============
R_UniformAllocate

UBO offsets need to be 256 byte aligned on NVIDIA hardware
This is also the maximum required alignment by the Vulkan spec
===============
*/
byte * R_UniformAllocate(int size, id<MTLBuffer> * buffer, uint32_t * buffer_offset)
{
	if (size > MAX_UNIFORM_ALLOC)
		Sys_Error("Increase MAX_UNIFORM_ALLOC");

	const int align_mod = size % 256;
	const int aligned_size = ((size % 256) == 0) ? size : (size + 256 - align_mod);

	dynbuffer_t *dyn_ub = &dyn_uniform_buffers[current_dyn_buffer_index];

	if ((dyn_ub->current_offset + MAX_UNIFORM_ALLOC) > (DYNAMIC_UNIFORM_BUFFER_SIZE_KB * 1024))
		Sys_Error("Out of dynamic uniform buffer space, increase DYNAMIC_UNIFORM_BUFFER_SIZE_KB");

	*buffer = dyn_ub->buffer;
	*buffer_offset = dyn_ub->current_offset;

	unsigned char *data = dyn_ub->data + dyn_ub->current_offset;
	dyn_ub->current_offset += aligned_size;

	//*descriptor_set = ubo_descriptor_sets[current_dyn_buffer_index];

	return data;
}

/*
===============
R_InitGPUBuffers
===============
*/
void R_InitGPUBuffers()
{
	R_InitDynamicVertexBuffers();
	R_InitDynamicIndexBuffers();
	R_InitDynamicUniformBuffers();
	R_InitFanIndexBuffer();
}

/*
===============
R_CreateDescriptorSetLayouts
===============
*/
void R_CreateDescriptorSetLayouts()
{
}

/*
===============
R_CreateDescriptorPool
===============
*/
void R_CreateDescriptorPool()
{
}

/*
===============
R_CreatePipelineLayouts
===============
*/
void R_CreatePipelineLayouts()
{
	
	
#ifdef METAL_WIP
	Con_Printf("Creating pipeline layouts\n");

	VkResult err;

	// Basic
	VkDescriptorSetLayout basic_descriptor_set_layouts[1] = { vulkan_globals.single_texture_set_layout };
	
	VkPushConstantRange push_constant_range;
	memset(&push_constant_range, 0, sizeof(push_constant_range));
	push_constant_range.offset = 0;
	push_constant_range.size = 21 * sizeof(float);
	push_constant_range.stageFlags = VK_SHADER_STAGE_ALL_GRAPHICS;

	VkPipelineLayoutCreateInfo pipeline_layout_create_info;
	memset(&pipeline_layout_create_info, 0, sizeof(pipeline_layout_create_info));
	pipeline_layout_create_info.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
	pipeline_layout_create_info.setLayoutCount = 1;
	pipeline_layout_create_info.pSetLayouts = basic_descriptor_set_layouts;
	pipeline_layout_create_info.pushConstantRangeCount = 1;
	pipeline_layout_create_info.pPushConstantRanges = &push_constant_range;

	err = vkCreatePipelineLayout(vulkan_globals.device, &pipeline_layout_create_info, NULL, &vulkan_globals.basic_pipeline_layout);
	if (err != VK_SUCCESS)
		Sys_Error("vkCreatePipelineLayout failed");

	// World
	VkDescriptorSetLayout world_descriptor_set_layouts[3] = {
		vulkan_globals.single_texture_set_layout,
		vulkan_globals.single_texture_set_layout,
		vulkan_globals.single_texture_set_layout
	};

	pipeline_layout_create_info.setLayoutCount = 3;
	pipeline_layout_create_info.pSetLayouts = world_descriptor_set_layouts;

	err = vkCreatePipelineLayout(vulkan_globals.device, &pipeline_layout_create_info, NULL, &vulkan_globals.world_pipeline_layout);
	if (err != VK_SUCCESS)
		Sys_Error("vkCreatePipelineLayout failed");

	// Alias
	VkDescriptorSetLayout alias_descriptor_set_layouts[3] = {
		vulkan_globals.single_texture_set_layout,
		vulkan_globals.single_texture_set_layout,
		vulkan_globals.ubo_set_layout
	};

	pipeline_layout_create_info.setLayoutCount = 3;
	pipeline_layout_create_info.pSetLayouts = alias_descriptor_set_layouts;

	err = vkCreatePipelineLayout(vulkan_globals.device, &pipeline_layout_create_info, NULL, &vulkan_globals.alias_pipeline_layout);
	if (err != VK_SUCCESS)
		Sys_Error("vkCreatePipelineLayout failed");

	// Sky
	VkDescriptorSetLayout sky_layer_descriptor_set_layouts[2] = {
		vulkan_globals.single_texture_set_layout,
		vulkan_globals.single_texture_set_layout,
	};

	pipeline_layout_create_info.setLayoutCount = 2;
	pipeline_layout_create_info.pSetLayouts = sky_layer_descriptor_set_layouts;

	err = vkCreatePipelineLayout(vulkan_globals.device, &pipeline_layout_create_info, NULL, &vulkan_globals.sky_layer_pipeline_layout);
	if (err != VK_SUCCESS)
		Sys_Error("vkCreatePipelineLayout failed");

	// Postprocess
	VkDescriptorSetLayout postprocess_descriptor_set_layouts[1] = {
		vulkan_globals.input_attachment_set_layout,
	};

	memset(&push_constant_range, 0, sizeof(push_constant_range));
	push_constant_range.offset = 0;
	push_constant_range.size = 2 * sizeof(float);
	push_constant_range.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;

	pipeline_layout_create_info.setLayoutCount = 1;
	pipeline_layout_create_info.pSetLayouts = postprocess_descriptor_set_layouts;
	pipeline_layout_create_info.pushConstantRangeCount = 1;
	pipeline_layout_create_info.pPushConstantRanges = &push_constant_range;

	err = vkCreatePipelineLayout(vulkan_globals.device, &pipeline_layout_create_info, NULL, &vulkan_globals.postprocess_pipeline_layout);
	if (err != VK_SUCCESS)
		Sys_Error("vkCreatePipelineLayout failed");

	// Screen warp
	VkDescriptorSetLayout screen_warp_descriptor_set_layouts[1] = {
		vulkan_globals.screen_warp_set_layout,
	};

	memset(&push_constant_range, 0, sizeof(push_constant_range));
	push_constant_range.offset = 0;
	push_constant_range.size = 4 * sizeof(float);
	push_constant_range.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;

	pipeline_layout_create_info.setLayoutCount = 1;
	pipeline_layout_create_info.pSetLayouts = screen_warp_descriptor_set_layouts;
	pipeline_layout_create_info.pushConstantRangeCount = 1;
	pipeline_layout_create_info.pPushConstantRanges = &push_constant_range;

	err = vkCreatePipelineLayout(vulkan_globals.device, &pipeline_layout_create_info, NULL, &vulkan_globals.screen_warp_pipeline_layout);
	if (err != VK_SUCCESS)
		Sys_Error("vkCreatePipelineLayout failed");

	// Texture warp
	VkDescriptorSetLayout tex_warp_descriptor_set_layouts[2] = {
		vulkan_globals.single_texture_set_layout,
		vulkan_globals.single_texture_cs_write_set_layout,
	};

	memset(&push_constant_range, 0, sizeof(push_constant_range));
	push_constant_range.offset = 0;
	push_constant_range.size = 1 * sizeof(float);
	push_constant_range.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;

	pipeline_layout_create_info.setLayoutCount = 2;
	pipeline_layout_create_info.pSetLayouts = tex_warp_descriptor_set_layouts;
	pipeline_layout_create_info.pushConstantRangeCount = 1;
	pipeline_layout_create_info.pPushConstantRanges = &push_constant_range;

	err = vkCreatePipelineLayout(vulkan_globals.device, &pipeline_layout_create_info, NULL, &vulkan_globals.cs_tex_warp_pipeline_layout);
	if (err != VK_SUCCESS)
		Sys_Error("vkCreatePipelineLayout failed");

	// Show triangles
	pipeline_layout_create_info.setLayoutCount = 0;
	pipeline_layout_create_info.pushConstantRangeCount = 0;

	err = vkCreatePipelineLayout(vulkan_globals.device, &pipeline_layout_create_info, NULL, &vulkan_globals.showtris_pipeline_layout);
	if (err != VK_SUCCESS)
		Sys_Error("vkCreatePipelineLayout failed");
#endif
}


/*
===============
R_InitSamplers
===============
*/
void R_InitSamplers()
{
	Con_Printf("Initializing samplers\n");

	if (r_metalstate.point_sampler == nil)
	{
		MTLSamplerDescriptor* desc = [[MTLSamplerDescriptor alloc] init];
		
		desc.minFilter = MTLSamplerMinMagFilterNearest;
		desc.magFilter = MTLSamplerMinMagFilterNearest;
		desc.sAddressMode = MTLSamplerAddressModeRepeat;
		desc.tAddressMode = MTLSamplerAddressModeRepeat;
		desc.rAddressMode = MTLSamplerAddressModeRepeat;
		desc.mipFilter = MTLSamplerMinMagFilterLinear;
		desc.normalizedCoordinates = YES;
		desc.label = @"point";
		
		r_metalstate.point_sampler = [r_metalstate.device newSamplerStateWithDescriptor:desc];
		if (!r_metalstate.point_sampler)
			Sys_Error("vkCreateSampler failed");
		
		desc.label = @"point_aniso";
		desc.maxAnisotropy = 2; // TODO
		
		r_metalstate.point_aniso_sampler = [r_metalstate.device newSamplerStateWithDescriptor:desc];
		if (!r_metalstate.point_aniso_sampler)
			Sys_Error("vkCreateSampler failed");
		
		desc.label = @"linear";
		desc.maxAnisotropy = 1;
		desc.minFilter = MTLSamplerMinMagFilterLinear;
		desc.magFilter = MTLSamplerMinMagFilterLinear;
		
		r_metalstate.linear_sampler = [r_metalstate.device newSamplerStateWithDescriptor:desc];
		if (!r_metalstate.linear_sampler)
			Sys_Error("vkCreateSampler failed");
		
		desc.label = @"linear_aniso";
		desc.maxAnisotropy = 2; // TODO
		
		r_metalstate.linear_aniso_sampler = [r_metalstate.device newSamplerStateWithDescriptor:desc];
		if (!r_metalstate.linear_aniso_sampler)
			Sys_Error("vkCreateSampler failed");
	}

	TexMgr_UpdateTextureDescriptorSets();
}

static void R_CreateMetalPipeline(MetalRenderPipeline_t* pipeline, MTLRenderPipelineDescriptor* pipelineDesc, MTLDepthStencilDescriptor* depthDesc)
{
	NSError* err = nil;
	
	pipeline->state = [r_metalstate.device newRenderPipelineStateWithDescriptor:pipelineDesc error:&err];
	pipeline->depthState = [r_metalstate.device newDepthStencilStateWithDescriptor:depthDesc];
	
	if (err)
	{
		Sys_Error("newRenderPipelineStateWithDescriptor failed: %s", [[err description] UTF8String]);
	}
}

/*
===============
R_CreatePipelines
===============
*/
void R_CreatePipelines()
{
	int render_pass;
	int alpha_blend, alpha_test, fullbright_enabled;
	NSError* err;

	Con_Printf("Creating pipelines\n");
	id<MTLLibrary> defaultLibrary = [r_metalstate.device newDefaultLibrary];
	
	id<MTLFunction> basic_vert_module = [defaultLibrary newFunctionWithName:@"basic_vert_spv"];
	id<MTLFunction> basic_frag_module = [defaultLibrary newFunctionWithName:@"basic_frag_spv"];
	id<MTLFunction> basic_alphatest_frag_module = [defaultLibrary newFunctionWithName:@"basic_alphatest_frag_spv"];
	id<MTLFunction> basic_notex_frag_module = [defaultLibrary newFunctionWithName:@"basic_notex_frag_spv"];
	id<MTLFunction> world_vert_module = [defaultLibrary newFunctionWithName:@"world_vert_spv"];
	id<MTLFunction> world_frag_module = [defaultLibrary newFunctionWithName:@"world_frag_spv"];
	id<MTLFunction> alias_vert_module = [defaultLibrary newFunctionWithName:@"alias_vert_spv"];
	id<MTLFunction> alias_frag_module = [defaultLibrary newFunctionWithName:@"alias_frag_spv"];
	id<MTLFunction> alias_alphatest_frag_module = [defaultLibrary newFunctionWithName:@"alias_alphatest_frag_spv"];
	id<MTLFunction> sky_layer_vert_module = [defaultLibrary newFunctionWithName:@"sky_layer_vert_spv"];
	id<MTLFunction> sky_layer_frag_module = [defaultLibrary newFunctionWithName:@"sky_layer_frag_spv"];
	id<MTLFunction> postprocess_vert_module = [defaultLibrary newFunctionWithName:@"postprocess_vert_spv"];
	id<MTLFunction> postprocess_frag_module = [defaultLibrary newFunctionWithName:@"postprocess_frag_spv"];
	id<MTLFunction> screen_warp_comp_module = [defaultLibrary newFunctionWithName:@"screen_warp_comp"];
	//id<MTLFunction> screen_warp_rgba8_comp_module = [defaultLibrary newFunctionWithName:@"screen_warp_rgba8_comp"];
	id<MTLFunction> cs_tex_warp_module = [defaultLibrary newFunctionWithName:@"cs_tex_warp_comp"];
	id<MTLFunction> showtris_vert_module = [defaultLibrary newFunctionWithName:@"showtris_vert_spv"];
	id<MTLFunction> showtris_frag_module = [defaultLibrary newFunctionWithName:@"showtris_frag_spv"];
	
	MTLDepthStencilDescriptor* depthStateDesc = [[MTLDepthStencilDescriptor alloc] init];
	depthStateDesc.depthCompareFunction = MTLCompareFunctionAlways; // MTLCompareFunctionLessEqual
	depthStateDesc.depthWriteEnabled = NO;
	
	MTLVertexDescriptor *vertexDescriptor = [[MTLVertexDescriptor alloc] init];
	{
		// Positions.
		vertexDescriptor.attributes[0].format = MTLVertexFormatFloat3;
		vertexDescriptor.attributes[0].offset = 0;
		vertexDescriptor.attributes[0].bufferIndex = VBO_Vertex_Start;
		
		// Texcoords.
		vertexDescriptor.attributes[1].format = MTLVertexFormatFloat2;
		vertexDescriptor.attributes[1].offset = 12;
		vertexDescriptor.attributes[1].bufferIndex = VBO_Vertex_Start;
		
		// Normals
		vertexDescriptor.attributes[2].format = MTLVertexFormatUChar4Normalized;
		vertexDescriptor.attributes[2].offset = 20;
		vertexDescriptor.attributes[2].bufferIndex = VBO_Vertex_Start;
		
		// Single interleaved buffer.
		vertexDescriptor.layouts[VBO_Vertex_Start].stride = 24;
		vertexDescriptor.layouts[VBO_Vertex_Start].stepRate = 1;
		vertexDescriptor.layouts[VBO_Vertex_Start].stepFunction = MTLVertexStepFunctionPerVertex;
	}
	
	//_modelDepthState = [_device newDepthStencilStateWithDescriptor:depthStateDesc];
	
	MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
	{
		pipelineStateDescriptor.colorAttachments[0].pixelFormat = r_metalstate.color_format;
		pipelineStateDescriptor.colorAttachments[0].blendingEnabled = NO;
		pipelineStateDescriptor.depthAttachmentPixelFormat = r_metalstate.depth_format;
		pipelineStateDescriptor.vertexDescriptor = vertexDescriptor;
		pipelineStateDescriptor.vertexFunction = basic_vert_module;
		pipelineStateDescriptor.fragmentFunction = basic_alphatest_frag_module;
	}
	
	//================
	// Basic pipelines
	//================
	
	for (render_pass = 0; render_pass < 2; ++render_pass)
	{
		//pipeline_create_info.renderPass = (render_pass == 0) ? vulkan_globals.main_render_pass : vulkan_globals.ui_render_pass;
		//multisample_state_create_info.rasterizationSamples = (render_pass == 0) ? vulkan_globals.sample_count : VK_SAMPLE_COUNT_1_BIT;
		
		pipelineStateDescriptor.label = @"basic_alphatest";
		R_CreateMetalPipeline(&r_metalstate.basic_alphatest_pipeline[render_pass], pipelineStateDescriptor, depthStateDesc);
	}
	
	pipelineStateDescriptor.fragmentFunction = basic_notex_frag_module;
	pipelineStateDescriptor.colorAttachments[0].blendingEnabled = YES;
	pipelineStateDescriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
	pipelineStateDescriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
	pipelineStateDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	pipelineStateDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	pipelineStateDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
	pipelineStateDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	
	for (render_pass = 0; render_pass < 2; ++render_pass)
	{
		//pipeline_create_info.renderPass = (render_pass == 0) ? vulkan_globals.main_render_pass : vulkan_globals.ui_render_pass;
		//multisample_state_create_info.rasterizationSamples = (render_pass == 0) ? vulkan_globals.sample_count : VK_SAMPLE_COUNT_1_BIT;
		
		pipelineStateDescriptor.label = @"basic_notex_blend";
		R_CreateMetalPipeline(&r_metalstate.basic_notex_blend_pipeline[render_pass], pipelineStateDescriptor, depthStateDesc);
	}
	
	// Basic version of above (no multisampling)
	{
		pipelineStateDescriptor.label = @"basic_poly_blend";
		
		R_CreateMetalPipeline(&r_metalstate.basic_poly_blend_pipeline, pipelineStateDescriptor, depthStateDesc);
	}
	
	pipelineStateDescriptor.fragmentFunction = basic_frag_module;
	
	for (render_pass = 0; render_pass < 2; ++render_pass)
	{
		//pipeline_create_info.renderPass = (render_pass == 0) ? vulkan_globals.main_render_pass : vulkan_globals.ui_render_pass;
		//multisample_state_create_info.rasterizationSamples = (render_pass == 0) ? vulkan_globals.sample_count : VK_SAMPLE_COUNT_1_BIT;
		
		pipelineStateDescriptor.label = @"basic_blend";
		
		R_CreateMetalPipeline(&r_metalstate.basic_blend_pipeline[render_pass], pipelineStateDescriptor, depthStateDesc);
	}
	
	//================
	// Warp
	//================
	
	{
		pipelineStateDescriptor.colorAttachments[0].blendingEnabled = NO;
		pipelineStateDescriptor.vertexFunction = basic_vert_module;
		pipelineStateDescriptor.fragmentFunction = basic_frag_module;
		
		pipelineStateDescriptor.label = @"warp";
		R_CreateMetalPipeline(&r_metalstate.raster_tex_warp_pipeline, pipelineStateDescriptor, depthStateDesc);
	}
	
	//================
	// Particles
	//================
	
	{
		pipelineStateDescriptor.colorAttachments[0].blendingEnabled = YES;
		depthStateDesc.depthCompareFunction = MTLCompareFunctionLessEqual; // MTLCompareFunctionLessEqual
		depthStateDesc.depthWriteEnabled = NO;
		
		pipelineStateDescriptor.label = @"particles";
		R_CreateMetalPipeline(&r_metalstate.particle_pipeline, pipelineStateDescriptor, depthStateDesc);
	}
	
	//================
	// Water
	//================
	
	{
		pipelineStateDescriptor.colorAttachments[0].blendingEnabled = NO;
		depthStateDesc.depthCompareFunction = MTLCompareFunctionLessEqual; // MTLCompareFunctionLessEqual
		depthStateDesc.depthWriteEnabled = YES;
		
		pipelineStateDescriptor.label = @"water";
		R_CreateMetalPipeline(&r_metalstate.water_pipeline, pipelineStateDescriptor, depthStateDesc);
	}
	
	{
		pipelineStateDescriptor.colorAttachments[0].blendingEnabled = YES;
		depthStateDesc.depthWriteEnabled = NO;
		
		pipelineStateDescriptor.label = @"water_blend";
		R_CreateMetalPipeline(&r_metalstate.water_blend_pipeline, pipelineStateDescriptor, depthStateDesc);
	}
	
	//================
	// Sprites
	//================
	
	pipelineStateDescriptor.fragmentFunction = basic_alphatest_frag_module;
	pipelineStateDescriptor.colorAttachments[0].blendingEnabled = NO;
	
	pipelineStateDescriptor.label = @"sprite";
	R_CreateMetalPipeline(&r_metalstate.sprite_pipeline, pipelineStateDescriptor, depthStateDesc);
	
	//================
	// Sky
	//================
	
	{
		pipelineStateDescriptor.fragmentFunction = basic_notex_frag_module;
		depthStateDesc.depthCompareFunction = MTLCompareFunctionLessEqual; // MTLCompareFunctionLessEqual
		depthStateDesc.depthWriteEnabled = YES;
		
		pipelineStateDescriptor.label = @"sky";
		R_CreateMetalPipeline(&r_metalstate.sky_color_pipeline, pipelineStateDescriptor, depthStateDesc);
	}
	
	{
		depthStateDesc.depthCompareFunction = MTLCompareFunctionAlways;
		pipelineStateDescriptor.fragmentFunction = basic_frag_module;
		
		pipelineStateDescriptor.label = @"sky_box";
		R_CreateMetalPipeline(&r_metalstate.sky_box_pipeline, pipelineStateDescriptor, depthStateDesc);
	}
	
	// Sky layer verts are different
	MTLVertexDescriptor *skyVertexDescriptor = [[MTLVertexDescriptor alloc] init];
	{
		// Positions.
		skyVertexDescriptor.attributes[0].format = MTLVertexFormatFloat3;
		skyVertexDescriptor.attributes[0].offset = 0;
		skyVertexDescriptor.attributes[0].bufferIndex = VBO_Vertex_Start;
		
		// Texcoords.
		skyVertexDescriptor.attributes[1].format = MTLVertexFormatFloat2;
		skyVertexDescriptor.attributes[1].offset = 12;
		skyVertexDescriptor.attributes[1].bufferIndex = VBO_Vertex_Start;
		
		skyVertexDescriptor.attributes[2].format = MTLVertexFormatFloat2;
		skyVertexDescriptor.attributes[2].offset = 20;
		skyVertexDescriptor.attributes[2].bufferIndex = VBO_Vertex_Start;
		
		// Normals
		skyVertexDescriptor.attributes[3].format = MTLVertexFormatUChar4Normalized;
		skyVertexDescriptor.attributes[3].offset = 28;
		skyVertexDescriptor.attributes[3].bufferIndex = VBO_Vertex_Start;
		
		// Single interleaved buffer.
		skyVertexDescriptor.layouts[VBO_Vertex_Start].stride = 32;
		skyVertexDescriptor.layouts[VBO_Vertex_Start].stepRate = 1;
		skyVertexDescriptor.layouts[VBO_Vertex_Start].stepFunction = MTLVertexStepFunctionPerVertex;
	}
	
	{
		pipelineStateDescriptor.colorAttachments[0].blendingEnabled = NO;
		
		pipelineStateDescriptor.vertexFunction = sky_layer_vert_module;
		pipelineStateDescriptor.fragmentFunction = sky_layer_frag_module;
		pipelineStateDescriptor.vertexDescriptor = skyVertexDescriptor;
		
		pipelineStateDescriptor.label = @"sky_layer";
		R_CreateMetalPipeline(&r_metalstate.sky_layer_pipeline, pipelineStateDescriptor, depthStateDesc);
	}
	
	//================
	// Show triangles
	//================
	
	if (r_metalstate.non_solid_fill)
	{
		depthStateDesc.depthCompareFunction = MTLCompareFunctionAlways;
		depthStateDesc.depthWriteEnabled = NO;
		pipelineStateDescriptor.colorAttachments[0].blendingEnabled = NO;
		
		MTLVertexDescriptor *showTrisDescriptor = [[MTLVertexDescriptor alloc] init];
		{
			// Positions.
			showTrisDescriptor.attributes[0].format = MTLVertexFormatFloat3;
			showTrisDescriptor.attributes[0].offset = 0;
			showTrisDescriptor.attributes[0].bufferIndex = VBO_Vertex_Start;
			
			// Single interleaved buffer.
			showTrisDescriptor.layouts[VBO_Vertex_Start].stride = 24;
			showTrisDescriptor.layouts[VBO_Vertex_Start].stepRate = 1;
			showTrisDescriptor.layouts[VBO_Vertex_Start].stepFunction = MTLVertexStepFunctionPerVertex;
		}
		
		pipelineStateDescriptor.vertexDescriptor = showTrisDescriptor;
		pipelineStateDescriptor.vertexFunction = showtris_vert_module;
		pipelineStateDescriptor.fragmentFunction = showtris_frag_module;
		
		pipelineStateDescriptor.label = @"showtris";
		R_CreateMetalPipeline(&r_metalstate.showtris_pipeline, pipelineStateDescriptor, depthStateDesc);
		
		depthStateDesc.depthCompareFunction = MTLCompareFunctionLessEqual;
		pipelineStateDescriptor.colorAttachments[0].blendingEnabled = NO;
		// NOTE Depth bias set with command encoder
		
		pipelineStateDescriptor.label = @"showtris_depth_test";
		R_CreateMetalPipeline(&r_metalstate.showtris_depth_test_pipeline, pipelineStateDescriptor, depthStateDesc);
	}
	
	
	//================
	// World pipelines
	//================
	
	depthStateDesc.depthCompareFunction = MTLCompareFunctionLessEqual;
	depthStateDesc.depthWriteEnabled = YES;
	pipelineStateDescriptor.colorAttachments[0].blendingEnabled = NO;
	
	MTLVertexDescriptor *worldVertexDescriptor = [[MTLVertexDescriptor alloc] init];
	{
		// Positions.
		worldVertexDescriptor.attributes[0].format = MTLVertexFormatFloat3;
		worldVertexDescriptor.attributes[0].offset = 0;
		worldVertexDescriptor.attributes[0].bufferIndex = VBO_Vertex_Start;
		
		// Texcoords.
		worldVertexDescriptor.attributes[1].format = MTLVertexFormatFloat2;
		worldVertexDescriptor.attributes[1].offset = 12;
		worldVertexDescriptor.attributes[1].bufferIndex = VBO_Vertex_Start;
		
		// lmap texcoords
		worldVertexDescriptor.attributes[2].format = MTLVertexFormatFloat2;
		worldVertexDescriptor.attributes[2].offset = 20;
		worldVertexDescriptor.attributes[2].bufferIndex = VBO_Vertex_Start;
		
		// Single interleaved buffer.
		worldVertexDescriptor.layouts[VBO_Vertex_Start].stride = 28;
		worldVertexDescriptor.layouts[VBO_Vertex_Start].stepRate = 1;
		worldVertexDescriptor.layouts[VBO_Vertex_Start].stepFunction = MTLVertexStepFunctionPerVertex;
	}
	
	pipelineStateDescriptor.vertexDescriptor = worldVertexDescriptor;
	pipelineStateDescriptor.vertexFunction = world_vert_module;
	pipelineStateDescriptor.fragmentFunction = world_frag_module;
	
	MTLFunctionConstantValues* constantValues = [[MTLFunctionConstantValues alloc] init];
	
	for (alpha_blend = 0; alpha_blend < 2; ++alpha_blend) {
		for (alpha_test = 0; alpha_test < 2; ++alpha_test) {
			for (fullbright_enabled = 0; fullbright_enabled < 2; ++fullbright_enabled) {
				int pipeline_index = fullbright_enabled + (alpha_test * 2) + (alpha_blend * 4);
				
				[constantValues setConstantValue:&fullbright_enabled type:MTLDataTypeBool withName:@"use_fullbright"];
				[constantValues setConstantValue:&alpha_test type:MTLDataTypeBool withName:@"use_alpha_test"];
				[constantValues setConstantValue:&alpha_blend type:MTLDataTypeBool withName:@"use_alpha_blend"];
				
				r_metalstate.world_pipelines_frag_shaders[pipeline_index] = [defaultLibrary newFunctionWithName:@"world_frag_spv" constantValues:constantValues error:&err];
				if (err)
					Sys_Error("vkCreateGraphicsPipelines failed");
				
				pipelineStateDescriptor.fragmentFunction = r_metalstate.world_pipelines_frag_shaders[pipeline_index];
				
				pipelineStateDescriptor.colorAttachments[0].blendingEnabled = alpha_blend ? YES : NO;
				depthStateDesc.depthCompareFunction = alpha_blend ? MTLCompareFunctionAlways : MTLCompareFunctionLessEqual;
				if ( pipeline_index > 0 ) {
					//pipeline_create_info.flags = VK_PIPELINE_CREATE_DERIVATIVE_BIT;
					//pipeline_create_info.basePipelineHandle = vulkan_globals.world_pipelines[0];
					//pipeline_create_info.basePipelineIndex = -1;
				} else {
					//pipeline_create_info.flags = VK_PIPELINE_CREATE_ALLOW_DERIVATIVES_BIT;
				}
				
				pipelineStateDescriptor.label = [NSString stringWithFormat:@"world %d", pipeline_index];
				R_CreateMetalPipeline(&r_metalstate.world_pipelines[pipeline_index], pipelineStateDescriptor, depthStateDesc);
			}
		}
	}
	
	depthStateDesc.depthCompareFunction = MTLCompareFunctionLessEqual;
	depthStateDesc.depthWriteEnabled = YES;
	pipelineStateDescriptor.colorAttachments[0].blendingEnabled = NO;
	
	//================
	// Alias pipeline
	//================

	MTLVertexDescriptor *aliasVertexDescriptor = [[MTLVertexDescriptor alloc] init];
	{
		// texcoord
		aliasVertexDescriptor.attributes[0].format = MTLVertexFormatFloat2;
		aliasVertexDescriptor.attributes[0].offset = 0;
		aliasVertexDescriptor.attributes[0].bufferIndex = VBO_Alias_Vertex_Start;
		
		// pose1_position
		aliasVertexDescriptor.attributes[1].format = MTLVertexFormatUChar4Normalized;
		aliasVertexDescriptor.attributes[1].offset = 0;
		aliasVertexDescriptor.attributes[1].bufferIndex = VBO_Alias_Vertex_Start+1;
		
		// pose1_normal
		aliasVertexDescriptor.attributes[2].format = MTLVertexFormatChar4Normalized;
		aliasVertexDescriptor.attributes[2].offset = 4;
		aliasVertexDescriptor.attributes[2].bufferIndex = VBO_Alias_Vertex_Start+1;
		
		// pose2_position
		aliasVertexDescriptor.attributes[3].format = MTLVertexFormatUChar4Normalized;
		aliasVertexDescriptor.attributes[3].offset = 0;
		aliasVertexDescriptor.attributes[3].bufferIndex = VBO_Alias_Vertex_Start+2;
		
		// pose2_normal
		aliasVertexDescriptor.attributes[4].format = MTLVertexFormatChar4Normalized;
		aliasVertexDescriptor.attributes[4].offset = 4;
		aliasVertexDescriptor.attributes[4].bufferIndex = VBO_Alias_Vertex_Start+2;
		
		aliasVertexDescriptor.layouts[VBO_Alias_Vertex_Start].stride = 8;
		aliasVertexDescriptor.layouts[VBO_Alias_Vertex_Start].stepRate = 1;
		aliasVertexDescriptor.layouts[VBO_Alias_Vertex_Start].stepFunction = MTLVertexStepFunctionPerVertex;
		
		aliasVertexDescriptor.layouts[VBO_Alias_Vertex_Start+1].stride = 8;
		aliasVertexDescriptor.layouts[VBO_Alias_Vertex_Start+1].stepRate = 1;
		aliasVertexDescriptor.layouts[VBO_Alias_Vertex_Start+1].stepFunction = MTLVertexStepFunctionPerVertex;
		
		aliasVertexDescriptor.layouts[VBO_Alias_Vertex_Start+2].stride = 8;
		aliasVertexDescriptor.layouts[VBO_Alias_Vertex_Start+2].stepRate = 1;
		aliasVertexDescriptor.layouts[VBO_Alias_Vertex_Start+2].stepFunction = MTLVertexStepFunctionPerVertex;
	}
	
	{
		pipelineStateDescriptor.vertexDescriptor = aliasVertexDescriptor;
		pipelineStateDescriptor.vertexFunction = alias_vert_module;
		pipelineStateDescriptor.fragmentFunction = alias_frag_module;
		
		pipelineStateDescriptor.label = @"alias";
		R_CreateMetalPipeline(&r_metalstate.alias_pipeline, pipelineStateDescriptor, depthStateDesc);
	}

	{
		pipelineStateDescriptor.fragmentFunction = alias_alphatest_frag_module;
		
		pipelineStateDescriptor.label = @"alias_alphatest";
		R_CreateMetalPipeline(&r_metalstate.alias_alphatest_pipeline, pipelineStateDescriptor, depthStateDesc);
	}

	{
		depthStateDesc.depthWriteEnabled = NO;
		pipelineStateDescriptor.colorAttachments[0].blendingEnabled = YES;
		pipelineStateDescriptor.fragmentFunction = alias_frag_module;
		
		pipelineStateDescriptor.label = @"alias_blend";
		R_CreateMetalPipeline(&r_metalstate.alias_blend_pipeline, pipelineStateDescriptor, depthStateDesc);
	}
	
	//================
	// Postprocess pipeline
	//================
	
	{
		depthStateDesc.depthCompareFunction = MTLCompareFunctionAlways;
		depthStateDesc.depthWriteEnabled = NO;
		pipelineStateDescriptor.colorAttachments[0].blendingEnabled = NO;
		
		pipelineStateDescriptor.vertexDescriptor = nil;
		pipelineStateDescriptor.vertexFunction = postprocess_vert_module;
		pipelineStateDescriptor.fragmentFunction = postprocess_frag_module;
		
		pipelineStateDescriptor.label = @"postprocess";
		R_CreateMetalPipeline(&r_metalstate.postprocess_pipeline, pipelineStateDescriptor, depthStateDesc);
	}
	
	
	//================
	// Screen Warp
	//================
	
	r_metalstate.screen_warp_compute_pipeline = [r_metalstate.device newComputePipelineStateWithFunction:screen_warp_comp_module
																									error:&err];
	
	if (err)
	{
		Sys_Error("Error generating compute state");
	}
	
	//================
	// Texture Warp
	//================
	
	r_metalstate.cs_tex_warp_compute_pipeline = [r_metalstate.device newComputePipelineStateWithFunction:cs_tex_warp_module
																																  error:&err];
}

/*
===============
R_DestroyPipelines
===============
*/
void R_DestroyPipelines(void)
{
	int i;
	for (i = 0; i < 2; ++i)
	{
		r_metalstate.basic_alphatest_pipeline[i].state = nil;
		r_metalstate.basic_alphatest_pipeline[i].depthState = nil;
		r_metalstate.basic_blend_pipeline[i].state = nil;
		r_metalstate.basic_blend_pipeline[i].depthState = nil;
		r_metalstate.basic_notex_blend_pipeline[i].state = nil;
		r_metalstate.basic_notex_blend_pipeline[i].depthState = nil;
	}
	r_metalstate.basic_poly_blend_pipeline.state = nil;
	r_metalstate.basic_poly_blend_pipeline.depthState = nil;
	for (i = 0; i < WORLD_PIPELINE_COUNT; ++i) {
		r_metalstate.world_pipelines[i].state = nil;
		r_metalstate.world_pipelines[i].depthState = nil;
	}
	r_metalstate.water_pipeline.state = nil;
	r_metalstate.water_pipeline.depthState = nil;
	r_metalstate.water_blend_pipeline.state = nil;
	r_metalstate.water_blend_pipeline.depthState = nil;
	r_metalstate.raster_tex_warp_pipeline.state = nil;
	r_metalstate.raster_tex_warp_pipeline.depthState = nil;
	r_metalstate.particle_pipeline.state = nil;
	r_metalstate.particle_pipeline.depthState = nil;
	r_metalstate.sprite_pipeline.state = nil;
	r_metalstate.sprite_pipeline.depthState = nil;
	r_metalstate.sky_color_pipeline.state = nil;
	r_metalstate.sky_color_pipeline.depthState = nil;
	r_metalstate.sky_box_pipeline.state = nil;
	r_metalstate.sky_box_pipeline.depthState = nil;
	r_metalstate.sky_layer_pipeline.state = nil;
	r_metalstate.sky_layer_pipeline.depthState = nil;
	r_metalstate.alias_pipeline.state = nil;
	r_metalstate.alias_pipeline.depthState = nil;
	r_metalstate.alias_alphatest_pipeline.state = nil;
	r_metalstate.alias_alphatest_pipeline.depthState = nil;
	r_metalstate.alias_blend_pipeline.state = nil;
	r_metalstate.alias_blend_pipeline.depthState = nil;
	r_metalstate.postprocess_pipeline.state = nil;
	r_metalstate.postprocess_pipeline.depthState = nil;
	r_metalstate.screen_warp_pipeline.state = nil;
	r_metalstate.screen_warp_pipeline.depthState = nil;
	r_metalstate.cs_tex_warp_pipeline.state = nil;
	r_metalstate.cs_tex_warp_pipeline.depthState = nil;
	if (r_metalstate.showtris_pipeline.state != nil)
	{
		r_metalstate.showtris_pipeline.state = nil;
		r_metalstate.showtris_pipeline.depthState = nil;
		r_metalstate.showtris_depth_test_pipeline.state = nil;
		r_metalstate.showtris_depth_test_pipeline.depthState = nil;
	}
	
	r_metalstate.screen_warp_compute_pipeline = nil;
	r_metalstate.cs_tex_warp_compute_pipeline = nil;
}

/*
===============
R_Init
===============
*/
void R_Init (void)
{
	extern cvar_t gl_finish;

	Cmd_AddCommand ("timerefresh", R_TimeRefresh_f);
	Cmd_AddCommand ("pointfile", R_ReadPointFile_f);
	Cmd_AddCommand ("vkmemstats", R_VulkanMemStats_f);

	Cvar_RegisterVariable (&r_norefresh);
	Cvar_RegisterVariable (&r_lightmap);
	Cvar_RegisterVariable (&r_fullbright);
	Cvar_RegisterVariable (&r_drawentities);
	Cvar_RegisterVariable (&r_drawviewmodel);
	Cvar_RegisterVariable (&r_shadows);
	Cvar_RegisterVariable (&r_wateralpha);
	Cvar_SetCallback (&r_wateralpha, R_SetWateralpha_f);
	Cvar_RegisterVariable (&r_dynamic);
	Cvar_RegisterVariable (&r_novis);
	Cvar_SetCallback (&r_novis, R_VisChanged);
	Cvar_RegisterVariable (&r_speeds);
	Cvar_RegisterVariable (&r_pos);

	Cvar_RegisterVariable (&gl_finish);
	Cvar_RegisterVariable (&gl_clear);
	Cvar_RegisterVariable (&gl_cull);
	Cvar_RegisterVariable (&gl_smoothmodels);
	Cvar_RegisterVariable (&gl_affinemodels);
	Cvar_RegisterVariable (&gl_polyblend);
	Cvar_RegisterVariable (&gl_playermip);
	Cvar_RegisterVariable (&gl_nocolors);

	//johnfitz -- new cvars
	Cvar_RegisterVariable (&r_clearcolor);
	Cvar_SetCallback (&r_clearcolor, R_SetClearColor_f);
	Cvar_RegisterVariable (&r_waterquality);
	Cvar_RegisterVariable (&r_waterwarp);
	Cvar_RegisterVariable (&r_waterwarpcompute);
	Cvar_RegisterVariable (&r_drawflat);
	Cvar_RegisterVariable (&r_flatlightstyles);
	Cvar_RegisterVariable (&r_oldskyleaf);
	Cvar_SetCallback (&r_oldskyleaf, R_VisChanged);
	Cvar_RegisterVariable (&r_drawworld);
	Cvar_RegisterVariable (&r_showtris);
	Cvar_RegisterVariable (&r_showbboxes);
	Cvar_RegisterVariable (&gl_farclip);
	Cvar_RegisterVariable (&gl_fullbrights);
	Cvar_SetCallback (&gl_fullbrights, GL_Fullbrights_f);
	Cvar_RegisterVariable (&r_lerpmodels);
	Cvar_RegisterVariable (&r_lerpmove);
	Cvar_RegisterVariable (&r_nolerp_list);
	Cvar_SetCallback (&r_nolerp_list, R_Model_ExtraFlags_List_f);
	Cvar_RegisterVariable (&r_noshadow_list);
	Cvar_SetCallback (&r_noshadow_list, R_Model_ExtraFlags_List_f);
	//johnfitz

	Cvar_RegisterVariable (&gl_zfix); // QuakeSpasm z-fighting fix
	Cvar_RegisterVariable (&r_lavaalpha);
	Cvar_RegisterVariable (&r_telealpha);
	Cvar_RegisterVariable (&r_slimealpha);
	Cvar_SetCallback (&r_lavaalpha, R_SetLavaalpha_f);
	Cvar_SetCallback (&r_telealpha, R_SetTelealpha_f);
	Cvar_SetCallback (&r_slimealpha, R_SetSlimealpha_f);

	R_InitParticles ();
	R_SetClearColor_f (&r_clearcolor); //johnfitz

	Sky_Init (); //johnfitz
	Fog_Init (); //johnfitz
}

/*
===============
R_TranslatePlayerSkin -- johnfitz -- rewritten.  also, only handles new colors, not new skins
===============
*/
void R_TranslatePlayerSkin (int playernum)
{
	int			top, bottom;

	top = (cl.scores[playernum].colors & 0xf0)>>4;
	bottom = cl.scores[playernum].colors &15;

	//FIXME: if gl_nocolors is on, then turned off, the textures may be out of sync with the scoreboard colors.
	if (!gl_nocolors.value)
		if (playertextures[playernum])
			TexMgr_ReloadImage (playertextures[playernum], top, bottom);
}

/*
===============
R_TranslateNewPlayerSkin -- johnfitz -- split off of TranslatePlayerSkin -- this is called when
the skin or model actually changes, instead of just new colors
added bug fix from bengt jardup
===============
*/
void R_TranslateNewPlayerSkin (int playernum)
{
	char		name[64];
	byte		*pixels;
	aliashdr_t	*paliashdr;
	int		skinnum;

//get correct texture pixels
	currententity = &cl_entities[1+playernum];

	if (!currententity->model || currententity->model->type != mod_alias)
		return;

	paliashdr = (aliashdr_t *)Mod_Extradata (currententity->model);

	skinnum = currententity->skinnum;

	//TODO: move these tests to the place where skinnum gets received from the server
	if (skinnum < 0 || skinnum >= paliashdr->numskins)
	{
		Con_DPrintf("(%d): Invalid player skin #%d\n", playernum, skinnum);
		skinnum = 0;
	}

	pixels = (byte *)paliashdr + paliashdr->texels[skinnum]; // This is not a persistent place!

//upload new image
	q_snprintf(name, sizeof(name), "player_%i", playernum);
	playertextures[playernum] = TexMgr_LoadImage (currententity->model, name, paliashdr->skinwidth, paliashdr->skinheight,
		SRC_INDEXED, pixels, paliashdr->gltextures[skinnum][0]->source_file, paliashdr->gltextures[skinnum][0]->source_offset, TEXPREF_PAD | TEXPREF_OVERWRITE);

//now recolor it
	R_TranslatePlayerSkin (playernum);
}

/*
===============
R_NewGame -- johnfitz -- handle a game switch
===============
*/
void R_NewGame (void)
{
	int i;

	//clear playertexture pointers (the textures themselves were freed by texmgr_newgame)
	for (i=0; i<MAX_SCOREBOARD; i++)
		playertextures[i] = NULL;
}

/*
=============
R_ParseWorldspawn

called at map load
=============
*/
static void R_ParseWorldspawn (void)
{
	char key[128], value[4096];
	const char *data;

	map_wateralpha = r_wateralpha.value;
	map_lavaalpha = r_lavaalpha.value;
	map_telealpha = r_telealpha.value;
	map_slimealpha = r_slimealpha.value;

	data = COM_Parse(cl.worldmodel->entities);
	if (!data)
		return; // error
	if (com_token[0] != '{')
		return; // error
	while (1)
	{
		data = COM_Parse(data);
		if (!data)
			return; // error
		if (com_token[0] == '}')
			break; // end of worldspawn
		if (com_token[0] == '_')
			strcpy(key, com_token + 1);
		else
			strcpy(key, com_token);
		while (key[strlen(key)-1] == ' ') // remove trailing spaces
			key[strlen(key)-1] = 0;
		data = COM_Parse(data);
		if (!data)
			return; // error
		strcpy(value, com_token);

		if (!strcmp("wateralpha", key))
			map_wateralpha = atof(value);

		if (!strcmp("lavaalpha", key))
			map_lavaalpha = atof(value);

		if (!strcmp("telealpha", key))
			map_telealpha = atof(value);

		if (!strcmp("slimealpha", key))
			map_slimealpha = atof(value);
	}
}


/*
===============
R_NewMap
===============
*/
void R_NewMap (void)
{
	int		i;

	for (i=0 ; i<256 ; i++)
		d_lightstylevalue[i] = 264;		// normal light value

// clear out efrags in case the level hasn't been reloaded
// FIXME: is this one short?
	for (i=0 ; i<cl.worldmodel->numleafs ; i++)
		cl.worldmodel->leafs[i].efrags = NULL;

	r_viewleaf = NULL;
	R_ClearParticles ();
	GL_DeleteBModelVertexBuffer();

	GL_BuildLightmaps ();
	GL_BuildBModelVertexBuffer ();
	//ericw -- no longer load alias models into a VBO here, it's done in Mod_LoadAliasModel

	r_framecount = 0; //johnfitz -- paranoid?
	r_visframecount = 0; //johnfitz -- paranoid?

	Sky_NewMap (); //johnfitz -- skybox in worldspawn
	Fog_NewMap (); //johnfitz -- global fog in worldspawn
	R_ParseWorldspawn (); //ericw -- wateralpha, lavaalpha, telealpha, slimealpha in worldspawn

	load_subdivide_size = gl_subdivide_size.value; //johnfitz -- is this the right place to set this?
}

/*
====================
R_TimeRefresh_f

For program optimization
====================
*/
void R_TimeRefresh_f (void)
{
	int		i;
	float		start, stop, time;

	if (cls.state != ca_connected)
	{
		Con_Printf("Not connected to a server\n");
		return;
	}

	start = Sys_DoubleTime ();
	for (i = 0; i < 128; i++)
	{
		GL_BeginRendering(&glx, &gly, &glwidth, &glheight);
		r_refdef.viewangles[1] = i/128.0*360.0;
		R_RenderView ();
		GL_EndRendering (true);
	}

	//glFinish ();
	stop = Sys_DoubleTime ();
	time = stop-start;
	Con_Printf ("%f seconds (%f fps)\n", time, 128/time);
}

/*
====================
R_VulkanMemStats_f
====================
*/
void R_VulkanMemStats_f(void)
{
	Con_Printf("Metal allocations:\n");
	Con_Printf(" Tex:    %d\n", num_metal_tex_allocations);
	Con_Printf(" BModel: %d\n", num_metal_bmodel_allocations);
	Con_Printf(" Mesh:   %d\n", num_metal_mesh_allocations);
	Con_Printf(" Misc:   %d\n", num_metal_misc_allocations);
	Con_Printf(" DynBuf: %d\n", num_metal_dynbuf_allocations);

}


/*
 ============
 V_PolyBlend -- johnfitz -- moved here from gl_rmain.c, and rewritten to use glOrtho
 ============
 */
void V_PolyBlend (void)
{
	int i;
	
	if (!gl_polyblend.value || !v_blend[3])
		return;
	
	GL_SetCanvas (CANVAS_DEFAULT);
	
	id<MTLBuffer> vertex_buffer;
	uint32_t vertex_buffer_offset;
	basicvertex_t * vertices = (basicvertex_t*)R_VertexAllocate(4 * sizeof(basicvertex_t), &vertex_buffer, &vertex_buffer_offset);
	
	memset(vertices, 0, 4 * sizeof(basicvertex_t));
	
	vertices[0].position[0] = 0.0f;
	vertices[0].position[1] = 0.0f;
	
	vertices[1].position[0] = vid.width;
	vertices[1].position[1] = 0.0f;
	
	vertices[2].position[0] = vid.width;
	vertices[2].position[1] = vid.height;
	
	vertices[3].position[0] = 0.0f;
	vertices[3].position[1] = vid.height;
	
	for (i = 0; i < 4; ++i)
	{
		vertices[i].color[0] = v_blend[0] * 255.0f;
		vertices[i].color[1] = v_blend[1] * 255.0f;
		vertices[i].color[2] = v_blend[2] * 255.0f;
		vertices[i].color[3] = v_blend[3] * 255.0f;
	}
	
	R_UpdatePushConstants();
	R_BindPipeline(&r_metalstate.basic_poly_blend_pipeline);
	[r_metalstate.render_encoder setVertexBuffer:vertex_buffer offset:vertex_buffer_offset atIndex:VBO_Vertex_Start];
	[r_metalstate.render_encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:r_metalstate.fan_index_buffer indexBufferOffset:0];
}

