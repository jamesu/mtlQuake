/*
Copyright (C) 1996-2001 Id Software, Inc.
Copyright (C) 2002-2009 John Fitzgibbons and others
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
//gl_warp.c -- warping animation support

#include "quakedef.h"
#include "mtl_renderstate.h"

extern cvar_t r_drawflat;

cvar_t r_waterquality = {"r_waterquality", "8", CVAR_NONE};
cvar_t r_waterwarp = {"r_waterwarp", "1", CVAR_ARCHIVE};
cvar_t r_waterwarpcompute = { "r_waterwarpcompute", "1", CVAR_ARCHIVE };

float load_subdivide_size; //johnfitz -- remember what subdivide_size value was when this map was loaded

float	turbsin[] =
{
#include "gl_warp_sin.h"
};

#define WARPCALC(s,t) ((s + turbsin[(int)((t*2)+(cl.time*(128.0/M_PI))) & 255]) * (1.0/64)) //johnfitz -- correct warp

//==============================================================================
//
//  OLD-STYLE WATER
//
//==============================================================================

extern	qmodel_t	*loadmodel;

msurface_t	*warpface;

cvar_t gl_subdivide_size = {"gl_subdivide_size", "128", CVAR_ARCHIVE};

void BoundPoly (int numverts, float *verts, vec3_t mins, vec3_t maxs)
{
	int		i, j;
	float	*v;

	mins[0] = mins[1] = mins[2] = 999999999;
	maxs[0] = maxs[1] = maxs[2] = -999999999;
	v = verts;
	for (i=0 ; i<numverts ; i++)
		for (j=0 ; j<3 ; j++, v++)
		{
			if (*v < mins[j])
				mins[j] = *v;
			if (*v > maxs[j])
				maxs[j] = *v;
		}
}

void SubdividePolygon (int numverts, float *verts)
{
	int		i, j, k;
	vec3_t	mins, maxs;
	float	m;
	float	*v;
	vec3_t	front[64], back[64];
	int		f, b;
	float	dist[64];
	float	frac;
	glpoly_t	*poly;
	float	s, t;

	if (numverts > 60)
		Sys_Error ("numverts = %i", numverts);

	BoundPoly (numverts, verts, mins, maxs);

	for (i=0 ; i<3 ; i++)
	{
		m = (mins[i] + maxs[i]) * 0.5;
		m = gl_subdivide_size.value * floor (m/gl_subdivide_size.value + 0.5);
		if (maxs[i] - m < 8)
			continue;
		if (m - mins[i] < 8)
			continue;

		// cut it
		v = verts + i;
		for (j=0 ; j<numverts ; j++, v+= 3)
			dist[j] = *v - m;

		// wrap cases
		dist[j] = dist[0];
		v-=i;
		VectorCopy (verts, v);

		f = b = 0;
		v = verts;
		for (j=0 ; j<numverts ; j++, v+= 3)
		{
			if (dist[j] >= 0)
			{
				VectorCopy (v, front[f]);
				f++;
			}
			if (dist[j] <= 0)
			{
				VectorCopy (v, back[b]);
				b++;
			}
			if (dist[j] == 0 || dist[j+1] == 0)
				continue;
			if ( (dist[j] > 0) != (dist[j+1] > 0) )
			{
				// clip point
				frac = dist[j] / (dist[j] - dist[j+1]);
				for (k=0 ; k<3 ; k++)
					front[f][k] = back[b][k] = v[k] + frac*(v[3+k] - v[k]);
				f++;
				b++;
			}
		}

		SubdividePolygon (f, front[0]);
		SubdividePolygon (b, back[0]);
		return;
	}

	poly = (glpoly_t *) Hunk_Alloc (sizeof(glpoly_t) + (numverts-4) * VERTEXSIZE*sizeof(float));
	poly->next = warpface->polys->next;
	warpface->polys->next = poly;
	poly->numverts = numverts;
	for (i=0 ; i<numverts ; i++, verts+= 3)
	{
		VectorCopy (verts, poly->verts[i]);
		s = DotProduct (verts, warpface->texinfo->vecs[0]);
		t = DotProduct (verts, warpface->texinfo->vecs[1]);
		poly->verts[i][3] = s;
		poly->verts[i][4] = t;
	}
}

/*
================
GL_SubdivideSurface
================
*/
void GL_SubdivideSurface (msurface_t *fa)
{
	vec3_t	verts[64];
	int		i;

	warpface = fa;

	//the first poly in the chain is the undivided poly for newwater rendering.
	//grab the verts from that.
	for (i=0; i<fa->polys->numverts; i++)
		VectorCopy (fa->polys->verts[i], verts[i]);

	SubdividePolygon (fa->polys->numverts, verts[0]);
}

//==============================================================================
//
//  RENDER-TO-FRAMEBUFFER WATER
//
//==============================================================================
static void R_RasterWarpTexture(texture_t *tx, float warptess) {
	float x, y, x2;
	
	R_BeginWarpPass(tx);

	//render warp
	GL_SetCanvas(CANVAS_WARPIMAGE);
	R_BindPipeline(&r_metalstate.raster_tex_warp_pipeline);
	TexMgr_BindTexture(tx->gltexture, 0, 0);
	
	MTLViewport viewport;
	viewport.originX = 0;
	viewport.originY = 0;
	viewport.znear = 0.0f;
	viewport.zfar = 1.0f;
	viewport.width = WARPIMAGESIZE;
	viewport.height = WARPIMAGESIZE;
	[r_metalstate.render_encoder setViewport:viewport];

	int num_verts = 0;
	for (y = 0.0; y<128.01; y += warptess) // .01 for rounding errors
		num_verts += 2;

	R_UpdatePushConstants();
	
	for (x = 0.0; x<128.0; x = x2)
	{
		id<MTLBuffer> buffer;
		uint32_t buffer_offset;
		basicvertex_t * vertices = (basicvertex_t*)R_VertexAllocate(num_verts * sizeof(basicvertex_t), &buffer, &buffer_offset);

		int i = 0;
		x2 = x + warptess;
		for (y = 0.0; y<128.01; y += warptess) // .01 for rounding errors
		{
			vertices[i].position[0] = x;
			vertices[i].position[1] = y;
			vertices[i].position[2] = 0.0f;
			vertices[i].texcoord[0] = WARPCALC(x, y);
			vertices[i].texcoord[1] = WARPCALC(y, x);
			vertices[i].color[0] = 255;
			vertices[i].color[1] = 255;
			vertices[i].color[2] = 255;
			vertices[i].color[3] = 255;
			i += 1;
			vertices[i].position[0] = x2;
			vertices[i].position[1] = y;
			vertices[i].position[2] = 0.0f;
			vertices[i].texcoord[0] = WARPCALC(x2, y);
			vertices[i].texcoord[1] = WARPCALC(y, x2);
			vertices[i].color[0] = 255;
			vertices[i].color[1] = 255;
			vertices[i].color[2] = 255;
			vertices[i].color[3] = 255;
			i += 1;
		}
		
		[r_metalstate.render_encoder setVertexBuffer:buffer offset:buffer_offset atIndex:1];
		[r_metalstate.render_encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:num_verts];
	}

	R_EndPass();
}

static void R_ComputeWarpTexture(texture_t *tx, float warptess)
{
	[r_metalstate.compute_encoder setTexture:TexMgr_GetPrivateData(tx->gltexture)->texture atIndex:0];
	[r_metalstate.compute_encoder setTexture:TexMgr_GetPrivateData(tx->warpimage)->texture atIndex:1];
	
	MTLSize threadGroupSize = MTLSizeMake(8,8,1);
	MTLSize threadGroupCount = MTLSizeMake(WARPIMAGESIZE / 8, WARPIMAGESIZE / 8,1);
	
	[r_metalstate.compute_encoder dispatchThreadgroups:threadGroupCount threadsPerThreadgroup:threadGroupSize];
}

/*
=============
R_UpdateWarpTextures -- johnfitz -- each frame, update warping textures
=============
*/
static texture_t * warp_textures[MAX_GLTEXTURES];

void R_UpdateWarpTextures (void)
{
	texture_t *tx;
	int i, mip;
	float warptess;
	
	assert(r_metalstate.render_encoder == nil);

	if (cl.paused || r_drawflat_cheatsafe || r_lightmap_cheatsafe)
		return;

	warptess = 128.0/CLAMP (3.0, floor(r_waterquality.value), 64.0);

	int num_textures = cl.worldmodel->numtextures;
	int num_warp_textures = 0;

	// Count warp texture & prepare barrier from undefined to GENERL if using compute warp
	for (i = 0; i < num_textures; ++i)
	{
		if (!(tx = cl.worldmodel->textures[i]))
			continue;

		if (!tx->update_warp)
			continue;

		warp_textures[num_warp_textures] = tx;
		num_warp_textures += 1;
	}


	if (r_waterwarpcompute.value)
	{
		// Begin warp compute pass if we have warps to render
		R_BeginWarpComputePass();
	}

	// Render warp to top mips
	for (i = 0; i < num_warp_textures; ++i)
	{
		tx = warp_textures[i];

		if (r_waterwarpcompute.value)
			R_ComputeWarpTexture(tx, warptess);
		else
			R_RasterWarpTexture(tx, warptess);
	}
	
	if (r_waterwarpcompute.value)
	{
		R_EndPass();
	}
	
	if (num_warp_textures == 0)
		return;
	
	// Generate mips for warp textures
	R_BeginWarpMipGen();
	
	for (i = 0; i < num_warp_textures; ++i)
	{
		R_GenMipsForTexture(warp_textures[i]->warpimage);
	}
	
	R_EndPass();

	//if warp render went down into sbar territory, we need to be sure to refresh it next frame
	if (WARPIMAGESIZE + sb_lines > glheight)
		Sbar_Changed ();

	//if viewsize is less than 100, we need to redraw the frame around the viewport
	scr_tileclear_updates = 0;
}