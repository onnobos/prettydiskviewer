#ifndef C_DISKSCAN_H
#define C_DISKSCAN_H

#include <stdint.h>
#include <stdbool.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    C_ENTRY_UNKNOWN = 0,
    C_ENTRY_FILE = 1,
    C_ENTRY_DIR = 2,
    C_ENTRY_SYMLINK = 3,
    C_ENTRY_OTHER = 4
} CEntryType;

typedef struct {
    uint32_t name_offset;   // Byte offset in CDirListing.name_pool
    uint16_t name_len;      // Length in bytes
    uint8_t entry_type;     // CEntryType
    uint8_t flags_internal; // bit 0: is_firmlink, bit 1: is_mountpoint, bit 2: is_dataless
    uint32_t link_count;
    uint32_t flags;         // BSD st_flags
    uint32_t mtime;         // Unix epoch seconds
    uint64_t file_id;       // Inode
    int64_t alloc_size;     // Allocated size on disk (bytes)
    int64_t apparent_size;  // Logical length (bytes)
    int64_t private_size;   // Private size (bytes) - actual space freed if removed
} CDiskEntry;

typedef struct {
    CDiskEntry *entries;
    size_t count;
    size_t capacity;
    char *name_pool;
    size_t name_pool_len;
    size_t name_pool_cap;
    uint64_t dir_dev;
    int error_code; // 0 if success, errno if failed (e.g. EACCES, ENOENT)
    bool used_fallback;
} CDirListing;

static inline const char *c_diskscan_entry_name(const CDirListing *listing, size_t index) {
    if (!listing || !listing->name_pool || index >= listing->count) return "";
    return listing->name_pool + listing->entries[index].name_offset;
}

static inline bool c_diskscan_entry_is_firmlink(const CDiskEntry *entry) {
    return (entry->flags_internal & 0x01) != 0;
}

static inline bool c_diskscan_entry_is_mountpoint(const CDiskEntry *entry) {
    return (entry->flags_internal & 0x02) != 0;
}

static inline bool c_diskscan_entry_is_dataless(const CDiskEntry *entry) {
    return (entry->flags_internal & 0x04) != 0;
}

// Scans an entire directory using getattrlistbulk (falling back to readdir/lstat if needed).
// Sets error_code if cannot open or read.
// Always call c_diskscan_free_listing after done.
int c_diskscan_read_dir(const char *dir_path, CDirListing *listing);

void c_diskscan_free_listing(CDirListing *listing);

// Stat a single path (useful for root/top-level item)
int c_diskscan_stat_path(const char *path,
                         uint64_t *out_dev,
                         uint64_t *out_fileid,
                         int64_t *out_alloc,
                         int64_t *out_apparent,
                         int64_t *out_priv,
                         uint32_t *out_mtime,
                         uint32_t *out_links,
                         CEntryType *out_type,
                         bool follow_symlinks);

#ifdef __cplusplus
}
#endif

#endif /* C_DISKSCAN_H */
