#ifndef NAS_AI_HTTP_RANGE_H
#define NAS_AI_HTTP_RANGE_H
#include <stdint.h>

/* Unknown size is discovered with bytes=0-0. Known-size requests never pass EOF. */
static int AiHttpRangeEnd(int64_t start, int64_t total, int64_t chunk, int64_t *end)
{
    if (!end || start < 0 || total < 0 || chunk <= 0) return 0;
    if (total == 0) {
        if (start != 0) return 0;
        *end = 0;
        return 1;
    }
    if (start >= total) return 0;
    const int64_t remaining = total - start;
    const int64_t count = remaining < chunk ? remaining : chunk;
    *end = start + count - 1;
    return 1;
}
#endif
