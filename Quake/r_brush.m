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
// r_brush.c: brush model rendering. renamed from r_surf.c

#include "quakedef.h"
#include "mtl_renderstate.h"

extern cvar_t gl_fullbrights, r_drawflat; //johnfitz
extern cvar_t gl_zfix; // QuakeSpasm z-fighting fix

int		gl_lightmap_format;
int		lightmap_bytes;

#define	BLOCK_WIDTH	128
#define	BLOCK_HEIGHT	128

gltexture_t	*lightmap_textures[MAX_LIGHTMAPS]; //johnfitz -- changed to an array

unsigned	blocklights[BLOCK_WIDTH*BLOCK_HEIGHT*3]; //johnfitz -- was 18*18, added lit support (*3) and loosened surface extents maximum (BLOCK_WIDTH*BLOCK_HEIGHT)

typedef struct glRect_s {
	unsigned char l,t,w,h;
} glRect_t;

glpoly_t	*lightmap_polys[MAX_LIGHTMAPS];
qboolean	lightmap_modified[MAX_LIGHTMAPS];
glRect_t	lightmap_rectchange[MAX_LIGHTMAPS];

int			allocated[MAX_LIGHTMAPS][BLOCK_WIDTH];
int			last_lightmap_allocated; //ericw -- optimization: remember the index of the last lightmap AllocBlock stored a surf in

// the lightmap texture data needs to be kept in
// main memory so texsubimage can update properly
byte		lightmaps[4*MAX_LIGHTMAPS*BLOCK_WIDTH*BLOCK_HEIGHT];

id<MTLBuffer>				bmodel_vertex_buffer;

extern cvar_t r_showtris;

/*
===============
R_TextureAnimation -- johnfitz -- added "frame" param to eliminate use of "currententity" global

Returns the proper texture for a given time and base texture
===============
*/
texture_t *R_TextureAnimation (texture_t *base, int frame)
{
	int		relative;
	int		count;

	if (frame)
		if (base->alternate_anims)
			base = base->alternate_anims;

	if (!base->anim_total)
		return base;

	relative = (int)(cl.time*10) % base->anim_total;

	count = 0;
	while (base->anim_min > relative || base->anim_max <= relative)
	{
		base = base->anim_next;
		if (!base)
			Sys_Error ("R_TextureAnimation: broken cycle");
		if (++count > 100)
			Sys_Error ("R_TextureAnimation: infinite cycle");
	}

	return base;
}

/*
================
DrawGLPoly
================
*/
void DrawGLPoly (glpoly_t *p, float color[3], float alpha)
{
	const int numverts = p->numverts;
	const int numtriangles = (numverts - 2);
	const int numindices = numtriangles * 3;

	id<MTLBuffer> vertex_buffer;
	id<MTLBuffer> index_buffer;
	uint32_t vertex_buffer_offset=0;
	uint32_t index_buffer_offset=0;

	basicvertex_t * vertices = (basicvertex_t*)R_VertexAllocate(numverts * sizeof(basicvertex_t), &vertex_buffer, &vertex_buffer_offset);

	float	*v;
	int		i;
	int		current_index = 0;

	v = p->verts[0];
	for (i = 0; i < numverts; ++i, v += VERTEXSIZE)
	{
		vertices[i].position[0] = v[0];
		vertices[i].position[1] = v[1];
		vertices[i].position[2] = v[2];
		vertices[i].texcoord[0] = v[3];
		vertices[i].texcoord[1] = v[4];
		vertices[i].color[0] = color[0] * 255.0f;
		vertices[i].color[1] = color[1] * 255.0f;
		vertices[i].color[2] = color[2] * 255.0f;
		vertices[i].color[3] = alpha * 255.0f;
	}

	// I don't know the maximum poly size quake maps can have, so just in case fall back to dynamic allocations
	// TODO: Find out if it's necessary
	if (numindices > FAN_INDEX_BUFFER_SIZE)
	{
		id<MTLBuffer> index_buffer;
		uint32_t index_buffer_offset;

		uint16_t * indices = (uint16_t *)R_IndexAllocate(numindices * sizeof(uint16_t), &index_buffer, &index_buffer_offset);
		for (i = 0; i < numtriangles; ++i)
		{
			indices[current_index++] = 0;
			indices[current_index++] = 1 + i;
			indices[current_index++] = 2 + i;
		}
	}
	else
	{
		index_buffer = r_metalstate.fan_index_buffer;
		index_buffer_offset = 0;
	}
	
	// Render poly
	R_UpdatePushConstants();
	[r_metalstate.render_encoder setVertexBuffer:vertex_buffer offset:vertex_buffer_offset atIndex:VBO_Vertex_Start];
	[r_metalstate.render_encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:numindices indexType:MTLIndexTypeUInt16 indexBuffer:index_buffer indexBufferOffset:(NSUInteger)index_buffer_offset];
}

/*
=============================================================

	BRUSH MODELS

=============================================================
*/

/*
=================
R_DrawBrushModel
=================
*/
void R_DrawBrushModel (entity_t *e)
{
	int			i, k;
	msurface_t	*psurf;
	float		dot;
	mplane_t	*pplane;
	qmodel_t	*clmodel;

	if (R_CullModelForEntity(e))
		return;

	currententity = e;
	clmodel = e->model;

	VectorSubtract (r_refdef.vieworg, e->origin, modelorg);
	if (e->angles[0] || e->angles[1] || e->angles[2])
	{
		vec3_t	temp;
		vec3_t	forward, right, up;

		VectorCopy (modelorg, temp);
		AngleVectors (e->angles, forward, right, up);
		modelorg[0] = DotProduct (temp, forward);
		modelorg[1] = -DotProduct (temp, right);
		modelorg[2] = DotProduct (temp, up);
	}

	psurf = &clmodel->surfaces[clmodel->firstmodelsurface];

// calculate dynamic lighting for bmodel if it's not an
// instanced model
	if (clmodel->firstmodelsurface != 0)
	{
		for (k=0 ; k<MAX_DLIGHTS ; k++)
		{
			if ((cl_dlights[k].die < cl.time) ||
				(!cl_dlights[k].radius))
				continue;

			R_MarkLights (&cl_dlights[k], k,
				clmodel->nodes + clmodel->hulls[0].firstclipnode);
		}
	}

	e->angles[0] = -e->angles[0];	// stupid quake bug
	if (gl_zfix.value)
	{
		e->origin[0] -= DIST_EPSILON;
		e->origin[1] -= DIST_EPSILON;
		e->origin[2] -= DIST_EPSILON;
	}
	float model_matrix[16];
	IdentityMatrix(model_matrix);
	R_RotateForEntity (model_matrix, e->origin, e->angles);
	if (gl_zfix.value)
	{
		e->origin[0] += DIST_EPSILON;
		e->origin[1] += DIST_EPSILON;
		e->origin[2] += DIST_EPSILON;
	}
	e->angles[0] = -e->angles[0];	// stupid quake bug

	float mvp[16];
	memcpy(mvp, r_metalstate.view_projection_matrix, 16 * sizeof(float));
	MatrixMultiply(mvp, model_matrix);

	memcpy(&r_metalstate.push_constants[0], &mvp[0], 16 * sizeof(float));
	r_metalstate.push_constants_dirty = true;
	R_UpdatePushConstants();

	R_ClearTextureChains (clmodel, chain_model);
	for (i=0 ; i<clmodel->nummodelsurfaces ; i++, psurf++)
	{
		pplane = psurf->plane;
		dot = DotProduct (modelorg, pplane->normal) - pplane->dist;
		if (((psurf->flags & SURF_PLANEBACK) && (dot < -BACKFACE_EPSILON)) ||
			(!(psurf->flags & SURF_PLANEBACK) && (dot > BACKFACE_EPSILON)))
		{
			R_ChainSurface (psurf, chain_model);
			rs_brushpolys++;
		}
	}

	R_DrawTextureChains (clmodel, e, chain_model);
	R_DrawTextureChains_Water (clmodel, e, chain_model);
	
	memcpy(&r_metalstate.push_constants[0], &r_metalstate.view_projection_matrix[0], 16 * sizeof(float));
	r_metalstate.push_constants_dirty = true;
}

/*
=================
R_DrawBrushModel_ShowTris -- johnfitz
=================
*/
void R_DrawBrushModel_ShowTris(entity_t *e)
{
	int			i;
	msurface_t	*psurf;
	float		dot;
	mplane_t	*pplane;
	qmodel_t	*clmodel;
	float color[] = { 1.0f, 1.0f, 1.0f };
	const alpha = 1.0f;

	if (R_CullModelForEntity(e))
		return;

	currententity = e;
	clmodel = e->model;

	VectorSubtract (r_refdef.vieworg, e->origin, modelorg);
	if (e->angles[0] || e->angles[1] || e->angles[2])
	{
		vec3_t	temp;
		vec3_t	forward, right, up;

		VectorCopy (modelorg, temp);
		AngleVectors (e->angles, forward, right, up);
		modelorg[0] = DotProduct (temp, forward);
		modelorg[1] = -DotProduct (temp, right);
		modelorg[2] = DotProduct (temp, up);
	}

	psurf = &clmodel->surfaces[clmodel->firstmodelsurface];

	e->angles[0] = -e->angles[0];	// stupid quake bug
	float model_matrix[16];
	IdentityMatrix(model_matrix);
	R_RotateForEntity (model_matrix, e->origin, e->angles);
	e->angles[0] = -e->angles[0];	// stupid quake bug

	float mvp[16];
	memcpy(mvp, r_metalstate.view_projection_matrix, 16 * sizeof(float));
	MatrixMultiply(mvp, model_matrix);
	
	memcpy(&r_metalstate.push_constants[0], &mvp[0], 16 * sizeof(float));
	r_metalstate.push_constants_dirty = true;

	if (r_showtris.value == 1)
		R_BindPipeline(&r_metalstate.showtris_pipeline);
	else
		R_BindPipeline(&r_metalstate.showtris_depth_test_pipeline);

	//
	// draw it
	//
	for (i=0 ; i<clmodel->nummodelsurfaces ; i++, psurf++)
	{
		pplane = psurf->plane;
		dot = DotProduct (modelorg, pplane->normal) - pplane->dist;
		if (((psurf->flags & SURF_PLANEBACK) && (dot < -BACKFACE_EPSILON)) ||
			(!(psurf->flags & SURF_PLANEBACK) && (dot > BACKFACE_EPSILON)))
		{
			DrawGLPoly (psurf->polys, color, alpha);
		}
	}

	memcpy(&r_metalstate.push_constants[0], &r_metalstate.view_projection_matrix[0], 16 * sizeof(float));
	r_metalstate.push_constants_dirty = true;
}

/*
=============================================================

	LIGHTMAPS

=============================================================
*/

/*
================
R_RenderDynamicLightmaps
called during rendering
================
*/
void R_RenderDynamicLightmaps (msurface_t *fa)
{
	byte		*base;
	int			maps;
	glRect_t	 *theRect;
	int smax, tmax;

	if (fa->flags & SURF_DRAWTILED) //johnfitz -- not a lightmapped surface
		return;

	// add to lightmap chain
	fa->polys->chain = lightmap_polys[fa->lightmaptexturenum];
	lightmap_polys[fa->lightmaptexturenum] = fa->polys;

	// check for lightmap modification
	for (maps=0; maps < MAXLIGHTMAPS && fa->styles[maps] != 255; maps++)
		if (d_lightstylevalue[fa->styles[maps]] != fa->cached_light[maps])
			goto dynamic;

	if (fa->dlightframe == r_framecount	// dynamic this frame
		|| fa->cached_dlight)			// dynamic previously
	{
dynamic:
		if (r_dynamic.value)
		{
			lightmap_modified[fa->lightmaptexturenum] = true;
			theRect = &lightmap_rectchange[fa->lightmaptexturenum];
			if (fa->light_t < theRect->t) {
				if (theRect->h)
					theRect->h += theRect->t - fa->light_t;
				theRect->t = fa->light_t;
			}
			if (fa->light_s < theRect->l) {
				if (theRect->w)
					theRect->w += theRect->l - fa->light_s;
				theRect->l = fa->light_s;
			}
			smax = (fa->extents[0]>>4)+1;
			tmax = (fa->extents[1]>>4)+1;
			if ((theRect->w + theRect->l) < (fa->light_s + smax))
				theRect->w = (fa->light_s-theRect->l)+smax;
			if ((theRect->h + theRect->t) < (fa->light_t + tmax))
				theRect->h = (fa->light_t-theRect->t)+tmax;
			base = lightmaps + fa->lightmaptexturenum*lightmap_bytes*BLOCK_WIDTH*BLOCK_HEIGHT;
			base += fa->light_t * BLOCK_WIDTH * lightmap_bytes + fa->light_s * lightmap_bytes;
			R_BuildLightMap (fa, base, BLOCK_WIDTH*lightmap_bytes);
		}
	}
}

/*
========================
AllocBlock -- returns a texture number and the position inside it
========================
*/
int AllocBlock (int w, int h, int *x, int *y)
{
	int		i, j;
	int		best, best2;
	int		texnum;

	// ericw -- rather than searching starting at lightmap 0 every time,
	// start at the last lightmap we allocated a surface in.
	// This makes AllocBlock much faster on large levels (can shave off 3+ seconds
	// of load time on a level with 180 lightmaps), at a cost of not quite packing
	// lightmaps as tightly vs. not doing this (uses ~5% more lightmaps)
	for (texnum=last_lightmap_allocated ; texnum<MAX_LIGHTMAPS ; texnum++, last_lightmap_allocated++)
	{
		best = BLOCK_HEIGHT;

		for (i=0 ; i<BLOCK_WIDTH-w ; i++)
		{
			best2 = 0;

			for (j=0 ; j<w ; j++)
			{
				if (allocated[texnum][i+j] >= best)
					break;
				if (allocated[texnum][i+j] > best2)
					best2 = allocated[texnum][i+j];
			}
			if (j == w)
			{	// this is a valid spot
				*x = i;
				*y = best = best2;
			}
		}

		if (best + h > BLOCK_HEIGHT)
			continue;

		for (i=0 ; i<w ; i++)
			allocated[texnum][*x + i] = best + h;

		return texnum;
	}

	Sys_Error ("AllocBlock: full");
	return 0; //johnfitz -- shut up compiler
}


mvertex_t	*r_pcurrentvertbase;
qmodel_t	*currentmodel;

int	nColinElim;

/*
========================
GL_CreateSurfaceLightmap
========================
*/
void GL_CreateSurfaceLightmap (msurface_t *surf)
{
	int		smax, tmax;
	byte	*base;

	smax = (surf->extents[0]>>4)+1;
	tmax = (surf->extents[1]>>4)+1;

	surf->lightmaptexturenum = AllocBlock (smax, tmax, &surf->light_s, &surf->light_t);
	base = lightmaps + surf->lightmaptexturenum*lightmap_bytes*BLOCK_WIDTH*BLOCK_HEIGHT;
	base += (surf->light_t * BLOCK_WIDTH + surf->light_s) * lightmap_bytes;
	R_BuildLightMap (surf, base, BLOCK_WIDTH*lightmap_bytes);
}

/*
================
BuildSurfaceDisplayList -- called at level load time
================
*/
void BuildSurfaceDisplayList (msurface_t *fa)
{
	int			i, lindex, lnumverts;
	medge_t		*pedges, *r_pedge;
	float		*vec;
	float		s, t;
	glpoly_t	*poly;

// reconstruct the polygon
	pedges = currentmodel->edges;
	lnumverts = fa->numedges;

	//
	// draw texture
	//
	poly = (glpoly_t *) Hunk_Alloc (sizeof(glpoly_t) + (lnumverts-4) * VERTEXSIZE*sizeof(float));
	poly->next = fa->polys;
	fa->polys = poly;
	poly->numverts = lnumverts;

	for (i=0 ; i<lnumverts ; i++)
	{
		lindex = currentmodel->surfedges[fa->firstedge + i];

		if (lindex > 0)
		{
			r_pedge = &pedges[lindex];
			vec = r_pcurrentvertbase[r_pedge->v[0]].position;
		}
		else
		{
			r_pedge = &pedges[-lindex];
			vec = r_pcurrentvertbase[r_pedge->v[1]].position;
		}
		s = DotProduct (vec, fa->texinfo->vecs[0]) + fa->texinfo->vecs[0][3];
		s /= fa->texinfo->texture->width;

		t = DotProduct (vec, fa->texinfo->vecs[1]) + fa->texinfo->vecs[1][3];
		t /= fa->texinfo->texture->height;

		VectorCopy (vec, poly->verts[i]);
		poly->verts[i][3] = s;
		poly->verts[i][4] = t;

		//
		// lightmap texture coordinates
		//
		s = DotProduct (vec, fa->texinfo->vecs[0]) + fa->texinfo->vecs[0][3];
		s -= fa->texturemins[0];
		s += fa->light_s*16;
		s += 8;
		s /= BLOCK_WIDTH*16; //fa->texinfo->texture->width;

		t = DotProduct (vec, fa->texinfo->vecs[1]) + fa->texinfo->vecs[1][3];
		t -= fa->texturemins[1];
		t += fa->light_t*16;
		t += 8;
		t /= BLOCK_HEIGHT*16; //fa->texinfo->texture->height;

		poly->verts[i][5] = s;
		poly->verts[i][6] = t;
	}

	//johnfitz -- removed gl_keeptjunctions code

	poly->numverts = lnumverts;
}

/*
==================
GL_BuildLightmaps -- called at level load time

Builds the lightmap texture
with all the surfaces from all brush models
==================
*/
void GL_BuildLightmaps (void)
{
	char	name[16];
	byte	*data;
	int		i, j;
	qmodel_t	*m;

	memset (allocated, 0, sizeof(allocated));
	last_lightmap_allocated = 0;

	r_framecount = 1; // no dlightcache

	//johnfitz -- null out array (the gltexture objects themselves were already freed by Mod_ClearAll)
	for (i=0; i < MAX_LIGHTMAPS; i++)
		lightmap_textures[i] = NULL;
	//johnfitz

	lightmap_bytes = 4;

	for (j=1 ; j<MAX_MODELS ; j++)
	{
		m = cl.model_precache[j];
		if (!m)
			break;
		if (m->name[0] == '*')
			continue;
		r_pcurrentvertbase = m->vertexes;
		currentmodel = m;
		for (i=0 ; i<m->numsurfaces ; i++)
		{
			//johnfitz -- rewritten to use SURF_DRAWTILED instead of the sky/water flags
			if (m->surfaces[i].flags & SURF_DRAWTILED)
				continue;
			GL_CreateSurfaceLightmap (m->surfaces + i);
			BuildSurfaceDisplayList (m->surfaces + i);
			//johnfitz
		}
	}

	//
	// upload all lightmaps that were filled
	//
	for (i=0; i<MAX_LIGHTMAPS; i++)
	{
		if (!allocated[i][0])
			break;		// no more used
		lightmap_modified[i] = false;
		lightmap_rectchange[i].l = BLOCK_WIDTH;
		lightmap_rectchange[i].t = BLOCK_HEIGHT;
		lightmap_rectchange[i].w = 0;
		lightmap_rectchange[i].h = 0;

		//johnfitz -- use texture manager
		sprintf(name, "lightmap%03i",i);
		data = lightmaps+i*BLOCK_WIDTH*BLOCK_HEIGHT*lightmap_bytes;
		lightmap_textures[i] = TexMgr_LoadImage (cl.worldmodel, name, BLOCK_WIDTH, BLOCK_HEIGHT,
			 SRC_LIGHTMAP, data, "", (src_offset_t)data, TEXPREF_LINEAR | TEXPREF_NOPICMIP);
		//johnfitz
	}

	//johnfitz -- warn about exceeding old limits
	if (i >= 64)
		Con_DWarning ("%i lightmaps exceeds standard limit of 64 (max = %d).\n", i, MAX_LIGHTMAPS);
	//johnfitz
}

/*
=============================================================

	VBO support

=============================================================
*/

void GL_DeleteBModelVertexBuffer (void)
{
	//GL_WaitForDeviceIdle();
	bmodel_vertex_buffer = nil;
	num_metal_bmodel_allocations--;
}

/*
==================
GL_BuildBModelVertexBuffer

Deletes gl_bmodel_vbo if it already exists, then rebuilds it with all
surfaces from world + all brush models
==================
*/
void GL_BuildBModelVertexBuffer (void)
{
	unsigned int	numverts, varray_bytes, varray_index;
	int		i, j;
	qmodel_t	*m;
	float		*varray;
	int remaining_size;
	int copy_offset;

	// count all verts in all models
	numverts = 0;
	for (j=1 ; j<MAX_MODELS ; j++)
	{
		m = cl.model_precache[j];
		if (!m || m->name[0] == '*' || m->type != mod_brush)
			continue;

		for (i=0 ; i<m->numsurfaces ; i++)
		{
			numverts += m->surfaces[i].numedges;
		}
	}
	
	// build vertex array
	varray_bytes = VERTEXSIZE * sizeof(float) * numverts;
	const int align_mod = varray_bytes % r_metalstate.vbo_alignment;
	const int aligned_size = ((varray_bytes % r_metalstate.vbo_alignment) == 0)
	? varray_bytes
	: (varray_bytes + r_metalstate.vbo_alignment - align_mod);
	
	varray = (float *) malloc (aligned_size);
	varray_index = 0;
	
	for (j=1 ; j<MAX_MODELS ; j++)
	{
		m = cl.model_precache[j];
		if (!m || m->name[0] == '*' || m->type != mod_brush)
			continue;

		for (i=0 ; i<m->numsurfaces ; i++)
		{
			msurface_t *s = &m->surfaces[i];
			s->vbo_firstvert = varray_index;
			memcpy (&varray[VERTEXSIZE * varray_index], s->polys->verts, VERTEXSIZE * sizeof(float) * s->numedges);
			varray_index += s->numedges;
		}
	}

	// Allocate & upload to GPU
	bmodel_vertex_buffer = [r_metalstate.device newBufferWithBytes:varray length:aligned_size options:MTLResourceCPUCacheModeDefaultCache];
	bmodel_vertex_buffer.label = @"Brush Vertex Buffer";
	num_metal_bmodel_allocations++;
	
	free (varray);
}

/*
===============
R_AddDynamicLights
===============
*/
void R_AddDynamicLights (msurface_t *surf)
{
	int			lnum;
	int			sd, td;
	float		dist, rad, minlight;
	vec3_t		impact, local;
	int			s, t;
	int			i;
	int			smax, tmax;
	mtexinfo_t	*tex;
	//johnfitz -- lit support via lordhavoc
	float		cred, cgreen, cblue, brightness;
	unsigned	*bl;
	//johnfitz

	smax = (surf->extents[0]>>4)+1;
	tmax = (surf->extents[1]>>4)+1;
	tex = surf->texinfo;

	for (lnum=0 ; lnum<MAX_DLIGHTS ; lnum++)
	{
		if (! (surf->dlightbits[lnum >> 5] & (1U << (lnum & 31))))
			continue;		// not lit by this light

		rad = cl_dlights[lnum].radius;
		dist = DotProduct (cl_dlights[lnum].origin, surf->plane->normal) -
				surf->plane->dist;
		rad -= fabs(dist);
		minlight = cl_dlights[lnum].minlight;
		if (rad < minlight)
			continue;
		minlight = rad - minlight;

		for (i=0 ; i<3 ; i++)
		{
			impact[i] = cl_dlights[lnum].origin[i] -
					surf->plane->normal[i]*dist;
		}

		local[0] = DotProduct (impact, tex->vecs[0]) + tex->vecs[0][3];
		local[1] = DotProduct (impact, tex->vecs[1]) + tex->vecs[1][3];

		local[0] -= surf->texturemins[0];
		local[1] -= surf->texturemins[1];

		//johnfitz -- lit support via lordhavoc
		bl = blocklights;
		cred = cl_dlights[lnum].color[0] * 256.0f;
		cgreen = cl_dlights[lnum].color[1] * 256.0f;
		cblue = cl_dlights[lnum].color[2] * 256.0f;
		//johnfitz
		for (t = 0 ; t<tmax ; t++)
		{
			td = local[1] - t*16;
			if (td < 0)
				td = -td;
			for (s=0 ; s<smax ; s++)
			{
				sd = local[0] - s*16;
				if (sd < 0)
					sd = -sd;
				if (sd > td)
					dist = sd + (td>>1);
				else
					dist = td + (sd>>1);
				if (dist < minlight)
				//johnfitz -- lit support via lordhavoc
				{
					brightness = rad - dist;
					bl[0] += (int) (brightness * cred);
					bl[1] += (int) (brightness * cgreen);
					bl[2] += (int) (brightness * cblue);
				}
				bl += 3;
				//johnfitz
			}
		}
	}
}


/*
===============
R_BuildLightMap -- johnfitz -- revised for lit support via lordhavoc

Combine and scale multiple lightmaps into the 8.8 format in blocklights
===============
*/
void R_BuildLightMap (msurface_t *surf, byte *dest, int stride)
{
	int			smax, tmax;
	int			r,g,b;
	int			i, j, size;
	byte		*lightmap;
	unsigned	scale;
	int			maps;
	unsigned	*bl;

	surf->cached_dlight = (surf->dlightframe == r_framecount);

	smax = (surf->extents[0]>>4)+1;
	tmax = (surf->extents[1]>>4)+1;
	size = smax*tmax;
	lightmap = surf->samples;

	if (cl.worldmodel->lightdata)
	{
	// clear to no light
		memset (&blocklights[0], 0, size * 3 * sizeof (unsigned int)); //johnfitz -- lit support via lordhavoc

	// add all the lightmaps
		if (lightmap)
		{
			for (maps = 0 ; maps < MAXLIGHTMAPS && surf->styles[maps] != 255 ;
				 maps++)
			{
				scale = d_lightstylevalue[surf->styles[maps]];
				surf->cached_light[maps] = scale;	// 8.8 fraction
				//johnfitz -- lit support via lordhavoc
				bl = blocklights;
				for (i=0 ; i<size ; i++)
				{
					*bl++ += *lightmap++ * scale;
					*bl++ += *lightmap++ * scale;
					*bl++ += *lightmap++ * scale;
				}
				//johnfitz
			}
		}

	// add all the dynamic lights
		if (surf->dlightframe == r_framecount)
			R_AddDynamicLights (surf);
	}
	else
	{
	// set to full bright if no light data
		memset (&blocklights[0], 255, size * 3 * sizeof (unsigned int)); //johnfitz -- lit support via lordhavoc
	}

// bound, invert, and shift
// store:
	stride -= smax * 4;
	bl = blocklights;
	for (i=0 ; i<tmax ; i++, dest += stride)
	{
		for (j=0 ; j<smax ; j++)
		{
			r = *bl++ >> 8;
			g = *bl++ >> 8;
			b = *bl++ >> 8;
			*dest++ = (r > 255)? 255 : r;
			*dest++ = (g > 255)? 255 : g;
			*dest++ = (b > 255)? 255 : b;
			*dest++ = 255;
		}
	}
}

/*
===============
R_UploadLightmap -- johnfitz -- uploads the modified lightmap to opengl if necessary

assumes lightmap texture is already bound
===============
*/
static void R_UploadLightmap(int lmap, gltexture_t * lightmap)
{
	glRect_t	*theRect;

	lightmap_modified[lmap] = false;
	
	theRect = &lightmap_rectchange[lmap];
	
	byte * data = lightmaps + (lmap * BLOCK_HEIGHT + theRect->t) * BLOCK_WIDTH * lightmap_bytes;

	[TexMgr_GetPrivateData(lightmap)->texture replaceRegion: MTLRegionMake2D(0, theRect->t, BLOCK_WIDTH, theRect->h)
			 mipmapLevel:0
				withBytes:data
			 bytesPerRow:BLOCK_WIDTH * lightmap_bytes];

	theRect->l = BLOCK_WIDTH;
	theRect->t = BLOCK_HEIGHT;
	theRect->h = 0;
	theRect->w = 0;
	
	rs_dynamiclightmaps++;
}

void R_UploadLightmaps (void)
{
	int lmap;

	for (lmap = 0; lmap < MAX_LIGHTMAPS; lmap++)
	{
		if (!lightmap_modified[lmap])
			continue;

		R_UploadLightmap(lmap, lightmap_textures[lmap]);
	}
}
