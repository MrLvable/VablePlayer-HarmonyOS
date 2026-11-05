#ifndef NAS_AI_LOCAL_SOURCE_H
#define NAS_AI_LOCAL_SOURCE_H
#include <limits.h>

/* fd:// borrows an app-held descriptor. The NAPI entry duplicates it before work queues. */
static inline int ai_parse_fd_source(const char *source, int *descriptor) {
    const char prefix[] = "fd://";
    if (!source || !descriptor) return 0;
    for (int i = 0; i < 5; ++i) { if (source[i] != prefix[i]) return 0; }
    const char *at = source + 5;
    if (*at < '0' || *at > '9') return 0;
    if (*at == '0' && at[1] != '\0') return 0;
    int value = 0;
    while (*at) {
        if (*at < '0' || *at > '9' || value > (INT_MAX - (*at - '0')) / 10) return 0;
        value = value * 10 + (*at++ - '0');
    }
    *descriptor = value; return 1;
}
#endif
