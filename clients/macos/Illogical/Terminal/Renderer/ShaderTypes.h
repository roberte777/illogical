//  ShaderTypes.h
//  Types shared between Swift and the Metal shaders.
//
//  This is the app's Swift bridging header *and* an include of Shaders.metal,
//  so every struct below has exactly one definition and the two sides cannot
//  drift. The layouts are the ones libghostty's renderer uses
//  (`src/renderer/metal/shaders.zig`); keeping them identical is what lets us
//  port the shader bodies verbatim.

#ifndef ILLOGICAL_SHADER_TYPES_H
#define ILLOGICAL_SHADER_TYPES_H

#include <stdbool.h>
#include <stdint.h>
#include <simd/simd.h>

// Bit mask for Uniforms.padding_extend: which directions cell colors bleed
// into the padding around the grid.
typedef enum {
  ILLO_PADDING_EXTEND_LEFT = 1u,
  ILLO_PADDING_EXTEND_RIGHT = 2u,
  ILLO_PADDING_EXTEND_UP = 4u,
  ILLO_PADDING_EXTEND_DOWN = 8u,
} IllogicalPaddingExtend;

// Which atlas a CellText instance samples from.
typedef enum {
  ILLO_ATLAS_GRAYSCALE = 0u,
  ILLO_ATLAS_COLOR = 1u,
} IllogicalAtlasKind;

// Bit mask for CellText.bools.
typedef enum {
  // Never apply the minimum contrast correction to this glyph. Set for
  // graphics elements (box drawing, blocks, powerline) where a "corrected"
  // colour would break the seam with the neighbouring cell.
  ILLO_CELL_NO_MIN_CONTRAST = 1u,
  // This instance is the cursor sprite itself, so the cursor-cell colour
  // override in the vertex shader must not apply to it.
  ILLO_CELL_IS_CURSOR_GLYPH = 2u,
} IllogicalCellTextBools;

// Buffer indices, shared so Swift and MSL agree without magic numbers.
typedef enum {
  ILLO_BUFFER_VERTEX = 0,
  ILLO_BUFFER_UNIFORMS = 1,
  ILLO_BUFFER_CELL_BG = 2,
} IllogicalBufferIndex;

typedef enum {
  ILLO_TEXTURE_GRAYSCALE = 0,
  ILLO_TEXTURE_COLOR = 1,
} IllogicalTextureIndex;

typedef struct {
  // World coordinates -> normalized device coordinates.
  matrix_float4x4 projection_matrix;

  // Render target size in pixels.
  simd_float2 screen_size;

  // Cell size in pixels.
  simd_float2 cell_size;

  // Grid size in columns and rows.
  simd_ushort2 grid_size;

  // Blank space around the grid, in pixels: top, right, bottom, left.
  simd_float4 grid_padding;

  // IllogicalPaddingExtend mask.
  uint8_t padding_extend;

  // WCAG 2.0 minimum contrast ratio for text. 1 disables the correction.
  float min_contrast;

  // Cursor cell, so text under a block cursor can be recoloured.
  simd_ushort2 cursor_pos;
  simd_uchar4 cursor_color;

  // Default background for the whole surface.
  simd_uchar4 bg_color;

  // The cursor covers two cells.
  bool cursor_wide;
  // Colours handed to the shader are already Display P3 and need no
  // conversion. False means they are sRGB.
  bool use_display_p3;
  // The colour attachment is an `*_srgb` format, so the shader must output
  // linear values and let Metal encode them after blending.
  bool use_linear_blending;
  // Correct alpha so linear blending keeps the apparent stroke weight of
  // gamma-incorrect blending.
  bool use_linear_correction;
} IllogicalUniforms;

// One instance of the cell text shader: a single glyph, underline,
// strikethrough, overline or cursor sprite.
//
// Keep this small: at 200x60 with decorations there can be tens of thousands
// per frame. 32 bytes is the size libghostty settled on.
typedef struct {
  // Top-left of the glyph in its atlas, in pixels.
  simd_uint2 glyph_pos;
  // Glyph size in the atlas, in pixels.
  simd_uint2 glyph_size;
  // Left bearing, and the distance from the cell bottom to the glyph top.
  simd_short2 bearings;
  // Grid coordinates.
  simd_ushort2 grid_pos;
  // Premultiplication happens in the shader; this is straight RGBA.
  simd_uchar4 color;
  // IllogicalAtlasKind.
  uint8_t atlas;
  // IllogicalCellTextBools mask.
  uint8_t bools;
} IllogicalCellText;

// One cell background colour. The cell background pass is a full-screen
// triangle that indexes this array by fragment position, so there is no
// per-cell geometry at all.
typedef simd_uchar4 IllogicalCellBg;

#endif /* ILLOGICAL_SHADER_TYPES_H */
