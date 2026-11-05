// Independent bounded audio reader. It never creates or changes a player.
#include <napi/native_api.h>
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <poll.h>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <vector>
#include "subtitle_text.h"
#include "http_range.h"
#include "local_source.h"
extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
}

namespace {
constexpr int kRate = 16000;
constexpr int64_t kBudget = 32LL * 1024 * 1024;
constexpr size_t kChunk = 512 * 1024;
using Clock = std::chrono::steady_clock;
struct SubtitleCue { int64_t startMs = 0, endMs = 0; std::string text; };
struct Job {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string id, url, path, headers, error;
    int64_t startMs = 0, durationMs = 12000, actualStartMs = 0, actualEndMs = 0, sourceBytes = 0;
    int64_t subtitlePreRollMs = 5000;
    int64_t sourceOpenBytes = 0, sourceProbeBytes = 0, sourceSeekBytes = 0;
    int audioStreamIndex = -1;
    int sourceFd = -1;
    bool subtitles = false;
    int subtitleStreamIndex = -1, subtitleOrdinal = -1, selectedStreamIndex = -1;
    std::string preferredLanguage, language;
    std::vector<SubtitleCue> cues;
    std::atomic<bool> cancelled {false};
    std::atomic<bool> ownsOutput {false};
    Clock::time_point deadline;
    ~Job() { if (sourceFd >= 0) close(sourceFd); }
    void Check() const {
        if (cancelled.load()) throw std::runtime_error("EXTRACTION_CANCELLED");
        if (Clock::now() >= deadline) throw std::runtime_error("EXTRACTION_TIMEOUT");
    }
};
std::mutex jobsMutex;
std::map<std::string, std::shared_ptr<Job>> jobs;
struct Fd {
    int value = -1;
    explicit Fd(int fd = -1) : value(fd) {}
    ~Fd() { if (value >= 0) close(value); }
};
void Need(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
void AvNeed(int value, const char *message) { Need(value >= 0, message); }
std::string Lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return std::tolower(c); }); return s;
}
std::string Trim(const std::string &s) {
    auto a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return {};
    return s.substr(a, s.find_last_not_of(" \t\r\n") - a + 1);
}
std::string HttpFailure(int status, const std::map<std::string, std::string> &headers,
    const std::vector<uint8_t> &received, size_t bodyStart) {
    const auto value = [&headers](const char *name) -> std::string {
        auto entry = headers.find(name); return entry == headers.end() ? "" : entry->second;
    };
    const std::string type = Lower(value("content-type"));
    const char *kind = type.find("json") != std::string::npos ? "JSON"
        : type.find("html") != std::string::npos ? "HTML"
        : type.find("video/") != std::string::npos || type.find("audio/") != std::string::npos
            || type.find("octet-stream") != std::string::npos ? "MEDIA" : "OTHER";
    // Only allowlisted classifications and numeric status/code leave this layer.
    // Never attach a URL, response text, arbitrary header value or credential.
    std::string message = status == 401 || status == 403 ? "HTTP_AUTHENTICATION_FAILED" : "HTTP_RANGE_REQUIRED";
    message += "_STATUS_" + std::to_string(status) + "_" + kind;
    message += "_CR_" + std::string(value("content-range").empty() ? "N" : "Y");
    message += "_CL_" + std::string(value("content-length").empty() ? "N" : "Y");
    if (kind == std::string("JSON") && bodyStart < received.size()) {
        const std::string body(received.begin() + bodyStart, received.end());
        const size_t key = body.find("\"code\"");
        if (key != std::string::npos) {
            size_t at = key + 6;
            while (at < body.size() && std::isspace(static_cast<unsigned char>(body[at]))) at++;
            if (at < body.size() && body[at++] == ':') {
                while (at < body.size() && std::isspace(static_cast<unsigned char>(body[at]))) at++;
                const size_t start = at;
                if (at < body.size() && body[at] == '-') at++;
                const size_t digits = at;
                while (at < body.size() && body[at] >= '0' && body[at] <= '9') at++;
                const size_t end = at;
                while (at < body.size() && std::isspace(static_cast<unsigned char>(body[at]))) at++;
                if (end > digits && end - start <= 10 && at < body.size() && (body[at] == ',' || body[at] == '}')) {
                    message += "_API_" + body.substr(start, end - start);
                }
            }
        }
    }
    return message;
}
void WaitFd(Job &job, int fd, short events) {
    for (;;) {
        job.Check();
        pollfd p {fd, events, 0};
        int result = poll(&p, 1, 100);
        if (result < 0 && errno == EINTR) continue;
        Need(result >= 0, "HTTP_POLL_FAILED");
        if (result == 0) continue;
        if (p.revents & events) return;
        Need(!(p.revents & (POLLERR | POLLHUP | POLLNVAL)), "HTTP_CONNECTION_CLOSED");
    }
}
struct HttpAddress {
    std::string host, authority, path;
    int port = 80, family = AF_INET;
    sockaddr_storage address {};
    socklen_t length = 0;
};
HttpAddress ParseAddress(const std::string &url) {
    Need(url.rfind("http://", 0) == 0, "SOURCE_REQUIRES_LOCAL_PATH_OR_NUMERIC_HTTP");
    Need(url.find_first_of("\r\n#") == std::string::npos, "INVALID_SOURCE_URL");
    HttpAddress result;
    size_t end = url.find_first_of("/?", 7);
    result.authority = url.substr(7, end == std::string::npos ? end : end - 7);
    Need(!result.authority.empty() && result.authority.find('@') == std::string::npos, "INVALID_SOURCE_AUTHORITY");
    result.path = end == std::string::npos ? "/" : (url[end] == '?' ? "/" + url.substr(end) : url.substr(end));
    std::string port;
    if (result.authority[0] == '[') {
        size_t closeBracket = result.authority.find(']');
        Need(closeBracket != std::string::npos, "INVALID_SOURCE_AUTHORITY");
        result.host = result.authority.substr(1, closeBracket - 1); result.family = AF_INET6;
        if (closeBracket + 1 < result.authority.size()) {
            Need(result.authority[closeBracket + 1] == ':', "INVALID_SOURCE_PORT");
            port = result.authority.substr(closeBracket + 2);
        }
    } else {
        size_t colon = result.authority.find(':');
        result.host = result.authority.substr(0, colon);
        if (colon != std::string::npos) port = result.authority.substr(colon + 1);
    }
    if (!port.empty()) {
        Need(port.size() <= 5 && port.find_first_not_of("0123456789") == std::string::npos, "INVALID_SOURCE_PORT");
        result.port = std::stoi(port); Need(result.port > 0 && result.port <= 65535, "INVALID_SOURCE_PORT");
    }
    if (result.family == AF_INET) {
        auto *a = reinterpret_cast<sockaddr_in *>(&result.address); a->sin_family = AF_INET; a->sin_port = htons(result.port);
        Need(inet_pton(AF_INET, result.host.c_str(), &a->sin_addr) == 1, "HTTP_HOSTNAME_UNSUPPORTED_USE_NUMERIC_IP");
        result.length = sizeof(*a);
    } else {
        auto *a = reinterpret_cast<sockaddr_in6 *>(&result.address); a->sin6_family = AF_INET6; a->sin6_port = htons(result.port);
        Need(inet_pton(AF_INET6, result.host.c_str(), &a->sin6_addr) == 1, "HTTP_HOSTNAME_UNSUPPORTED_USE_NUMERIC_IP");
        result.length = sizeof(*a);
    }
    return result;
}

class Source {
public:
    Job &job;
    int64_t size = 0, position = 0;
    std::string failure;
    explicit Source(Job &j) : job(j), local(j.sourceFd >= 0 || (!j.url.empty() && j.url[0] == '/')) {
        if (local) {
            file.value = j.sourceFd >= 0 ? fcntl(j.sourceFd, F_DUPFD_CLOEXEC, 0) : open(j.url.c_str(), O_RDONLY | O_CLOEXEC);
            struct stat st {};
            Need(file.value >= 0 && fstat(file.value, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0, "LOCAL_SOURCE_UNAVAILABLE");
            size = st.st_size;
        } else { address = ParseAddress(j.url); Fetch(0); }
    }
    int Read(uint8_t *buffer, int length) {
        job.Check();
        if (position >= size) return AVERROR_EOF;
        int count = static_cast<int>(std::min<int64_t>(length, size - position));
        if (local) {
            Need(job.sourceBytes + count <= kBudget, "SOURCE_READ_BUDGET_EXCEEDED");
            ssize_t got = pread(file.value, buffer, count, position);
            Need(got >= 0, "LOCAL_SOURCE_READ_FAILED");
            if (got == 0) return AVERROR_EOF;
            job.sourceBytes += got; position += got; return static_cast<int>(got);
        }
        if (position < cacheStart || position >= cacheStart + static_cast<int64_t>(cache.size())) Fetch(position / kChunk * kChunk);
        count = static_cast<int>(std::min<int64_t>(count, cacheStart + cache.size() - position));
        Need(count > 0, "HTTP_EMPTY_RANGE");
        memcpy(buffer, cache.data() + position - cacheStart, count); position += count; return count;
    }
    static int ReadCallback(void *opaque, uint8_t *buffer, int length) {
        auto *source = static_cast<Source *>(opaque);
        try { return source->Read(buffer, length); }
        catch (const std::exception &e) { source->failure = e.what(); return AVERROR(EIO); }
    }
    static int64_t SeekCallback(void *opaque, int64_t offset, int whence) {
        auto *source = static_cast<Source *>(opaque);
        whence &= ~AVSEEK_FORCE;
        if (whence == AVSEEK_SIZE) return source->size;
        int64_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? source->position : whence == SEEK_END ? source->size : -1;
        if (base < 0 || offset < -base || offset > source->size - base) return AVERROR(EINVAL);
        source->position = base + offset; return source->position;
    }
private:
    bool local;
    Fd file;
    HttpAddress address;
    std::vector<uint8_t> cache;
    int64_t cacheStart = -1;
    ssize_t Receive(int fd, uint8_t *buffer, size_t capacity) {
        for (;;) {
            WaitFd(job, fd, POLLIN);
            ssize_t n = recv(fd, buffer, capacity, 0);
            if (n < 0 && (errno == EAGAIN || errno == EINTR)) continue;
            Need(n > 0, "HTTP_TRUNCATED_RANGE");
            job.sourceBytes += n; Need(job.sourceBytes <= kBudget, "SOURCE_READ_BUDGET_EXCEEDED"); return n;
        }
    }
    void Fetch(int64_t start) {
        job.Check();
        int64_t requestedEnd = 0;
        Need(AiHttpRangeEnd(start, size, kChunk, &requestedEnd), "HTTP_RANGE_START_OUTSIDE_SOURCE");
        Need(job.sourceBytes + static_cast<int64_t>(kChunk) + 16384 <= kBudget, "SOURCE_READ_BUDGET_EXCEEDED");
        Fd socketFd(socket(address.family, SOCK_STREAM | SOCK_CLOEXEC, 0));
        Need(socketFd.value >= 0 && fcntl(socketFd.value, F_SETFL, O_NONBLOCK) == 0, "HTTP_SOCKET_FAILED");
        int connected = connect(socketFd.value, reinterpret_cast<sockaddr *>(&address.address), address.length);
        Need(connected == 0 || errno == EINPROGRESS, "HTTP_CONNECT_FAILED");
        if (connected != 0) {
            WaitFd(job, socketFd.value, POLLOUT);
            int error = 0; socklen_t length = sizeof(error);
            Need(getsockopt(socketFd.value, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0, "HTTP_CONNECT_FAILED");
        }
        const std::string request = "GET " + address.path + " HTTP/1.1\r\nHost: " + address.authority
            + "\r\nConnection: close\r\nAccept: */*\r\nUser-Agent: NasPlayerHarmony-AudioExtractor/1.0"
            + "\r\nAccept-Encoding: identity\r\nRange: bytes=" + std::to_string(start) + "-"
            + std::to_string(requestedEnd) + "\r\n" + job.headers + "\r\n";
        size_t sent = 0;
        while (sent < request.size()) {
            WaitFd(job, socketFd.value, POLLOUT);
            ssize_t n = send(socketFd.value, request.data() + sent, request.size() - sent, MSG_NOSIGNAL);
            if (n < 0 && (errno == EAGAIN || errno == EINTR)) continue;
            Need(n > 0, "HTTP_SEND_FAILED"); sent += n;
        }
        std::vector<uint8_t> received; size_t headerEnd = std::string::npos;
        while (headerEnd == std::string::npos) {
            uint8_t buffer[4096]; ssize_t n = Receive(socketFd.value, buffer, sizeof(buffer));
            received.insert(received.end(), buffer, buffer + n);
            std::string text(received.begin(), received.end()); headerEnd = text.find("\r\n\r\n");
            Need(headerEnd == std::string::npos ? received.size() < 16384 : headerEnd <= 16384, "HTTP_HEADERS_TOO_LARGE");
        }
        std::string header(received.begin(), received.begin() + headerEnd);
        size_t firstEnd = header.find("\r\n");
        int status = 0; Need(sscanf(header.c_str(), "HTTP/%*s %d", &status) == 1, "HTTP_INVALID_RESPONSE");
        Need(status < 300 || status >= 400, "HTTP_REDIRECT_REJECTED");
        std::map<std::string, std::string> headers;
        size_t at = firstEnd == std::string::npos ? header.size() : firstEnd + 2;
        while (at < header.size()) {
            size_t end = header.find("\r\n", at); if (end == std::string::npos) end = header.size();
            std::string line = header.substr(at, end - at); size_t colon = line.find(':');
            Need(colon != std::string::npos, "HTTP_INVALID_HEADER");
            headers[Lower(Trim(line.substr(0, colon)))] = Trim(line.substr(colon + 1)); at = end + 2;
        }
        if (status != 206) {
            std::string failure = HttpFailure(status, headers, received, headerEnd + 4);
            if (status == 416) failure += "_START_" + std::to_string(start) + "_END_"
                + std::to_string(requestedEnd) + "_TOTAL_" + std::to_string(size);
            throw std::runtime_error(failure);
        }
        unsigned long long begin = 0, end = 0, total = 0;
        Need(sscanf(headers["content-range"].c_str(), "bytes %llu-%llu/%llu", &begin, &end, &total) == 3,
            "HTTP_INVALID_CONTENT_RANGE");
        Need(begin == static_cast<uint64_t>(start) && end >= begin && end <= static_cast<uint64_t>(requestedEnd) && total > end
            && total <= static_cast<uint64_t>(INT64_MAX), "HTTP_INVALID_CONTENT_RANGE");
        Need(size == 0 || size == static_cast<int64_t>(total), "SOURCE_SIZE_CHANGED"); size = total;
        Need(headers["transfer-encoding"].empty() || Lower(headers["transfer-encoding"]) == "identity", "HTTP_CHUNKED_RANGE_UNSUPPORTED");
        Need(headers["content-encoding"].empty() || Lower(headers["content-encoding"]) == "identity", "HTTP_ENCODED_RANGE_UNSUPPORTED");
        const size_t expected = end - begin + 1;
        if (!headers["content-length"].empty()) Need(headers["content-length"] == std::to_string(expected), "HTTP_RANGE_LENGTH_MISMATCH");
        cache.assign(received.begin() + headerEnd + 4, received.end());
        Need(cache.size() <= expected, "HTTP_RANGE_LENGTH_MISMATCH");
        while (cache.size() < expected) {
            uint8_t buffer[16384]; ssize_t n = Receive(socketFd.value, buffer, std::min(sizeof(buffer), expected - cache.size()));
            cache.insert(cache.end(), buffer, buffer + n);
        }
        cacheStart = start;
    }
};

struct MediaState {
    AVFormatContext *format = nullptr;
    AVIOContext *io = nullptr;
    AVCodecContext *codec = nullptr;
    SwrContext *resampler = nullptr;
    AVFrame *frame = nullptr;
    AVPacket *packet = nullptr;
    ~MediaState() {
        av_packet_free(&packet); av_frame_free(&frame); swr_free(&resampler); avcodec_free_context(&codec);
        avformat_close_input(&format);
        if (io) { av_freep(&io->buffer); avio_context_free(&io); }
    }
};
int Interrupt(void *opaque) {
    auto *job = static_cast<Job *>(opaque);
    return job->cancelled.load() || Clock::now() >= job->deadline;
}
int RejectNestedIo(AVFormatContext *, AVIOContext **, const char *, int, AVDictionary **) { return AVERROR(EPERM); }
void Put16(uint8_t *at, uint16_t value) { at[0] = value; at[1] = value >> 8; }
void Put32(uint8_t *at, uint32_t value) { for (int i = 0; i < 4; i++) at[i] = value >> (8 * i); }
void WriteAll(int fd, const void *data, size_t length) {
    const auto *bytes = static_cast<const uint8_t *>(data);
    while (length) {
        ssize_t n = write(fd, bytes, length); if (n < 0 && errno == EINTR) continue;
        Need(n > 0, "OUTPUT_WRITE_FAILED"); bytes += n; length -= n;
    }
}
void Extract(Job &job) {
    job.deadline = Clock::now() + std::chrono::seconds(25);
    Need(avformat_version() == AV_VERSION_INT(62, 3, 100) && avcodec_version() == AV_VERSION_INT(62, 11, 100)
        && avutil_version() == AV_VERSION_INT(60, 8, 100) && swresample_version() == AV_VERSION_INT(6, 1, 100), "FFMPEG_ABI_VERSION_MISMATCH");
    job.Check();
    Source source(job);
    MediaState state;
    state.format = avformat_alloc_context(); Need(state.format != nullptr, "FORMAT_ALLOCATION_FAILED");
    uint8_t *buffer = static_cast<uint8_t *>(av_malloc(32768)); Need(buffer != nullptr, "IO_ALLOCATION_FAILED");
    state.io = avio_alloc_context(buffer, 32768, 0, &source, Source::ReadCallback, nullptr, Source::SeekCallback);
    if (!state.io) { av_free(buffer); throw std::runtime_error("IO_ALLOCATION_FAILED"); }
    state.format->pb = state.io; state.format->flags |= AVFMT_FLAG_CUSTOM_IO;
    state.format->interrupt_callback = {Interrupt, &job}; state.format->io_open = RejectNestedIo;
    state.format->probesize = 512 * 1024; state.format->max_analyze_duration = 2 * AV_TIME_BASE;
    AVDictionary *options = nullptr;
    av_dict_set(&options, "format_whitelist", "matroska,webm,mov,mp4,m4a,3gp,3g2,mj2,mp3,wav,aac,flac,ogg,mpegts", 0);
    int opened = avformat_open_input(&state.format, nullptr, nullptr, &options); av_dict_free(&options);
    if (!source.failure.empty()) throw std::runtime_error(source.failure);
    AvNeed(opened, "MEDIA_FORMAT_UNSUPPORTED");
    job.sourceOpenBytes = job.sourceBytes;
    int streamInfo = avformat_find_stream_info(state.format, nullptr);
    if (!source.failure.empty()) throw std::runtime_error(source.failure);
    AvNeed(streamInfo, "MEDIA_STREAM_INFO_FAILED"); job.Check();
    job.sourceProbeBytes = job.sourceBytes - job.sourceOpenBytes;
    const AVCodec *decoder = nullptr;
    int index = job.audioStreamIndex >= 0 ? job.audioStreamIndex
        : av_find_best_stream(state.format, AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0);
    Need(index >= 0 && index < static_cast<int>(state.format->nb_streams), "NO_AUDIO_TRACK");
    AVStream *stream = state.format->streams[index];
    Need(stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO, "SELECTED_TRACK_IS_NOT_AUDIO");
    if (!decoder) decoder = avcodec_find_decoder(stream->codecpar->codec_id);
    Need(decoder != nullptr, "AUDIO_CODEC_UNSUPPORTED");
    const int64_t originUs = state.format->start_time != AV_NOPTS_VALUE ? state.format->start_time : 0;
    // MKV Cues commonly index video only. Seeking the audio stream can fall back
    // to a linear scan from the first cluster. Keep the container's indexed
    // default stream enabled until the seek has completed, then discard it.
    AvNeed(av_seek_frame(state.format, -1, originUs + job.startMs * 1000, AVSEEK_FLAG_BACKWARD), "MEDIA_SEEK_FAILED");
    job.sourceSeekBytes = job.sourceBytes - job.sourceOpenBytes - job.sourceProbeBytes;
    for (unsigned i = 0; i < state.format->nb_streams; i++) if (i != static_cast<unsigned>(index)) state.format->streams[i]->discard = AVDISCARD_ALL;
    state.codec = avcodec_alloc_context3(decoder); Need(state.codec != nullptr, "CODEC_ALLOCATION_FAILED");
    AvNeed(avcodec_parameters_to_context(state.codec, stream->codecpar), "AUDIO_PARAMETERS_INVALID");
    state.codec->pkt_timebase = stream->time_base; state.codec->thread_count = 1;
    AvNeed(avcodec_open2(state.codec, decoder, nullptr), "AUDIO_DECODER_OPEN_FAILED");
    avcodec_flush_buffers(state.codec);
    state.frame = av_frame_alloc(); state.packet = av_packet_alloc(); Need(state.frame && state.packet, "DECODE_ALLOCATION_FAILED");
    Fd output(open(job.path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600));
    Need(output.value >= 0, "OUTPUT_CREATE_FAILED");
    job.ownsOutput.store(true);
    bool committed = false;
    try {
        uint8_t header[44] {}; WriteAll(output.value, header, sizeof(header));
        const int64_t windowStart = job.startMs * kRate / 1000;
        const int64_t windowEnd = (job.startMs + job.durationMs) * kRate / 1000;
        int64_t samplesWritten = 0, firstSample = -1, writtenUntil = -1;
        int inputRate = 0, inputFormat = -1, inputChannels = 0;
        bool done = false;
        auto drain = [&]() {
            for (;;) {
                job.Check();
                int result = avcodec_receive_frame(state.codec, state.frame);
                if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) return;
                AvNeed(result, "AUDIO_DECODE_FAILED");
                AVFrame *frame = state.frame;
                Need(frame->sample_rate > 0 && frame->nb_samples > 0 && frame->nb_samples <= frame->sample_rate * 2
                    && frame->ch_layout.nb_channels > 0 && frame->ch_layout.nb_channels <= 64, "AUDIO_FRAME_INVALID");
                Need(frame->best_effort_timestamp != AV_NOPTS_VALUE, "AUDIO_TIMESTAMPS_UNAVAILABLE");
                if (!state.resampler) {
                    AVChannelLayout mono = AV_CHANNEL_LAYOUT_MONO, input {};
                    if (frame->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC) av_channel_layout_default(&input, frame->ch_layout.nb_channels);
                    else AvNeed(av_channel_layout_copy(&input, &frame->ch_layout), "AUDIO_LAYOUT_INVALID");
                    int result = swr_alloc_set_opts2(&state.resampler, &mono, AV_SAMPLE_FMT_S16, kRate,
                        &input, static_cast<AVSampleFormat>(frame->format), frame->sample_rate, 0, nullptr);
                    av_channel_layout_uninit(&input); AvNeed(result, "RESAMPLER_ALLOCATION_FAILED");
                    AvNeed(swr_init(state.resampler), "RESAMPLER_INIT_FAILED");
                    inputRate = frame->sample_rate; inputFormat = frame->format; inputChannels = frame->ch_layout.nb_channels;
                }
                Need(inputRate == frame->sample_rate && inputFormat == frame->format && inputChannels == frame->ch_layout.nb_channels,
                    "AUDIO_FORMAT_CHANGED");
                const int64_t delay = swr_get_delay(state.resampler, inputRate);
                const int capacity = static_cast<int>(av_rescale_rnd(delay + frame->nb_samples, kRate, inputRate, AV_ROUND_UP));
                Need(capacity > 0 && capacity <= kRate * 3, "AUDIO_FRAME_TOO_LARGE");
                std::vector<int16_t> pcm(capacity); uint8_t *outputData = reinterpret_cast<uint8_t *>(pcm.data());
                int converted = swr_convert(state.resampler, &outputData, capacity,
                    const_cast<const uint8_t **>(frame->extended_data), frame->nb_samples);
                AvNeed(converted, "AUDIO_RESAMPLE_FAILED");
                const int64_t frameSample = av_rescale_q(frame->best_effort_timestamp, stream->time_base, {1, kRate})
                    - av_rescale_q(originUs, AV_TIME_BASE_Q, {1, kRate}) - av_rescale_q(delay, {1, inputRate}, {1, kRate});
                int64_t begin = std::max<int64_t>(0, windowStart - frameSample);
                if (writtenUntil >= 0) {
                    Need(frameSample <= writtenUntil + kRate / 10, "AUDIO_TIMELINE_DISCONTINUITY");
                    begin = std::max(begin, writtenUntil - frameSample);
                }
                const int64_t end = std::min<int64_t>(converted, windowEnd - frameSample);
                if (end > begin) {
                    if (firstSample < 0) firstSample = frameSample + begin;
                    WriteAll(output.value, pcm.data() + begin, static_cast<size_t>(end - begin) * sizeof(int16_t));
                    samplesWritten += end - begin; writtenUntil = frameSample + end;
                }
                done = frameSample + converted >= windowEnd;
                av_frame_unref(frame); if (done) return;
            }
        };
        while (!done) {
            job.Check(); int result = av_read_frame(state.format, state.packet);
            if (!source.failure.empty()) throw std::runtime_error(source.failure);
            if (result == AVERROR_EOF) { AvNeed(avcodec_send_packet(state.codec, nullptr), "AUDIO_DRAIN_FAILED"); drain(); break; }
            AvNeed(result, "MEDIA_READ_FAILED");
            if (state.packet->stream_index == index) {
                result = avcodec_send_packet(state.codec, state.packet);
                if (result == AVERROR(EAGAIN)) { drain(); result = avcodec_send_packet(state.codec, state.packet); }
                AvNeed(result, "AUDIO_PACKET_FAILED"); drain();
            }
            av_packet_unref(state.packet);
        }
        job.Check(); Need(samplesWritten > 0 && firstSample >= 0, "NO_AUDIO_IN_REQUESTED_WINDOW");
        const uint32_t bytes = static_cast<uint32_t>(samplesWritten * 2);
        memcpy(header, "RIFF", 4); Put32(header + 4, bytes + 36); memcpy(header + 8, "WAVEfmt ", 8);
        Put32(header + 16, 16); Put16(header + 20, 1); Put16(header + 22, 1); Put32(header + 24, kRate);
        Put32(header + 28, kRate * 2); Put16(header + 32, 2); Put16(header + 34, 16); memcpy(header + 36, "data", 4); Put32(header + 40, bytes);
        Need(lseek(output.value, 0, SEEK_SET) == 0, "OUTPUT_SEEK_FAILED"); WriteAll(output.value, header, sizeof(header));
        job.actualStartMs = firstSample * 1000 / kRate;
        job.actualEndMs = (firstSample + samplesWritten) * 1000 / kRate;
        committed = true;
    } catch (...) { if (!committed) unlink(job.path.c_str()); throw; }
}

bool TextSubtitle(AVCodecID id) {
    const AVCodecDescriptor *descriptor = avcodec_descriptor_get(id);
    return descriptor && (descriptor->props & AV_CODEC_PROP_TEXT_SUB);
}
std::string StreamLanguage(AVStream *stream) {
    AVDictionaryEntry *entry = av_dict_get(stream->metadata, "language", nullptr, 0);
    return entry && entry->value ? std::string(entry->value).substr(0, 128) : "";
}
void ExtractTextSubtitles(Job &job) {
    job.deadline = Clock::now() + std::chrono::seconds(25); job.Check();
    Need(avformat_version() == AV_VERSION_INT(62, 3, 100) && avcodec_version() == AV_VERSION_INT(62, 11, 100)
        && avutil_version() == AV_VERSION_INT(60, 8, 100) && swresample_version() == AV_VERSION_INT(6, 1, 100), "FFMPEG_ABI_VERSION_MISMATCH");
    Source source(job); MediaState state;
    state.format = avformat_alloc_context(); Need(state.format != nullptr, "FORMAT_ALLOCATION_FAILED");
    uint8_t *buffer = static_cast<uint8_t *>(av_malloc(32768)); Need(buffer != nullptr, "IO_ALLOCATION_FAILED");
    state.io = avio_alloc_context(buffer, 32768, 0, &source, Source::ReadCallback, nullptr, Source::SeekCallback);
    if (!state.io) { av_free(buffer); throw std::runtime_error("IO_ALLOCATION_FAILED"); }
    state.format->pb = state.io; state.format->flags |= AVFMT_FLAG_CUSTOM_IO;
    state.format->interrupt_callback = {Interrupt, &job}; state.format->io_open = RejectNestedIo;
    state.format->probesize = 512 * 1024; state.format->max_analyze_duration = 2 * AV_TIME_BASE;
    AVDictionary *options = nullptr;
    av_dict_set(&options, "format_whitelist", "matroska,webm,mov,mp4,m4a,3gp,3g2,mj2,mp3,wav,aac,flac,ogg,mpegts", 0);
    int result = avformat_open_input(&state.format, nullptr, nullptr, &options); av_dict_free(&options);
    if (!source.failure.empty()) throw std::runtime_error(source.failure);
    AvNeed(result, "MEDIA_FORMAT_UNSUPPORTED");
    job.sourceOpenBytes = job.sourceBytes;
    result = avformat_find_stream_info(state.format, nullptr);
    if (!source.failure.empty()) throw std::runtime_error(source.failure);
    AvNeed(result, "MEDIA_STREAM_INFO_FAILED"); job.Check();
    job.sourceProbeBytes = job.sourceBytes - job.sourceOpenBytes;
    int index = job.subtitleStreamIndex, ordinal = 0;
    bool foundSubtitle = false, foundMatching = false;
    if (index < 0) {
        for (unsigned i = 0; i < state.format->nb_streams; i++) {
            AVStream *candidate = state.format->streams[i];
            if (candidate->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) continue;
            foundSubtitle = true;
            if (job.subtitleOrdinal >= 0) {
                if (ordinal++ == job.subtitleOrdinal) { index = i; break; }
                continue;
            }
            const bool matches = job.preferredLanguage.empty()
                || Lower(StreamLanguage(candidate)) == Lower(job.preferredLanguage);
            if (!matches) continue;
            foundMatching = true;
            if (TextSubtitle(candidate->codecpar->codec_id)) { index = i; break; }
        }
    }
    if (index < 0) {
        if (!foundSubtitle) throw std::runtime_error("NO_SUBTITLE_TRACK");
        if (job.subtitleOrdinal >= 0) throw std::runtime_error("SUBTITLE_ORDINAL_NOT_FOUND");
        if (!job.preferredLanguage.empty() && !foundMatching) throw std::runtime_error("PREFERRED_SUBTITLE_LANGUAGE_NOT_FOUND");
        throw std::runtime_error("SUBTITLE_BITMAP_OR_CODEC_UNSUPPORTED");
    }
    Need(index < static_cast<int>(state.format->nb_streams), "SUBTITLE_STREAM_NOT_FOUND");
    AVStream *stream = state.format->streams[index];
    Need(stream->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE, "SELECTED_TRACK_IS_NOT_SUBTITLE");
    Need(TextSubtitle(stream->codecpar->codec_id), "SUBTITLE_BITMAP_OR_CODEC_UNSUPPORTED");
    const AVCodec *decoder = avcodec_find_decoder(stream->codecpar->codec_id); Need(decoder != nullptr, "SUBTITLE_CODEC_UNSUPPORTED");
    state.codec = avcodec_alloc_context3(decoder); Need(state.codec != nullptr, "CODEC_ALLOCATION_FAILED");
    AvNeed(avcodec_parameters_to_context(state.codec, stream->codecpar), "SUBTITLE_PARAMETERS_INVALID");
    state.codec->pkt_timebase = stream->time_base; state.codec->thread_count = 1;
    AvNeed(avcodec_open2(state.codec, decoder, nullptr), "SUBTITLE_DECODER_OPEN_FAILED");
    const int64_t originUs = state.format->start_time != AV_NOPTS_VALUE ? state.format->start_time : 0;
    const int64_t prerollMs = std::max<int64_t>(0, job.startMs - job.subtitlePreRollMs);
    // -1 chooses the container's default indexed stream and uses AV_TIME_BASE;
    // text tracks often have no dedicated seek index in MKV/MP4.
    AvNeed(av_seek_frame(state.format, -1, originUs + prerollMs * 1000, AVSEEK_FLAG_BACKWARD), "MEDIA_SEEK_FAILED");
    job.sourceSeekBytes = job.sourceBytes - job.sourceOpenBytes - job.sourceProbeBytes;
    // Keep one timed A/V stream as a window-end sentinel: with sparse subtitles,
    // discarding every other stream can make av_read_frame scan far past the window.
    // Matroska reads each Block before checking discard, so this is not a claim
    // that video payload is skipped on the network.
    int clockIndex = -1;
    for (unsigned i = 0; i < state.format->nb_streams; i++) {
        AVStream *candidate = state.format->streams[i];
        if (candidate->codecpar->codec_type == AVMEDIA_TYPE_VIDEO
            && !(candidate->disposition & AV_DISPOSITION_ATTACHED_PIC)) { clockIndex = i; break; }
    }
    if (clockIndex < 0) {
        for (unsigned i = 0; i < state.format->nb_streams; i++) {
            if (state.format->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) { clockIndex = i; break; }
        }
    }
    for (unsigned i = 0; i < state.format->nb_streams; i++) {
        if (static_cast<int>(i) != index && static_cast<int>(i) != clockIndex) {
            state.format->streams[i]->discard = AVDISCARD_ALL;
        }
    }
    avcodec_flush_buffers(state.codec); state.packet = av_packet_alloc(); Need(state.packet != nullptr, "DECODE_ALLOCATION_FAILED");
    job.selectedStreamIndex = index; job.language = StreamLanguage(stream);
    const int64_t windowEnd = job.startMs + job.durationMs;
    size_t textBytes = 0; bool unknownTiming = false;
    for (;;) {
        job.Check(); result = av_read_frame(state.format, state.packet);
        if (!source.failure.empty()) throw std::runtime_error(source.failure);
        if (result == AVERROR_EOF) break;
        AvNeed(result, "MEDIA_READ_FAILED");
        AVPacket *packet = state.packet; AVStream *packetStream = state.format->streams[packet->stream_index];
        int64_t packetMs = packet->pts == AV_NOPTS_VALUE ? INT64_MIN
            : av_rescale_q(packet->pts, packetStream->time_base, {1, 1000}) - originUs / 1000;
        if (packetMs != INT64_MIN && packetMs > windowEnd + 2000) { av_packet_unref(packet); break; }
        if (packet->stream_index == index) {
            AVSubtitle subtitle {}; subtitle.pts = AV_NOPTS_VALUE; int got = 0;
            result = avcodec_decode_subtitle2(state.codec, &subtitle, &got, packet);
            if (result < 0) { avsubtitle_free(&subtitle); throw std::runtime_error("SUBTITLE_DECODE_FAILED"); }
            if (got) {
                try {
                    Need(subtitle.num_rects <= 64, "TOO_MANY_SUBTITLE_RECTS");
                    const int64_t baseMs = packetMs != INT64_MIN ? packetMs
                        : subtitle.pts != AV_NOPTS_VALUE ? subtitle.pts / 1000 - originUs / 1000 : INT64_MIN;
                    const int64_t durationMs = packet->duration > 0 ? av_rescale_q(packet->duration, stream->time_base, {1, 1000}) : 0;
                    int64_t start = 0, end = 0;
                    if (baseMs == INT64_MIN || !AiSubtitleInterval(baseMs, subtitle.start_display_time,
                        subtitle.end_display_time, durationMs, &start, &end)) { unknownTiming = true; }
                    else if (end > job.startMs && start < windowEnd) {
                        std::string text;
                        for (unsigned i = 0; i < subtitle.num_rects; i++) {
                            AVSubtitleRect *rect = subtitle.rects[i]; Need(rect != nullptr && rect->type != SUBTITLE_BITMAP, "SUBTITLE_BITMAP_OR_CODEC_UNSUPPORTED");
                            const char *input = rect->text ? rect->text : rect->ass;
                            if (!input) continue;
                            const size_t length = strnlen(input, 32769); Need(length <= 32768, "SUBTITLE_TEXT_TOO_LARGE");
                            char plain[16385]; int count = AiSubtitlePlain(input, length, plain, sizeof(plain), !rect->text && rect->ass);
                            Need(count >= 0, "SUBTITLE_TEXT_MALFORMED");
                            if (count > 0) { if (!text.empty()) text += '\n'; text.append(plain, count); }
                        }
                        if (!text.empty()) {
                            textBytes += text.size(); Need(textBytes <= 128 * 1024 && job.cues.size() < 1000, "SUBTITLE_WINDOW_TOO_LARGE");
                            job.cues.push_back({std::max<int64_t>(0, start), end, std::move(text)});
                        }
                    }
                } catch (...) { avsubtitle_free(&subtitle); throw; }
            }
            avsubtitle_free(&subtitle);
        }
        av_packet_unref(packet);
    }
    job.Check();
    Need(!job.cues.empty() || !unknownTiming, "SUBTITLE_TIMING_UNAVAILABLE");
    std::sort(job.cues.begin(), job.cues.end(), [](const SubtitleCue &a, const SubtitleCue &b) {
        return a.startMs != b.startMs ? a.startMs < b.startMs : a.endMs < b.endMs;
    });
    job.cues.erase(std::unique(job.cues.begin(), job.cues.end(), [](const SubtitleCue &a, const SubtitleCue &b) {
        return a.startMs == b.startMs && a.endMs == b.endMs && a.text == b.text;
    }), job.cues.end());
}

std::string StringValue(napi_env env, napi_value value, size_t max) {
    napi_valuetype type; Need(napi_typeof(env, value, &type) == napi_ok && type == napi_string, "INVALID_STRING_OPTION");
    size_t length = 0; napi_get_value_string_utf8(env, value, nullptr, 0, &length); Need(length <= max, "STRING_OPTION_TOO_LONG");
    std::vector<char> buffer(length + 1); napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length);
    return std::string(buffer.data(), length);
}
napi_value Property(napi_env env, napi_value object, const char *name) {
    napi_value value; Need(napi_get_named_property(env, object, name, &value) == napi_ok, "INVALID_OPTIONS"); return value;
}
int64_t Integer(napi_env env, napi_value object, const char *name, int64_t fallback, bool optional = false) {
    bool has = false; napi_has_named_property(env, object, name, &has); if (!has && optional) return fallback;
    napi_value property = Property(env, object, name); napi_valuetype type;
    if (optional && napi_typeof(env, property, &type) == napi_ok && (type == napi_undefined || type == napi_null)) return fallback;
    double value = 0; Need(napi_get_value_double(env, property, &value) == napi_ok && std::isfinite(value)
        && std::floor(value) == value && value >= -1 && value <= 9007199254740991.0, "INVALID_NUMBER_OPTION");
    return static_cast<int64_t>(value);
}
void SetString(napi_env env, napi_value object, const char *name, const std::string &text) {
    napi_value value; napi_create_string_utf8(env, text.c_str(), text.size(), &value); napi_set_named_property(env, object, name, value);
}
void SetNumber(napi_env env, napi_value object, const char *name, int64_t number) {
    napi_value value; napi_create_int64(env, number, &value); napi_set_named_property(env, object, name, value);
}
void Execute(napi_env, void *data) {
    auto *job = static_cast<Job *>(data);
    try { if (job->subtitles) ExtractTextSubtitles(*job); else Extract(*job); }
    catch (const std::exception &e) { job->error = e.what(); }
    catch (...) { job->error = "EXTRACTION_FAILED"; }
}
void Complete(napi_env env, napi_status status, void *data) {
    auto *job = static_cast<Job *>(data);
    if (status != napi_ok || job->cancelled.load()) {
        job->error = "EXTRACTION_CANCELLED";
        if (job->ownsOutput.load()) unlink(job->path.c_str());
    }
    if (job->error.empty()) {
        napi_value value; napi_create_object(env, &value); SetNumber(env, value, "sourceBytes", job->sourceBytes);
        SetNumber(env, value, "sourceOpenBytes", job->sourceOpenBytes);
        SetNumber(env, value, "sourceProbeBytes", job->sourceProbeBytes);
        SetNumber(env, value, "sourceSeekBytes", job->sourceSeekBytes);
        SetNumber(env, value, "sourceDecodeBytes", job->sourceBytes - job->sourceOpenBytes - job->sourceProbeBytes - job->sourceSeekBytes);
        if (job->subtitles) {
            SetString(env, value, "language", job->language); SetNumber(env, value, "streamIndex", job->selectedStreamIndex);
            napi_value cues; napi_create_array_with_length(env, job->cues.size(), &cues);
            for (size_t i = 0; i < job->cues.size(); i++) {
                napi_value cue; napi_create_object(env, &cue); SetString(env, cue, "text", job->cues[i].text);
                SetNumber(env, cue, "startMs", job->cues[i].startMs); SetNumber(env, cue, "endMs", job->cues[i].endMs);
                napi_set_element(env, cues, static_cast<uint32_t>(i), cue);
            }
            napi_set_named_property(env, value, "cues", cues);
        } else {
            SetString(env, value, "path", job->path); SetNumber(env, value, "startMs", job->actualStartMs);
            SetNumber(env, value, "endMs", job->actualEndMs); SetNumber(env, value, "sampleRate", kRate); SetNumber(env, value, "channels", 1);
        }
        napi_resolve_deferred(env, job->deferred, value);
    } else {
        napi_value message, error; napi_create_string_utf8(env, job->error.c_str(), NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &error); SetString(env, error, "code", job->error); napi_reject_deferred(env, job->deferred, error);
    }
    napi_delete_async_work(env, job->work);
    std::lock_guard<std::mutex> lock(jobsMutex); jobs.erase(job->id);
}
napi_value QueueExtraction(napi_env env, napi_callback_info info, bool subtitles) {
    napi_value promise; napi_deferred deferred; napi_create_promise(env, &deferred, &promise);
    try {
        size_t count = 1; napi_value args[1]; napi_get_cb_info(env, info, &count, args, nullptr, nullptr); Need(count == 1, "OPTIONS_REQUIRED");
        auto job = std::make_shared<Job>(); job->env = env; job->deferred = deferred; job->subtitles = subtitles;
        job->id = StringValue(env, Property(env, args[0], "jobId"), 128);
        job->url = StringValue(env, Property(env, args[0], "url"), 8192);
        if (!subtitles) job->path = StringValue(env, Property(env, args[0], "outputPath"), 4096);
        Need(!job->id.empty() && !job->url.empty() && (subtitles || (!job->path.empty() && job->path[0] == '/')), "INVALID_PATH_OR_JOB_ID");
        Need(job->path.find('\0') == std::string::npos && job->url.find('\0') == std::string::npos && job->path != job->url, "INVALID_SOURCE_OR_OUTPUT");
        if (job->url.rfind("fd://", 0) == 0) {
            int borrowed = -1;
            Need(ai_parse_fd_source(job->url.c_str(), &borrowed), "INVALID_SOURCE_FD");
            // Retain our own handle while still on the JS/NAPI call stack. A
            // route cancellation may then close mpv's borrowed handle safely.
            job->sourceFd = fcntl(borrowed, F_DUPFD_CLOEXEC, 0);
            struct stat st {};
            Need(job->sourceFd >= 0 && fstat(job->sourceFd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0,
                "LOCAL_SOURCE_UNAVAILABLE");
        }
        job->startMs = Integer(env, args[0], "startMs", 0); job->durationMs = Integer(env, args[0], "durationMs", 12000);
        Need(job->startMs >= 0 && job->startMs <= 7LL * 24 * 60 * 60 * 1000 && job->durationMs >= 100 && job->durationMs <= 30000, "INVALID_AUDIO_WINDOW");
        if (!subtitles) Need(Integer(env, args[0], "sampleRate", kRate) == kRate, "ONLY_MONO_16000_SUPPORTED");
        int64_t stream = Integer(env, args[0], "audioStreamIndex", -1, true); Need(stream >= -1 && stream <= 1024, "INVALID_AUDIO_STREAM_INDEX"); job->audioStreamIndex = stream;
        stream = Integer(env, args[0], "subtitleStreamIndex", -1, true); Need(stream >= -1 && stream <= 1024, "INVALID_SUBTITLE_STREAM_INDEX"); job->subtitleStreamIndex = stream;
        stream = Integer(env, args[0], "subtitleOrdinal", -1, true); Need(stream >= -1 && stream <= 1024, "INVALID_SUBTITLE_ORDINAL"); job->subtitleOrdinal = stream;
        job->subtitlePreRollMs = Integer(env, args[0], "preRollMs", 5000, true);
        Need(job->subtitlePreRollMs >= 0 && job->subtitlePreRollMs <= 30000, "INVALID_SUBTITLE_PREROLL");
        bool hasLanguage = false; napi_has_named_property(env, args[0], "preferredLanguage", &hasLanguage);
        if (hasLanguage) {
            napi_value language = Property(env, args[0], "preferredLanguage"); napi_valuetype type;
            if (napi_typeof(env, language, &type) == napi_ok && type != napi_undefined && type != napi_null) {
                job->preferredLanguage = Trim(StringValue(env, language, 64));
            }
        }
        napi_value headers = Property(env, args[0], "headers"), keys; Need(napi_get_property_names(env, headers, &keys) == napi_ok, "INVALID_HEADERS");
        uint32_t length = 0; napi_get_array_length(env, keys, &length); Need(length <= 64, "TOO_MANY_HEADERS");
        for (uint32_t i = 0; i < length; i++) {
            napi_value key, value; napi_get_element(env, keys, i, &key); napi_get_property(env, headers, key, &value);
            std::string name = StringValue(env, key, 128), text = StringValue(env, value, 8192), lower = Lower(name);
            Need(!name.empty() && name.find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~") == std::string::npos
                && text.find_first_of("\r\n") == std::string::npos && text.find('\0') == std::string::npos, "INVALID_HTTP_HEADER");
            Need(lower != "range" && lower != "host" && lower != "connection" && lower != "accept-encoding" && lower != "content-length"
                && lower != "transfer-encoding", "RESERVED_HTTP_HEADER");
            job->headers += name + ": " + text + "\r\n"; Need(job->headers.size() <= 32768, "HTTP_HEADERS_TOO_LARGE");
        }
        napi_value resource; napi_create_string_utf8(env, "boundedAudioExtraction", NAPI_AUTO_LENGTH, &resource);
        {
            std::lock_guard<std::mutex> lock(jobsMutex); Need(jobs.empty(), "EXTRACTION_BUSY"); jobs[job->id] = job;
        }
        napi_status created = napi_create_async_work(env, nullptr, resource, Execute, Complete, job.get(), &job->work);
        if (created != napi_ok || napi_queue_async_work(env, job->work) != napi_ok) {
            if (job->work) napi_delete_async_work(env, job->work);
            std::lock_guard<std::mutex> lock(jobsMutex); jobs.erase(job->id); throw std::runtime_error("EXTRACTION_SCHEDULING_FAILED");
        }
    } catch (const std::exception &e) {
        napi_value message, error; napi_create_string_utf8(env, e.what(), NAPI_AUTO_LENGTH, &message); napi_create_error(env, nullptr, message, &error);
        SetString(env, error, "code", e.what()); napi_reject_deferred(env, deferred, error);
    }
    return promise;
}
napi_value ExtractAudio(napi_env env, napi_callback_info info) { return QueueExtraction(env, info, false); }
napi_value ExtractSubtitles(napi_env env, napi_callback_info info) { return QueueExtraction(env, info, true); }
napi_value CancelExtraction(napi_env env, napi_callback_info info) {
    try {
        size_t count = 1; napi_value args[1]; napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
        if (count) {
            std::string id = StringValue(env, args[0], 128); std::lock_guard<std::mutex> lock(jobsMutex);
            auto found = jobs.find(id); if (found != jobs.end()) found->second->cancelled.store(true);
        }
    } catch (...) {}
    napi_value value; napi_get_undefined(env, &value); return value;
}
napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor properties[] = {
        {"extractAudio", nullptr, ExtractAudio, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"extractTextSubtitles", nullptr, ExtractSubtitles, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancelExtraction", nullptr, CancelExtraction, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, 3, properties); return exports;
}
napi_module module = {1, 0, nullptr, Init, "ai_audio_extractor", nullptr, {0}};
__attribute__((constructor)) void Register() { napi_module_register(&module); }
} // namespace
