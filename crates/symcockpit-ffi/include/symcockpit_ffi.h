#ifndef SYMCOCKPIT_FFI_H
#define SYMCOCKPIT_FFI_H

#include <stdint.h>

/* C ABI of libsymcockpit_ffi (ADR 0004). Used by the Quick Look and FinderSync extensions.
 *
 * Every *_json function returns UTF-8 JSON text and never crashes the caller:
 *   {"ok":true,"format":"dir|zip|tar|7z","entries":[{"name","path","kind","size","depth",
 *     "compressed"?}],"truncated":bool,"notices":[".."],"total_entries"?,"declared_bytes"?}
 *   {"ok":false,"error":"..."}
 * A limit hit (entries, depth, declared size, time) is a partial result with truncated=true
 * and a notice; nothing is ever unpacked. Returns NULL only when memory is exhausted.
 *
 * path:    NUL-terminated UTF-8, valid for the call; NULL gives an error result.
 * options: NULL for the defaults, or a JSON object {"max_entries","max_depth",
 *          "max_total_bytes","time_ms"}; values are clamped to hard ceilings.
 * Strings returned by *_json belong to the caller: free them with symcockpit_free_string. */

#define SYMCOCKPIT_FFI_ABI_VERSION 1

char *symcockpit_list_dir_json(const char *path, const char *options);
char *symcockpit_list_archive_json(const char *path, const char *options);
void symcockpit_free_string(char *s);          /* NULL is allowed */
uint32_t symcockpit_ffi_abi_version(void);     /* equals SYMCOCKPIT_FFI_ABI_VERSION */
const char *symcockpit_ffi_version(void);      /* static, do not free */

#endif
