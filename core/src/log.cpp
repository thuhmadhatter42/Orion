#include "log.h"

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <mutex>
#include <os/log.h>
#include <pwd.h>
#include <sys/stat.h>
#include <unistd.h>

namespace bk {

namespace {

const size_t kDefaultRoll = 1048576;
const char *const kFile = "plugin.log";

std::mutex g_mu;
std::string g_dir;                 // explicit override
size_t g_roll = kDefaultRoll;
bool g_warned_unwritable = false;  // once per distinct failure (reset when the folder changes)

os_log_t os() {
    static os_log_t l = os_log_create("com.jshriver.orion", "core");
    return l;
}

// caller holds g_mu
bool resolve_dir(std::string &out) {
    if (!g_dir.empty()) { out = g_dir; return true; }
    const char *env = getenv("BEATKEY_LOG_DIR");
    if (env && env[0]) { out = env; return true; }
    struct passwd *pw = getpwuid(getuid());
    const char *home = (pw && pw->pw_dir && pw->pw_dir[0]) ? pw->pw_dir : getenv("HOME");
    if (!home || !home[0]) return false;
    out = std::string(home) + "/Library/Logs/Beat Key";
    return true;
}

bool mkdirs(const std::string &path) {
    std::string tmp = path;
    for (size_t i = 1; i < tmp.size(); i++) {
        if (tmp[i] != '/') continue;
        tmp[i] = 0;
        if (mkdir(tmp.c_str(), 0755) != 0 && errno != EEXIST) return false;
        tmp[i] = '/';
    }
    return mkdir(tmp.c_str(), 0755) == 0 || errno == EEXIST;
}

}  // namespace

void log_set_dir(const char *dir) {
    std::lock_guard<std::mutex> lock(g_mu);
    g_dir = dir ? dir : "";
    g_warned_unwritable = false;
}

void log_set_roll_bytes(size_t bytes) {
    std::lock_guard<std::mutex> lock(g_mu);
    g_roll = bytes ? bytes : kDefaultRoll;
}

std::string log_path() {
    std::lock_guard<std::mutex> lock(g_mu);
    std::string dir;
    if (!resolve_dir(dir)) return "";
    return dir + "/" + kFile;
}

void logv(const char *area, const char *fmt, va_list ap) {
    char msg[1024];
    vsnprintf(msg, sizeof msg, fmt, ap);

    char ts[48];
    time_t t = time(nullptr);
    struct tm tmv;
    localtime_r(&t, &tmv);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S %z", &tmv);
    char line[1280];
    int n = snprintf(line, sizeof line, "%s pid %d %s %s\n", ts, (int)getpid(), (area && area[0]) ? area : "-", msg);
    if (n < 0) return;
    if ((size_t)n >= sizeof line) { n = (int)sizeof line - 1; line[n - 1] = '\n'; }

    os_log(os(), "%{public}s", line);

    std::lock_guard<std::mutex> lock(g_mu);
    std::string dir;
    if (!resolve_dir(dir)) {
        if (!g_warned_unwritable) {
            g_warned_unwritable = true;
            os_log_error(os(), "log file unavailable: no log folder (no home directory)");
        }
        return;
    }
    const std::string path = dir + "/" + kFile, old = path + ".1";
    struct stat st;
    if (stat(path.c_str(), &st) == 0 && (size_t)st.st_size >= g_roll) {
        if (rename(path.c_str(), old.c_str()) != 0)
            os_log_error(os(), "log roll failed: rename %{public}s: %{public}s", path.c_str(), strerror(errno));
    }
    int fd = open(path.c_str(), O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0 && errno == ENOENT && mkdirs(dir)) fd = open(path.c_str(), O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) {
        if (!g_warned_unwritable) {
            g_warned_unwritable = true;
            os_log_error(os(), "log file unavailable: %{public}s (%{public}s)", strerror(errno), path.c_str());
        }
        return;
    }
    ssize_t w = write(fd, line, (size_t)n);
    if (w != (ssize_t)n)
        os_log_error(os(), "log file short write: %zd of %d (%{public}s)", w, n, strerror(errno));
    close(fd);
}

void logf(const char *area, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    logv(area, fmt, ap);
    va_end(ap);
}

void fail(const char *area, char *err, size_t err_cap, const char *fmt, ...) {
    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    if (err && err_cap) snprintf(err, err_cap, "%s", msg);
    logf(area, "REFUSED: %s", msg);
}

}  // namespace bk
