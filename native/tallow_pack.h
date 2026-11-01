// Asset packs: one file holding a game's assets, read instead of loose files once it is mounted.
#ifndef TALLOW_PACK_H
#define TALLOW_PACK_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Mounts a pack. Its files then appear to be at root/<name in the pack>. Returns the number of files, or -1.
int tn_pack_mount(const char* file, const char* root);
void tn_pack_unmount_all(void);
// Whether a full path names a file inside a mounted pack.
int tn_pack_exists(const char* path);
// Whether any file in a mounted pack is inside this folder.
int tn_pack_has_folder(const char* path);
// A file's contents, to be given back with tn_pack_free. NULL when the path is not in a pack, or the pack has
// been changed since it was built (each file carries a checksum).
void* tn_pack_read(const char* path, size_t* size);
void tn_pack_free(void* data);
// One number that stands for the game content in the mounted packs (the files under Assets/, by name and
// checksum, in any order), for comparing two machines' copies. 0 when nothing is mounted. Engine files are left
// out: they differ between systems.
unsigned tn_pack_fingerprint(void);
// For listing: how many files are mounted, and the full path of each.
int tn_pack_count(void);
const char* tn_pack_path(int index);
#ifdef __cplusplus
}
#endif
#endif
