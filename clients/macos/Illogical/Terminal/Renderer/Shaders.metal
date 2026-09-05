//  Shaders.metal
//  The terminal's three draw passes.
//
//  Ported from libghostty's `src/renderer/shaders/shaders.metal`. The colour
//  handling in particular is not something to reinvent: text on a terminal is
//  thin, high-contrast and everywhere, so the difference between blending in
//  the right space and the wrong one is visible on every glyph.
//
//  Three passes, in order:
//
//    1. bg_color   — one triangle, the default background.
//    2. cell_bg    — one triangle, per-cell background read from a buffer.
//    3. cell_text  — one instanced quad per glyph/decoration/cursor.
//
//  There is no per-cell geometry for backgrounds: the fragment shader derives
//  its grid position from the fragment coordinate and indexes the buffer. An
//  80x24 screen is two triangles and 1,920 bytes, not 1,920 quads.

#include <metal_stdlib>

using namespace metal;

//-------------------------------------------------------------------
// Shared types
//-------------------------------------------------------------------
//
// These mirror ShaderTypes.h, which is the Swift side of the same
// definitions. They are duplicated rather than #include-d because this file
// is compiled at runtime from source (see MetalShaders.swift) and a runtime
// compile has no include path. `RendererLayoutTests` asserts that the two
// agree; if you change one, change the other and the test will tell you if
// you got it wrong.
//
// Only Uniforms and CellBg need matching layouts: CellText reaches the vertex
// shader through a vertex descriptor, which describes the offsets explicitly.

enum PaddingExtend : uint8_t {
  EXTEND_LEFT = 1u,
  EXTEND_RIGHT = 2u,
  EXTEND_UP = 4u,
  EXTEND_DOWN = 8u,
};

enum CellTextAtlas : uint8_t {
  ATLAS_GRAYSCALE = 0u,
  ATLAS_COLOR = 1u,
};

enum CellTextBools : uint8_t {
  NO_MIN_CONTRAST = 1u,
  IS_CURSOR_GLYPH = 2u,
};

struct Uniforms {
  float4x4 projection_matrix;
  float2 screen_size;
  float2 cell_size;
  ushort2 grid_size;
  float4 grid_padding;
  uint8_t padding_extend;
  float min_contrast;
  ushort2 cursor_pos;
  uchar4 cursor_color;
  uchar4 bg_color;
  bool cursor_wide;
  bool use_display_p3;
  bool use_linear_blending;
  bool use_linear_correction;
};

//-------------------------------------------------------------------
// Colour
//-------------------------------------------------------------------
#pragma mark - Colors

// D50-adapted sRGB to XYZ.
// http://www.brucelindbloom.com/Eqn_RGB_XYZ_Matrix.html
constant float3x3 sRGB_XYZ = transpose(float3x3(
  0.4360747, 0.3850649, 0.1430804,
  0.2225045, 0.7168786, 0.0606169,
  0.0139322, 0.0971045, 0.7141733
));

// XYZ to Display P3.
// http://endavid.com/index.php?entry=79
constant float3x3 XYZ_DP3 = transpose(float3x3(
  2.40414768,-0.99010704,-0.39759019,
 -0.84239098, 1.79905954, 0.01597023,
  0.04838763,-0.09752546, 1.27393636
));

constant float3x3 sRGB_DP3 = XYZ_DP3 * sRGB_XYZ;

float3 srgb_to_display_p3(float3 srgb) {
  return sRGB_DP3 * srgb;
}

float4 linearize(float4 srgb) {
  bool3 cutoff = srgb.rgb <= 0.04045;
  float3 lower = srgb.rgb / 12.92;
  float3 higher = pow((srgb.rgb + 0.055) / 1.055, 2.4);
  srgb.rgb = mix(higher, lower, float3(cutoff));
  return srgb;
}

float linearize(float v) {
  return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

float4 unlinearize(float4 lin) {
  bool3 cutoff = lin.rgb <= 0.0031308;
  float3 lower = lin.rgb * 12.92;
  float3 higher = pow(lin.rgb, 1.0 / 2.4) * 1.055 - 0.055;
  lin.rgb = mix(higher, lower, float3(cutoff));
  return lin;
}

float unlinearize(float v) {
  return v <= 0.0031308 ? v * 12.92 : pow(v, 1.0 / 2.4) * 1.055 - 0.055;
}

// Relative luminance. Takes linear RGB.
float luminance(float3 color) {
  return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
}

// https://www.w3.org/TR/2008/REC-WCAG20-20081211/#contrast-ratiodef
// Takes linear RGB.
float contrast_ratio(float3 color1, float3 color2) {
  float l1 = luminance(color1);
  float l2 = luminance(color2);
  return (max(l1, l2) + 0.05f) / (min(l1, l2) + 0.05f);
}

// Return fg if it already clears the minimum ratio against bg, otherwise
// whichever of black or white clears it by more.
float4 contrasted_color(float minimum, float4 fg, float4 bg) {
  float ratio = contrast_ratio(fg.rgb, bg.rgb);
  if (ratio < minimum) {
    float white_ratio = contrast_ratio(float3(1.0f), bg.rgb);
    float black_ratio = contrast_ratio(float3(0.0f), bg.rgb);
    if (white_ratio > black_ratio) {
      return float4(1.0f);
    } else {
      return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }
  }
  return fg;
}

// Load a straight-alpha RGBA8 colour and return it premultiplied in the
// Display P3 space, linear or gamma encoded as requested.
float4 load_color(uchar4 in_color, bool display_p3, bool linear) {
  float4 color = float4(in_color) / 255.0f;

  // Already in the output space and no linearization wanted: just
  // premultiply.
  if (display_p3 && !linear) {
    color.rgb *= color.a;
    return color;
  }

  // sRGB and Display P3 share a transfer function, so one linearize covers
  // both. We need linear even when not blending linearly, because the colour
  // space conversion is only valid on linear values.
  color = linearize(color);

  if (!display_p3) {
    color.rgb = srgb_to_display_p3(color.rgb);
  }

  if (!linear) {
    color = unlinearize(color);
  }

  color.rgb *= color.a;
  return color;
}

//-------------------------------------------------------------------
// Full screen vertex shader
//-------------------------------------------------------------------
#pragma mark - Full Screen Vertex Shader

struct FullScreenVertexOut {
  float4 position [[position]];
};

// One oversized triangle clipped to the viewport, rather than two for a quad:
// no shared edge, so no risk of a seam and one less vertex.
//
// X <- vid == 0: (-1, -3)
// |\
// | \
// |###\
// |#+# \   `+` is (0, 0), `#` is the viewport
// |###  \
// X------X <- vid == 2: (3, 1)
// ^
// vid == 1: (-1, 1)
vertex FullScreenVertexOut full_screen_vertex(uint vid [[vertex_id]]) {
  FullScreenVertexOut out;
  float4 position;
  position.x = (vid == 2) ? 3.0 : -1.0;
  position.y = (vid == 0) ? -3.0 : 1.0;
  position.zw = 1.0;
  out.position = position;
  return out;
}

//-------------------------------------------------------------------
// Background colour
//-------------------------------------------------------------------
#pragma mark - BG Color Shader

fragment float4 bg_color_fragment(
  FullScreenVertexOut in [[stage_in]],
  constant Uniforms &uniforms [[buffer(1)]]
) {
  return load_color(
    uniforms.bg_color,
    uniforms.use_display_p3,
    uniforms.use_linear_blending
  );
}

//-------------------------------------------------------------------
// Cell backgrounds
//-------------------------------------------------------------------
#pragma mark - Cell BG Shader

fragment float4 cell_bg_fragment(
  FullScreenVertexOut in [[stage_in]],
  constant Uniforms &uniforms [[buffer(1)]],
  constant uchar4 *cells [[buffer(2)]]
) {
  // grid_padding is (top, right, bottom, left); .wx is (left, top).
  int2 grid_pos = int2(floor((in.position.xy - uniforms.grid_padding.wx) / uniforms.cell_size));

  float4 bg = float4(0.0);

  // Outside the grid we either clamp (bleeding the edge cell's colour into
  // the padding) or draw nothing and let the base background show.
  if (grid_pos.x < 0) {
    if (uniforms.padding_extend & EXTEND_LEFT) {
      grid_pos.x = 0;
    } else {
      return bg;
    }
  } else if (grid_pos.x > uniforms.grid_size.x - 1) {
    if (uniforms.padding_extend & EXTEND_RIGHT) {
      grid_pos.x = uniforms.grid_size.x - 1;
    } else {
      return bg;
    }
  }

  if (grid_pos.y < 0) {
    if (uniforms.padding_extend & EXTEND_UP) {
      grid_pos.y = 0;
    } else {
      return bg;
    }
  } else if (grid_pos.y > uniforms.grid_size.y - 1) {
    if (uniforms.padding_extend & EXTEND_DOWN) {
      grid_pos.y = uniforms.grid_size.y - 1;
    } else {
      return bg;
    }
  }

  uchar4 cell_color = cells[grid_pos.y * uniforms.grid_size.x + grid_pos.x];

  return load_color(
    cell_color,
    uniforms.use_display_p3,
    uniforms.use_linear_blending
  );
}

//-------------------------------------------------------------------
// Cell text
//-------------------------------------------------------------------
#pragma mark - Cell Text Shader

struct CellTextVertexIn {
  uint2 glyph_pos [[attribute(0)]];
  uint2 glyph_size [[attribute(1)]];
  int2 bearings [[attribute(2)]];
  ushort2 grid_pos [[attribute(3)]];
  uchar4 color [[attribute(4)]];
  uint8_t atlas [[attribute(5)]];
  uint8_t bools [[attribute(6)]];
};

struct CellTextVertexOut {
  float4 position [[position]];
  uint8_t atlas [[flat]];
  float4 color [[flat]];
  float4 bg_color [[flat]];
  float2 tex_coord;
};

vertex CellTextVertexOut cell_text_vertex(
  uint vid [[vertex_id]],
  CellTextVertexIn in [[stage_in]],
  constant Uniforms &uniforms [[buffer(1)]],
  constant uchar4 *bg_colors [[buffer(2)]]
) {
  float2 cell_pos = uniforms.cell_size * float2(in.grid_pos);

  // A 4-vertex triangle strip. Which corner we are is the vertex id:
  //
  //   0 --> 1
  //   |   .'|
  //   |  /  |
  //   | L   |
  //   2 --> 3
  float2 corner;
  corner.x = float(vid == 1 || vid == 3);
  corner.y = float(vid == 2 || vid == 3);

  CellTextVertexOut out;
  out.atlas = in.atlas;

  //              === Grid Cell ===
  //      +X
  // 0,0--...->
  //   |
  //   . offset.x = bearings.x
  // +Y.               .|.
  //   .               | |
  //   |   cell_pos -> +-------+   _.
  //   v             ._|       |_. _|- offset.y = cell_size.y - bearings.y
  //                 | | .###. | |
  //                 | | #...# | |
  //   glyph_size.y -+ | ##### | |
  //                 | | #.... | +- bearings.y
  //                 |_| .#### | |
  //                   |       |_|
  //                   +-------+
  //                     |_._|
  //                       |
  //                  glyph_size.x
  //
  // bearings.y is measured from the bottom of the cell to the top of the
  // glyph, so the top-down offset is the cell height minus it.
  float2 size = float2(in.glyph_size);
  float2 offset = float2(in.bearings);
  offset.y = uniforms.cell_size.y - offset.y;

  cell_pos = cell_pos + size * corner + offset;
  out.position = uniforms.projection_matrix * float4(cell_pos.x, cell_pos.y, 0.0f, 1.0f);

  // Unnormalized: the atlas is sampled in pixel coordinate mode, so the
  // shader never needs to know the atlas size and a resize costs nothing.
  out.tex_coord = float2(in.glyph_pos) + float2(in.glyph_size) * corner;

  // Always fetch linear, so the contrast maths below is meaningful.
  out.color = load_color(in.color, uniforms.use_display_p3, true);

  out.bg_color = load_color(
    bg_colors[in.grid_pos.y * uniforms.grid_size.x + in.grid_pos.x],
    uniforms.use_display_p3,
    true
  );
  float4 global_bg = load_color(uniforms.bg_color, uniforms.use_display_p3, true);
  out.bg_color += global_bg * (1.0 - out.bg_color.a);

  if (uniforms.min_contrast > 1.0f && (in.bools & NO_MIN_CONTRAST) == 0) {
    out.color = contrasted_color(uniforms.min_contrast, out.color, out.bg_color);
  }

  bool is_cursor_pos = (
      in.grid_pos.x == uniforms.cursor_pos.x ||
      (uniforms.cursor_wide && in.grid_pos.x == uniforms.cursor_pos.x + 1)
    ) && in.grid_pos.y == uniforms.cursor_pos.y;

  // Text sitting under a block cursor is drawn in the cursor's text colour.
  // The cursor sprite itself is exempt, or it would recolour itself.
  if ((in.bools & IS_CURSOR_GLYPH) == 0 && is_cursor_pos) {
    out.color = load_color(uniforms.cursor_color, uniforms.use_display_p3, true);
  }

  return out;
}

fragment float4 cell_text_fragment(
  CellTextVertexOut in [[stage_in]],
  texture2d<float> textureGrayscale [[texture(0)]],
  texture2d<float> textureColor [[texture(1)]],
  constant Uniforms &uniforms [[buffer(1)]]
) {
  constexpr sampler textureSampler(
    coord::pixel,
    address::clamp_to_edge,
    filter::nearest
  );

  switch (in.atlas) {
    default:
    case ATLAS_GRAYSCALE: {
      // The interpolated colour is linear; re-encode if we are not blending
      // in linear space. Alpha is premultiplied, so divide it out first.
      float4 color = in.color;
      if (!uniforms.use_linear_blending) {
        color.rgb /= color.a;
        color = unlinearize(color);
        color.rgb *= color.a;
      }

      float a = textureGrayscale.sample(textureSampler, in.tex_coord).r;

      // Linear blending thins strokes compared to the gamma-incorrect
      // blending everyone's eyes are trained on. Blend the luminances the
      // "wrong" way, then solve for the alpha that reproduces that result
      // through a correct linear blend.
      if (uniforms.use_linear_correction) {
        float4 bg = in.bg_color;
        float fg_l = luminance(color.rgb);
        float bg_l = luminance(bg.rgb);
        // Guard against the degenerate case where fg and bg match.
        if (abs(fg_l - bg_l) > 0.001) {
          float blend_l = linearize(unlinearize(fg_l) * a + unlinearize(bg_l) * (1.0 - a));
          a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
        }
      }

      // Premultiplied alpha: scaling the whole colour applies the mask.
      color *= a;
      return color;
    }

    case ATLAS_COLOR: {
      // Colour glyphs are rasterized premultiplied and linear.
      float4 color = textureColor.sample(textureSampler, in.tex_coord);

      if (uniforms.use_linear_blending) {
        return color;
      }

      color.rgb /= color.a;
      color = unlinearize(color);
      color.rgb *= color.a;
      return color;
    }
  }
}
