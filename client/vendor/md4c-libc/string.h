/* Freestanding shim for md4c. mem* come from compiler_rt; the rest from libc_shim.zig. */
#ifndef ST_SHIM_STRING_H
#define ST_SHIM_STRING_H
#include <stddef.h>
void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);
char *strchr(const char *s, int c);
int strncmp(const char *a, const char *b, size_t n);
#endif
