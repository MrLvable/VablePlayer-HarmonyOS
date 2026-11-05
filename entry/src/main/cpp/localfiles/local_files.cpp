// Read-only operations rooted at a caller's already-authorized directory/file fd.
// No user URI is converted into an absolute storage path.
#include <cmath>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <mutex>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_set>
#include <vector>
#include <napi/native_api.h>
namespace {
constexpr uint64_t SAFE = 9007199254740991ULL;
enum class Op { List, Stat, Open, Read, Close };
struct Entry { std::string name; bool directory = false; uint64_t size = 0; double modified = 0; };
struct Work {
    Op op = Op::Stat; napi_async_work async = nullptr; napi_deferred deferred = nullptr;
    int root = -1, opened = -1; uint32_t maximum = 0;
    std::string path, error; Entry info; std::vector<Entry> entries; std::vector<uint8_t> bytes;
    ~Work() { if (root >= 0) ::close(root); if (opened >= 0) ::close(opened); }
};
std::mutex ownedMutex;
std::unordered_set<int> owned;
bool integer(napi_env env, napi_value value, uint64_t &result, uint64_t max) {
    double n = -1;
    if (!value || napi_get_value_double(env, value, &n) != napi_ok || !std::isfinite(n) ||
        n < 0 || n != std::floor(n) || n > static_cast<double>(max)) return false;
    result = static_cast<uint64_t>(n); return true;
}
bool string(napi_env env, napi_value value, std::string &out) {
    napi_valuetype type; size_t n = 0;
    if (!value || napi_typeof(env, value, &type) != napi_ok || type != napi_string ||
        napi_get_value_string_utf8(env, value, nullptr, 0, &n) != napi_ok || n > 4096) return false;
    std::vector<char> text(n + 1);
    if (napi_get_value_string_utf8(env, value, text.data(), text.size(), nullptr) != napi_ok) return false;
    out.assign(text.data(), n); return out.find('\0') == std::string::npos;
}
int child(int root, const std::string &path) {
    if ((!path.empty() && path.front() == '/') || path.find('\\') != std::string::npos) return -1;
    int current = fcntl(root, F_DUPFD_CLOEXEC, 0);
    if (current < 0 || path.empty()) return current;
    size_t start = 0, depth = 0;
    while (start < path.size()) {
        const auto end = path.find('/', start);
        const auto part = path.substr(start, end == std::string::npos ? std::string::npos : end - start);
        if (part.empty() || part == "." || part == ".." || ++depth > 32) { ::close(current); return -1; }
        const bool last = end == std::string::npos;
        const int next = openat(current, part.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (last ? 0 : O_DIRECTORY));
        ::close(current); current = next;
        if (current < 0 || last) return current;
        start = end + 1;
        if (start == path.size()) { ::close(current); return -1; }
    }
    return current;
}
bool describe(int fd, Entry &out) {
    struct stat st {};
    if (fstat(fd, &st) != 0 || (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)) || st.st_size < 0 ||
        static_cast<uint64_t>(st.st_size) > SAFE) return false;
    out.directory = S_ISDIR(st.st_mode); out.size = st.st_size;
    out.modified = static_cast<double>(st.st_mtim.tv_sec) * 1000 + st.st_mtim.tv_nsec / 1000000.0; return true;
}
void execute(napi_env, void *data) {
    auto *w = static_cast<Work *>(data);
    try {
        if (w->op == Op::Close) { if (w->root >= 0) { ::close(w->root); w->root = -1; } return; }
        w->opened = child(w->root, w->path);
        if (w->opened < 0 || !describe(w->opened, w->info)) { w->error = "LOCAL_ROOT_OR_PATH_NOT_READABLE"; return; }
        if (w->op == Op::List) {
            if (!w->info.directory) { w->error = "LOCAL_NOT_DIRECTORY"; return; }
            const int listing = fcntl(w->opened, F_DUPFD_CLOEXEC, 0);
            DIR *dir = listing >= 0 ? fdopendir(listing) : nullptr;
            if (!dir) { if (listing >= 0) ::close(listing); w->error = "LOCAL_LIST_FAILED"; return; }
            dirent *raw;
            while (true) {
                errno = 0; raw = readdir(dir);
                if (raw == nullptr) { if (errno != 0) w->error = "LOCAL_LIST_FAILED"; break; }
                std::string name = raw->d_name;
                if (name == "." || name == "..") continue;
                struct stat st {};
                if (fstatat(w->opened, name.c_str(), &st, AT_SYMLINK_NOFOLLOW) != 0) { w->error = "LOCAL_ENTRY_CHANGED"; break; }
                if (!S_ISDIR(st.st_mode) && !S_ISREG(st.st_mode)) continue;
                if (w->entries.size() >= 10000 || name.size() > 1024 || st.st_size < 0 || static_cast<uint64_t>(st.st_size) > SAFE) {
                    w->error = "LOCAL_DIRECTORY_TOO_LARGE"; break;
                }
                w->entries.push_back({name, S_ISDIR(st.st_mode), static_cast<uint64_t>(st.st_size),
                    static_cast<double>(st.st_mtim.tv_sec) * 1000 + st.st_mtim.tv_nsec / 1000000.0});
            }
            closedir(dir);
        } else if (w->op == Op::Read) {
            if (w->info.directory || w->info.size > w->maximum) { w->error = "LOCAL_DOCUMENT_TOO_LARGE_OR_DIRECTORY"; return; }
            w->bytes.resize(static_cast<size_t>(w->maximum) + 1);
            size_t total = 0;
            while (total < w->bytes.size()) {
                const auto count = pread(w->opened, w->bytes.data() + total, w->bytes.size() - total, total);
                if (count < 0) { w->error = "LOCAL_DOCUMENT_READ_FAILED"; break; }
                if (count == 0) break;
                total += static_cast<size_t>(count);
            }
            if (total > w->maximum) w->error = "LOCAL_DOCUMENT_TOO_LARGE";
            w->bytes.resize(total);
        }
    } catch (...) { w->error = "LOCAL_NATIVE_OPERATION_FAILED"; }
}
napi_value number(napi_env env, double n) { napi_value result; napi_create_double(env, n, &result); return result; }
napi_value info(napi_env env, const Entry &e) {
    napi_value result, isDirectory, name; napi_create_object(env, &result);
    napi_get_boolean(env, e.directory, &isDirectory); napi_create_string_utf8(env, e.name.c_str(), e.name.size(), &name);
    napi_set_named_property(env, result, "name", name); napi_set_named_property(env, result, "isDirectory", isDirectory);
    napi_set_named_property(env, result, "size", number(env, static_cast<double>(e.size)));
    napi_set_named_property(env, result, "modifiedTime", number(env, e.modified)); return result;
}
void complete(napi_env env, napi_status status, void *data) {
    auto *w = static_cast<Work *>(data);
    if (status != napi_ok && w->error.empty()) w->error = "LOCAL_ASYNC_FAILED";
    if (!w->error.empty()) {
        napi_value message, error; napi_create_string_utf8(env, w->error.c_str(), NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &error); napi_reject_deferred(env, w->deferred, error);
    } else {
        napi_value result; napi_get_undefined(env, &result);
        if (w->op == Op::List) {
            napi_create_array_with_length(env, w->entries.size(), &result);
            for (size_t i = 0; i < w->entries.size(); i++) napi_set_element(env, result, i, info(env, w->entries[i]));
        } else if (w->op == Op::Stat || w->op == Op::Open) {
            result = info(env, w->info);
            if (w->op == Op::Open) {
                if (w->info.directory) {
                    napi_value message, error; napi_create_string_utf8(env, "LOCAL_NOT_PLAYABLE_FILE", NAPI_AUTO_LENGTH, &message);
                    napi_create_error(env, nullptr, message, &error); napi_reject_deferred(env, w->deferred, error);
                    napi_delete_async_work(env, w->async); delete w; return;
                }
                { std::lock_guard<std::mutex> lock(ownedMutex); owned.insert(w->opened); }
                napi_set_named_property(env, result, "fd", number(env, w->opened)); w->opened = -1;
            }
        } else if (w->op == Op::Read) {
            void *buffer = nullptr;
            if (napi_create_arraybuffer(env, w->bytes.size(), &buffer, &result) != napi_ok) {
                napi_value message, error; napi_create_string_utf8(env, "LOCAL_BUFFER_ALLOCATION_FAILED", NAPI_AUTO_LENGTH, &message);
                napi_create_error(env, nullptr, message, &error); napi_reject_deferred(env, w->deferred, error);
                napi_delete_async_work(env, w->async); delete w; return;
            }
            if (buffer && !w->bytes.empty()) std::memcpy(buffer, w->bytes.data(), w->bytes.size());
        }
        napi_resolve_deferred(env, w->deferred, result);
    }
    if (w->async) napi_delete_async_work(env, w->async); delete w;
}
napi_value queue(napi_env env, Work *w) {
    napi_value promise, name; napi_create_promise(env, &w->deferred, &promise);
    if (!w->error.empty()) { complete(env, napi_ok, w); return promise; }
    napi_create_string_utf8(env, "Local authorized fd", NAPI_AUTO_LENGTH, &name);
    if (napi_create_async_work(env, nullptr, name, execute, complete, w, &w->async) != napi_ok || napi_queue_async_work(env, w->async) != napi_ok) {
        w->error = "LOCAL_ASYNC_QUEUE_FAILED"; complete(env, napi_ok, w);
    }
    return promise;
}
napi_value call(napi_env env, napi_callback_info info, Op op) {
    size_t argc = 3; napi_value argv[3] = {}; napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    auto *w = new Work(); w->op = op; uint64_t fd = 0, maximum = 0;
    if (argc < 2 || !integer(env, argv[0], fd, INT32_MAX) || !string(env, argv[1], w->path)) w->error = "LOCAL_INVALID_ARGUMENTS";
    else {
        w->root = fcntl(static_cast<int>(fd), F_DUPFD_CLOEXEC, 0);
        if (w->root < 0) w->error = "LOCAL_ROOT_CLOSED";
        if (op == Op::Read) {
            if (argc != 3 || !integer(env, argv[2], maximum, 2097152) || maximum < 1) w->error = "LOCAL_INVALID_DOCUMENT_LIMIT";
            else w->maximum = static_cast<uint32_t>(maximum);
        }
    }
    return queue(env, w);
}
napi_value list(napi_env env, napi_callback_info info) { return call(env, info, Op::List); }
napi_value stat(napi_env env, napi_callback_info info) { return call(env, info, Op::Stat); }
napi_value openChild(napi_env env, napi_callback_info info) { return call(env, info, Op::Open); }
napi_value readSmall(napi_env env, napi_callback_info info) { return call(env, info, Op::Read); }
napi_value closeFile(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value arg; napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr);
    auto *w = new Work(); w->op = Op::Close; uint64_t fd = 0;
    if (argc != 1 || !integer(env, arg, fd, INT32_MAX)) w->error = "LOCAL_INVALID_FD";
    else { std::lock_guard<std::mutex> lock(ownedMutex); if (owned.erase(fd)) w->root = static_cast<int>(fd); }
    return queue(env, w);
}
napi_value init(napi_env env, napi_value exports) {
    napi_property_descriptor methods[] = {
        {"list", nullptr, list, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stat", nullptr, stat, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"openChild", nullptr, openChild, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"readSmall", nullptr, readSmall, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeFile", nullptr, closeFile, nullptr, nullptr, nullptr, napi_default, nullptr}};
    napi_define_properties(env, exports, sizeof(methods) / sizeof(methods[0]), methods); return exports;
}
static napi_module module = {.nm_version = 1, .nm_flags = 0, .nm_filename = nullptr, .nm_register_func = init,
    .nm_modname = "nas_local", .nm_priv = nullptr, .reserved = {0}};
}
extern "C" __attribute__((visibility("default"))) napi_value napi_register_module_v1(napi_env env, napi_value exports) { return init(env, exports); }
extern "C" __attribute__((constructor)) void RegisterModule() { napi_module_register(&module); }
