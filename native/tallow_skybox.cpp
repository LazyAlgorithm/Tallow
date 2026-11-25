// Skybox import (tallowengine.com/docs/skybox): one picture (an equirectangular .hdr/.exr/.png/.jpg panorama, or a
// .ktx/.dds cubemap) or six face pictures become a linear RGBA16F cube with every mip level, written as a .ktx the
// engine loads with bgfx. bimg reads every format (stb_image for .hdr/.png/.jpg, tinyexr for .exr, its own .ktx/.dds
// readers), so no other image library is needed. Faces are +X, -X, +Y, -Y, +Z, -Z, rows top to bottom, the same as
// Engine/shaders/include/cube.sh.

#include <bimg/bimg.h>
#include <bimg/decode.h>
#include <bx/allocator.h>
#include <bx/file.h>
#include <bx/math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <vector>
#include "stb_image_write.h"
#include "tinyexr.h"

#ifdef _WIN32
#define TN_API extern "C" __declspec(dllexport)
#else
#define TN_API extern "C" __attribute__((visibility("default")))
#endif

namespace
{
	bx::DefaultAllocator sAllocator;

	void SetError(char* err, int errLength, const char* message)
	{
		if (err != nullptr && errLength > 0)
			snprintf(err, (size_t)errLength, "%s", message);
	}

	bool ReadFile(const char* path, std::vector<uint8_t>& out)
	{
		FILE* file = fopen(path, "rb");
		if (file == nullptr)
			return false;
		fseek(file, 0, SEEK_END);
		long size = ftell(file);
		fseek(file, 0, SEEK_SET);
		if (size <= 0)
		{
			fclose(file);
			return false;
		}
		out.resize((size_t)size);
		bool ok = fread(out.data(), 1, (size_t)size, file) == (size_t)size;
		fclose(file);
		return ok;
	}

	float SrgbToLinear(float c)
	{
		return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f);
	}

	// A picture as linear RGBA floats: one face (or the panorama), or six faces when it was a cubemap.
	struct Picture
	{
		uint32_t width = 0, height = 0;
		bool cube = false;
		std::vector<float> pixels; // width * height * 4 per side
	};

	bool LoadPicture(const char* path, Picture& out, char* err, int errLength)
	{
		std::vector<uint8_t> bytes;
		if (!ReadFile(path, bytes))
		{
			char message[512];
			snprintf(message, sizeof(message), "can't read %s", path);
			SetError(err, errLength, message);
			return false;
		}
		bx::Error error;
		bimg::ImageContainer* source = bimg::imageParse(&sAllocator, bytes.data(), (uint32_t)bytes.size(), bimg::TextureFormat::Count, &error);
		if (source == nullptr)
		{
			char message[512];
			snprintf(message, sizeof(message), "can't read the picture %s (%.*s)", path, (int)error.getMessage().getLength(), error.getMessage().getCPtr());
			SetError(err, errLength, message);
			return false;
		}
		const bimg::TextureFormat::Enum format = source->m_format;
		// Pictures of 8-bit colour are sRGB; float formats (.hdr, .exr, half/float .ktx/.dds, BC6H) are linear light.
		const bool linear = bimg::isFloat(format) || format == bimg::TextureFormat::BC6H || format == bimg::TextureFormat::RGB9E5F;
		bimg::ImageContainer* converted = bimg::imageConvert(&sAllocator, bimg::TextureFormat::RGBA32F, *source, false);
		if (converted == nullptr)
		{
			bimg::imageFree(source);
			SetError(err, errLength, "the picture's format can't be converted");
			return false;
		}
		out.width = converted->m_width;
		out.height = converted->m_height;
		out.cube = converted->m_cubeMap;
		const uint32_t sides = out.cube ? 6 : 1;
		const size_t sideFloats = (size_t)out.width * out.height * 4;
		out.pixels.resize(sideFloats * sides);
		for (uint32_t side = 0; side < sides; side++)
		{
			bimg::ImageMip mip;
			if (!bimg::imageGetRawData(*converted, (uint16_t)side, 0, converted->m_data, converted->m_size, mip))
			{
				bimg::imageFree(converted);
				bimg::imageFree(source);
				SetError(err, errLength, "the picture has no data");
				return false;
			}
			memcpy(&out.pixels[sideFloats * side], mip.m_data, sideFloats * sizeof(float));
		}
		bimg::imageFree(converted);
		bimg::imageFree(source);
		for (size_t i = 0; i < out.pixels.size(); i += 4)
		{
			for (int c = 0; c < 3; c++)
			{
				float v = out.pixels[i + c];
				if (!(v >= 0.0f) || v > 65000.0f)
					v = v > 65000.0f ? 65000.0f : 0.0f; // NaN and negatives to 0; keep it inside half floats
				out.pixels[i + c] = linear ? v : SrgbToLinear(v);
			}
			out.pixels[i + 3] = 1.0f;
		}
		return true;
	}

	void Bilinear(const float* pixels, uint32_t width, uint32_t height, float x, float y, bool wrapX, float* rgb)
	{
		x -= 0.5f;
		y -= 0.5f;
		const float fx = floorf(x), fy = floorf(y);
		const float tx = x - fx, ty = y - fy;
		int x0 = (int)fx, y0 = (int)fy, x1 = x0 + 1, y1 = y0 + 1;
		auto fixX = [&](int v) { return wrapX ? ((v % (int)width) + (int)width) % (int)width : bx::clamp(v, 0, (int)width - 1); };
		x0 = fixX(x0);
		x1 = fixX(x1);
		y0 = bx::clamp(y0, 0, (int)height - 1);
		y1 = bx::clamp(y1, 0, (int)height - 1);
		const float* a = pixels + ((size_t)y0 * width + x0) * 4;
		const float* b = pixels + ((size_t)y0 * width + x1) * 4;
		const float* c = pixels + ((size_t)y1 * width + x0) * 4;
		const float* d = pixels + ((size_t)y1 * width + x1) * 4;
		for (int i = 0; i < 3; i++)
			rgb[i] = (a[i] * (1 - tx) + b[i] * tx) * (1 - ty) + (c[i] * (1 - tx) + d[i] * tx) * ty;
	}

	// The direction a face's texel looks along (cube.sh cubeDirection).
	void CubeDirection(int face, float s, float t, float* dir)
	{
		float x, y, z;
		switch (face)
		{
		case 0: x = 1; y = -t; z = -s; break;
		case 1: x = -1; y = -t; z = s; break;
		case 2: x = s; y = 1; z = t; break;
		case 3: x = s; y = -1; z = -t; break;
		case 4: x = s; y = -t; z = 1; break;
		default: x = -s; y = -t; z = -1; break;
		}
		const float length = sqrtf(x * x + y * y + z * z);
		dir[0] = x / length;
		dir[1] = y / length;
		dir[2] = z / length;
	}

	uint32_t NextPow2(uint32_t v)
	{
		uint32_t p = 1;
		while (p < v && p < (1u << 15))
			p <<= 1;
		return p;
	}

	// Resamples one square face (any size) to size x size, averaging when it shrinks by more than two.
	void ResampleFace(const float* src, uint32_t srcSize, float* dst, uint32_t size)
	{
		const uint32_t taps = srcSize > size * 2 ? srcSize / size : 1;
		for (uint32_t y = 0; y < size; y++)
		{
			for (uint32_t x = 0; x < size; x++)
			{
				float sum[3] = {0, 0, 0};
				for (uint32_t j = 0; j < taps; j++)
				{
					for (uint32_t i = 0; i < taps; i++)
					{
						float rgb[3];
						const float sx = ((float)x + (i + 0.5f) / taps) * srcSize / size;
						const float sy = ((float)y + (j + 0.5f) / taps) * srcSize / size;
						Bilinear(src, srcSize, srcSize, sx, sy, false, rgb);
						sum[0] += rgb[0];
						sum[1] += rgb[1];
						sum[2] += rgb[2];
					}
				}
				float* out = dst + ((size_t)y * size + x) * 4;
				const float n = (float)(taps * taps);
				out[0] = sum[0] / n;
				out[1] = sum[1] / n;
				out[2] = sum[2] / n;
				out[3] = 1;
			}
		}
	}
}

// Imports a skybox into a cube .ktx (RGBA16F, all mips). count 1: a panorama (2:1) or a cubemap file; count 6: the
// faces +X, -X, +Y, -Y, +Z, -Z. maxSize caps the face size (a power of two). Returns the face size, or 0 with err set.
TN_API int32_t tn_skybox_import(const char* const* paths, int32_t count, int32_t maxSize, const char* outPath, char* err, int32_t errLength)
{
	if (paths == nullptr || (count != 1 && count != 6) || outPath == nullptr)
	{
		SetError(err, errLength, "a skybox is one picture or six faces");
		return 0;
	}
	const uint32_t cap = NextPow2((uint32_t)bx::clamp(maxSize, 16, 8192));
	uint32_t size = 0;
	std::vector<float> faces; // six faces at size x size, linear RGBA

	if (count == 6)
	{
		Picture face[6];
		for (int i = 0; i < 6; i++)
		{
			if (!LoadPicture(paths[i], face[i], err, errLength))
				return 0;
			if (face[i].cube || face[i].width != face[i].height || face[i].width != face[0].width)
			{
				SetError(err, errLength, "the six faces must be square pictures of the same size");
				return 0;
			}
		}
		size = bx::min(NextPow2(face[0].width), cap);
		faces.resize((size_t)size * size * 4 * 6);
		for (int i = 0; i < 6; i++)
			ResampleFace(face[i].pixels.data(), face[i].width, &faces[(size_t)size * size * 4 * i], size);
	}
	else
	{
		Picture picture;
		if (!LoadPicture(paths[0], picture, err, errLength))
			return 0;
		if (picture.cube)
		{
			size = bx::min(NextPow2(picture.width), cap);
			faces.resize((size_t)size * size * 4 * 6);
			const size_t side = (size_t)picture.width * picture.height * 4;
			for (int i = 0; i < 6; i++)
				ResampleFace(&picture.pixels[side * i], picture.width, &faces[(size_t)size * size * 4 * i], size);
		}
		else
		{
			const float aspect = (float)picture.width / (float)bx::max(picture.height, 1u);
			if (aspect < 1.5f || aspect > 2.5f)
			{
				SetError(err, errLength, "a skybox picture must be a 2:1 panorama (cross layouts are not supported: use six face pictures or a cubemap .ktx/.dds)");
				return 0;
			}
			size = bx::max(bx::min(NextPow2(picture.width / 4), cap), 16u);
			faces.resize((size_t)size * size * 4 * 6);
			// Average 2x2 samples per texel when the panorama has more detail than the face.
			const int taps = picture.width / 4 > size ? 2 : 1;
			for (int face = 0; face < 6; face++)
			{
				for (uint32_t y = 0; y < size; y++)
				{
					for (uint32_t x = 0; x < size; x++)
					{
						float sum[3] = {0, 0, 0};
						for (int j = 0; j < taps; j++)
						{
							for (int i = 0; i < taps; i++)
							{
								float dir[3], rgb[3];
								CubeDirection(face, ((x + (i + 0.5f) / taps) / size) * 2 - 1, ((y + (j + 0.5f) / taps) / size) * 2 - 1, dir);
								// Left-handed, +Y up: the panorama's middle looks along +Z, a quarter to the right +X.
								const float lon = atan2f(dir[0], dir[2]);
								const float lat = asinf(bx::clamp(dir[1], -1.0f, 1.0f));
								const float u = 0.5f + lon / (2 * bx::kPi);
								const float v = 0.5f - lat / bx::kPi;
								Bilinear(picture.pixels.data(), picture.width, picture.height, u * picture.width, v * picture.height, true, rgb);
								sum[0] += rgb[0];
								sum[1] += rgb[1];
								sum[2] += rgb[2];
							}
						}
						float* out = &faces[(((size_t)face * size + y) * size + x) * 4];
						const float n = (float)(taps * taps);
						out[0] = sum[0] / n;
						out[1] = sum[1] / n;
						out[2] = sum[2] / n;
						out[3] = 1;
					}
				}
			}
		}
	}

	// Every mip level, each the box average of the one above; written level by level, faces inside (the .ktx order).
	uint8_t mips = 1;
	while ((size >> mips) > 0)
		mips++;
	std::vector<uint16_t> data;
	std::vector<float> level = faces, next;
	uint32_t s = size;
	for (uint8_t m = 0; m < mips; m++)
	{
		for (size_t i = 0; i < level.size(); i++)
			data.push_back(bx::halfFromFloat(level[i]));
		if (m + 1 == mips)
			break;
		const uint32_t half = s / 2;
		next.assign((size_t)half * half * 4 * 6, 0.0f);
		for (int face = 0; face < 6; face++)
		{
			const float* src = &level[(size_t)s * s * 4 * face];
			float* dst = &next[(size_t)half * half * 4 * face];
			for (uint32_t y = 0; y < half; y++)
				for (uint32_t x = 0; x < half; x++)
					for (int c = 0; c < 4; c++)
						dst[((size_t)y * half + x) * 4 + c] = 0.25f * (src[((size_t)(2 * y) * s + 2 * x) * 4 + c] + src[((size_t)(2 * y) * s + 2 * x + 1) * 4 + c] + src[((size_t)(2 * y + 1) * s + 2 * x) * 4 + c] + src[((size_t)(2 * y + 1) * s + 2 * x + 1) * 4 + c]);
		}
		level.swap(next);
		s = half;
	}

	bx::FileWriter writer;
	bx::Error error;
	if (!bx::open(&writer, outPath, false, &error))
	{
		SetError(err, errLength, "can't write the skybox cache file");
		return 0;
	}
	bimg::imageWriteKtx(&writer, bimg::TextureFormat::RGBA16F, true, size, size, 1, mips, 1, false, data.data(), &error);
	bx::close(&writer);
	if (!error.isOk())
	{
		SetError(err, errLength, "can't write the skybox cache file");
		return 0;
	}
	return (int32_t)size;
}

// For the skybox test: writes linear RGBA float pixels as a picture of one kind. kind 0 .png, 1 .jpg, 2 .hdr, 3 .exr
// (width x height); 4 .ktx, 5 .dds (a cube of six width x width faces, RGBA16F). 8-bit pictures are stored as sRGB.
TN_API bool tn_skybox_write_test_picture(const char* path, int32_t kind, int32_t width, int32_t height, const float* rgba)
{
	if (kind <= 1)
	{
		std::vector<uint8_t> bytes((size_t)width * height * 4);
		for (size_t i = 0; i < bytes.size(); i++)
		{
			float v = bx::clamp(rgba[i], 0.0f, 1.0f);
			if (i % 4 != 3)
				v = v <= 0.0031308f ? v * 12.92f : 1.055f * powf(v, 1 / 2.4f) - 0.055f;
			bytes[i] = (uint8_t)(v * 255 + 0.5f);
		}
		return kind == 0 ? stbi_write_png(path, width, height, 4, bytes.data(), width * 4) != 0 : stbi_write_jpg(path, width, height, 4, bytes.data(), 95) != 0;
	}
	if (kind == 2)
		return stbi_write_hdr(path, width, height, 4, rgba) != 0;
	if (kind == 3)
	{
		const char* error = nullptr;
		const int result = SaveEXR(rgba, width, height, 4, 1, path, &error);
		if (error != nullptr)
			FreeEXRErrorMessage(error);
		return result == TINYEXR_SUCCESS;
	}
	bimg::ImageContainer* image = bimg::imageAlloc(&sAllocator, bimg::TextureFormat::RGBA16F, (uint32_t)width, (uint32_t)width, 1, 1, true, false);
	if (image == nullptr)
		return false;
	uint16_t* halves = (uint16_t*)image->m_data;
	const size_t total = (size_t)width * width * 4 * 6;
	for (size_t i = 0; i < total; i++)
		halves[i] = bx::halfFromFloat(rgba[i]);
	bx::FileWriter writer;
	bx::Error error;
	bool ok = bx::open(&writer, path, false, &error);
	if (ok)
	{
		if (kind == 4)
			bimg::imageWriteKtx(&writer, *image, image->m_data, image->m_size, &error);
		else
			bimg::imageWriteDds(&writer, *image, image->m_data, image->m_size, &error);
		bx::close(&writer);
		ok = error.isOk();
	}
	bimg::imageFree(image);
	return ok;
}
