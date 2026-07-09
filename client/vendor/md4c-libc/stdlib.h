/* Freestanding shim for md4c. Backed by std.heap.wasm_allocator in libc_shim.zig. */
#ifndef ST_SHIM_STDLIB_H
#define ST_SHIM_STDLIB_H
#include <stddef.h>
void *malloc(size_t size);
void *realloc(void *ptr, size_t size);
void free(void *ptr);
void qsort(void *base, size_t n, size_t width, int (*cmp)(const void *, const void *));
void *bsearch(const void *key, const void *base, size_t n, size_t width, int (*cmp)(const void *, const void *));
#endif
