#ifndef AI_SUBTITLE_TEXT_H
#define AI_SUBTITLE_TEXT_H
#include <stddef.h>
#include <stdint.h>

// Both inputs are already scaled to milliseconds by av_rescale_q. FFmpeg's
// display offsets are milliseconds relative to packet PTS, not seconds.
static inline int AiSubtitleInterval(int64_t baseMs, uint32_t startDisplayMs,
    uint32_t endDisplayMs, int64_t packetDurationMs, int64_t *startMs, int64_t *endMs)
{
    int64_t finish = 0;
    if (endDisplayMs != UINT32_MAX && endDisplayMs > startDisplayMs) finish = endDisplayMs;
    else if (packetDurationMs > (int64_t)startDisplayMs) finish = packetDurationMs;
    else return 0; // Unknown duration is not replaced with an invented default.
    if (baseMs > INT64_MAX - finish || baseMs > INT64_MAX - (int64_t)startDisplayMs) return 0;
    *startMs = baseMs + startDisplayMs; *endMs = baseMs + finish;
    return *endMs > *startMs;
}

// Returns UTF-8 byte count, 0 for formatting/drawings alone, -1 for malformed
// ASS or insufficient output capacity. No text is fabricated for bitmap cues.
static inline int AiSubtitlePlain(const char *input, size_t length, char *output, size_t capacity, int isAss)
{
    size_t begin = 0, written = 0;
    if (!input || !output || capacity == 0) return -1;
    if (length >= 3 && (unsigned char)input[0] == 0xEF && (unsigned char)input[1] == 0xBB && (unsigned char)input[2] == 0xBF) begin = 3;
    if (isAss) {
        int classic = length - begin >= 9 && input[begin] == 'D' && input[begin + 1] == 'i'
            && input[begin + 2] == 'a' && input[begin + 3] == 'l' && input[begin + 4] == 'o'
            && input[begin + 5] == 'g' && input[begin + 6] == 'u' && input[begin + 7] == 'e' && input[begin + 8] == ':';
        if (classic) begin += 9;
        int commas = classic ? 9 : 8;
        while (begin < length && commas > 0) if (input[begin++] == ',') commas--;
        if (commas != 0) return -1;
    }
    int drawing = 0;
    for (size_t at = begin; at < length; at++) {
        char c = input[at];
        if (isAss && c == '{' && at + 1 < length && input[at + 1] == '\\') {
            size_t end = at + 1;
            while (end < length && input[end] != '}') {
                if (input[end] == '\\' && end + 2 < length && input[end + 1] == 'p'
                    && input[end + 2] >= '0' && input[end + 2] <= '9') drawing = input[end + 2] != '0';
                end++;
            }
            if (end == length) return -1;
            at = end; continue;
        }
        if (drawing) continue;
        if (isAss && c == '\\' && at + 1 < length) {
            char next = input[at + 1];
            if (next == 'N' || next == 'n') { c = '\n'; at++; }
            else if (next == 'h') { c = ' '; at++; }
            else if (next == '\\') { c = '\\'; at++; }
        }
        if (written + 1 >= capacity) return -1;
        output[written++] = c;
    }
    size_t first = 0;
    while (first < written && (output[first] == ' ' || output[first] == '\n' || output[first] == '\r' || output[first] == '\t')) first++;
    while (written > first && (output[written - 1] == ' ' || output[written - 1] == '\n' || output[written - 1] == '\r' || output[written - 1] == '\t')) written--;
    for (size_t at = first; at < written; at++) output[at - first] = output[at];
    written -= first; output[written] = 0; return (int)written;
}
#endif
