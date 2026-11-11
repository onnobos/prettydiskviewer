#include "c_diskscan.h"

#include <sys/syscall.h>
#include <sys/attr.h>
#include <sys/vnode.h>
#include <sys/stat.h>
#include <dirent.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#define BULK_BUF_SIZE 262144
#define INITIAL_CAPACITY 64
#define INITIAL_NAME_POOL 1024

#ifndef SF_FIRMLINK
#define SF_FIRMLINK 0x00800000
#endif

#ifndef SF_DATALESS
#define SF_DATALESS 0x40000000
#endif

static int append_entry_with_name(CDirListing *listing,
                                  CDiskEntry *entry,
                                  const char *name,
                                  size_t name_len) {
    // Append to name pool
    size_t needed_pool = listing->name_pool_len + name_len + 1;
    if (needed_pool > listing->name_pool_cap) {
        size_t new_cap = listing->name_pool_cap == 0 ? INITIAL_NAME_POOL : listing->name_pool_cap * 2;
        while (new_cap < needed_pool) {
            new_cap *= 2;
        }
        char *new_pool = (char *)realloc(listing->name_pool, new_cap);
        if (!new_pool) return -1;
        listing->name_pool = new_pool;
        listing->name_pool_cap = new_cap;
    }

    uint32_t offset = (uint32_t)listing->name_pool_len;
    memcpy(listing->name_pool + offset, name, name_len);
    listing->name_pool[offset + name_len] = '\0';
    listing->name_pool_len += name_len + 1;

    entry->name_offset = offset;
    entry->name_len = (uint16_t)name_len;

    // Append to entries array
    if (listing->count >= listing->capacity) {
        size_t new_cap = listing->capacity == 0 ? INITIAL_CAPACITY : listing->capacity * 2;
        CDiskEntry *new_arr = (CDiskEntry *)realloc(listing->entries, new_cap * sizeof(CDiskEntry));
        if (!new_arr) return -1;
        listing->entries = new_arr;
        listing->capacity = new_cap;
    }

    listing->entries[listing->count] = *entry;
    listing->count++;
    return 0;
}

static int read_dir_fallback(int dirfd, const char *dir_path, CDirListing *listing) {
    DIR *dir = fdopendir(dirfd);
    if (!dir) {
        listing->error_code = errno;
        close(dirfd);
        return -1;
    }

    struct dirent *de;
    while ((de = readdir(dir)) != NULL) {
        if (de->d_name[0] == '.' && (de->d_name[1] == '\0' || (de->d_name[1] == '.' && de->d_name[2] == '\0'))) {
            continue;
        }

        struct stat st;
        if (fstatat(dirfd, de->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
            continue;
        }

        CDiskEntry entry;
        memset(&entry, 0, sizeof(entry));
        entry.file_id = st.st_ino;
        entry.link_count = (uint32_t)st.st_nlink;
        entry.flags = st.st_flags;
        entry.mtime = (uint32_t)st.st_mtime;
        entry.apparent_size = (int64_t)st.st_size;

        if (st.st_flags & SF_FIRMLINK) {
            entry.flags_internal |= 0x01;
        }
        if (st.st_flags & SF_DATALESS) {
            entry.flags_internal |= 0x04;
        }

        if (S_ISDIR(st.st_mode)) {
            entry.entry_type = C_ENTRY_DIR;
            entry.alloc_size = 0;
            entry.private_size = 0;
            entry.apparent_size = 0;
        } else {
            if (S_ISREG(st.st_mode)) {
                entry.entry_type = C_ENTRY_FILE;
            } else if (S_ISLNK(st.st_mode)) {
                entry.entry_type = C_ENTRY_SYMLINK;
            } else {
                entry.entry_type = C_ENTRY_OTHER;
            }

            if (entry.flags_internal & 0x04) {
                // Dataless
                entry.alloc_size = 0;
                entry.private_size = 0;
            } else {
                entry.alloc_size = (int64_t)st.st_blocks * 512;
                entry.private_size = entry.alloc_size;
            }
        }

        size_t nlen = strlen(de->d_name);
        if (append_entry_with_name(listing, &entry, de->d_name, nlen) != 0) {
            listing->error_code = ENOMEM;
            closedir(dir);
            return -1;
        }
    }

    closedir(dir);
    listing->used_fallback = true;
    return 0;
}

int c_diskscan_read_dir(const char *dir_path, CDirListing *listing) {
    if (!listing) return -1;
    memset(listing, 0, sizeof(*listing));

    int dirfd = open(dir_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dirfd < 0) {
        listing->error_code = errno;
        return -1;
    }

    struct stat st;
    if (fstat(dirfd, &st) == 0) {
        listing->dir_dev = (uint64_t)st.st_dev;
    } else {
        listing->error_code = errno;
        close(dirfd);
        return -1;
    }

    struct attrlist attrList;
    memset(&attrList, 0, sizeof(attrList));
    attrList.bitmapcount = ATTR_BIT_MAP_COUNT;
    attrList.commonattr = ATTR_CMN_RETURNED_ATTRS |
                          ATTR_CMN_NAME |
                          ATTR_CMN_ERROR |
                          ATTR_CMN_OBJTYPE |
                          ATTR_CMN_MODTIME |
                          ATTR_CMN_FLAGS |
                          ATTR_CMN_FILEID;
    attrList.fileattr = ATTR_FILE_LINKCOUNT |
                        ATTR_FILE_ALLOCSIZE |
                        ATTR_FILE_DATALENGTH;
    attrList.dirattr = ATTR_DIR_MOUNTSTATUS;
    attrList.forkattr = ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_EXT_FLAGS;

    char *buf = (char *)malloc(BULK_BUF_SIZE);
    if (!buf) {
        listing->error_code = ENOMEM;
        close(dirfd);
        return -1;
    }

    while (1) {
        int count = getattrlistbulk(dirfd, &attrList, buf, BULK_BUF_SIZE, 0);
        if (count < 0) {
            if (errno == ENOTSUP || errno == EINVAL) {
                // Bulk attrs not supported by this filesystem; switch to fallback
                free(buf);
                return read_dir_fallback(dirfd, dir_path, listing);
            }
            listing->error_code = errno;
            free(buf);
            close(dirfd);
            return -1;
        }
        if (count == 0) {
            break; // Finished reading directory entries
        }

        char *cursor = buf;
        for (int i = 0; i < count; i++) {
            char *entry_start = cursor;
            uint32_t entry_len = *(uint32_t *)cursor;
            cursor += sizeof(uint32_t);

            attribute_set_t returned = *(attribute_set_t *)cursor;
            cursor += sizeof(attribute_set_t);

            const char *name = "";
            if (returned.commonattr & ATTR_CMN_NAME) {
                struct attrreference *name_ref = (struct attrreference *)cursor;
                name = (char *)name_ref + name_ref->attr_dataoffset;
                cursor += sizeof(struct attrreference);
            }

            fsobj_type_t obj_type = 0;
            if (returned.commonattr & ATTR_CMN_OBJTYPE) {
                obj_type = *(fsobj_type_t *)cursor;
                cursor += sizeof(fsobj_type_t);
            }

            uint32_t mtime = 0;
            if (returned.commonattr & ATTR_CMN_MODTIME) {
                struct timespec ts = *(struct timespec *)cursor;
                mtime = (uint32_t)ts.tv_sec;
                cursor += sizeof(struct timespec);
            }

            uint32_t flags = 0;
            if (returned.commonattr & ATTR_CMN_FLAGS) {
                flags = *(uint32_t *)cursor;
                cursor += sizeof(uint32_t);
            }

            uint64_t fileid = 0;
            if (returned.commonattr & ATTR_CMN_FILEID) {
                fileid = *(uint64_t *)cursor;
                cursor += sizeof(uint64_t);
            }

            uint32_t entry_err = 0;
            if (returned.commonattr & ATTR_CMN_ERROR) {
                entry_err = *(uint32_t *)cursor;
                cursor += sizeof(uint32_t);
                (void)entry_err;
            }

            // Directory attributes appear BEFORE file attributes in getattrlistbulk
            uint32_t mountstatus = 0;
            if (returned.dirattr & ATTR_DIR_MOUNTSTATUS) {
                mountstatus = *(uint32_t *)cursor;
                cursor += sizeof(uint32_t);
            }

            // File attributes
            uint32_t link_count = 1;
            if (returned.fileattr & ATTR_FILE_LINKCOUNT) {
                link_count = *(uint32_t *)cursor;
                cursor += sizeof(uint32_t);
            }

            off_t alloc_size = 0;
            if (returned.fileattr & ATTR_FILE_ALLOCSIZE) {
                alloc_size = *(off_t *)cursor;
                cursor += sizeof(off_t);
            }

            off_t apparent_size = 0;
            if (returned.fileattr & ATTR_FILE_DATALENGTH) {
                apparent_size = *(off_t *)cursor;
                cursor += sizeof(off_t);
            }

            off_t private_size = 0;
            bool has_private_size = false;
            if (returned.forkattr & ATTR_CMNEXT_PRIVATESIZE) {
                private_size = *(off_t *)cursor;
                has_private_size = true;
                cursor += sizeof(off_t);
            }

            if (returned.forkattr & ATTR_CMNEXT_EXT_FLAGS) {
                uint64_t ext_flags = *(uint64_t *)cursor;
                cursor += sizeof(uint64_t);
                (void)ext_flags;
            }

            // Skip current and parent dir entries
            if (!(name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0')))) {
                CDiskEntry entry;
                memset(&entry, 0, sizeof(entry));
                entry.file_id = fileid;
                entry.link_count = link_count;
                entry.flags = flags;
                entry.mtime = mtime;

                if (flags & SF_FIRMLINK) {
                    entry.flags_internal |= 0x01;
                }
                if (mountstatus & DIR_MNTSTATUS_MNTPOINT) {
                    entry.flags_internal |= 0x02;
                }
                if (flags & SF_DATALESS) {
                    entry.flags_internal |= 0x04;
                }

                if (obj_type == VDIR) {
                    entry.entry_type = C_ENTRY_DIR;
                    entry.alloc_size = 0;
                    entry.apparent_size = 0;
                    entry.private_size = 0;
                } else {
                    if (obj_type == VREG) {
                        entry.entry_type = C_ENTRY_FILE;
                    } else if (obj_type == VLNK) {
                        entry.entry_type = C_ENTRY_SYMLINK;
                    } else {
                        entry.entry_type = C_ENTRY_OTHER;
                    }

                    if (entry.flags_internal & 0x04) {
                        // Dataless iCloud/cloud file
                        entry.alloc_size = 0;
                        entry.private_size = 0;
                        entry.apparent_size = (int64_t)apparent_size;
                    } else {
                        entry.alloc_size = (int64_t)alloc_size;
                        entry.apparent_size = (int64_t)apparent_size;
                        entry.private_size = has_private_size ? (int64_t)private_size : (int64_t)alloc_size;
                    }
                }

                size_t nlen = strlen(name);
                if (append_entry_with_name(listing, &entry, name, nlen) != 0) {
                    listing->error_code = ENOMEM;
                    free(buf);
                    close(dirfd);
                    return -1;
                }
            }

            cursor = entry_start + entry_len;
        }
    }

    free(buf);
    close(dirfd);
    return 0;
}

void c_diskscan_free_listing(CDirListing *listing) {
    if (!listing) return;
    if (listing->entries) {
        free(listing->entries);
        listing->entries = NULL;
    }
    if (listing->name_pool) {
        free(listing->name_pool);
        listing->name_pool = NULL;
    }
    listing->count = 0;
    listing->capacity = 0;
    listing->name_pool_len = 0;
    listing->name_pool_cap = 0;
}

int c_diskscan_stat_path(const char *path,
                         uint64_t *out_dev,
                         uint64_t *out_fileid,
                         int64_t *out_alloc,
                         int64_t *out_apparent,
                         int64_t *out_priv,
                         uint32_t *out_mtime,
                         uint32_t *out_links,
                         CEntryType *out_type,
                         bool follow_symlinks) {
    struct stat st;
    int res = follow_symlinks ? stat(path, &st) : lstat(path, &st);
    if (res != 0) {
        return -1;
    }
    if (out_dev) *out_dev = (uint64_t)st.st_dev;
    if (out_fileid) *out_fileid = (uint64_t)st.st_ino;
    if (out_links) *out_links = (uint32_t)st.st_nlink;
    if (out_mtime) *out_mtime = (uint32_t)st.st_mtime;

    CEntryType etype;
    if (S_ISDIR(st.st_mode)) etype = C_ENTRY_DIR;
    else if (S_ISREG(st.st_mode)) etype = C_ENTRY_FILE;
    else if (S_ISLNK(st.st_mode)) etype = C_ENTRY_SYMLINK;
    else etype = C_ENTRY_OTHER;
    if (out_type) *out_type = etype;

    int64_t alloc = 0;
    int64_t apparent = (int64_t)st.st_size;
    int64_t priv = 0;

    if (etype == C_ENTRY_DIR) {
        alloc = 0;
        priv = 0;
        apparent = 0;
    } else if (st.st_flags & SF_DATALESS) {
        alloc = 0;
        priv = 0;
    } else {
        alloc = (int64_t)st.st_blocks * 512;
        priv = alloc;
    }

    if (out_alloc) *out_alloc = alloc;
    if (out_apparent) *out_apparent = apparent;
    if (out_priv) *out_priv = priv;

    return 0;
}
