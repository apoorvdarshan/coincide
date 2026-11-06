#ifndef COINCIDE_COMPUTER_USE_H
#define COINCIDE_COMPUTER_USE_H
#include <stdbool.h>
#include <stddef.h>
void *coincide_cu_create(void);
void coincide_cu_destroy(void *context);
/* UTF-8 request <=262144 bytes, result <=4194304 bytes plus NUL. Caller owns
   returned malloc buffer and releases it with coincide_cu_free. No borrowed
   data. check(guard) is synchronous and is rechecked immediately before input;
   guard is borrowed for this call only, never captured by screenshot callbacks.
 */
char *coincide_cu_call(void *context, const unsigned char *request,
                       size_t length, size_t *result_length,
                       bool (*check)(const void *), const void *guard);
void coincide_cu_free(char *buffer);
#endif
