/* Freestanding shim for md4c. Only snprintf is real; logging is compiled out. */
#ifndef ST_SHIM_STDIO_H
#define ST_SHIM_STDIO_H
#include <stddef.h>
int snprintf(char *buf, size_t size, const char *fmt, ...);
#define stderr ((void *)0)
#define fprintf(...) ((int)0)
#endif
