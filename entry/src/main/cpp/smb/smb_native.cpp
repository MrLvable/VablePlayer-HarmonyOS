// NASPlayer SMB read-only bridge. The linked libsmb2 library is LGPL-2.1-or-later;
// its pinned binary, headers, source location and full license are in vendor/libsmb2-6.2.
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
#include <napi/native_api.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>

namespace {
constexpr uint64_t SAFE_INTEGER = 9007199254740991ULL;
constexpr uint32_t MAX_READ = 1024 * 1024;
constexpr uint32_t WIRE_CHUNK = 64 * 1024;
constexpr size_t MAX_ENTRIES = 10000;
enum class Op { List, Stat, Open, Read, Close };
struct Entry { std::string name; uint32_t type = 0; uint64_t size = 0; double modified = 0; };
struct Session {
    smb2_context *context = nullptr;
    smb2fh *file = nullptr;
    std::mutex io;
    std::atomic<bool> closing { false };
    uint64_t size = 0;
    double modified = 0;
    ~Session() { dispose(); }
    // Called on a worker while holding io. Never destroy a context from another thread.
    void dispose() {
        if (context) {
            if (file) smb2_close(context, file);
            file = nullptr;
            smb2_disconnect_share(context);
            smb2_destroy_context(context);
            context = nullptr;
        }
    }
};
struct CancelFlag { std::atomic<bool> cancelled { false }; };
struct Work {
    Op op = Op::Stat;
    napi_async_work async = nullptr;
    napi_deferred deferred = nullptr;
    std::string server, share, username, password, domain, path, error;
    int32_t timeout = 8;
    uint64_t sessionId = 0, offset = 0, requestId = 0;
    uint32_t length = 0;
    std::shared_ptr<Session> session;
    std::shared_ptr<CancelFlag> cancel;
    bool readRegistered = false;
    Entry stat;
    std::vector<Entry> entries;
    std::vector<uint8_t> bytes;
};
std::mutex registryMutex;
std::unordered_map<uint64_t, std::shared_ptr<Session>> sessions;
std::unordered_map<uint64_t, std::shared_ptr<CancelFlag>> pendingReads;
std::atomic<uint64_t> nextSession { 1 };

bool stringValue(napi_env env, napi_value value, std::string &out) {
    napi_valuetype type;
    size_t length = 0;
    if (!value || napi_typeof(env, value, &type) != napi_ok || type != napi_string ||
        napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok || length > 4096) return false;
    std::vector<char> data(length + 1);
    if (napi_get_value_string_utf8(env, value, data.data(), data.size(), nullptr) != napi_ok) return false;
    out.assign(data.data(), length);
    return out.find('\0') == std::string::npos;
}
bool property(napi_env env, napi_value object, const char *name, std::string &out) {
    napi_value value = nullptr;
    return napi_get_named_property(env, object, name, &value) == napi_ok && stringValue(env, value, out);
}
bool integer(napi_env env, napi_value value, uint64_t &out, uint64_t maximum = SAFE_INTEGER) {
    double n = -1;
    if (!value || napi_get_value_double(env, value, &n) != napi_ok || !std::isfinite(n) ||
        n < 0 || n != std::floor(n) || n > static_cast<double>(maximum)) return false;
    out = static_cast<uint64_t>(n);
    return true;
}
bool safePath(const std::string &path) {
    if (path.find('\\') != std::string::npos || path.find('\0') != std::string::npos) return false;
    size_t pos = 0;
    while (pos <= path.size()) {
        const size_t end = path.find('/', pos);
        const auto part = path.substr(pos, end == std::string::npos ? std::string::npos : end - pos);
        if (part == ".." || part == ".") return false;
        if (end == std::string::npos) break;
        pos = end + 1;
    }
    return true;
}
Entry entry(const smb2_stat_64 &raw, const std::string &name = "") {
    return { name, raw.smb2_type, raw.smb2_size,
        static_cast<double>(raw.smb2_mtime) * 1000.0 + raw.smb2_mtime_nsec / 1000000.0 };
}
bool connect(Work *w, const std::shared_ptr<Session> &session) {
    session->context = smb2_init_context();
    if (!session->context) { w->error = "SMB_INIT_FAILED"; return false; }
    smb2_set_timeout(session->context, w->timeout);
    smb2_set_password(session->context, w->password.c_str());
    if (!w->domain.empty()) smb2_set_domain(session->context, w->domain.c_str());
    if (smb2_connect_share(session->context, w->server.c_str(), w->share.c_str(),
        w->username.empty() ? "guest" : w->username.c_str()) < 0) {
        w->error = "SMB_CONNECT_OR_AUTH_FAILED"; return false;
    }
    return true;
}
bool cancelled(const Work *w) {
    return w->session->closing || (w->cancel && w->cancel->cancelled);
}
void executeRead(Work *w) {
    auto s = w->session;
    std::lock_guard<std::mutex> lock(s->io);
    if (cancelled(w) || !s->context || !s->file) { w->error = "SMB_READ_CANCELLED"; return; }
    if (w->offset >= s->size) return;
    const uint32_t wanted = static_cast<uint32_t>(std::min<uint64_t>(w->length, s->size - w->offset));
    w->bytes.resize(wanted);
    uint32_t completed = 0;
    uint32_t limit = smb2_get_max_read_size(s->context);
    limit = limit == 0 ? WIRE_CHUNK : std::min(limit, WIRE_CHUNK);
    while (completed < wanted && !cancelled(w)) {
        const uint32_t count = std::min(limit, wanted - completed);
        const int actual = smb2_pread(s->context, s->file, w->bytes.data() + completed,
            count, w->offset + completed);
        if (actual < 0 || static_cast<uint32_t>(actual) > count) { w->error = "SMB_READ_FAILED"; break; }
        if (actual == 0) break;
        completed += static_cast<uint32_t>(actual);
    }
    w->bytes.resize(completed);
    if (cancelled(w)) { w->bytes.clear(); w->error = "SMB_READ_CANCELLED"; }
}
void execute(napi_env, void *data) {
    auto *w = static_cast<Work *>(data);
    try {
        if (w->op == Op::Read) { executeRead(w); return; }
        if (w->op == Op::Close) {
            if (w->session) { std::lock_guard<std::mutex> lock(w->session->io); w->session->dispose(); }
            return;
        }
        auto s = std::make_shared<Session>();
        if (!connect(w, s)) { s->dispose(); return; }
        if (w->op == Op::List) {
            smb2dir *directory = smb2_opendir(s->context, w->path.c_str());
            if (!directory) w->error = "SMB_LIST_FAILED";
            else {
                smb2dirent *raw;
                while ((raw = smb2_readdir(s->context, directory)) != nullptr) {
                    std::string name = raw->name ? raw->name : "";
                    if (name == "." || name == "..") continue;
                    if (name.empty() || name.size() > 1024 || name.find('/') != std::string::npos ||
                        name.find('\\') != std::string::npos || raw->st.smb2_size > SAFE_INTEGER) {
                        w->error = "SMB_ENTRY_INVALID"; break;
                    }
                    if (w->entries.size() >= MAX_ENTRIES) { w->error = "SMB_DIRECTORY_TOO_LARGE"; break; }
                    w->entries.push_back(entry(raw->st, name));
                }
                smb2_closedir(s->context, directory);
            }
        } else if (w->op == Op::Stat) {
            smb2_stat_64 raw {};
            if (smb2_stat(s->context, w->path.c_str(), &raw) < 0) w->error = "SMB_STAT_FAILED";
            else if (raw.smb2_size > SAFE_INTEGER) w->error = "SMB_SIZE_UNSUPPORTED";
            else w->stat = entry(raw);
        } else {
            s->file = smb2_open(s->context, w->path.c_str(), O_RDONLY);
            smb2_stat_64 raw {};
            if (!s->file || smb2_fstat(s->context, s->file, &raw) < 0) w->error = "SMB_OPEN_FAILED";
            else if (raw.smb2_type != SMB2_TYPE_FILE || raw.smb2_size > SAFE_INTEGER) w->error = "SMB_NOT_PLAYABLE_FILE";
            else {
                s->size = raw.smb2_size; s->modified = entry(raw).modified;
                w->sessionId = nextSession++;
                std::lock_guard<std::mutex> guard(registryMutex);
                if (sessions.size() >= 8) w->error = "SMB_TOO_MANY_SESSIONS";
                else { sessions.emplace(w->sessionId, s); w->session = s; }
            }
        }
        if (w->op != Op::Open || !w->error.empty()) s->dispose();
    } catch (...) {
        w->error = "SMB_NATIVE_OPERATION_FAILED";
        if (w->op == Op::Open && w->session) {
            w->session->closing = true;
            { std::lock_guard<std::mutex> guard(registryMutex); sessions.erase(w->sessionId); }
            std::lock_guard<std::mutex> lock(w->session->io); w->session->dispose();
        }
    }
}
napi_value number(napi_env env, double value) { napi_value out; napi_create_double(env, value, &out); return out; }
napi_value statValue(napi_env env, const Entry &e) {
    napi_value out, directory, name;
    napi_create_object(env, &out);
    napi_get_boolean(env, e.type == SMB2_TYPE_DIRECTORY, &directory);
    napi_create_string_utf8(env, e.name.c_str(), e.name.size(), &name);
    napi_set_named_property(env, out, "name", name);
    napi_set_named_property(env, out, "type", number(env, e.type));
    napi_set_named_property(env, out, "isDirectory", directory);
    napi_set_named_property(env, out, "size", number(env, static_cast<double>(e.size)));
    napi_set_named_property(env, out, "modifiedTime", number(env, e.modified));
    return out;
}
void complete(napi_env env, napi_status status, void *data) {
    auto *w = static_cast<Work *>(data);
    if (w->readRegistered) { std::lock_guard<std::mutex> lock(registryMutex); pendingReads.erase(w->requestId); }
    if (status != napi_ok && w->error.empty()) w->error = "SMB_ASYNC_FAILED";
    if (!w->error.empty()) {
        napi_value message, error;
        napi_create_string_utf8(env, w->error.c_str(), NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, w->deferred, error);
    } else {
        napi_value result;
        napi_get_undefined(env, &result);
        if (w->op == Op::Stat) result = statValue(env, w->stat);
        else if (w->op == Op::List) {
            napi_create_array_with_length(env, w->entries.size(), &result);
            for (size_t i = 0; i < w->entries.size(); i++) napi_set_element(env, result, i, statValue(env, w->entries[i]));
        } else if (w->op == Op::Open) {
            napi_create_object(env, &result);
            napi_set_named_property(env, result, "sessionId", number(env, static_cast<double>(w->sessionId)));
            napi_set_named_property(env, result, "size", number(env, static_cast<double>(w->session->size)));
            napi_set_named_property(env, result, "modifiedTime", number(env, w->session->modified));
        } else if (w->op == Op::Read) {
            void *buffer = nullptr;
            if (napi_create_arraybuffer(env, w->bytes.size(), &buffer, &result) != napi_ok) {
                napi_value message, error;
                napi_create_string_utf8(env, "SMB_BUFFER_ALLOCATION_FAILED", NAPI_AUTO_LENGTH, &message);
                napi_create_error(env, nullptr, message, &error);
                napi_reject_deferred(env, w->deferred, error);
                napi_delete_async_work(env, w->async); delete w; return;
            }
            if (!w->bytes.empty()) std::memcpy(buffer, w->bytes.data(), w->bytes.size());
        }
        napi_resolve_deferred(env, w->deferred, result);
    }
    if (w->async) napi_delete_async_work(env, w->async);
    delete w;
}
napi_value queue(napi_env env, Work *w) {
    napi_value promise, name;
    napi_create_promise(env, &w->deferred, &promise);
    if (!w->error.empty()) { complete(env, napi_ok, w); return promise; }
    napi_create_string_utf8(env, "SMB bounded read", NAPI_AUTO_LENGTH, &name);
    if (napi_create_async_work(env, nullptr, name, execute, complete, w, &w->async) != napi_ok ||
        napi_queue_async_work(env, w->async) != napi_ok) {
        if (w->op == Op::Close && w->session) {
            // Queue exhaustion must not leak an already-detached session or do network IO on the UI thread.
            const auto session = w->session;
            std::thread([session]() { std::lock_guard<std::mutex> lock(session->io); session->dispose(); }).detach();
        }
        w->error = "SMB_ASYNC_QUEUE_FAILED"; complete(env, napi_ok, w);
    }
    return promise;
}
napi_value connectionCall(napi_env env, napi_callback_info info, Op op) {
    size_t argc = 2; napi_value argv[2] = {};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    auto *w = new Work(); w->op = op;
    napi_value timeout = nullptr; uint64_t seconds = 0;
    if (argc != 2 || !property(env, argv[0], "server", w->server) || w->server.empty() ||
        !property(env, argv[0], "share", w->share) || w->share.empty() ||
        !property(env, argv[0], "username", w->username) || !property(env, argv[0], "password", w->password) ||
        !property(env, argv[0], "domain", w->domain) || !stringValue(env, argv[1], w->path) || !safePath(w->path) ||
        napi_get_named_property(env, argv[0], "timeoutSeconds", &timeout) != napi_ok ||
        !integer(env, timeout, seconds, 30) || seconds < 1) w->error = "SMB_INVALID_CONNECTION_OR_PATH";
    else w->timeout = static_cast<int32_t>(seconds);
    return queue(env, w);
}
napi_value listDirectory(napi_env env, napi_callback_info info) { return connectionCall(env, info, Op::List); }
napi_value stat(napi_env env, napi_callback_info info) { return connectionCall(env, info, Op::Stat); }
napi_value openRead(napi_env env, napi_callback_info info) { return connectionCall(env, info, Op::Open); }
napi_value readAt(napi_env env, napi_callback_info info) {
    size_t argc = 4; napi_value argv[4] = {};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    auto *w = new Work(); w->op = Op::Read; uint64_t length = 0;
    if (argc != 4 || !integer(env, argv[0], w->sessionId) || !integer(env, argv[1], w->offset) ||
        !integer(env, argv[2], length, MAX_READ) || length < 1 || !integer(env, argv[3], w->requestId) ||
        w->requestId < 1 || w->offset > SAFE_INTEGER - length) w->error = "SMB_INVALID_READ_RANGE";
    else {
        std::lock_guard<std::mutex> lock(registryMutex);
        const auto found = sessions.find(w->sessionId);
        if (found == sessions.end() || found->second->closing) w->error = "SMB_SESSION_CLOSED";
        else if (pendingReads.size() >= 32 || pendingReads.count(w->requestId)) w->error = "SMB_READ_BUSY";
        else {
            w->session = found->second; w->length = static_cast<uint32_t>(length);
            w->cancel = std::make_shared<CancelFlag>(); pendingReads.emplace(w->requestId, w->cancel); w->readRegistered = true;
        }
    }
    return queue(env, w);
}
napi_value cancelRead(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value arg = nullptr, result; uint64_t id = 0;
    napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr);
    if (argc == 1 && integer(env, arg, id)) {
        std::lock_guard<std::mutex> lock(registryMutex);
        auto found = pendingReads.find(id); if (found != pendingReads.end()) found->second->cancelled = true;
    }
    napi_get_undefined(env, &result); return result;
}
napi_value close(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value arg = nullptr;
    napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr);
    auto *w = new Work(); w->op = Op::Close;
    if (argc != 1 || !integer(env, arg, w->sessionId) || w->sessionId < 1) w->error = "SMB_INVALID_SESSION";
    else {
        std::lock_guard<std::mutex> lock(registryMutex);
        auto found = sessions.find(w->sessionId);
        if (found != sessions.end()) { w->session = found->second; w->session->closing = true; sessions.erase(found); }
    }
    return queue(env, w);
}
napi_value init(napi_env env, napi_value exports) {
    napi_property_descriptor methods[] = {
        {"listDirectory", nullptr, listDirectory, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stat", nullptr, stat, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"openRead", nullptr, openRead, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"readAt", nullptr, readAt, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancelRead", nullptr, cancelRead, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"close", nullptr, close, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(methods) / sizeof(methods[0]), methods); return exports;
}
static napi_module module = { .nm_version = 1, .nm_flags = 0, .nm_filename = nullptr,
    .nm_register_func = init, .nm_modname = "nas_smb", .nm_priv = nullptr, .reserved = {0} };
}
extern "C" __attribute__((visibility("default"))) napi_value napi_register_module_v1(napi_env env, napi_value exports) { return init(env, exports); }
extern "C" __attribute__((constructor)) void RegisterModule() { napi_module_register(&module); }
