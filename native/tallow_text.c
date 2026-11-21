// Text rasterized and extruded on the CPU for WorldText (docs/world-text.md): a font's glyphs drawn into an RGBA8
// bitmap (white, with the glyph coverage in alpha) for the letters' faces and, for text with depth, a mesh of the
// glyph outlines extruded into solid letters. The interface's own text is Dear ImGui's; this is for text that lives
// in the world, which needs a texture and geometry the renderer can draw.

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

#if defined(_WIN32)
#define TN_API __declspec(dllexport)
#elif defined(__GNUC__)
#define TN_API __attribute__((visibility("default")))
#else
#define TN_API
#endif

// A font's bytes are kept for the life of the font, so stb_truetype can read the tables at any time.
typedef struct TnTextFont
{
	stbtt_fontinfo info;
	unsigned char* data;
} TnTextFont;

// The engine's default font (Roboto, the one the interface uses), from tallow_native.cpp.
extern const void* tn_text_default_font_data(int* size);

static TnTextFont* s_default_font;
static int s_default_font_tried;

static TnTextFont* MakeFont(const unsigned char* data, int size, int owned)
{
	if (data == NULL || size <= 0)
		return NULL;
	unsigned char* copy = NULL;
	if (owned)
	{
		copy = (unsigned char*)malloc((size_t)size);
		if (copy == NULL)
			return NULL;
		memcpy(copy, data, (size_t)size);
	}
	else
		copy = (unsigned char*)data;
	const int offset = stbtt_GetFontOffsetForIndex(copy, 0);
	TnTextFont* font = (TnTextFont*)calloc(1, sizeof(TnTextFont));
	if (font == NULL)
	{
		if (owned)
			free(copy);
		return NULL;
	}
	if (offset < 0 || !stbtt_InitFont(&font->info, copy, offset))
	{
		if (owned)
			free(copy);
		free(font);
		return NULL;
	}
	font->data = copy;
	return font;
}

// A font from a .ttf or .otf file's bytes (copied). NULL when they are not a font stb_truetype can read.
TN_API TnTextFont* tn_text_font_load(const unsigned char* data, int size)
{
	return MakeFont(data, size, 1);
}

// The engine's own font (Roboto); NULL only if the copy fails.
TN_API TnTextFont* tn_text_font_default(void)
{
	if (!s_default_font_tried)
	{
		s_default_font_tried = 1;
		int size = 0;
		const void* data = tn_text_default_font_data(&size);
		s_default_font = MakeFont((const unsigned char*)data, size, 0);
	}
	return s_default_font;
}

// Frees a font made by tn_text_font_load. The default font is not freed.
TN_API void tn_text_font_free(TnTextFont* font)
{
	if (font == NULL || font == s_default_font)
		return;
	free(font->data);
	free(font);
}

// Decodes one UTF-8 code point and moves *at past it. Returns -1 at the end.
static int NextCodepoint(const unsigned char** at, const unsigned char* end)
{
	if (*at >= end)
		return -1;
	const unsigned char* p = *at;
	unsigned int c = *p++;
	int codepoint = c;
	int extra = 0;
	if ((c & 0x80) == 0)
		codepoint = (int)c;
	else if ((c & 0xE0) == 0xC0)
	{
		codepoint = (int)(c & 0x1F);
		extra = 1;
	}
	else if ((c & 0xF0) == 0xE0)
	{
		codepoint = (int)(c & 0x0F);
		extra = 2;
	}
	else if ((c & 0xF8) == 0xF0)
	{
		codepoint = (int)(c & 0x07);
		extra = 3;
	}
	else
	{
		// Not a lead byte: take it as it is, so a broken string still draws something.
		*at = p;
		return 0xFFFD;
	}
	for (int i = 0; i < extra; i++)
	{
		if (p >= end || (*p & 0xC0) != 0x80)
		{
			*at = p;
			return 0xFFFD;
		}
		codepoint = (codepoint << 6) | (*p++ & 0x3F);
	}
	*at = p;
	return codepoint;
}

// The width of one line, in pixels, with kerning between the glyphs (as stb_truetype lays them out).
static float LineWidth(stbtt_fontinfo* info, const unsigned char* at, const unsigned char* end, float scale)
{
	float width = 0;
	int previous = 0;
	while (at < end)
	{
		int codepoint = NextCodepoint(&at, end);
		if (codepoint < 0)
			break;
		if (codepoint == '\r')
			continue;
		if (codepoint == '\t')
		{
			int advance = 0, bearing = 0;
			stbtt_GetCodepointHMetrics(info, ' ', &advance, &bearing);
			width += advance * scale * 4.0f;
			previous = 0;
			continue;
		}
		int advance = 0, bearing = 0;
		stbtt_GetCodepointHMetrics(info, codepoint, &advance, &bearing);
		if (previous != 0)
			width += stbtt_GetCodepointKernAdvance(info, previous, codepoint) * scale;
		width += advance * scale;
		previous = codepoint;
	}
	return width;
}

// Where every line and glyph of a string goes, at one size: the bitmap's size and the pen positions both the
// rasterizer and the extruder use.
typedef struct TnLayout
{
	int width, height, lineHeight, pad, lines;
	float widest, scale;
	int ascent, descent;
} TnLayout;

// The bitmaps of a huge string would be too big for a texture; refuse them the same way for both paths.
static int LayoutFits(const TnLayout* layout)
{
	if (layout->width < layout->pad * 2 + 1)
		return 0;
	if (layout->width > 8192 || layout->height > 8192)
		return 0;
	return (long)layout->width * (long)layout->height <= 64L * 1024L * 1024L;
}

static int ComputeLayout(TnTextFont* font, const char* utf8, int length, float pixelHeight, TnLayout* layout)
{
	if (font == NULL || utf8 == NULL || length <= 0)
		return 0;
	if (!(pixelHeight > 0.0f))
		return 0;
	if (pixelHeight < 4.0f)
		pixelHeight = 4.0f;
	if (pixelHeight > 1024.0f)
		pixelHeight = 1024.0f;

	const float scale = stbtt_ScaleForPixelHeight(&font->info, pixelHeight);
	int ascent = 0, descent = 0, gap = 0;
	stbtt_GetFontVMetrics(&font->info, &ascent, &descent, &gap);
	int lineHeight = (int)ceilf((ascent - descent) * scale);
	if (lineHeight < 1)
		lineHeight = 1;
	const int pad = pixelHeight < 16.0f ? 1 : 2;

	const unsigned char* begin = (const unsigned char*)utf8;
	const unsigned char* end = begin + length;
	int lines = 1;
	for (const unsigned char* at = begin; at < end; at++)
	{
		if (*at == '\n')
			lines++;
	}
	if (lines > 1000)
		return 0;
	float widest = 0;
	const unsigned char* lineStart = begin;
	for (const unsigned char* at = begin; at <= end; at++)
	{
		if (at == end || *at == '\n')
		{
			float width = LineWidth(&font->info, lineStart, at, scale);
			if (width > widest)
				widest = width;
			lineStart = at + 1;
		}
	}
	layout->width = (int)ceilf(widest) + pad * 2;
	layout->height = lines * lineHeight + pad * 2;
	layout->lineHeight = lineHeight;
	layout->pad = pad;
	layout->lines = lines;
	layout->widest = widest;
	layout->scale = scale;
	layout->ascent = ascent;
	layout->descent = descent;
	return LayoutFits(layout);
}

// A glyph with its pen position: what the rasterizer and the extruder each draw. baseline is in the bitmap's
// coordinates (y down from the top of the block).
typedef void (*TnGlyphFn)(void* user, int codepoint, float penX, float baseline);

static void ForEachGlyph(TnTextFont* font, const char* utf8, int length, const TnLayout* layout, int align,
	TnGlyphFn fn, void* user)
{
	stbtt_fontinfo* info = &font->info;
	const unsigned char* begin = (const unsigned char*)utf8;
	const unsigned char* end = begin + length;
	int lineIndex = 0;
	const unsigned char* lineStart = begin;
	for (const unsigned char* at = begin; at <= end; at++)
	{
		if (at != end && *at != '\n')
			continue;
		const float lineWidth = LineWidth(info, lineStart, at, layout->scale);
		float penX = (float)layout->pad;
		if (align == 1)
			penX += (layout->widest - lineWidth) * 0.5f;
		else if (align == 2)
			penX += layout->widest - lineWidth;
		const float baseline = (float)(layout->pad + lineIndex * layout->lineHeight) + layout->ascent * layout->scale;
		int previous = 0;
		const unsigned char* glyphAt = lineStart;
		while (glyphAt < at)
		{
			int codepoint = NextCodepoint(&glyphAt, at);
			if (codepoint < 0)
				break;
			if (codepoint == '\r')
				continue;
			if (codepoint == '\t')
			{
				int advance = 0, bearing = 0;
				stbtt_GetCodepointHMetrics(info, ' ', &advance, &bearing);
				penX += advance * layout->scale * 4.0f;
				previous = 0;
				continue;
			}
			int advance = 0, bearing = 0;
			stbtt_GetCodepointHMetrics(info, codepoint, &advance, &bearing);
			if (previous != 0)
				penX += stbtt_GetCodepointKernAdvance(info, previous, codepoint) * layout->scale;
			fn(user, codepoint, penX, baseline);
			penX += advance * layout->scale;
			previous = codepoint;
		}
		lineIndex++;
		lineStart = at + 1;
	}
}

// White everywhere: the glyph's alpha is what makes the text; the colour comes from the renderer's tint.
static unsigned char* MakePixels(const TnLayout* layout)
{
	long count = (long)layout->width * (long)layout->height;
	unsigned char* pixels = (unsigned char*)malloc((size_t)count * 4);
	if (pixels == NULL)
		return NULL;
	for (long i = 0; i < count; i++)
	{
		pixels[i * 4 + 0] = 255;
		pixels[i * 4 + 1] = 255;
		pixels[i * 4 + 2] = 255;
		pixels[i * 4 + 3] = 0;
	}
	return pixels;
}

typedef struct TnBlit
{
	stbtt_fontinfo* info;
	float scale;
	unsigned char* pixels;
	int width, height;
} TnBlit;

static void BlitGlyph(void* user, int codepoint, float penX, float baseline)
{
	TnBlit* blit = (TnBlit*)user;
	int x0 = 0, y0 = 0, x1 = 0, y1 = 0;
	stbtt_GetCodepointBitmapBoxSubpixel(blit->info, codepoint, blit->scale, blit->scale, 0.0f, 0.0f, &x0, &y0, &x1, &y1);
	const int glyphWidth = x1 - x0;
	const int glyphHeight = y1 - y0;
	if (glyphWidth <= 0 || glyphHeight <= 0 || glyphWidth > 2048 || glyphHeight > 2048)
		return;
	unsigned char* glyph = (unsigned char*)malloc((size_t)glyphWidth * (size_t)glyphHeight);
	if (glyph == NULL)
		return;
	stbtt_MakeCodepointBitmapSubpixel(blit->info, glyph, glyphWidth, glyphHeight, glyphWidth, blit->scale,
		blit->scale, 0.0f, 0.0f, codepoint);
	// Glyphs are baked without a subpixel shift, so the pen is rounded to the nearest pixel.
	const int left = (int)floorf(penX + 0.5f) + x0;
	const int top = (int)floorf(baseline + 0.5f) + y0;
	for (int gy = 0; gy < glyphHeight; gy++)
	{
		const int y = top + gy;
		if (y < 0 || y >= blit->height)
			continue;
		for (int gx = 0; gx < glyphWidth; gx++)
		{
			const int x = left + gx;
			if (x < 0 || x >= blit->width)
				continue;
			const unsigned char coverage = glyph[(size_t)gy * glyphWidth + gx];
			if (coverage == 0)
				continue;
			unsigned char* destination = blit->pixels + ((size_t)y * blit->width + x) * 4 + 3;
			if (coverage > *destination)
				*destination = coverage;
		}
	}
	free(glyph);
}

// Rasterizes UTF-8 text into an RGBA8 bitmap: white glyphs, their coverage in alpha, antialiased, with a small
// transparent margin. pixelHeight is the height of one line (ascent to descent) in pixels; align is 0 left, 1 centre
// or 2 right within the block. The block's size is returned as well as the line height and margin in pixels, so the
// engine can size the quad it draws. NULL when the text is too big to rasterize (a texture limit) or memory is short.
TN_API unsigned char* tn_text_rasterize(TnTextFont* font, const char* utf8, int length, float pixelHeight, int align,
	int* outWidth, int* outHeight, int* outLineHeight, int* outPad)
{
	if (outWidth != NULL)
		*outWidth = 0;
	if (outHeight != NULL)
		*outHeight = 0;
	if (outLineHeight != NULL)
		*outLineHeight = 0;
	if (outPad != NULL)
		*outPad = 0;
	TnLayout layout;
	if (!ComputeLayout(font, utf8, length, pixelHeight, &layout))
		return NULL;
	unsigned char* pixels = MakePixels(&layout);
	if (pixels == NULL)
		return NULL;
	TnBlit blit = { &font->info, layout.scale, pixels, layout.width, layout.height };
	ForEachGlyph(font, utf8, length, &layout, align, BlitGlyph, &blit);
	if (outWidth != NULL)
		*outWidth = layout.width;
	if (outHeight != NULL)
		*outHeight = layout.height;
	if (outLineHeight != NULL)
		*outLineHeight = layout.lineHeight;
	if (outPad != NULL)
		*outPad = layout.pad;
	return pixels;
}

// Frees a bitmap made by tn_text_rasterize.
TN_API void tn_text_bitmap_free(unsigned char* pixels)
{
	free(pixels);
}

// ------------------------------------------------------------------------------------------
// Extruded letters: the outlines the texture shows, made solid
// ------------------------------------------------------------------------------------------

typedef struct TnPoint
{
	float x, y;
} TnPoint;

typedef struct TnContour
{
	TnPoint* points;
	int count, capacity;
	float area;
	int depth;
} TnContour;

typedef struct TnContours
{
	TnContour* items;
	int count, capacity;
} TnContours;

typedef struct TnPolygon
{
	TnPoint* points;
	int count, capacity;
} TnPolygon;

static void ContourAdd(TnContour* contour, float x, float y)
{
	if (contour->count > 0)
	{
		const TnPoint* last = &contour->points[contour->count - 1];
		const float dx = x - last->x, dy = y - last->y;
		if (dx * dx + dy * dy < 1.0e-8f)
			return;
	}
	if (contour->count == contour->capacity)
	{
		int capacity = contour->capacity > 0 ? contour->capacity * 2 : 16;
		TnPoint* grown = (TnPoint*)realloc(contour->points, (size_t)capacity * sizeof(TnPoint));
		if (grown == NULL)
			return;
		contour->points = grown;
		contour->capacity = capacity;
	}
	contour->points[contour->count].x = x;
	contour->points[contour->count].y = y;
	contour->count++;
}

static TnContour* StartContour(TnContours* contours)
{
	if (contours->count == contours->capacity)
	{
		int capacity = contours->capacity > 0 ? contours->capacity * 2 : 8;
		TnContour* grown = (TnContour*)realloc(contours->items, (size_t)capacity * sizeof(TnContour));
		if (grown == NULL)
			return NULL;
		contours->items = grown;
		contours->capacity = capacity;
	}
	TnContour* contour = &contours->items[contours->count++];
	memset(contour, 0, sizeof(*contour));
	return contour;
}

// A quadratic Bezier, flattened into short straight edges (about two pixels each).
static void FlattenQuadratic(TnContour* contour, TnPoint p0, TnPoint p1, TnPoint p2)
{
	float d = sqrtf((p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y)) +
		sqrtf((p2.x - p1.x) * (p2.x - p1.x) + (p2.y - p1.y) * (p2.y - p1.y));
	int segments = (int)ceilf(d / 2.0f);
	if (segments < 2)
		segments = 2;
	if (segments > 24)
		segments = 24;
	for (int i = 1; i <= segments; i++)
	{
		const float t = (float)i / (float)segments;
		const float u = 1.0f - t;
		ContourAdd(contour, u * u * p0.x + 2.0f * u * t * p1.x + t * t * p2.x,
			u * u * p0.y + 2.0f * u * t * p1.y + t * t * p2.y);
	}
}

// A cubic Bezier, flattened the same way.
static void FlattenCubic(TnContour* contour, TnPoint p0, TnPoint p1, TnPoint p2, TnPoint p3)
{
	float d = sqrtf((p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y)) +
		sqrtf((p2.x - p1.x) * (p2.x - p1.x) + (p2.y - p1.y) * (p2.y - p1.y)) +
		sqrtf((p3.x - p2.x) * (p3.x - p2.x) + (p3.y - p2.y) * (p3.y - p2.y));
	int segments = (int)ceilf(d / 2.0f);
	if (segments < 3)
		segments = 3;
	if (segments > 32)
		segments = 32;
	for (int i = 1; i <= segments; i++)
	{
		const float t = (float)i / (float)segments;
		const float u = 1.0f - t;
		ContourAdd(contour, u * u * u * p0.x + 3.0f * u * u * t * p1.x + 3.0f * u * t * t * p2.x + t * t * t * p3.x,
			u * u * u * p0.y + 3.0f * u * u * t * p1.y + 3.0f * u * t * t * p2.y + t * t * t * p3.y);
	}
}

// Finishes a contour: a closed loop needs no repeated last point.
static void CloseContour(TnContour* contour)
{
	if (contour != NULL && contour->count >= 2)
	{
		const TnPoint* first = &contour->points[0];
		const TnPoint* last = &contour->points[contour->count - 1];
		const float dx = first->x - last->x, dy = first->y - last->y;
		if (dx * dx + dy * dy < 1.0e-6f)
			contour->count--;
	}
}

typedef struct TnShapeContext
{
	TnTextFont* font;
	float scale;
	float height;
	TnContours contours;
	TnContour* current;
	TnPoint previous;
} TnShapeContext;

// Y is up from the bottom of the block (the bitmap's rows counted the other way), so the mesh and its uv agree.
static TnPoint ShapePoint(const TnShapeContext* context, float penX, float baseline, float vx, float vy)
{
	TnPoint point;
	point.x = penX + vx * context->scale;
	point.y = context->height - baseline + vy * context->scale;
	return point;
}

static void ShapeGlyph(void* user, int codepoint, float penX, float baseline)
{
	TnShapeContext* context = (TnShapeContext*)user;
	stbtt_vertex* vertices = NULL;
	int count = stbtt_GetCodepointShape(&context->font->info, codepoint, &vertices);
	if (count <= 0 || vertices == NULL)
		return;
	context->current = NULL;
	for (int i = 0; i < count; i++)
	{
		const stbtt_vertex* vertex = &vertices[i];
		const TnPoint point = ShapePoint(context, penX, baseline, (float)vertex->x, (float)vertex->y);
		switch (vertex->type)
		{
		case STBTT_vmove:
			CloseContour(context->current);
			context->current = StartContour(&context->contours);
			if (context->current != NULL)
			{
				ContourAdd(context->current, point.x, point.y);
				context->previous = point;
			}
			break;
		case STBTT_vline:
			if (context->current != NULL)
			{
				ContourAdd(context->current, point.x, point.y);
				context->previous = point;
			}
			break;
		case STBTT_vcurve:
			if (context->current != NULL)
			{
				const TnPoint control = ShapePoint(context, penX, baseline, (float)vertex->cx, (float)vertex->cy);
				FlattenQuadratic(context->current, context->previous, control, point);
				context->previous = point;
			}
			break;
		case STBTT_vcubic:
			if (context->current != NULL)
			{
				const TnPoint control1 = ShapePoint(context, penX, baseline, (float)vertex->cx, (float)vertex->cy);
				const TnPoint control2 = ShapePoint(context, penX, baseline, (float)vertex->cx1, (float)vertex->cy1);
				FlattenCubic(context->current, context->previous, control1, control2, point);
				context->previous = point;
			}
			break;
		default:
			break;
		}
	}
	CloseContour(context->current);
	stbtt_FreeShape(&context->font->info, vertices);
}

static float ContourArea(const TnPoint* points, int count)
{
	float area = 0;
	for (int i = 0; i < count; i++)
	{
		const TnPoint* a = &points[i];
		const TnPoint* b = &points[(i + 1) % count];
		area += a->x * b->y - b->x * a->y;
	}
	return area * 0.5f;
}

static void ReverseContour(TnContour* contour)
{
	for (int i = 0, j = contour->count - 1; i < j; i++, j--)
	{
		TnPoint temporary = contour->points[i];
		contour->points[i] = contour->points[j];
		contour->points[j] = temporary;
	}
}

// Whether a point is inside a contour: a ray to the left crosses its edges an odd number of times.
static int PointInContour(const TnContour* contour, float x, float y)
{
	int inside = 0;
	for (int i = 0, j = contour->count - 1; i < contour->count; j = i++)
	{
		const TnPoint* a = &contour->points[i];
		const TnPoint* b = &contour->points[j];
		if (((a->y > y) != (b->y > y)) && (x < (b->x - a->x) * (y - a->y) / (b->y - a->y) + a->x))
			inside = !inside;
	}
	return inside;
}

// Which contours sit inside which, so that holes can be joined to their letter's outline.
static void ClassifyContours(TnContours* contours)
{
	for (int i = 0; i < contours->count; i++)
	{
		TnContour* contour = &contours->items[i];
		contour->area = ContourArea(contour->points, contour->count);
		contour->depth = 0;
	}
	for (int i = 0; i < contours->count; i++)
	{
		const TnContour* contour = &contours->items[i];
		if (contour->count < 3)
			continue;
		for (int j = 0; j < contours->count; j++)
		{
			if (i == j || contours->items[j].count < 3)
				continue;
			if (PointInContour(&contours->items[j], contour->points[0].x, contour->points[0].y))
				contours->items[i].depth++;
		}
	}
	// Outer outlines run anticlockwise and holes clockwise, so the sides' normals and the fill can be worked out
	// from the area alone.
	for (int i = 0; i < contours->count; i++)
	{
		TnContour* contour = &contours->items[i];
		const int outer = (contour->depth & 1) == 0;
		if ((outer && contour->area < 0) || (!outer && contour->area > 0))
		{
			ReverseContour(contour);
			contour->area = -contour->area;
		}
	}
}

// Whether two line segments cross.
static int SegmentsCross(TnPoint a0, TnPoint a1, TnPoint b0, TnPoint b1)
{
	const float d1 = (a1.x - a0.x) * (b0.y - a0.y) - (a1.y - a0.y) * (b0.x - a0.x);
	const float d2 = (a1.x - a0.x) * (b1.y - a0.y) - (a1.y - a0.y) * (b1.x - a0.x);
	const float d3 = (b1.x - b0.x) * (a0.y - b0.y) - (b1.y - b0.y) * (a0.x - b0.x);
	const float d4 = (b1.x - b0.x) * (a1.y - b0.y) - (b1.y - b0.y) * (a1.x - b0.x);
	return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0));
}

static int SamePoint(TnPoint a, TnPoint b)
{
	const float dx = a.x - b.x, dy = a.y - b.y;
	return dx * dx + dy * dy < 1.0e-6f;
}

// Whether a hole can be joined to poly[o] with a straight line that crosses nothing else of the letter.
static int BridgeVisible(const TnPoint* poly, int count, int o, TnPoint holePoint, const TnContours* contours,
	const TnContour* outer, int skipHole)
{
	const TnPoint from = poly[o];
	for (int i = 0; i < count; i++)
	{
		if (i == o)
			continue;
		const TnPoint a = poly[i], b = poly[(i + 1) % count];
		if (SamePoint(a, holePoint) || SamePoint(b, holePoint) || SamePoint(from, a) || SamePoint(from, b))
			continue;
		if (SegmentsCross(from, holePoint, a, b))
			return 0;
	}
	for (int i = 0; i < contours->count; i++)
	{
		const TnContour* contour = &contours->items[i];
		if (i == skipHole || contour == outer || contour->count < 3)
			continue;
		// Only the letter's own other holes can be in the way.
		if (!PointInContour(outer, contour->points[0].x, contour->points[0].y))
			continue;
		for (int e = 0; e < contour->count; e++)
		{
			const TnPoint a = contour->points[e], b = contour->points[(e + 1) % contour->count];
			if (SamePoint(a, holePoint) || SamePoint(b, holePoint) || SamePoint(from, a) || SamePoint(from, b))
				continue;
			if (SegmentsCross(from, holePoint, a, b))
				return 0;
		}
	}
	return 1;
}

static void PolygonAdd(TnPolygon* polygon, TnPoint point)
{
	if (polygon->count > 0 && SamePoint(polygon->points[polygon->count - 1], point))
		return;
	if (polygon->count == polygon->capacity)
	{
		int capacity = polygon->capacity > 0 ? polygon->capacity * 2 : 16;
		TnPoint* grown = (TnPoint*)realloc(polygon->points, (size_t)capacity * sizeof(TnPoint));
		if (grown == NULL)
			return;
		polygon->points = grown;
		polygon->capacity = capacity;
	}
	polygon->points[polygon->count++] = point;
}

// Joins a hole to the outline with a bridge: the nearest pair of points with a clear line between them.
static void MergeHole(TnPolygon* polygon, const TnContour* hole, const TnContours* contours, const TnContour* outer,
	int holeIndex)
{
	if (hole->count < 3)
		return;
	// The hole's rightmost point: a bridge from there keeps the line inside the letter.
	int h = 0;
	for (int i = 1; i < hole->count; i++)
	{
		if (hole->points[i].x > hole->points[h].x ||
			(hole->points[i].x == hole->points[h].x && hole->points[i].y > hole->points[h].y))
			h = i;
	}
	int best = -1;
	float bestDistance = 0.0f;
	for (int o = 0; o < polygon->count; o++)
	{
		const float dx = polygon->points[o].x - hole->points[h].x;
		const float dy = polygon->points[o].y - hole->points[h].y;
		const float distance = dx * dx + dy * dy;
		if (best >= 0 && distance >= bestDistance)
			continue;
		if (!BridgeVisible(polygon->points, polygon->count, o, hole->points[h], contours, outer, holeIndex))
			continue;
		best = o;
		bestDistance = distance;
	}
	if (best < 0)
	{
		// Nothing with a clear line: take the nearest, so the hole is still cut out.
		best = 0;
		bestDistance = 1.0e30f;
		for (int o = 0; o < polygon->count; o++)
		{
			const float dx = polygon->points[o].x - hole->points[h].x;
			const float dy = polygon->points[o].y - hole->points[h].y;
			const float distance = dx * dx + dy * dy;
			if (distance < bestDistance)
			{
				best = o;
				bestDistance = distance;
			}
		}
	}
	// Insert the hole's loop between best and best + 1, starting and ending at the bridge's points. The hole runs
	// clockwise, so walking it in its own order keeps the combined outline anticlockwise.
	TnPolygon merged;
	memset(&merged, 0, sizeof(merged));
	for (int i = 0; i <= best; i++)
		PolygonAdd(&merged, polygon->points[i]);
	for (int i = 0; i <= hole->count; i++)
		PolygonAdd(&merged, hole->points[(h + i) % hole->count]);
	PolygonAdd(&merged, polygon->points[best]);
	for (int i = best + 1; i < polygon->count; i++)
		PolygonAdd(&merged, polygon->points[i]);
	free(polygon->points);
	polygon->points = merged.points;
	polygon->count = merged.count;
	polygon->capacity = merged.capacity;
}

// Removes points that lie on the line between their neighbours (they make no useful triangle).
static void RemoveCollinear(TnPolygon* polygon)
{
	for (int i = 0; i < polygon->count && polygon->count > 3;)
	{
		const TnPoint* a = &polygon->points[(i + polygon->count - 1) % polygon->count];
		const TnPoint* b = &polygon->points[i];
		const TnPoint* c = &polygon->points[(i + 1) % polygon->count];
		const float cross = (b->x - a->x) * (c->y - a->y) - (b->y - a->y) * (c->x - a->x);
		if (fabsf(cross) < 1.0e-5f)
		{
			memmove(&polygon->points[i], &polygon->points[i + 1], (size_t)(polygon->count - i - 1) * sizeof(TnPoint));
			polygon->count--;
		}
		else
			i++;
	}
}

static int PointInTriangle(const TnPoint* a, const TnPoint* b, const TnPoint* c, TnPoint p)
{
	const float d1 = (b->x - a->x) * (p.y - a->y) - (b->y - a->y) * (p.x - a->x);
	const float d2 = (c->x - b->x) * (p.y - b->y) - (c->y - b->y) * (p.x - b->x);
	const float d3 = (a->x - c->x) * (p.y - c->y) - (a->y - c->y) * (p.x - c->x);
	return d1 >= 0.0f && d2 >= 0.0f && d3 >= 0.0f;
}

// The extruded text's buffers, grown as the glyphs are walked.
typedef struct TnMeshBuffers
{
	float* facePositions;
	float* faceNormals;
	float* faceUvs;
	uint32_t* faceIndices;
	int faceVertices, faceIndexCount, faceVertexCapacity, faceIndexCapacity;
	float* sidePositions;
	float* sideNormals;
	uint32_t* sideIndices;
	int sideVertices, sideIndexCount, sideVertexCapacity, sideIndexCapacity;
	int failed;
} TnMeshBuffers;

static int GrowIndices(uint32_t** buffer, int* capacity, int needed)
{
	if (needed <= *capacity)
		return 1;
	int grown = *capacity > 0 ? *capacity : 512;
	while (grown < needed)
		grown *= 2;
	uint32_t* resized = (uint32_t*)realloc(*buffer, (size_t)grown * sizeof(uint32_t));
	if (resized == NULL)
		return 0;
	*buffer = resized;
	*capacity = grown;
	return 1;
}

// The three arrays of the face vertices (or the two of the sides) grow together, so they always hold as many
// vertices as the shared count says.
static int GrowFaceVertices(TnMeshBuffers* buffers, int needed)
{
	if (needed <= buffers->faceVertexCapacity)
		return 1;
	int grown = buffers->faceVertexCapacity > 0 ? buffers->faceVertexCapacity : 256;
	while (grown < needed)
		grown *= 2;
	float* positions = (float*)realloc(buffers->facePositions, (size_t)grown * 3 * sizeof(float));
	if (positions == NULL)
		return 0;
	buffers->facePositions = positions;
	float* normals = (float*)realloc(buffers->faceNormals, (size_t)grown * 3 * sizeof(float));
	if (normals == NULL)
		return 0;
	buffers->faceNormals = normals;
	float* uvs = (float*)realloc(buffers->faceUvs, (size_t)grown * 2 * sizeof(float));
	if (uvs == NULL)
		return 0;
	buffers->faceUvs = uvs;
	buffers->faceVertexCapacity = grown;
	return 1;
}

static int GrowSideVertices(TnMeshBuffers* buffers, int needed)
{
	if (needed <= buffers->sideVertexCapacity)
		return 1;
	int grown = buffers->sideVertexCapacity > 0 ? buffers->sideVertexCapacity : 256;
	while (grown < needed)
		grown *= 2;
	float* positions = (float*)realloc(buffers->sidePositions, (size_t)grown * 3 * sizeof(float));
	if (positions == NULL)
		return 0;
	buffers->sidePositions = positions;
	float* normals = (float*)realloc(buffers->sideNormals, (size_t)grown * 3 * sizeof(float));
	if (normals == NULL)
		return 0;
	buffers->sideNormals = normals;
	buffers->sideVertexCapacity = grown;
	return 1;
}

static void AddFaceTriangle(TnMeshBuffers* buffers, TnPoint a, TnPoint b, TnPoint c, float z,
	const TnLayout* layout, int front)
{
	if (buffers->failed)
		return;
	if (!GrowFaceVertices(buffers, buffers->faceVertices + 3) ||
		!GrowIndices(&buffers->faceIndices, &buffers->faceIndexCapacity, buffers->faceIndexCount + 3))
	{
		buffers->failed = 1;
		return;
	}
	// Clockwise seen from the front (-Z): the engine's front face winds that way.
	const TnPoint points[3] = { a, front ? c : b, front ? b : c };
	const uint32_t base = (uint32_t)buffers->faceVertices;
	for (int i = 0; i < 3; i++)
	{
		const int vertex = buffers->faceVertices++;
		buffers->facePositions[vertex * 3 + 0] = points[i].x;
		buffers->facePositions[vertex * 3 + 1] = points[i].y;
		buffers->facePositions[vertex * 3 + 2] = z;
		buffers->faceNormals[vertex * 3 + 0] = 0;
		buffers->faceNormals[vertex * 3 + 1] = 0;
		buffers->faceNormals[vertex * 3 + 2] = front ? -1.0f : 1.0f;
		buffers->faceUvs[vertex * 2 + 0] = points[i].x / (float)layout->width;
		buffers->faceUvs[vertex * 2 + 1] = (layout->height - points[i].y) / (float)layout->height;
	}
	buffers->faceIndices[buffers->faceIndexCount++] = base;
	buffers->faceIndices[buffers->faceIndexCount++] = base + 1;
	buffers->faceIndices[buffers->faceIndexCount++] = base + 2;
}

// Fills a joined outline (holes bridged in) with triangles, front and back.
static void AddFacePolygon(TnMeshBuffers* buffers, TnPolygon* polygon, float halfDepth, const TnLayout* layout)
{
	if (polygon->count < 3)
		return;
	RemoveCollinear(polygon);
	if (polygon->count < 3)
		return;
	if (ContourArea(polygon->points, polygon->count) < 0)
	{
		for (int i = 0, j = polygon->count - 1; i < j; i++, j--)
		{
			TnPoint temporary = polygon->points[i];
			polygon->points[i] = polygon->points[j];
			polygon->points[j] = temporary;
		}
	}
	int guard = polygon->count * polygon->count + 16;
	while (polygon->count >= 3 && guard-- > 0)
	{
		int ear = -1;
		for (int i = 0; i < polygon->count; i++)
		{
			const int previous = (i + polygon->count - 1) % polygon->count;
			const int next = (i + 1) % polygon->count;
			const TnPoint* a = &polygon->points[previous];
			const TnPoint* b = &polygon->points[i];
			const TnPoint* c = &polygon->points[next];
			const float cross = (b->x - a->x) * (c->y - a->y) - (b->y - a->y) * (c->x - a->x);
			if (cross <= 1.0e-5f)
				continue;
			int contains = 0;
			for (int j = 0; j < polygon->count; j++)
			{
				if (j == previous || j == i || j == next)
					continue;
				const TnPoint* p = &polygon->points[j];
				if (SamePoint(*p, *a) || SamePoint(*p, *b) || SamePoint(*p, *c))
					continue;
				if (PointInTriangle(a, b, c, *p))
				{
					contains = 1;
					break;
				}
			}
			if (contains)
				continue;
			ear = i;
			break;
		}
		if (ear < 0)
		{
			// No clean ear (a self-touching outline, or a bridge along an edge): take the most convex one, so the
			// rest can still be filled.
			float bestCross = -1.0e30f;
			for (int i = 0; i < polygon->count; i++)
			{
				const TnPoint* a = &polygon->points[(i + polygon->count - 1) % polygon->count];
				const TnPoint* b = &polygon->points[i];
				const TnPoint* c = &polygon->points[(i + 1) % polygon->count];
				const float cross = (b->x - a->x) * (c->y - a->y) - (b->y - a->y) * (c->x - a->x);
				if (cross > bestCross)
				{
					bestCross = cross;
					ear = i;
				}
			}
			if (ear < 0 || bestCross <= 1.0e-6f)
				break;
		}
		const int previous = (ear + polygon->count - 1) % polygon->count;
		const int next = (ear + 1) % polygon->count;
		AddFaceTriangle(buffers, polygon->points[previous], polygon->points[ear], polygon->points[next], -halfDepth,
			layout, 1);
		AddFaceTriangle(buffers, polygon->points[previous], polygon->points[ear], polygon->points[next], halfDepth,
			layout, 0);
		memmove(&polygon->points[ear], &polygon->points[ear + 1],
			(size_t)(polygon->count - ear - 1) * sizeof(TnPoint));
		polygon->count--;
	}
}

// One edge of an outline, made into a wall between the front and the back.
static void AddSideQuad(TnMeshBuffers* buffers, TnPoint a, TnPoint b, float halfDepth, float area)
{
	float dx = b.x - a.x, dy = b.y - a.y;
	const float length = sqrtf(dx * dx + dy * dy);
	if (length < 1.0e-5f)
		return;
	// Outward from the letter: to the right of an anticlockwise outline, to the left of a clockwise one.
	float nx = dy / length, ny = -dx / length;
	if (area < 0)
	{
		nx = -nx;
		ny = -ny;
	}
	if (buffers->failed)
		return;
	if (!GrowSideVertices(buffers, buffers->sideVertices + 4) ||
		!GrowIndices(&buffers->sideIndices, &buffers->sideIndexCapacity, buffers->sideIndexCount + 6))
	{
		buffers->failed = 1;
		return;
	}
	const uint32_t base = (uint32_t)buffers->sideVertices;
	const float positions[4][3] = {
		{ a.x, a.y, -halfDepth }, { b.x, b.y, -halfDepth }, { b.x, b.y, halfDepth }, { a.x, a.y, halfDepth } };
	for (int i = 0; i < 4; i++)
	{
		const int vertex = buffers->sideVertices++;
		buffers->sidePositions[vertex * 3 + 0] = positions[i][0];
		buffers->sidePositions[vertex * 3 + 1] = positions[i][1];
		buffers->sidePositions[vertex * 3 + 2] = positions[i][2];
		buffers->sideNormals[vertex * 3 + 0] = nx;
		buffers->sideNormals[vertex * 3 + 1] = ny;
		buffers->sideNormals[vertex * 3 + 2] = 0;
	}
	if (area > 0)
	{
		buffers->sideIndices[buffers->sideIndexCount++] = base;
		buffers->sideIndices[buffers->sideIndexCount++] = base + 1;
		buffers->sideIndices[buffers->sideIndexCount++] = base + 2;
		buffers->sideIndices[buffers->sideIndexCount++] = base;
		buffers->sideIndices[buffers->sideIndexCount++] = base + 2;
		buffers->sideIndices[buffers->sideIndexCount++] = base + 3;
	}
	else
	{
		buffers->sideIndices[buffers->sideIndexCount++] = base;
		buffers->sideIndices[buffers->sideIndexCount++] = base + 3;
		buffers->sideIndices[buffers->sideIndexCount++] = base + 2;
		buffers->sideIndices[buffers->sideIndexCount++] = base;
		buffers->sideIndices[buffers->sideIndexCount++] = base + 2;
		buffers->sideIndices[buffers->sideIndexCount++] = base + 1;
	}
}

// A bitmap of the words and, in the same pixels, their outlines extruded into solid letters: faces at -depth/2
// and +depth/2 (with uv into the bitmap), and a wall along every outline edge. X is in bitmap pixels from the left,
// Y is up from the bottom of the block, Z runs through the depth around 0.
typedef struct TnTextMesh
{
	int width, height, lineHeight, pad;
	unsigned char* pixels;
	int faceVertexCount, faceIndexCount;
	float* facePositions;
	float* faceNormals;
	float* faceUvs;
	uint32_t* faceIndices;
	int sideVertexCount, sideIndexCount;
	float* sidePositions;
	float* sideNormals;
	uint32_t* sideIndices;
} TnTextMesh;

TN_API TnTextMesh* tn_text_mesh_build(TnTextFont* font, const char* utf8, int length, float pixelHeight, int align,
	float depth)
{
	TnLayout layout;
	if (!ComputeLayout(font, utf8, length, pixelHeight, &layout))
		return NULL;
	if (!(depth > 0.0f))
		depth = 1.0f;
	if (depth > 4096.0f)
		depth = 4096.0f;
	unsigned char* pixels = MakePixels(&layout);
	if (pixels == NULL)
		return NULL;

	TnBlit blit = { &font->info, layout.scale, pixels, layout.width, layout.height };
	ForEachGlyph(font, utf8, length, &layout, align, BlitGlyph, &blit);

	TnShapeContext shape;
	memset(&shape, 0, sizeof(shape));
	shape.font = font;
	shape.scale = layout.scale;
	shape.height = (float)layout.height;
	ForEachGlyph(font, utf8, length, &layout, align, ShapeGlyph, &shape);
	ClassifyContours(&shape.contours);

	TnMeshBuffers buffers;
	memset(&buffers, 0, sizeof(buffers));
	const float halfDepth = depth * 0.5f;
	for (int i = 0; i < shape.contours.count; i++)
	{
		const TnContour* contour = &shape.contours.items[i];
		if ((contour->depth & 1) != 0 || contour->count < 3)
			continue;
		TnPolygon polygon;
		memset(&polygon, 0, sizeof(polygon));
		for (int p = 0; p < contour->count; p++)
			PolygonAdd(&polygon, contour->points[p]);
		for (int hole = 0; hole < shape.contours.count; hole++)
		{
			const TnContour* candidate = &shape.contours.items[hole];
			if (candidate->count < 3 || candidate->depth != contour->depth + 1)
				continue;
			if (PointInContour(contour, candidate->points[0].x, candidate->points[0].y))
				MergeHole(&polygon, candidate, &shape.contours, contour, hole);
		}
		AddFacePolygon(&buffers, &polygon, halfDepth, &layout);
		free(polygon.points);
	}
	for (int i = 0; i < shape.contours.count; i++)
	{
		const TnContour* contour = &shape.contours.items[i];
		if (contour->count < 3)
			continue;
		for (int p = 0; p < contour->count; p++)
			AddSideQuad(&buffers, contour->points[p], contour->points[(p + 1) % contour->count], halfDepth,
				contour->area);
	}
	for (int i = 0; i < shape.contours.count; i++)
		free(shape.contours.items[i].points);
	free(shape.contours.items);

	if (buffers.failed || buffers.faceVertices == 0 || buffers.sideVertices == 0)
	{
		free(buffers.facePositions);
		free(buffers.faceNormals);
		free(buffers.faceUvs);
		free(buffers.faceIndices);
		free(buffers.sidePositions);
		free(buffers.sideNormals);
		free(buffers.sideIndices);
		free(pixels);
		return NULL;
	}

	TnTextMesh* mesh = (TnTextMesh*)calloc(1, sizeof(TnTextMesh));
	if (mesh == NULL)
	{
		free(buffers.facePositions);
		free(buffers.faceNormals);
		free(buffers.faceUvs);
		free(buffers.faceIndices);
		free(buffers.sidePositions);
		free(buffers.sideNormals);
		free(buffers.sideIndices);
		free(pixels);
		return NULL;
	}
	mesh->width = layout.width;
	mesh->height = layout.height;
	mesh->lineHeight = layout.lineHeight;
	mesh->pad = layout.pad;
	mesh->pixels = pixels;
	mesh->faceVertexCount = buffers.faceVertices;
	mesh->faceIndexCount = buffers.faceIndexCount;
	mesh->facePositions = buffers.facePositions;
	mesh->faceNormals = buffers.faceNormals;
	mesh->faceUvs = buffers.faceUvs;
	mesh->faceIndices = buffers.faceIndices;
	mesh->sideVertexCount = buffers.sideVertices;
	mesh->sideIndexCount = buffers.sideIndexCount;
	mesh->sidePositions = buffers.sidePositions;
	mesh->sideNormals = buffers.sideNormals;
	mesh->sideIndices = buffers.sideIndices;
	return mesh;
}

// Frees the bitmap and the vertices of an extruded text.
TN_API void tn_text_mesh_free(TnTextMesh* mesh)
{
	if (mesh == NULL)
		return;
	free(mesh->pixels);
	free(mesh->facePositions);
	free(mesh->faceNormals);
	free(mesh->faceUvs);
	free(mesh->faceIndices);
	free(mesh->sidePositions);
	free(mesh->sideNormals);
	free(mesh->sideIndices);
	free(mesh);
}
