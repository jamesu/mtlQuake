/*
Copyright (C) 1996-2001 Id Software, Inc.
Copyright (C) 2002-2009 John Fitzgibbons and others
Copyright (C) 2007-2008 Kristian Duske
Copyright (C) 2010-2014 QuakeSpasm developers
Copyright (C) 2016 Axel Gneiting

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
// gl_vidsdl.c -- SDL vid component

#include "quakedef.h"
#include "cfgfile.h"
#include "bgmusic.h"
#include "resource.h"
#include "SDL.h"
#include "SDL_syswm.h"
#include "mtl_renderstate.h"


struct MetalRenderState r_metalstate;

#include <assert.h>

#define MAX_MODE_LIST	600 //johnfitz -- was 30
#define MAX_BPPS_LIST	5
#define MAX_RATES_LIST	20
#define MAXWIDTH		10000
#define MAXHEIGHT		10000

#define NUM_COMMAND_BUFFERS 2
#define MAX_SWAP_CHAIN_IMAGES 8

#define DEFAULT_REFRESHRATE	60

typedef struct {
	int			width;
	int			height;
	int			refreshrate;
	int			bpp;
} vmode_t;

static vmode_t	modelist[MAX_MODE_LIST];
static int		nummodes;

static qboolean	vid_initialized = false;

static SDL_Window	*draw_context;
static SDL_SysWMinfo sys_wm_info;

static qboolean	vid_locked = false; //johnfitz
static qboolean	vid_changed = false;

static void VID_Menu_Init (void); //johnfitz
static void VID_Menu_f (void); //johnfitz
static void VID_MenuDraw (void);
static void VID_MenuKey (int key);
static void VID_Restart(void);

static void ClearAllStates (void);
static void GL_InitInstance (void);
static void GL_InitDevice (void);
static void GL_CreateFrameBuffers(void);
static void GL_DestroyRenderResources(void);

viddef_t	vid;				// global video state
modestate_t	modestate = MS_UNINIT;
extern qboolean scr_initialized;

//====================================

//johnfitz -- new cvars
static cvar_t	vid_fullscreen = {"vid_fullscreen", "0", CVAR_ARCHIVE};	// QuakeSpasm, was "1"
static cvar_t	vid_width = {"vid_width", "800", CVAR_ARCHIVE};		// QuakeSpasm, was 640
static cvar_t	vid_height = {"vid_height", "600", CVAR_ARCHIVE};	// QuakeSpasm, was 480
static cvar_t	vid_bpp = {"vid_bpp", "16", CVAR_ARCHIVE};
static cvar_t	vid_refreshrate = {"vid_refreshrate", "60", CVAR_ARCHIVE};
static cvar_t	vid_vsync = {"vid_vsync", "0", CVAR_ARCHIVE};
static cvar_t	vid_desktopfullscreen = {"vid_desktopfullscreen", "0", CVAR_ARCHIVE}; // QuakeSpasm
static cvar_t	vid_borderless = {"vid_borderless", "0", CVAR_ARCHIVE}; // QuakeSpasm
cvar_t	vid_filter = {"vid_filter", "0", CVAR_ARCHIVE};
cvar_t	vid_anisotropic = {"vid_anisotropic", "0", CVAR_ARCHIVE};
cvar_t vid_fsaa = {"vid_fsaa", "0", CVAR_ARCHIVE};
cvar_t vid_fsaamode = { "vid_fsaamode", "0", CVAR_ARCHIVE };

cvar_t		vid_gamma = {"gamma", "1", CVAR_ARCHIVE}; //johnfitz -- moved here from view.c
cvar_t		vid_contrast = {"contrast", "1", CVAR_ARCHIVE}; //QuakeSpasm, MarkV


// Metal
static qboolean                  render_resources_created = false;

/*
================
VID_Gamma_Init -- call on init
================
*/
static void VID_Gamma_Init (void)
{
	Cvar_RegisterVariable (&vid_gamma);
	Cvar_RegisterVariable (&vid_contrast);
}

/*
======================
VID_GetCurrentWidth
======================
*/
static int VID_GetCurrentWidth (void)
{
	int w,h;
	SDL_GetWindowSize(draw_context, &w, &h);
	return w;
}

/*
=======================
VID_GetCurrentHeight
=======================
*/
static int VID_GetCurrentHeight (void)
{
	int w,h;
	SDL_GetWindowSize(draw_context, &w, &h);
	return h;
}

/*
====================
VID_GetCurrentRefreshRate
====================
*/
static int VID_GetCurrentRefreshRate (void)
{
	SDL_DisplayMode mode;
	int current_display;
	
	current_display = SDL_GetWindowDisplayIndex(draw_context);
	
	if (0 != SDL_GetCurrentDisplayMode(current_display, &mode))
		return DEFAULT_REFRESHRATE;
	
	return mode.refresh_rate;
}

/*
====================
VID_GetCurrentBPP
====================
*/
static int VID_GetCurrentBPP (void)
{
	const Uint32 pixelFormat = SDL_GetWindowPixelFormat(draw_context);
	return SDL_BITSPERPIXEL(pixelFormat);
}

/*
====================
VID_GetFullscreen

returns true if we are in regular fullscreen or "desktop fullscren"
====================
*/
static qboolean VID_GetFullscreen (void)
{
	return (SDL_GetWindowFlags(draw_context) & SDL_WINDOW_FULLSCREEN) != 0;
}

/*
====================
VID_GetDesktopFullscreen

returns true if we are specifically in "desktop fullscreen" mode
====================
*/
static qboolean VID_GetDesktopFullscreen (void)
{
	return (SDL_GetWindowFlags(draw_context) & SDL_WINDOW_FULLSCREEN_DESKTOP) == SDL_WINDOW_FULLSCREEN_DESKTOP;
}

/*
====================
VID_GetVSync
====================
*/
static qboolean VID_GetVSync (void)
{
	return true;
}

/*
====================
VID_GetWindow

used by pl_win.c
====================
*/
void *VID_GetWindow (void)
{
	return draw_context;
}

/*
====================
VID_HasMouseOrInputFocus
====================
*/
qboolean VID_HasMouseOrInputFocus (void)
{
	return (SDL_GetWindowFlags(draw_context) & (SDL_WINDOW_MOUSE_FOCUS | SDL_WINDOW_INPUT_FOCUS)) != 0;
}

/*
====================
VID_IsMinimized
====================
*/
qboolean VID_IsMinimized (void)
{
	return !(SDL_GetWindowFlags(draw_context) & SDL_WINDOW_SHOWN);
}

/*
================
VID_SDL2_GetDisplayMode

Returns a pointer to a statically allocated SDL_DisplayMode structure
if there is one with the requested params on the default display.
Otherwise returns NULL.

This is passed to SDL_SetWindowDisplayMode to specify a pixel format
with the requested bpp. If we didn't care about bpp we could just pass NULL.
================
*/
static SDL_DisplayMode *VID_SDL2_GetDisplayMode(int width, int height, int refreshrate, int bpp)
{
	static SDL_DisplayMode mode;
	const int sdlmodes = SDL_GetNumDisplayModes(0);
	int i;

	for (i = 0; i < sdlmodes; i++)
	{
		if (SDL_GetDisplayMode(0, i, &mode) != 0)
			continue;
		
		if (mode.w == width && mode.h == height
			&& SDL_BITSPERPIXEL(mode.format) == bpp
			&& mode.refresh_rate == refreshrate)
		{
			return &mode;
		}
	}
	return NULL;
}

/*
================
VID_ValidMode
================
*/
static qboolean VID_ValidMode (int width, int height, int refreshrate, int bpp, qboolean fullscreen)
{
// ignore width / height / bpp if vid_desktopfullscreen is enabled
	if (fullscreen && vid_desktopfullscreen.value)
		return true;
	
	if (width < 320)
		return false;

	if (height < 200)
		return false;

	if (fullscreen && VID_SDL2_GetDisplayMode(width, height, refreshrate, bpp) == NULL)
		bpp = 0;

	switch (bpp)
	{
	case 16:
	case 24:
	case 32:
		break;
	default:
		return false;
	}

	return true;
}

/*
================
VID_SetMode
================
*/
static qboolean VID_SetMode (int width, int height, int refreshrate, int bpp, qboolean fullscreen)
{
	int		temp;
	Uint32	flags;
	char		caption[50];
	int		previous_display;
	
	// so Con_Printfs don't mess us up by forcing vid and snd updates
	temp = scr_disabled_for_loading;
	scr_disabled_for_loading = true;

	CDAudio_Pause ();
	BGM_Pause ();

	q_snprintf(caption, sizeof(caption), "mtlQuake " MTLQUAKE_VER_STRING);

	/* Create the window if needed, hidden */
	if (!draw_context)
	{
		flags = SDL_WINDOW_HIDDEN;

		if (vid_borderless.value)
			flags |= SDL_WINDOW_BORDERLESS;
		
		draw_context = SDL_CreateWindow (caption, SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, width, height, flags);
		if (!draw_context)
			Sys_Error ("Couldn't create window: %s", SDL_GetError());

		SDL_VERSION(&sys_wm_info.version);
		if(!SDL_GetWindowWMInfo(draw_context,&sys_wm_info))
			Sys_Error ("Couldn't get window wm info: %s", SDL_GetError());

		previous_display = -1;
	}
	else
	{
		previous_display = SDL_GetWindowDisplayIndex(draw_context);
	}

	/* Ensure the window is not fullscreen */
	if (VID_GetFullscreen ())
	{
		if (SDL_SetWindowFullscreen (draw_context, 0) != 0)
			Sys_Error("Couldn't set fullscreen state mode: %s", SDL_GetError());
	}

	/* Set window size and display mode */
	SDL_SetWindowSize (draw_context, width, height);
	if (previous_display >= 0)
		SDL_SetWindowPosition (draw_context, SDL_WINDOWPOS_CENTERED_DISPLAY(previous_display), SDL_WINDOWPOS_CENTERED_DISPLAY(previous_display));
	else
		SDL_SetWindowPosition(draw_context, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED);
	SDL_SetWindowDisplayMode (draw_context, VID_SDL2_GetDisplayMode(width, height, refreshrate, bpp));
	SDL_SetWindowBordered (draw_context, vid_borderless.value ? SDL_FALSE : SDL_TRUE);

	/* Make window fullscreen if needed, and show the window */

	if (fullscreen) {
		Uint32 flags = vid_desktopfullscreen.value ?
			SDL_WINDOW_FULLSCREEN_DESKTOP :
			SDL_WINDOW_FULLSCREEN;
		if (SDL_SetWindowFullscreen (draw_context, flags) != 0)
			Sys_Error ("Couldn't set fullscreen state mode: %s", SDL_GetError());
	}
	
	
	SDL_ShowWindow (draw_context);

	vid.width = VID_GetCurrentWidth();
	vid.height = VID_GetCurrentHeight();
	vid.conwidth = vid.width & 0xFFFFFFF8;
	vid.conheight = vid.conwidth * vid.height / vid.width;
	vid.numpages = 2;

	modestate = VID_GetFullscreen() ? MS_FULLSCREEN : MS_WINDOWED;

	CDAudio_Resume ();
	BGM_Resume ();
	scr_disabled_for_loading = temp;

// fix the leftover Alt from any Alt-Tab or the like that switched us away
	ClearAllStates ();

	vid.recalc_refdef = 1;

// no pending changes
	vid_changed = false;

	return true;
}

/*
===================
VID_Changed_f -- kristian -- notify us that a value has changed that requires a vid_restart
===================
*/
static void VID_Changed_f (cvar_t *var)
{
	vid_changed = true;
}

/*
===================
VID_FilterChanged_f
===================
*/
static void VID_FilterChanged_f(cvar_t *var)
{
	R_InitSamplers();
}

/*
================
VID_Test -- johnfitz -- like vid_restart, but asks for confirmation after switching modes
================
*/
static void VID_Test (void)
{
	int old_width, old_height, old_refreshrate, old_bpp, old_fullscreen;

	if (vid_locked || !vid_changed)
		return;
//
// now try the switch
//
	old_width = VID_GetCurrentWidth();
	old_height = VID_GetCurrentHeight();
	old_refreshrate = VID_GetCurrentRefreshRate();
	old_bpp = VID_GetCurrentBPP();
	old_fullscreen = VID_GetFullscreen() ? true : false;

	VID_Restart ();

	//pop up confirmation dialoge
	if (!SCR_ModalMessage("Would you like to keep this\nvideo mode? (y/n)\n", 5.0f))
	{
		//revert cvars and mode
		Cvar_SetValueQuick (&vid_width, old_width);
		Cvar_SetValueQuick (&vid_height, old_height);
		Cvar_SetValueQuick (&vid_refreshrate, old_refreshrate);
		Cvar_SetValueQuick (&vid_bpp, old_bpp);
		Cvar_SetQuick (&vid_fullscreen, old_fullscreen ? "1" : "0");
		VID_Restart ();
	}
}

/*
================
VID_Unlock -- johnfitz
================
*/
static void VID_Unlock (void)
{
	vid_locked = false;
	VID_SyncCvars();
}

/*
================
VID_Lock -- ericw

Subsequent changes to vid_* mode settings, and vid_restart commands, will
be ignored until the "vid_unlock" command is run.

Used when changing gamedirs so the current settings override what was saved
in the config.cfg.
================
*/
void VID_Lock (void)
{
	vid_locked = true;
}

//==============================================================================
//
//	Metal Stuff
//
//==============================================================================

/*
===============
GL_InitInstance
===============
*/
static void GL_InitInstance( void )
{
	// Find metal driver
	int metalDriverIdx = -1;
	int drivers = SDL_GetNumRenderDrivers();
	for (int i=0; i<drivers; i++)
	{
		SDL_RendererInfo info;
		SDL_GetRenderDriverInfo(i, &info);
		
		if (strcasecmp(info.name, "metal") == 0)
		{
			metalDriverIdx = i;
		}
		//printf("Render driver[%i] == %s\n", i, info.name);
	}
	
	if (metalDriverIdx == -1)
	{
		Sys_Error("Unable to find metal render driver for SDL\n");
	}
	
	r_metalstate.current_renderer = SDL_CreateRenderer(draw_context, metalDriverIdx, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
	r_metalstate.current_window = draw_context;
}

/*
===============
GL_InitDevice
===============
*/
static void GL_InitDevice( void )
{
	CAMetalLayer* layer = (__bridge CAMetalLayer*)(SDL_RenderGetMetalLayer(r_metalstate.current_renderer));
	r_metalstate.device = layer.device;
	r_metalstate.metal_layer = layer;
	
	if (!r_metalstate.device)
	{
		Sys_Error("Couldn't find any Metal devices");
	}
	
	// TODO: memory type?
	
	Con_Printf("Device: %s\n", [r_metalstate.device.name UTF8String]);

	// GFX queue?
	// supportsFeatureSet?
	
#if TARGET_OS_OSX
	r_metalstate.color_format = r_metalstate.metal_layer.pixelFormat;
	r_metalstate.depth_format = MTLPixelFormatDepth32Float;
	
	if ( [r_metalstate.device supportsFeatureSet: MTLFeatureSet_OSX_GPUFamily1_v1] ) {
		r_metalstate.max_texture_dimension = 16 * 1024;
		r_metalstate.vbo_alignment = 256;
	}
	
#elif TARGET_OS_IOS
	
	if ( [r_metalstate.device supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily1_v1] ) {
		r_metalstate.max_texture_dimension = 4 * 1024;
		r_metalstate.vbo_alignment = 64;
	}
	
	if ( [r_metalstate.device supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily1_v2] ) {
		r_metalstate.max_texture_dimension = 8 * 1024;
	}
	
	if ( [r_metalstate.device supportsFeatureSet: MTLFeatureSet_iOS_GPUFamily3_v1] ) {
		r_metalstate.max_texture_dimension = 16 * 1024;
		r_metalstate.vbo_alignment = 16;
	}
#endif
	
}

static id<CAMetalDrawable> _current_drawable;


/*
===============
GL_InitCommandBuffers
===============
*/
static void GL_InitCommandBuffers( void )
{
	r_metalstate.frame_semaphore = dispatch_semaphore_create(NUM_COMMAND_BUFFERS);
	r_metalstate.command_queue = [r_metalstate.device newCommandQueueWithMaxCommandBufferCount:NUM_COMMAND_BUFFERS];
	if (!r_metalstate.command_queue)
	{
		Sys_Error("newCommandQueue failed");
	}
}

MTLRenderPassDescriptor* ui_render_pass_descriptor;
MTLRenderPassDescriptor* main_render_pass_descriptors[2];
MTLRenderPassDescriptor* warp_render_pass_descriptor;
MTLRenderPassDescriptor* postprocess_render_pass_descriptor;

/*
====================
GL_CreateRenderPasses
====================
*/
static void GL_CreateRenderPasses()
{
	NSError* err = nil;
	Con_Printf("Creating render passes\n");
	
	ui_render_pass_descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
	main_render_pass_descriptors[0] = [MTLRenderPassDescriptor renderPassDescriptor];
	main_render_pass_descriptors[1] = [MTLRenderPassDescriptor renderPassDescriptor];
	postprocess_render_pass_descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
	
	{
		main_render_pass_descriptors[0].colorAttachments[0].texture = r_metalstate.color_buffers[0];
		main_render_pass_descriptors[0].colorAttachments[0].loadAction = MTLLoadActionClear;
		main_render_pass_descriptors[0].colorAttachments[0].clearColor = MTLClearColorMake(0.0, 1.0, 1.0, 1.0);
		main_render_pass_descriptors[0].colorAttachments[0].storeAction = MTLStoreActionStore;
		
		main_render_pass_descriptors[0].depthAttachment.texture = r_metalstate.depth_buffer;
		main_render_pass_descriptors[0].depthAttachment.loadAction = MTLLoadActionClear;
		main_render_pass_descriptors[0].depthAttachment.storeAction = MTLStoreActionDontCare;
		main_render_pass_descriptors[0].depthAttachment.clearDepth = 1.0;
	}
	
	{
		main_render_pass_descriptors[1].colorAttachments[0].texture = r_metalstate.color_buffers[1];
		main_render_pass_descriptors[1].colorAttachments[0].loadAction = MTLLoadActionClear;
		main_render_pass_descriptors[1].colorAttachments[0].clearColor = MTLClearColorMake(0.0, 1.0, 1.0, 1.0);
		main_render_pass_descriptors[1].colorAttachments[0].storeAction = MTLStoreActionStore;
		
		main_render_pass_descriptors[1].depthAttachment.texture = r_metalstate.depth_buffer;
		main_render_pass_descriptors[1].depthAttachment.loadAction = MTLLoadActionClear;
		main_render_pass_descriptors[1].depthAttachment.storeAction = MTLStoreActionDontCare;
		main_render_pass_descriptors[1].depthAttachment.clearDepth = 1.0;
	}
	
	{
		ui_render_pass_descriptor.colorAttachments[0].texture = r_metalstate.color_buffers[0]; // set to swapchain image
		ui_render_pass_descriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
		ui_render_pass_descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
		
		ui_render_pass_descriptor.depthAttachment.texture = r_metalstate.depth_buffer;
		ui_render_pass_descriptor.depthAttachment.loadAction = MTLLoadActionClear;
		ui_render_pass_descriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
		ui_render_pass_descriptor.depthAttachment.clearDepth = 1.0;
	}
	
	{
		postprocess_render_pass_descriptor.colorAttachments[0].texture = nil; // set to swapchain image
		postprocess_render_pass_descriptor.colorAttachments[0].loadAction = MTLLoadActionDontCare;
		postprocess_render_pass_descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
		
		postprocess_render_pass_descriptor.depthAttachment.texture = r_metalstate.depth_buffer;
		postprocess_render_pass_descriptor.depthAttachment.loadAction = MTLLoadActionClear;
		postprocess_render_pass_descriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
		postprocess_render_pass_descriptor.depthAttachment.clearDepth = 1.0;
	}
	
	{
		warp_render_pass_descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
		
		warp_render_pass_descriptor.colorAttachments[0].texture = nil; // set to swapchain image
		warp_render_pass_descriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
		warp_render_pass_descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
		
		warp_render_pass_descriptor.depthAttachment.texture = r_metalstate.depth_buffer;
		warp_render_pass_descriptor.depthAttachment.loadAction = MTLLoadActionClear;
		warp_render_pass_descriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
		warp_render_pass_descriptor.depthAttachment.clearDepth = 1.0;
	}
}

/*
===============
GL_CreateDepthBuffer
===============
*/
static void GL_CreateDepthBuffer( void )
{
	Con_Printf("Creating depth buffer\n");

	if(r_metalstate.depth_buffer != nil)
		return;

	NSError* err = nil;
	
	MTLTextureDescriptor * depthDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:r_metalstate.depth_format width:vid.width height:vid.height mipmapped:NO];
	depthDescriptor.usage = MTLTextureUsageUnknown;
	depthDescriptor.storageMode = MTLStorageModePrivate;
	depthDescriptor.resourceOptions = MTLResourceStorageModePrivate;
	num_metal_misc_allocations += 1;
	
	r_metalstate.depth_buffer = [r_metalstate.device newTextureWithDescriptor:depthDescriptor];
	r_metalstate.depth_buffer.label = @"Depth Buffer";
}

/*
===============
GL_CreateColorBuffer
===============
*/
static void GL_CreateColorBuffer( void )
{
	NSError* err = nil;
	int i;
	
	Con_Printf("Creating color buffer\n");
	
	MTLTextureDescriptor * colorDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:r_metalstate.color_format width:vid.width height:vid.height mipmapped:NO];
	colorDescriptor.usage = MTLTextureUsageUnknown;
	colorDescriptor.storageMode = MTLStorageModePrivate;
	colorDescriptor.resourceOptions = MTLResourceStorageModePrivate;
	
	r_metalstate.color_buffers[0] = [r_metalstate.device newTextureWithDescriptor:colorDescriptor];
	r_metalstate.color_buffers[0].label = [NSString stringWithFormat:@"Color Buffer 0"];
	r_metalstate.color_buffers[1] = [r_metalstate.device newTextureWithDescriptor:colorDescriptor];
	r_metalstate.color_buffers[1].label = [NSString stringWithFormat:@"Color Buffer 1"];
	
	num_metal_misc_allocations += 2;
}

/*
===============
GL_CreateDescriptorSets
===============
*/
static void GL_CreateDescriptorSets(void)
{
}

/*
===============
GL_CreateSwapChain
===============
*/
static qboolean GL_CreateSwapChain( void )
{
	// create semaphores. swap chain managed by sdl.

	r_metalstate.frame_semaphore = dispatch_semaphore_create(NUM_FORWARD_FRAMES);
	
	
	return true;
}


/*
===============
GL_CreateFrameBuffers
===============
*/
static void GL_CreateFrameBuffers( void )
{
}

/*
===============
GL_CreateRenderResources
===============
*/
static void GL_CreateRenderResources( void )
{
	if (!GL_CreateSwapChain()) {
		render_resources_created = false;
		return;
	}

	GL_CreateColorBuffer();
	GL_CreateDepthBuffer();
	GL_CreateRenderPasses();
	GL_CreateFrameBuffers();
	R_CreatePipelines();
	GL_CreateDescriptorSets();

	render_resources_created = true;
}

/*
===============
GL_DestroyRenderResources
===============
*/
static void GL_DestroyRenderResources( void )
{
	uint32_t i;
	
	render_resources_created = false;
	
	GL_WaitForDeviceIdle();
	
	R_DestroyPipelines();
	
	r_metalstate.color_buffers[0] = nil;
	r_metalstate.color_buffers[1] = nil;
	r_metalstate.depth_buffer = nil;
	num_metal_misc_allocations -= 3;
}

/*
=================
GL_BeginRendering
=================
*/
qboolean GL_BeginRendering (int *x, int *y, int *width, int *height)
{
	int i;

	if (!render_resources_created) {
		GL_CreateRenderResources();

		if (!render_resources_created) {
			return false;
		}
	}

	R_SwapDynamicBuffers();
	
	if (dispatch_semaphore_wait(r_metalstate.frame_semaphore, DISPATCH_TIME_NOW) != 0)
	{
		return false;
	}

	r_metalstate.device_idle = false;
	r_metalstate.current_pipeline = nil;
	r_metalstate.render_encoder = nil;
	*x = *y = 0;
	*width = vid.width;
	*height = vid.height;

	NSError* err;
	
	r_metalstate.current_command_buffer = [r_metalstate.command_queue commandBuffer];
	r_metalstate.current_command_buffer.label = @"command buffer";

	MTLViewport viewport;
	viewport.originX = 0;
	viewport.originY = 0;
	viewport.width = vid.width;
	viewport.height = vid.height;
	viewport.znear = 0.0f;
	viewport.zfar = 1.0f;
	
	r_metalstate.scene_viewport = viewport;
	
	return true;
}

/*
=================
GL_AcquireNextSwapChainImage
=================
*/
qboolean GL_AcquireNextSwapChainImage(void)
{
	_current_drawable = r_metalstate.metal_layer.nextDrawable;
	if (_current_drawable == nil)
		return false;
	
	return true;
}

/*
=================
GL_EndRendering
=================
*/
void GL_EndRendering (qboolean swapchain_acquired)
{
	R_SubmitStagingBuffers();
	R_FlushDynamicBuffers();
	
	NSError *err;
	
	R_EndPass();

	if (swapchain_acquired == true)
	{
		// Render post process
		float postprocess_values[2] = { vid_gamma.value, q_min(2.0f, q_max(1.0f, vid_contrast.value)) };
		postprocess_render_pass_descriptor.colorAttachments[0].texture = _current_drawable.texture;
		
		r_metalstate.render_encoder = [r_metalstate.current_command_buffer renderCommandEncoderWithDescriptor:postprocess_render_pass_descriptor];
		r_metalstate.render_encoder.label = @"post process";
		postprocess_render_pass_descriptor.colorAttachments[0].texture = nil;
		
		GL_Viewport(0, 0, vid.width, vid.height);
		
		R_BindPipeline(&r_metalstate.postprocess_pipeline);
		memcpy(&r_metalstate.push_constants[0], &postprocess_values[0], 2 * sizeof(float));
		r_metalstate.push_constants_dirty = true;
		R_UpdatePushConstants();
		
		[r_metalstate.render_encoder setFragmentSamplerState:r_metalstate.point_sampler atIndex:0];
		[r_metalstate.render_encoder setFragmentTexture:r_metalstate.color_buffers[0] atIndex:0];
		[r_metalstate.render_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		
		R_EndPass();
	}
	
	r_metalstate.render_encoder = nil;
	r_metalstate.device_idle = false;
	r_metalstate.push_constants_dirty = true;

	if (swapchain_acquired == true)
	{
		[r_metalstate.current_command_buffer addCompletedHandler:^(id<MTLCommandBuffer> buffer)
		 {
			 dispatch_semaphore_signal(r_metalstate.frame_semaphore);
		 }];
		
		[r_metalstate.current_command_buffer presentDrawable:_current_drawable];
		[r_metalstate.current_command_buffer commit];
	}
	else
	{
		// dispatch immediately
		dispatch_semaphore_signal(r_metalstate.frame_semaphore);
	}
	
	r_metalstate.last_submitted_command_buffer = r_metalstate.current_command_buffer;
	r_metalstate.current_command_buffer= nil;
}

/*
=================
GL_WaitForDeviceIdle
=================
*/
void GL_WaitForDeviceIdle (void)
{
	if (!r_metalstate.device_idle)
	{
		R_SubmitStagingBuffers();
		[r_metalstate.last_submitted_command_buffer waitUntilCompleted];
	}

	r_metalstate.device_idle = true;
}

/*
=================
VID_Shutdown
=================
*/
void VID_Shutdown (void)
{
	if (vid_initialized)
	{
		SDL_QuitSubSystem(SDL_INIT_VIDEO);
		draw_context = NULL;
		PL_VID_Shutdown();
	}
}

/*
===================================================================

MAIN WINDOW

===================================================================
*/

/*
================
ClearAllStates
================
*/
static void ClearAllStates (void)
{
	Key_ClearStates ();
	IN_ClearStates ();
}


//==========================================================================
//
//  COMMANDS
//
//==========================================================================

/*
=================
VID_DescribeCurrentMode_f
=================
*/
static void VID_DescribeCurrentMode_f (void)
{
	if (draw_context)
		Con_Printf("%dx%dx%d %dHz %s\n",
			VID_GetCurrentWidth(),
			VID_GetCurrentHeight(),
			VID_GetCurrentBPP(),
			VID_GetCurrentRefreshRate(),
			VID_GetFullscreen() ? "fullscreen" : "windowed");
}

/*
=================
VID_DescribeModes_f -- johnfitz -- changed formatting, and added refresh rates after each mode.
=================
*/
static void VID_DescribeModes_f (void)
{
	int	i;
	int	lastwidth, lastheight, lastbpp, count;

	lastwidth = lastheight = lastbpp = count = 0;

	for (i = 0; i < nummodes; i++)
	{
		if (lastwidth != modelist[i].width || lastheight != modelist[i].height || lastbpp != modelist[i].bpp)
		{
			if (count > 0)
				Con_SafePrintf ("\n");
			Con_SafePrintf ("	%4i x %4i x %i : %i", modelist[i].width, modelist[i].height, modelist[i].bpp, modelist[i].refreshrate);
			lastwidth = modelist[i].width;
			lastheight = modelist[i].height;
			lastbpp = modelist[i].bpp;
			count++;
		}
	}
	Con_Printf ("\n%i modes\n", count);
}

//==========================================================================
//
//  INIT
//
//==========================================================================

/*
=================
VID_InitModelist
=================
*/
static void VID_InitModelist (void)
{
	const int sdlmodes = SDL_GetNumDisplayModes(0);
	int i;

	nummodes = 0;
	for (i = 0; i < sdlmodes; i++)
	{
		SDL_DisplayMode mode;

		if (nummodes >= MAX_MODE_LIST)
			break;
		if (SDL_GetDisplayMode(0, i, &mode) == 0)
		{
			modelist[nummodes].width = mode.w;
			modelist[nummodes].height = mode.h;
			modelist[nummodes].bpp = SDL_BITSPERPIXEL(mode.format);
			modelist[nummodes].refreshrate = mode.refresh_rate;
			nummodes++;
		}
	}
}

/*
===================
VID_Init
===================
*/
void	VID_Init (void)
{
	static char vid_center[] = "SDL_VIDEO_CENTERED=center";
	int		p, width, height, refreshrate, bpp;
	int		display_width, display_height, display_refreshrate, display_bpp;
	qboolean	fullscreen;
	const char	*read_vars[] = { "vid_fullscreen",
					 "vid_width",
					 "vid_height",
					 "vid_refreshrate",
					 "vid_bpp",
					 "vid_vsync",
					 "vid_desktopfullscreen",
					 "vid_fsaamode",
					 "vid_fsaa",
					 "vid_borderless"};
#define num_readvars	( sizeof(read_vars)/sizeof(read_vars[0]) )

	Cvar_RegisterVariable (&vid_fullscreen); //johnfitz
	Cvar_RegisterVariable (&vid_width); //johnfitz
	Cvar_RegisterVariable (&vid_height); //johnfitz
	Cvar_RegisterVariable (&vid_refreshrate); //johnfitz
	Cvar_RegisterVariable (&vid_bpp); //johnfitz
	Cvar_RegisterVariable (&vid_vsync); //johnfitz
	Cvar_RegisterVariable (&vid_filter);
	Cvar_RegisterVariable (&vid_anisotropic);
	Cvar_RegisterVariable (&vid_fsaamode);
	Cvar_RegisterVariable (&vid_fsaa);
	Cvar_RegisterVariable (&vid_desktopfullscreen); //QuakeSpasm
	Cvar_RegisterVariable (&vid_borderless); //QuakeSpasm
	Cvar_SetCallback (&vid_fullscreen, VID_Changed_f);
	Cvar_SetCallback (&vid_width, VID_Changed_f);
	Cvar_SetCallback (&vid_height, VID_Changed_f);
	Cvar_SetCallback (&vid_refreshrate, VID_Changed_f);
	Cvar_SetCallback (&vid_bpp, VID_Changed_f);
	Cvar_SetCallback (&vid_filter, VID_FilterChanged_f);
	Cvar_SetCallback (&vid_anisotropic, VID_FilterChanged_f);
	Cvar_SetCallback (&vid_fsaamode, VID_Changed_f);
	Cvar_SetCallback (&vid_fsaa, VID_Changed_f);
	Cvar_SetCallback (&vid_vsync, VID_Changed_f);
	Cvar_SetCallback (&vid_desktopfullscreen, VID_Changed_f);
	Cvar_SetCallback (&vid_borderless, VID_Changed_f);
	
	Cmd_AddCommand ("vid_unlock", VID_Unlock); //johnfitz
	Cmd_AddCommand ("vid_restart", VID_Restart); //johnfitz
	Cmd_AddCommand ("vid_test", VID_Test); //johnfitz
	Cmd_AddCommand ("vid_describecurrentmode", VID_DescribeCurrentMode_f);
	Cmd_AddCommand ("vid_describemodes", VID_DescribeModes_f);

	putenv (vid_center);	/* SDL_putenv is problematic in versions <= 1.2.9 */

	if (SDL_InitSubSystem(SDL_INIT_VIDEO) < 0)
		Sys_Error("Couldn't init SDL video: %s", SDL_GetError());

	{
		SDL_DisplayMode mode;
		if (SDL_GetDesktopDisplayMode(0, &mode) != 0)
			Sys_Error("Could not get desktop display mode: %s\n", SDL_GetError());

		display_width = mode.w;
		display_height = mode.h;
		display_refreshrate = mode.refresh_rate;
		display_bpp = SDL_BITSPERPIXEL(mode.format);
	}

	Cvar_SetValueQuick (&vid_bpp, (float)display_bpp);

	if (CFG_OpenConfig("config.cfg") == 0)
	{
		CFG_ReadCvars(read_vars, num_readvars);
		CFG_CloseConfig();
	}
	CFG_ReadCvarOverrides(read_vars, num_readvars);

	VID_InitModelist();

	width = (int)vid_width.value;
	height = (int)vid_height.value;
	refreshrate = (int)vid_refreshrate.value;
	bpp = (int)vid_bpp.value;
	fullscreen = (int)vid_fullscreen.value;

	if (COM_CheckParm("-current"))
	{
		width = display_width;
		height = display_height;
		refreshrate = display_refreshrate;
		bpp = display_bpp;
		fullscreen = true;
	}
	else
	{
		p = COM_CheckParm("-width");
		if (p && p < com_argc-1)
		{
			width = Q_atoi(com_argv[p+1]);

			if(!COM_CheckParm("-height"))
				height = width * 3 / 4;
		}

		p = COM_CheckParm("-height");
		if (p && p < com_argc-1)
		{
			height = Q_atoi(com_argv[p+1]);

			if(!COM_CheckParm("-width"))
				width = height * 4 / 3;
		}

		p = COM_CheckParm("-refreshrate");
		if (p && p < com_argc-1)
			refreshrate = Q_atoi(com_argv[p+1]);

		p = COM_CheckParm("-bpp");
		if (p && p < com_argc-1)
			bpp = Q_atoi(com_argv[p+1]);

		if (COM_CheckParm("-window") || COM_CheckParm("-w"))
			fullscreen = false;
		else if (COM_CheckParm("-fullscreen") || COM_CheckParm("-f"))
			fullscreen = true;
	}

	if (!VID_ValidMode(width, height, refreshrate, bpp, fullscreen))
	{
		width = (int)vid_width.value;
		height = (int)vid_height.value;
		refreshrate = (int)vid_refreshrate.value;
		bpp = (int)vid_bpp.value;
		fullscreen = (int)vid_fullscreen.value;
	}

	if (!VID_ValidMode(width, height, refreshrate, bpp, fullscreen))
	{
		width = 640;
		height = 480;
		refreshrate = display_refreshrate;
		bpp = display_bpp;
		fullscreen = false;
	}

	vid_initialized = true;

	vid.colormap = host_colormap;
	vid.fullbright = 256 - LittleLong (*((int *)vid.colormap + 2048));

	// set window icon
	PL_SetWindowIcon();

	VID_SetMode (width, height, refreshrate, bpp, fullscreen);

	Con_Printf("\nMetal Initialization\n");
	GL_InitInstance();
	GL_InitDevice();
	GL_InitCommandBuffers();
	r_metalstate.staging_buffer_size = INITIAL_STAGING_BUFFER_SIZE_KB * 1024;
	R_InitStagingBuffers();
	R_CreateDescriptorSetLayouts();
	R_CreateDescriptorPool();
	R_InitGPUBuffers();
	R_InitSamplers();
	R_CreatePipelineLayouts();

	GL_CreateRenderResources();

	//johnfitz -- removed code creating "glquake" subdirectory

	vid_menucmdfn = VID_Menu_f; //johnfitz
	vid_menudrawfn = VID_MenuDraw;
	vid_menukeyfn = VID_MenuKey;

	VID_Gamma_Init(); //johnfitz
	VID_Menu_Init(); //johnfitz

	//QuakeSpasm: current vid settings should override config file settings.
	//so we have to lock the vid mode from now until after all config files are read.
	vid_locked = true;
}

/*
===================
VID_Restart -- johnfitz -- change video modes on the fly
===================
*/
static void VID_Restart (void)
{
	int width, height, refreshrate, bpp;
	qboolean fullscreen;

	if (vid_locked || !vid_changed)
		return;

	width = (int)vid_width.value;
	height = (int)vid_height.value;
	refreshrate = (int)vid_refreshrate.value;
	bpp = (int)vid_bpp.value;
	fullscreen = vid_fullscreen.value ? true : false;

	//
	// validate new mode
	//
	if (!VID_ValidMode (width, height, refreshrate, bpp, fullscreen))
	{
		Con_Printf ("%dx%dx%d %dHz %s is not a valid mode\n",
				width, height, bpp, refreshrate, fullscreen? "fullscreen" : "windowed");
		return;
	}

	scr_initialized = false;
	
	GL_WaitForDeviceIdle();
	GL_DestroyRenderResources();

	//
	// set new mode
	//
	VID_SetMode (width, height, refreshrate, bpp, fullscreen);

	GL_CreateRenderResources();

	//conwidth and conheight need to be recalculated
	vid.conwidth = (scr_conwidth.value > 0) ? (int)scr_conwidth.value : (scr_conscale.value > 0) ? (int)(vid.width/scr_conscale.value) : vid.width;
	vid.conwidth = CLAMP (320, vid.conwidth, vid.width);
	vid.conwidth &= 0xFFFFFFF8;
	vid.conheight = vid.conwidth * vid.height / vid.width;
	//
	// keep cvars in line with actual mode
	//
	VID_SyncCvars();

	//
	// update mouse grab
	//
	if (key_dest == key_console || key_dest == key_menu)
	{
		if (modestate == MS_WINDOWED)
			IN_Deactivate(true);
		else if (modestate == MS_FULLSCREEN)
			IN_Activate();
	}

	scr_initialized = true;
}

// new proc by S.A., called by alt-return key binding.
void	VID_Toggle (void)
{
	// disabling the fast path completely because SDL_SetWindowFullscreen was changing
	// the window size on SDL2/WinXP and we weren't set up to handle it. --ericw
	//
	// TODO: Clear out the dead code, reinstate the fast path using SDL_SetWindowFullscreen
	// inside VID_SetMode, check window size to fix WinXP issue. This will
	// keep all the mode changing code in one place.
	static qboolean vid_toggle_works = false;
	qboolean toggleWorked;
	Uint32 flags = 0;

	S_ClearBuffer ();

	if (!vid_toggle_works)
		goto vrestart;
	else
	{
		// disabling the fast path because with SDL 1.2 it invalidates VBOs (using them
		// causes a crash, sugesting that the fullscreen toggle created a new GL context,
		// although texture objects remain valid for some reason).
		//
		// SDL2 does promise window resizes / fullscreen changes preserve the GL context,
		// so we could use the fast path with SDL2. --ericw
		vid_toggle_works = false;
		goto vrestart;
	}

	if (!VID_GetFullscreen())
	{
		flags = vid_desktopfullscreen.value ? SDL_WINDOW_FULLSCREEN_DESKTOP : SDL_WINDOW_FULLSCREEN;
	}

	toggleWorked = SDL_SetWindowFullscreen(draw_context, flags) == 0;

	if (toggleWorked)
	{
		Sbar_Changed ();	// Sbar seems to need refreshing

		modestate = VID_GetFullscreen() ? MS_FULLSCREEN : MS_WINDOWED;

		VID_SyncCvars();

		// update mouse grab
		if (key_dest == key_console || key_dest == key_menu)
		{
			if (modestate == MS_WINDOWED)
				IN_Deactivate(true);
			else if (modestate == MS_FULLSCREEN)
				IN_Activate();
		}
	}
	else
	{
		vid_toggle_works = false;
		Con_DPrintf ("SDL_WM_ToggleFullScreen failed, attempting VID_Restart\n");
	vrestart:
		Cvar_SetQuick (&vid_fullscreen, VID_GetFullscreen() ? "0" : "1");
		Cbuf_AddText ("vid_restart\n");
	}
}

/*
================
VID_SyncCvars -- johnfitz -- set vid cvars to match current video mode
================
*/
void VID_SyncCvars (void)
{
	if (draw_context)
	{
		if (!VID_GetDesktopFullscreen())
		{
			Cvar_SetValueQuick (&vid_width, VID_GetCurrentWidth());
			Cvar_SetValueQuick (&vid_height, VID_GetCurrentHeight());
		}
		Cvar_SetValueQuick (&vid_refreshrate, VID_GetCurrentRefreshRate());
		Cvar_SetValueQuick (&vid_bpp, VID_GetCurrentBPP());
		Cvar_SetQuick (&vid_fullscreen, VID_GetFullscreen() ? "1" : "0");
		// don't sync vid_desktopfullscreen, it's a user preference that
		// should persist even if we are in windowed mode.
	}

	vid_changed = false;
}

//==========================================================================
//
//  NEW VIDEO MENU -- johnfitz
//
//==========================================================================

enum {
	VID_OPT_MODE,
	VID_OPT_BPP,
	VID_OPT_REFRESHRATE,
	VID_OPT_FULLSCREEN,
	VID_OPT_VSYNC,
	VID_OPT_ANTIALIASING_SAMPLES,
	VID_OPT_ANTIALIASING_MODE,
	VID_OPT_FILTER,
	VID_OPT_ANISOTROPY,
	VID_OPT_UNDERWATER,
	VID_OPT_TEST,
	VID_OPT_APPLY,
	VIDEO_OPTIONS_ITEMS
};

static int	video_options_cursor = 0;

typedef struct {
	int width,height;
} vid_menu_mode;

//TODO: replace these fixed-length arrays with hunk_allocated buffers
static vid_menu_mode vid_menu_modes[MAX_MODE_LIST];
static int vid_menu_nummodes = 0;

static int vid_menu_bpps[MAX_BPPS_LIST];
static int vid_menu_numbpps = 0;

static int vid_menu_rates[MAX_RATES_LIST];
static int vid_menu_numrates=0;

/*
================
VID_Menu_Init
================
*/
static void VID_Menu_Init (void)
{
	int i, j, h, w;

	for (i = 0; i < nummodes; i++)
	{
		w = modelist[i].width;
		h = modelist[i].height;

		for (j = 0; j < vid_menu_nummodes; j++)
		{
			if (vid_menu_modes[j].width == w &&
				vid_menu_modes[j].height == h)
				break;
		}

		if (j == vid_menu_nummodes)
		{
			vid_menu_modes[j].width = w;
			vid_menu_modes[j].height = h;
			vid_menu_nummodes++;
		}
	}
}

/*
================
VID_Menu_RebuildBppList

regenerates bpp list based on current vid_width and vid_height
================
*/
static void VID_Menu_RebuildBppList (void)
{
	int i, j, b;

	vid_menu_numbpps = 0;

	for (i = 0; i < nummodes; i++)
	{
		if (vid_menu_numbpps >= MAX_BPPS_LIST)
			break;

		//bpp list is limited to bpps available with current width/height
		if (modelist[i].width != vid_width.value ||
			modelist[i].height != vid_height.value)
			continue;

		b = modelist[i].bpp;

		for (j = 0; j < vid_menu_numbpps; j++)
		{
			if (vid_menu_bpps[j] == b)
				break;
		}

		if (j == vid_menu_numbpps)
		{
			vid_menu_bpps[j] = b;
			vid_menu_numbpps++;
		}
	}

	//if there are no valid fullscreen bpps for this width/height, just pick one
	if (vid_menu_numbpps == 0)
	{
		Cvar_SetValueQuick (&vid_bpp, (float)modelist[0].bpp);
		return;
	}

	//if vid_bpp is not in the new list, change vid_bpp
	for (i = 0; i < vid_menu_numbpps; i++)
		if (vid_menu_bpps[i] == (int)(vid_bpp.value))
			break;

	if (i == vid_menu_numbpps)
		Cvar_SetValueQuick (&vid_bpp, (float)vid_menu_bpps[0]);
}

/*
================
VID_Menu_RebuildRateList

regenerates rate list based on current vid_width, vid_height and vid_bpp
================
*/
static void VID_Menu_RebuildRateList (void)
{
	int i,j,r;
	
	vid_menu_numrates=0;
	
	for (i=0;i<nummodes;i++)
	{
		//rate list is limited to rates available with current width/height/bpp
		if (modelist[i].width != vid_width.value ||
			 modelist[i].height != vid_height.value ||
			 modelist[i].bpp != vid_bpp.value)
			continue;
		
		r = modelist[i].refreshrate;
		
		for (j=0;j<vid_menu_numrates;j++)
		{
			if (vid_menu_rates[j] == r)
				break;
		}
		
		if (j==vid_menu_numrates)
		{
			vid_menu_rates[j] = r;
			vid_menu_numrates++;
		}
	}
	
	//if there are no valid fullscreen refreshrates for this width/height, just pick one
	if (vid_menu_numrates == 0)
	{
		Cvar_SetValue ("vid_refreshrate",(float)modelist[0].refreshrate);
		return;
	}
	
	//if vid_refreshrate is not in the new list, change vid_refreshrate
	for (i=0;i<vid_menu_numrates;i++)
		if (vid_menu_rates[i] == (int)(vid_refreshrate.value))
			break;
	
	if (i==vid_menu_numrates)
		Cvar_SetValue ("vid_refreshrate",(float)vid_menu_rates[0]);
}

/*
================
VID_Menu_ChooseNextMode

chooses next resolution in order, then updates vid_width and
vid_height cvars, then updates bpp and refreshrate lists
================
*/
static void VID_Menu_ChooseNextMode (int dir)
{
	int i;

	if (vid_menu_nummodes)
	{
		for (i = 0; i < vid_menu_nummodes; i++)
		{
			if (vid_menu_modes[i].width == vid_width.value &&
				vid_menu_modes[i].height == vid_height.value)
				break;
		}

		if (i == vid_menu_nummodes) //can't find it in list, so it must be a custom windowed res
		{
			i = 0;
		}
		else
		{
			i += dir;
			if (i >= vid_menu_nummodes)
				i = 0;
			else if (i < 0)
				i = vid_menu_nummodes-1;
		}

		Cvar_SetValueQuick (&vid_width, (float)vid_menu_modes[i].width);
		Cvar_SetValueQuick (&vid_height, (float)vid_menu_modes[i].height);
		VID_Menu_RebuildBppList ();
		VID_Menu_RebuildRateList ();
	}
}

/*
================
VID_Menu_ChooseNextBpp

chooses next bpp in order, then updates vid_bpp cvar
================
*/
static void VID_Menu_ChooseNextBpp (int dir)
{
	int i;

	if (vid_menu_numbpps)
	{
		for (i = 0; i < vid_menu_numbpps; i++)
		{
			if (vid_menu_bpps[i] == vid_bpp.value)
				break;
		}

		if (i == vid_menu_numbpps) //can't find it in list
		{
			i = 0;
		}
		else
		{
			i += dir;
			if (i >= vid_menu_numbpps)
				i = 0;
			else if (i < 0)
				i = vid_menu_numbpps-1;
		}

		Cvar_SetValueQuick (&vid_bpp, (float)vid_menu_bpps[i]);
	}
}

/*
================
VID_Menu_ChooseNextAAMode
================
*/
static void VID_Menu_ChooseNextAAMode(int dir)
{
#ifdef METAL_WIP
	if(vulkan_physical_device_features.sampleRateShading) {
		Cvar_SetValueQuick(&vid_fsaamode, (float)(((int)vid_fsaamode.value + 2 + dir) % 2));
	}
#endif
}

/*
================
VID_Menu_ChooseNextAASamples
================
*/
static void VID_Menu_ChooseNextAASamples(int dir)
{
	int value = vid_fsaa.value;

	if (dir > 0)
	{
		if (value >= 8)
			value = 16;
		else if (value >= 4)
			value = 8;
		else if (value >= 2)
			value = 4;
		else
			value = 2;
	}
	else 
	{
		if (value <= 2)
			value = 0;
		else if (value <= 4)
			value = 2;
		else if (value <= 8)
			value = 4;
		else if (value <= 16)
			value = 8;
		else
			value = 16;
	}

	Cvar_SetValueQuick(&vid_fsaa, (float)value);
}

/*
================
VID_Menu_ChooseNextWaterWarp
================
*/
static void VID_Menu_ChooseNextWaterWarp (int dir)
{
	Cvar_SetValueQuick(&r_waterwarp, (float)(((int)r_waterwarp.value + 3 + dir) % 3));
}

/*
================
VID_Menu_ChooseNextRate

chooses next refresh rate in order, then updates vid_refreshrate cvar
================
*/
static void VID_Menu_ChooseNextRate (int dir)
{
	int i;
	
	for (i=0;i<vid_menu_numrates;i++)
	{
		if (vid_menu_rates[i] == vid_refreshrate.value)
			break;
	}
	
	if (i==vid_menu_numrates) //can't find it in list
	{
		i = 0;
	}
	else
	{
		i+=dir;
		if (i>=vid_menu_numrates)
			i = 0;
		else if (i<0)
			i = vid_menu_numrates-1;
	}
	
	Cvar_SetValue ("vid_refreshrate",(float)vid_menu_rates[i]);
}

/*
================
VID_MenuKey
================
*/
static void VID_MenuKey (int key)
{
	switch (key)
	{
	case K_ESCAPE:
		VID_SyncCvars (); //sync cvars before leaving menu. FIXME: there are other ways to leave menu
		S_LocalSound ("misc/menu1.wav");
		M_Menu_Options_f ();
		break;

	case K_UPARROW:
		S_LocalSound ("misc/menu1.wav");
		video_options_cursor--;
		if (video_options_cursor < 0)
			video_options_cursor = VIDEO_OPTIONS_ITEMS-1;
		break;

	case K_DOWNARROW:
		S_LocalSound ("misc/menu1.wav");
		video_options_cursor++;
		if (video_options_cursor >= VIDEO_OPTIONS_ITEMS)
			video_options_cursor = 0;
		break;

	case K_LEFTARROW:
		S_LocalSound ("misc/menu3.wav");
		switch (video_options_cursor)
		{
		case VID_OPT_MODE:
			VID_Menu_ChooseNextMode (1);
			break;
		case VID_OPT_BPP:
			VID_Menu_ChooseNextBpp (1);
			break;
		case VID_OPT_REFRESHRATE:
			VID_Menu_ChooseNextRate (1);
			break;
		case VID_OPT_FULLSCREEN:
			Cbuf_AddText ("toggle vid_fullscreen\n");
			break;
		case VID_OPT_VSYNC:
			Cbuf_AddText ("toggle vid_vsync\n"); // kristian
			break;
		case VID_OPT_ANTIALIASING_SAMPLES:
			VID_Menu_ChooseNextAASamples(-1);
			break;
		case VID_OPT_ANTIALIASING_MODE:
			VID_Menu_ChooseNextAAMode (-1);
			break;
		case VID_OPT_FILTER:
			Cbuf_AddText ("toggle vid_filter\n");
			break;
		case VID_OPT_ANISOTROPY:
			Cbuf_AddText ("toggle vid_anisotropic\n");
			break;
		case VID_OPT_UNDERWATER:
			VID_Menu_ChooseNextWaterWarp (-1);
			break;
		default:
			break;
		}
		break;

	case K_RIGHTARROW:
		S_LocalSound ("misc/menu3.wav");
		switch (video_options_cursor)
		{
		case VID_OPT_MODE:
			VID_Menu_ChooseNextMode (-1);
			break;
		case VID_OPT_BPP:
			VID_Menu_ChooseNextBpp (-1);
			break;
		case VID_OPT_REFRESHRATE:
			VID_Menu_ChooseNextRate (-1);
			break;
		case VID_OPT_FULLSCREEN:
			Cbuf_AddText ("toggle vid_fullscreen\n");
			break;
		case VID_OPT_VSYNC:
			Cbuf_AddText ("toggle vid_vsync\n");
			break;
		case VID_OPT_ANTIALIASING_SAMPLES:
			VID_Menu_ChooseNextAASamples(1);
			break;
		case VID_OPT_ANTIALIASING_MODE:
			VID_Menu_ChooseNextAAMode(1);
			break;
		case VID_OPT_FILTER:
			Cbuf_AddText ("toggle vid_filter\n");
			break;
		case VID_OPT_ANISOTROPY:
			Cbuf_AddText ("toggle vid_anisotropic\n");
			break;
		case VID_OPT_UNDERWATER:
			VID_Menu_ChooseNextWaterWarp (1);
			break;
		default:
			break;
		}
		break;

	case K_ENTER:
	case K_KP_ENTER:
		m_entersound = true;
		switch (video_options_cursor)
		{
		case VID_OPT_MODE:
			VID_Menu_ChooseNextMode (1);
			break;
		case VID_OPT_BPP:
			VID_Menu_ChooseNextBpp (1);
			break;
		case VID_OPT_REFRESHRATE:
			VID_Menu_ChooseNextRate (1);
			break;
		case VID_OPT_FULLSCREEN:
			Cbuf_AddText ("toggle vid_fullscreen\n");
			break;
		case VID_OPT_VSYNC:
			Cbuf_AddText ("toggle vid_vsync\n");
			break;
		case VID_OPT_ANTIALIASING_SAMPLES:
			VID_Menu_ChooseNextAASamples(1);
			break;
		case VID_OPT_ANTIALIASING_MODE:
			VID_Menu_ChooseNextAAMode(1);
			break;
		case VID_OPT_FILTER:
			Cbuf_AddText ("toggle vid_filter\n");
			break;
		case VID_OPT_ANISOTROPY:
			Cbuf_AddText ("toggle vid_anisotropic\n");
			break;
		case VID_OPT_UNDERWATER:
			VID_Menu_ChooseNextWaterWarp (1);
			break;
		case VID_OPT_TEST:
			Cbuf_AddText ("vid_test\n");
			break;
		case VID_OPT_APPLY:
			Cbuf_AddText ("vid_restart\n");
			key_dest = key_game;
			m_state = m_none;
			IN_Activate();
			break;
		default:
			break;
		}
		break;

	default:
		break;
	}
}

/*
================
VID_MenuDraw
================
*/
static void VID_MenuDraw (void)
{
	int i, y;
	qpic_t *p;
	const char *title;

	y = 4;

	// plaque
	p = Draw_CachePic ("gfx/qplaque.lmp");
	M_DrawTransPic (16, y, p);

	//p = Draw_CachePic ("gfx/vidmodes.lmp");
	p = Draw_CachePic ("gfx/p_option.lmp");
	M_DrawPic ( (320-p->width)/2, y, p);

	y += 28;

	// title
	title = "Video Options";
	M_PrintWhite ((320-8*strlen(title))/2, y, title);

	y += 16;

	// options
	for (i = 0; i < VIDEO_OPTIONS_ITEMS; i++)
	{
		switch (i)
		{
		case VID_OPT_MODE:
			M_Print (16, y, "        Video mode");
			M_Print (184, y, va("%ix%i", (int)vid_width.value, (int)vid_height.value));
			break;
		case VID_OPT_BPP:
			M_Print (16, y, "       Color depth");
			M_Print (184, y, va("%i", (int)vid_bpp.value));
			break;
		case VID_OPT_REFRESHRATE:
			M_Print (16, y, "      Refresh rate");
			M_Print (184, y, va("%i", (int)vid_refreshrate.value));
			break;
		case VID_OPT_FULLSCREEN:
			M_Print (16, y, "        Fullscreen");
			M_DrawCheckbox (184, y, (int)vid_fullscreen.value);
			break;
		case VID_OPT_VSYNC:
			M_Print (16, y, "     Vertical sync");
			M_DrawCheckbox (184, y, (int)vid_vsync.value);
			break;
		case VID_OPT_ANTIALIASING_SAMPLES:
			M_Print (16, y, "      Antialiasing");
			M_Print (184, y, ((int)vid_fsaa.value >= 2) ? va("%ix", CLAMP(2, (int)vid_fsaa.value, 16)) : "off");
			break;
		case VID_OPT_ANTIALIASING_MODE:
			M_Print (16, y, "           AA Mode");
			M_Print (184, y, ((int)vid_fsaamode.value == 0) ? "Multisample" : "Supersample");
			break;
		case VID_OPT_FILTER:
			M_Print (16, y, "            Filter");
			M_Print (184, y, ((int)vid_filter.value == 0) ? "smooth" : "classic");
			break;
		case VID_OPT_ANISOTROPY:
			M_Print (16, y, "       Anisotropic");
			M_Print (184, y, ((int)vid_anisotropic.value == 0) ? "off" : "on");
			break;
		case VID_OPT_UNDERWATER:
			M_Print (16, y, "     Underwater FX");
			M_Print (184, y, ((int)r_waterwarp.value == 0) ? "off" : (((int)r_waterwarp.value == 1)  ? "Classic" : "glQuake"));
			break;
		case VID_OPT_TEST:
			y += 8; //separate the test and apply items
			M_Print (16, y, "      Test changes");
			break;
		case VID_OPT_APPLY:
			M_Print (16, y, "     Apply changes");
			break;
		}

		if (video_options_cursor == i)
			M_DrawCharacter (168, y, 12+((int)(realtime*4)&1));

		y += 8;
	}
}

/*
================
VID_Menu_f
================
*/
static void VID_Menu_f (void)
{
	IN_Deactivate(modestate == MS_WINDOWED);
	key_dest = key_menu;
	m_state = m_video;
	m_entersound = true;

	//set all the cvars to match the current mode when entering the menu
	VID_SyncCvars ();

	//set up bpp and rate lists based on current cvars
	VID_Menu_RebuildBppList ();
	VID_Menu_RebuildRateList ();
}

/*
==============================================================================

SCREEN SHOTS

==============================================================================
*/

static void SCR_ScreenShot_Usage (void)
{
	Con_Printf ("usage: screenshot <format> <quality>\n");
	Con_Printf ("   format must be \"png\" or \"tga\" or \"jpg\"\n");
	Con_Printf ("   quality must be 1-100\n");
	return;
}

/*
==================
SCR_ScreenShot_f -- johnfitz -- rewritten to use Image_WriteTGA
==================
*/
void SCR_ScreenShot_f (void)
{
#ifdef METAL_WIP
	VkBuffer buffer;
	VkResult err;
	char	ext[4];
	char	imagename[16];  //johnfitz -- was [80]
	char	checkname[MAX_OSPATH];
	int	i, quality;
	qboolean	ok;

	qboolean bgra = (vulkan_globals.swap_chain_format == VK_FORMAT_B8G8R8A8_UNORM)
		|| (vulkan_globals.swap_chain_format == VK_FORMAT_B8G8R8A8_SRGB);

	Q_strncpy (ext, "png", sizeof(ext));

	if (Cmd_Argc () >= 2)
	{
		const char	*requested_ext = Cmd_Argv (1);

		if (!q_strcasecmp ("png", requested_ext)
		    || !q_strcasecmp ("tga", requested_ext)
		    || !q_strcasecmp ("jpg", requested_ext))
			Q_strncpy (ext, requested_ext, sizeof(ext));
		else
		{
			SCR_ScreenShot_Usage ();
			return;
		}
	}

// read quality as the 3rd param (only used for JPG)
	quality = 90;
	if (Cmd_Argc () >= 3)
		quality = Q_atoi (Cmd_Argv(2));
	if (quality < 1 || quality > 100)
	{
		SCR_ScreenShot_Usage ();
		return;
	}

	if ((vulkan_globals.swap_chain_format != VK_FORMAT_B8G8R8A8_UNORM)
		&& (vulkan_globals.swap_chain_format != VK_FORMAT_B8G8R8A8_SRGB)
		&& (vulkan_globals.swap_chain_format != VK_FORMAT_R8G8B8A8_UNORM)
		&& (vulkan_globals.swap_chain_format != VK_FORMAT_R8G8B8A8_SRGB))
	{
		Con_Printf ("SCR_ScreenShot_f: Unsupported surface format\n");
		return;
	}

// find a file name to save it to
	for (i=0; i<10000; i++)
	{
		q_snprintf (imagename, sizeof(imagename), "vkquake%04i.%s", i, ext);	// "fitz%04i.tga"
		q_snprintf (checkname, sizeof(checkname), "%s/%s", com_gamedir, imagename);
		if (Sys_FileTime(checkname) == -1)
			break;	// file doesn't exist
	}
	if (i == 10000)
	{
		Con_Printf ("SCR_ScreenShot_f: Couldn't find an unused filename\n");
		return;
	}

// get data
	VkBufferCreateInfo buffer_create_info;
	memset(&buffer_create_info, 0, sizeof(buffer_create_info));
	buffer_create_info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
	buffer_create_info.size = glwidth * glheight * 4;
	buffer_create_info.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
	err = vkCreateBuffer(vulkan_globals.device, &buffer_create_info, NULL, &buffer);
	if (err != VK_SUCCESS)
		Sys_Error("vkCreateBuffer failed");

	VkMemoryRequirements memory_requirements;
	vkGetBufferMemoryRequirements(vulkan_globals.device, buffer, &memory_requirements);

	uint32_t memory_type_index = GL_MemoryTypeFromProperties(memory_requirements.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, VK_MEMORY_PROPERTY_HOST_CACHED_BIT);

	VkMemoryAllocateInfo memory_allocate_info;
	memset(&memory_allocate_info, 0, sizeof(memory_allocate_info));
	memory_allocate_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
	memory_allocate_info.allocationSize = memory_requirements.size;
	memory_allocate_info.memoryTypeIndex = memory_type_index;

	VkDeviceMemory memory;
	err = vkAllocateMemory(vulkan_globals.device, &memory_allocate_info, NULL, &memory);
	if (err != VK_SUCCESS)
		Sys_Error("vkAllocateMemory failed");

	err = vkBindBufferMemory(vulkan_globals.device, buffer, memory, 0);
	if (err != VK_SUCCESS)
		Sys_Error("vkBindBufferMemory failed");

	VkCommandBuffer command_buffer;

	VkCommandBufferAllocateInfo command_buffer_allocate_info;
	memset(&command_buffer_allocate_info, 0, sizeof(command_buffer_allocate_info));
	command_buffer_allocate_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
	command_buffer_allocate_info.commandPool = transient_command_pool;
	command_buffer_allocate_info.commandBufferCount = 1;
	err = vkAllocateCommandBuffers(vulkan_globals.device, &command_buffer_allocate_info, &command_buffer);
	if (err != VK_SUCCESS)
		Sys_Error("vkAllocateCommandBuffers failed");

	VkCommandBufferBeginInfo command_buffer_begin_info;
	memset(&command_buffer_begin_info, 0, sizeof(command_buffer_begin_info));
	command_buffer_begin_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
	command_buffer_begin_info.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

	err = vkBeginCommandBuffer(command_buffer, &command_buffer_begin_info);
	if (err != VK_SUCCESS)
		Sys_Error("vkBeginCommandBuffer failed");

	VkImageMemoryBarrier image_barrier;
	image_barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
	image_barrier.pNext = NULL;
	image_barrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
	image_barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
	image_barrier.oldLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
	image_barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
	image_barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
	image_barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
	image_barrier.image = swapchain_images[current_command_buffer];
	image_barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
	image_barrier.subresourceRange.baseMipLevel = 0;
	image_barrier.subresourceRange.levelCount = 1;
	image_barrier.subresourceRange.baseArrayLayer = 0;
	image_barrier.subresourceRange.layerCount = 1;

	vkCmdPipelineBarrier(command_buffer, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &image_barrier);

	VkBufferImageCopy image_copy;
	memset(&image_copy, 0, sizeof(image_copy));
	image_copy.bufferOffset = 0;
	image_copy.bufferRowLength = glwidth;
	image_copy.bufferImageHeight = glheight;
	image_copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
	image_copy.imageSubresource.layerCount = 1;
	image_copy.imageExtent.width = glwidth;
	image_copy.imageExtent.height = glheight;
	image_copy.imageExtent.depth = 1;

	vkCmdCopyImageToBuffer(command_buffer, swapchain_images[current_command_buffer], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &image_copy);

	err = vkEndCommandBuffer(command_buffer);
	if (err != VK_SUCCESS)
		Sys_Error("vkEndCommandBuffer failed");

	VkSubmitInfo submit_info;
	memset(&submit_info, 0, sizeof(submit_info));
	submit_info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
	submit_info.commandBufferCount = 1;
	submit_info.pCommandBuffers = &command_buffer;

	err = vkQueueSubmit(vulkan_globals.queue, 1, &submit_info, VK_NULL_HANDLE);
	if (err != VK_SUCCESS)
		Sys_Error("vkQueueSubmit failed");

	err = vkDeviceWaitIdle(vulkan_globals.device);
	if (err != VK_SUCCESS)
		Sys_Error("vkDeviceWaitIdle failed");

	void * buffer_ptr;
	vkMapMemory(vulkan_globals.device, memory, 0, glwidth * glheight * 4, 0, &buffer_ptr);

	if (bgra)
	{
		byte * data = (byte*)buffer_ptr;
		const int size = glwidth * glheight * 4;
		for (i = 0; i < size; i += 4)
		{
			const byte temp = data[i];
			data[i] = data[i+2];
			data[i+2] = temp;
		}
	}

	if (!q_strncasecmp (ext, "png", sizeof(ext)))
		ok = Image_WritePNG (imagename, buffer_ptr, glwidth, glheight, 32, true);
	else if (!q_strncasecmp (ext, "tga", sizeof(ext)))
		ok = Image_WriteTGA (imagename, buffer_ptr, glwidth, glheight, 32, true);
	else if (!q_strncasecmp (ext, "jpg", sizeof(ext)))
		ok = Image_WriteJPG (imagename, buffer_ptr, glwidth, glheight, 32, quality, true);
	else
		ok = false;

	if (ok)
		Con_Printf ("Wrote %s\n", imagename);
	else
		Con_Printf ("SCR_ScreenShot_f: Couldn't create %s\n", imagename);

	vkUnmapMemory(vulkan_globals.device, memory);
	vkFreeMemory(vulkan_globals.device, memory, NULL);
	vkDestroyBuffer(vulkan_globals.device, buffer, NULL);
	vkFreeCommandBuffers(vulkan_globals.device, transient_command_pool, 1, &command_buffer);
#endif
}

void R_BeginScenePass()
{
	r_metalstate.render_encoder = [r_metalstate.current_command_buffer renderCommandEncoderWithDescriptor:main_render_pass_descriptors[render_warp ? 1 : 0]];
	r_metalstate.render_encoder.label = @"scene pass";
	[r_metalstate.render_encoder setViewport:r_metalstate.scene_viewport];
}

void R_BeginUIPass()
{
	r_metalstate.render_encoder = [r_metalstate.current_command_buffer renderCommandEncoderWithDescriptor:ui_render_pass_descriptor];
	r_metalstate.render_encoder.label = @"ui pass";
}


void R_BeginWarpPass(texture_t *tx)
{
	warp_render_pass_descriptor.colorAttachments[0].texture = TexMgr_GetPrivateData(tx->warpimage)->texture;
	r_metalstate.render_encoder = [r_metalstate.current_command_buffer renderCommandEncoderWithDescriptor:warp_render_pass_descriptor];
	r_metalstate.render_encoder.label = @"warp raster pass";
	warp_render_pass_descriptor.colorAttachments[0].texture = nil;
}

void R_BeginWarpComputePass()
{
	const float push_constants[1] = { cl.time };
	
	r_metalstate.compute_encoder = [r_metalstate.current_command_buffer computeCommandEncoder];
	r_metalstate.compute_encoder.label = @"warp compute pass";
	
	[r_metalstate.compute_encoder setComputePipelineState:r_metalstate.cs_tex_warp_compute_pipeline];
	[r_metalstate.compute_encoder setBytes:&push_constants[0] length:sizeof(push_constants) atIndex:0];
}

void R_BeginWarpMipGen()
{
	r_metalstate.blit_encoder = [r_metalstate.current_command_buffer blitCommandEncoder];
	r_metalstate.blit_encoder.label = @"warp mip gen";
}

void R_GenMipsForTexture(gltexture_t *tex)
{
	[r_metalstate.blit_encoder generateMipmapsForTexture:TexMgr_GetPrivateData(tex)->texture];
}

void R_EndPass()
{
	int i;
	
	if (r_metalstate.render_encoder)
	{
		[r_metalstate.render_encoder endEncoding];
		r_metalstate.render_encoder = nil;
	}
	
	if (r_metalstate.compute_encoder)
	{
		[r_metalstate.compute_encoder endEncoding];
		r_metalstate.compute_encoder = nil;
	}
	
	if (r_metalstate.blit_encoder)
	{
		[r_metalstate.blit_encoder endEncoding];
		r_metalstate.blit_encoder = nil;
	}
	
	r_metalstate.current_pipeline = nil;
	
	r_metalstate.push_constants_dirty = true;
	
	for (i=0; i<MAX_BOUND_TEXTURES; i++)
	{
		r_metalstate.current_samplers[i] = nil;
		r_metalstate.current_textures[i] = nil;
	}
}

void R_UpdatePushConstants()
{
	if (r_metalstate.push_constants_dirty)
	{
		[r_metalstate.render_encoder setVertexBytes:&r_metalstate.push_constants length:sizeof(r_metalstate.push_constants) atIndex:0];
		[r_metalstate.render_encoder setFragmentBytes:&r_metalstate.push_constants length:sizeof(r_metalstate.push_constants) atIndex:0];
		r_metalstate.push_constants_dirty = false;
	}
}
