#include "subtitle_text.h"
#include "http_range.h"
#include "local_source.h"
#ifdef _WIN32
#define AI_EXPORT __declspec(dllexport)
#else
#define AI_EXPORT __attribute__((visibility("default")))
#endif
AI_EXPORT int ai_plain(const char *input, size_t length, char *output, size_t capacity, int ass)
{ return AiSubtitlePlain(input, length, output, capacity, ass); }
AI_EXPORT int ai_interval(int64_t base, uint32_t start, uint32_t end, int64_t duration, int64_t *a, int64_t *b)
{ return AiSubtitleInterval(base, start, end, duration, a, b); }
AI_EXPORT int ai_range_end(int64_t start, int64_t total, int64_t chunk, int64_t *end)
{ return AiHttpRangeEnd(start, total, chunk, end); }

AI_EXPORT int ai_fd_source(const char *source, int *descriptor)
{ return ai_parse_fd_source(source, descriptor); }
