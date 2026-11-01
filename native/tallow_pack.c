// Asset packs (.tpak). tools/build_player.py writes them; this reads them.
//
//   header   "TPAK1\0\0\0", u32 version, u32 file count, u64 index offset, u32 index size, u32 seed
//   data     each file's bytes, deflated when that makes them smaller, then scrambled
//   index    scrambled; per file: u16 name length, name, u64 offset, u32 stored size, u32 size, u32 crc32 of
//            the original bytes, u8 flags (bit 0: deflated)
//
// Scrambling is an XOR with a repeating 4096-byte block made from the pack's seed and the file's checksum. It keeps
// the assets from being opened or edited with ordinary tools, and the checksum catches a file that was changed
// anyway. It is not encryption: the key is in every game.
#include "tallow_pack.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#endif

// stb_image's inflate, compiled in tallow_assets.c.
extern char* stbi_zlib_decode_malloc_guesssize_headerflag(const char* buffer, int len, int initial_size, int* outlen, int parse_header);

#define TN_PACK_KEY 0x7E55E2A5u
#define TN_PACK_BLOCK 4096

typedef struct
{
	char* path;        // full, normalised: root + "/" + name
	uint64_t offset;
	uint32_t stored, size, crc;
	uint8_t flags;
	int pack;
} TnPackEntry;

typedef struct
{
	char* file;
	uint32_t seed;
} TnPack;

static TnPack* packs = NULL;
static int packCount = 0;
static TnPackEntry* entries = NULL;
static int entryCount = 0;
static uint32_t fingerprint = 0;

static FILE* open_file(const char* path)
{
#ifdef _WIN32
	wchar_t wide[1024];
	if (MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, 1024) > 0)
		return _wfopen(wide, L"rb");
#endif
	return fopen(path, "rb");
}

// Forward slashes, no doubled ones, no "." parts, ".." folded away: so that the same file always has the same name.
static char* normalise(const char* path)
{
	size_t length = strlen(path);
	char* out = (char*)malloc(length + 2);
	size_t n = 0;
	size_t i = 0;
	while (i < length)
	{
		char c = path[i] == '\\' ? '/' : path[i];
		if (c == '/')
		{
			// Skip repeats, and "./".
			while (i + 1 < length && (path[i + 1] == '/' || path[i + 1] == '\\')) i++;
			if (i + 2 < length && path[i + 1] == '.' && (path[i + 2] == '/' || path[i + 2] == '\\')) { i += 2; continue; }
			if (i + 3 < length && path[i + 1] == '.' && path[i + 2] == '.' && (path[i + 3] == '/' || path[i + 3] == '\\'))
			{
				// Drop the folder before "..".
				while (n > 0 && out[n - 1] != '/') n--;
				if (n > 0) n--;
				i += 3;
				continue;
			}
		}
		out[n++] = c;
		i++;
	}
	while (n > 1 && out[n - 1] == '/') n--;
	out[n] = 0;
	return out;
}

static void make_block(uint32_t seed, uint32_t salt, uint8_t* block)
{
	uint32_t state = seed ^ TN_PACK_KEY ^ (salt * 2654435761u);
	if (state == 0) state = TN_PACK_KEY;
	for (int i = 0; i < TN_PACK_BLOCK; i++)
	{
		state ^= state << 13;
		state ^= state >> 17;
		state ^= state << 5;
		block[i] = (uint8_t)(state >> 11);
	}
}

static void unscramble(uint8_t* data, size_t size, uint32_t seed, uint32_t salt)
{
	uint8_t block[TN_PACK_BLOCK];
	make_block(seed, salt, block);
	for (size_t i = 0; i < size; i++)
		data[i] ^= block[i % TN_PACK_BLOCK];
}

static uint32_t crc32_of(const uint8_t* data, size_t size)
{
	static uint32_t table[256];
	static int made = 0;
	if (!made)
	{
		for (uint32_t i = 0; i < 256; i++)
		{
			uint32_t c = i;
			for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
			table[i] = c;
		}
		made = 1;
	}
	uint32_t crc = 0xFFFFFFFFu;
	for (size_t i = 0; i < size; i++) crc = table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
	return crc ^ 0xFFFFFFFFu;
}

static uint32_t read_u32(const uint8_t* p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint64_t read_u64(const uint8_t* p) { return (uint64_t)read_u32(p) | ((uint64_t)read_u32(p + 4) << 32); }

static int seek_to(FILE* file, uint64_t offset)
{
#ifdef _WIN32
	return _fseeki64(file, (long long)offset, SEEK_SET);
#else
	return fseeko(file, (off_t)offset, SEEK_SET);
#endif
}

int tn_pack_mount(const char* fileName, const char* root)
{
	FILE* file = open_file(fileName);
	if (file == NULL) return -1;
	uint8_t header[32];
	if (fread(header, 1, 32, file) != 32 || memcmp(header, "TPAK1\0\0\0", 8) != 0 || read_u32(header + 8) != 1) { fclose(file); return -1; }
	uint32_t count = read_u32(header + 12);
	uint64_t indexOffset = read_u64(header + 16);
	uint32_t indexSize = read_u32(header + 24);
	uint32_t seed = read_u32(header + 28);
	uint8_t* index = (uint8_t*)malloc(indexSize ? indexSize : 1);
	if (index == NULL || seek_to(file, indexOffset) != 0 || fread(index, 1, indexSize, file) != indexSize) { free(index); fclose(file); return -1; }
	fclose(file);
	unscramble(index, indexSize, seed, 0xFFFFFFFFu);

	char* base = normalise(root);
	size_t baseLength = strlen(base);
	TnPackEntry* grown = (TnPackEntry*)realloc(entries, sizeof(TnPackEntry) * (size_t)(entryCount + count + 1));
	TnPack* grownPacks = (TnPack*)realloc(packs, sizeof(TnPack) * (size_t)(packCount + 1));
	if (grown == NULL || grownPacks == NULL) { free(index); free(base); return -1; }
	entries = grown;
	packs = grownPacks;
	size_t at = 0;
	int added = 0;
	for (uint32_t i = 0; i < count; i++)
	{
		if (at + 2 > indexSize) break;
		size_t nameLength = (size_t)index[at] | ((size_t)index[at + 1] << 8);
		at += 2;
		if (at + nameLength + 21 > indexSize) break;
		TnPackEntry* entry = &entries[entryCount + added];
		char* joined = (char*)malloc(baseLength + nameLength + 2);
		memcpy(joined, base, baseLength);
		joined[baseLength] = '/';
		memcpy(joined + baseLength + 1, index + at, nameLength);
		joined[baseLength + 1 + nameLength] = 0;
		entry->path = normalise(joined);
		free(joined);
		at += nameLength;
		entry->offset = read_u64(index + at);
		entry->stored = read_u32(index + at + 8);
		entry->size = read_u32(index + at + 12);
		entry->crc = read_u32(index + at + 16);
		entry->flags = index[at + 20];
		entry->pack = packCount;
		// The game's own content goes into the fingerprint: its name (as packed) and its checksum, mixed so that
		// the order of the files does not matter.
		if (nameLength > 7 && memcmp(index + at - nameLength, "Assets/", 7) == 0)
		{
			uint32_t hash = 2166136261u;
			for (size_t c = 0; c < nameLength; c++) hash = (hash ^ index[at - nameLength + c]) * 16777619u;
			for (int c = 0; c < 4; c++) hash = (hash ^ ((entry->crc >> (c * 8)) & 0xFF)) * 16777619u;
			hash ^= hash >> 15; hash *= 0x2c1b3c6du; hash ^= hash >> 12;
			fingerprint += hash;
		}
		at += 21;
		added++;
	}
	free(index);
	free(base);
	if ((uint32_t)added != count) { for (int i = 0; i < added; i++) free(entries[entryCount + i].path); return -1; }
	packs[packCount].file = (char*)malloc(strlen(fileName) + 1);
	strcpy(packs[packCount].file, fileName);
	packs[packCount].seed = seed;
	packCount++;
	entryCount += added;
	return added;
}

void tn_pack_unmount_all(void)
{
	for (int i = 0; i < entryCount; i++) free(entries[i].path);
	for (int i = 0; i < packCount; i++) free(packs[i].file);
	free(entries);
	free(packs);
	entries = NULL;
	packs = NULL;
	entryCount = 0;
	packCount = 0;
	fingerprint = 0;
}

static const TnPackEntry* find(const char* path)
{
	if (entryCount == 0 || path == NULL) return NULL;
	char* wanted = normalise(path);
	const TnPackEntry* found = NULL;
	// The newest pack wins, as the newest search path does for loose files.
	for (int i = entryCount - 1; i >= 0; i--)
	{
		if (strcmp(entries[i].path, wanted) == 0) { found = &entries[i]; break; }
	}
	free(wanted);
	return found;
}

int tn_pack_exists(const char* path) { return find(path) != NULL; }

int tn_pack_has_folder(const char* path)
{
	if (entryCount == 0 || path == NULL) return 0;
	char* wanted = normalise(path);
	size_t length = strlen(wanted);
	int found = 0;
	for (int i = 0; i < entryCount && !found; i++)
		found = strncmp(entries[i].path, wanted, length) == 0 && entries[i].path[length] == '/';
	free(wanted);
	return found;
}

void* tn_pack_read(const char* path, size_t* size)
{
	if (size != NULL) *size = 0;
	const TnPackEntry* entry = find(path);
	if (entry == NULL) return NULL;
	// Opened afresh each time: sounds are loaded from other threads.
	FILE* file = open_file(packs[entry->pack].file);
	if (file == NULL) return NULL;
	uint8_t* stored = (uint8_t*)malloc(entry->stored ? entry->stored : 1);
	if (stored == NULL || seek_to(file, entry->offset) != 0 || fread(stored, 1, entry->stored, file) != entry->stored) { free(stored); fclose(file); return NULL; }
	fclose(file);
	unscramble(stored, entry->stored, packs[entry->pack].seed, entry->crc);
	uint8_t* plain = stored;
	if (entry->flags & 1)
	{
		int length = 0;
		plain = (uint8_t*)stbi_zlib_decode_malloc_guesssize_headerflag((const char*)stored, (int)entry->stored, (int)entry->size + 16, &length, 1);
		free(stored);
		if (plain == NULL || (uint32_t)length != entry->size) { free(plain); return NULL; }
	}
	if (crc32_of(plain, entry->size) != entry->crc) { free(plain); return NULL; }
	if (size != NULL) *size = entry->size;
	return plain;
}

void tn_pack_free(void* data) { free(data); }
unsigned tn_pack_fingerprint(void) { return entryCount > 0 ? (fingerprint != 0 ? fingerprint : 1u) : 0u; }
int tn_pack_count(void) { return entryCount; }
const char* tn_pack_path(int index) { return index >= 0 && index < entryCount ? entries[index].path : NULL; }
