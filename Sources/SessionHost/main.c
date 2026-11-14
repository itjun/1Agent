// 私有 Unix socket 托管一个 PTY。窗口断开只分离；K 才结束整组进程。
// 帧为类型字节 + 大端 UInt32 长度 + 数据。无需端口、shell 包装器或远程守护程序。
#define _DARWIN_C_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <util.h>
#include <ghostty/vt.h>

#define LIMIT (32u * 1024u * 1024u)
typedef struct { uint8_t *bytes; size_t count, capacity; } Buffer;
static int master = -1, client = -1;
static pid_t child = 0;
static Buffer output = {0}, input = {0}, keyboard = {0};
static size_t sent = 0, keyboard_sent = 0;
static bool is_attached = false, is_exited = false, is_exit_sent = false;
static int exit_code = -1;
static GhosttyTerminal terminal = NULL;
static char command[2048] = "", pending_title[2048] = "";
static bool is_running = false, is_at_input = false;
static GhosttyColorScheme color_scheme = GHOSTTY_COLOR_SCHEME_DARK;

static bool append(Buffer *b, const void *bytes, size_t count) {
    if (count > LIMIT || b->count > LIMIT - count) return false;
    if (b->count + count > b->capacity) {
        size_t capacity = b->count + count + 4096;
        void *next = realloc(b->bytes, capacity);
        if (!next) return false;
        b->bytes = next; b->capacity = capacity;
    }
    if (count) memcpy(b->bytes + b->count, bytes, count);
    b->count += count;
    return true;
}
static bool frame(char type, const void *bytes, size_t count) {
    uint32_t size = htonl((uint32_t)count);
    return append(&output, &type, 1) && append(&output, &size, 4) && append(&output, bytes, count);
}
static double monotonic_time(void) {
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}
static void compact(Buffer *buffer, size_t *offset) {
    if (*offset == 0) return;
    memmove(buffer->bytes, buffer->bytes + *offset, buffer->count - *offset);
    buffer->count -= *offset; *offset = 0;
}
static void disconnect_client(void) {
    if (client >= 0) close(client);
    client = -1; is_attached = false; output.count = input.count = sent = 0;
    is_exit_sent = false;
}
static void enqueue_keyboard(const uint8_t *bytes, size_t count) {
    if (!append(&keyboard, bytes, count)) disconnect_client();
}
static void reply_to_pty(GhosttyTerminal t, void *userdata, const uint8_t *bytes, size_t count) {
    (void)t; (void)userdata;
    // 有窗口时由界面引擎应答，避免同一个终端查询应答两次。
    if (!is_attached) enqueue_keyboard(bytes, count);
}
static bool query_color_scheme(GhosttyTerminal t, void *userdata, GhosttyColorScheme *scheme) {
    (void)t; (void)userdata; *scheme = color_scheme; return true;
}
static void set_colors(const uint8_t *bytes, size_t count) {
    if (count != 58) return; // 明暗 + 前景/背景/光标/16 个 ANSI 色，每色 RGB 三字节。
    color_scheme = bytes[0] ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT;
    GhosttyColorRgb palette[256], color;
    const GhosttyTerminalOption options[] = {GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND,
        GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR};
    for (size_t i = 0; i < 3; i++) {
        memcpy(&color, bytes + 1 + i * 3, 3); ghostty_terminal_set(terminal, options[i], &color);
    }
    ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, palette);
    memcpy(palette, bytes + 10, 48);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, palette);
}
static bool buffer_write(void *userdata, const uint8_t *bytes, size_t count) {
    return append(userdata, bytes, count);
}
static bool format_screen(GhosttyTerminal t, Buffer *buffer, bool modes) {
    GhosttyFormatterTerminalOptions options = GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
    options.emit = GHOSTTY_FORMATTER_FORMAT_VT;
    options.extra = (GhosttyFormatterTerminalExtra)GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalExtra);
    options.extra.modes = modes;
    options.extra.scrolling_region = true;
    options.extra.tabstops = true;
    options.extra.pwd = false; // 下方通过 getter 导出，避免 formatter 把 C 字符串结尾 NUL 也写入 OSC 7。
    options.extra.keyboard = true;
    options.extra.screen = (GhosttyFormatterScreenExtra)GHOSTTY_INIT_SIZED(GhosttyFormatterScreenExtra);
    options.extra.screen.cursor = options.extra.screen.style = true;
    options.extra.screen.hyperlink = options.extra.screen.protection = true;
    options.extra.screen.kitty_keyboard = options.extra.screen.charsets = true;
    size_t original = buffer->count;
    GhosttySelection visible = GHOSTTY_INIT_SIZED(GhosttySelection);
    for (int attempt = 0; attempt < 2; attempt++) {
        GhosttyFormatter formatter = NULL;
        if (ghostty_formatter_terminal_new(NULL, &formatter, t, options) != GHOSTTY_SUCCESS) return false;
        GhosttyWriter writer = {.write = buffer_write, .userdata = buffer};
        bool ok = ghostty_formatter_format(formatter, writer) == GHOSTTY_SUCCESS;
        ghostty_formatter_free(formatter);
        if (ok) return true;
        // 极长彩色历史超出传输上限时仍恢复完整活动屏幕，不让会话无法接回。
        buffer->count = original;
        uint16_t rows = 0, columns = 0;
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ROWS, &rows);
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLS, &columns);
        GhosttyPoint start = {.tag = GHOSTTY_POINT_TAG_ACTIVE, .value.coordinate = {0, 0}};
        GhosttyPoint end = {.tag = GHOSTTY_POINT_TAG_ACTIVE, .value.coordinate = {(uint16_t)(columns - 1), (uint32_t)(rows - 1)}};
        if (ghostty_terminal_grid_ref(t, start, &visible.start) != GHOSTTY_SUCCESS ||
            ghostty_terminal_grid_ref(t, end, &visible.end) != GHOSTTY_SUCCESS) return false;
        options.selection = &visible;
    }
    return false;
}
static GhosttyTerminal clone_terminal(const uint8_t *snapshot, size_t count) {
    GhosttySnapshotDecoder decoder = NULL;
    GhosttyTerminal copy = NULL;
    if (ghostty_snapshot_decoder_new_buf(NULL, &decoder, snapshot, count) != GHOSTTY_SUCCESS) return NULL;
    if (ghostty_snapshot_decoder_decode(decoder, &copy) != GHOSTTY_SUCCESS) copy = NULL;
    ghostty_snapshot_decoder_free(decoder);
    // 快照中的未完成转义序列稍后单独追加；导出画面时先回到解析器初始状态。
    if (copy) ghostty_terminal_vt_write(copy, (const uint8_t *)"\x18", 1);
    return copy;
}
static bool format_color_overrides(Buffer *result) {
    GhosttyColorRgb current[256], defaults[256];
    ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, current);
    ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, defaults);
    char sequence[64];
    for (size_t i = 0; i < 256; i++) {
        if (!memcmp(&current[i], &defaults[i], sizeof(GhosttyColorRgb))) continue;
        int count = snprintf(sequence, sizeof(sequence), "\x1b]4;%zu;rgb:%02x/%02x/%02x\x1b\\", i, current[i].r, current[i].g, current[i].b);
        if (!append(result, sequence, (size_t)count)) return false;
    }
    for (int i = 0; i < 3; i++) {
        GhosttyColorRgb color, fallback;
        if (ghostty_terminal_get(terminal, (GhosttyTerminalData)(GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND + i), &color) != GHOSTTY_SUCCESS) continue;
        if (ghostty_terminal_get(terminal, (GhosttyTerminalData)(GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND_DEFAULT + i), &fallback) == GHOSTTY_SUCCESS && !memcmp(&color, &fallback, sizeof(color))) continue;
        int count = snprintf(sequence, sizeof(sequence), "\x1b]%d;rgb:%02x/%02x/%02x\x1b\\", 10 + i, color.r, color.g, color.b);
        if (!append(result, sequence, (size_t)count)) return false;
    }
    return true;
}
static bool send_snapshot(void) {
    uint8_t *snapshot = NULL, *continuation = NULL;
    size_t snapshot_count = 0, continuation_count = 0;
    if (ghostty_snapshot_encode_alloc(terminal, NULL, &snapshot, &snapshot_count) != GHOSTTY_SUCCESS) return false;
    if (ghostty_terminal_continuation_alloc(terminal, NULL, &continuation, &continuation_count) != GHOSTTY_SUCCESS) {
        ghostty_free(NULL, snapshot, snapshot_count); return false;
    }
    Buffer result = {0};
    bool ok = append(&result, "\x1b" "c", 2) && format_color_overrides(&result);
    GhosttyTerminalScreen active = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &active);
    GhosttyTerminal copy = clone_terminal(snapshot, snapshot_count);
    if (!copy) ok = false;
    if (ok && active == GHOSTTY_TERMINAL_SCREEN_ALTERNATE) {
        const char *primary = "\x1b[?1049l\x1b[?1047l\x1b[?47l";
        ghostty_terminal_vt_write(copy, (const uint8_t *)primary, strlen(primary));
        ok = format_screen(copy, &result, false) && append(&result, "\x1b" "7", 2);
        ghostty_terminal_free(copy);
        copy = clone_terminal(snapshot, snapshot_count);
        if (!copy) ok = false;
    }
    if (ok) ok = format_screen(copy, &result, true);
    GhosttyString pwd = {0};
    if (ok && ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_PWD, &pwd) == GHOSTTY_SUCCESS && pwd.len > 0)
        ok = append(&result, "\x1b]7;", 4) && append(&result, pwd.ptr, pwd.len) && append(&result, "\x1b\\", 2);
    if (ok) ok = append(&result, continuation, continuation_count);
    if (ok) ok = frame('R', result.bytes, result.count);
    if (copy) ghostty_terminal_free(copy);
    ghostty_free(NULL, continuation, continuation_count);
    ghostty_free(NULL, snapshot, snapshot_count);
    free(result.bytes);
    return ok;
}
static void status_values(uint32_t values[3]) {
    struct termios attributes;
    values[0] = htonl((uint32_t)(is_exited ? 0 : child)); values[1] = values[2] = 0;
    if (master >= 0) {
        pid_t foreground = tcgetpgrp(master);
        values[1] = htonl((uint32_t)(foreground > 0 ? foreground : 0));
        if (tcgetattr(master, &attributes) == 0)
            values[2] = htonl((attributes.c_lflag & ECHO) == 0 && (attributes.c_lflag & ICANON) != 0);
    }
}
static bool send_status(void) {
    uint32_t values[3]; status_values(values);
    return frame('S', values, sizeof(values));
}
// 单独的只读状态连接不占用显示连接，侧栏轮询不会和窗口接回互相抢占。
static void inspect_session(int listener) {
    int peer = accept(listener, NULL, NULL); uid_t uid; gid_t gid;
    if (peer < 0) return;
    if (getpeereid(peer, &uid, &gid) || uid != getuid()) { close(peer); return; }
    fcntl(peer, F_SETFL, O_NONBLOCK);
    int no_pipe = 1; setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &no_pipe, sizeof(no_pipe));
    uint8_t packet[2100]; uint32_t values[3], length; size_t offset = 0;
    status_values(values);
    packet[offset++] = 'S'; length = htonl(sizeof(values)); memcpy(packet + offset, &length, 4); offset += 4;
    memcpy(packet + offset, values, sizeof(values)); offset += sizeof(values);
    packet[offset++] = 'M'; size_t count = strlen(command); length = htonl((uint32_t)count + 1);
    memcpy(packet + offset, &length, 4); offset += 4; packet[offset++] = is_running ? 1 : 0;
    memcpy(packet + offset, command, count); offset += count;
    packet[offset++] = 'H'; memset(packet + offset, 0, 4); offset += 4;
    (void)write(peer, packet, offset); close(peer);
}
static bool send_command(void) {
    Buffer value = {0};
    uint8_t state = is_running ? 1 : 0;
    bool ok = append(&value, &state, 1) && append(&value, command, strlen(command)) && frame('M', value.bytes, value.count);
    free(value.bytes); return ok;
}
static void note_osc(char *text) {
    if (!strncmp(text, "133;A", 5) || !strncmp(text, "133;D", 5)) {
        is_running = is_at_input = false; command[0] = pending_title[0] = 0;
    } else if (!strncmp(text, "133;B", 5)) {
        is_at_input = true; pending_title[0] = 0;
    } else if (!strncmp(text, "133;C", 5)) {
        is_running = true; is_at_input = false;
        strlcpy(command, pending_title, sizeof(command)); pending_title[0] = 0;
    } else if ((!strncmp(text, "2;", 2) || !strncmp(text, "0;", 2)) && text[2]) {
        if (is_running && !command[0]) strlcpy(command, text + 2, sizeof(command));
        else if (is_at_input) strlcpy(pending_title, text + 2, sizeof(pending_title));
    }
}
static void track_command(const uint8_t *bytes, size_t count) {
    static char osc[16384]; static size_t used = 0; static int state = 0;
    for (size_t i = 0; i < count; i++) {
        uint8_t c = bytes[i];
        if (state == 0) { if (c == 27) state = 1; }
        else if (state == 1) { state = c == ']' ? 2 : (c == 27 ? 1 : 0); used = 0; }
        else if ((state == 2 && c == 7) || (state == 3 && c == '\\')) {
            osc[used] = 0; note_osc(osc); state = 0;
        } else if (state == 2 && c == 27) state = 3;
        else if (state == 2 && used + 1 < sizeof(osc)) osc[used++] = (char)c;
        else { state = 0; used = 0; }
    }
}
static void resize_terminal(const uint8_t *bytes, size_t count) {
    if (count != 8 || master < 0) return;
    uint16_t values[4]; memcpy(values, bytes, 8);
    struct winsize size = {ntohs(values[0]), ntohs(values[1]), ntohs(values[2]), ntohs(values[3])};
    if (size.ws_col < 2 || size.ws_row < 2 || size.ws_col > 2000 || size.ws_row > 2000) return;
    ghostty_terminal_resize(terminal, size.ws_col, size.ws_row,
        size.ws_xpixel / size.ws_col, size.ws_ypixel / size.ws_row);
    ioctl(master, TIOCSWINSZ, &size);
}
static void terminate_session(void) {
    if (child <= 0) return;
    // macOS 可能等 PTY master 释放后才完成前台作业的退出；先释放，不能反过来等 waitpid。
    if (master >= 0) { close(master); master = -1; }
    // forkpty 创建独立会话。只终止这个会话里的进程，不碰其他终端。
    int capacity = proc_listallpids(NULL, 0) + 64;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    int count = pids ? proc_listallpids(pids, capacity * (int)sizeof(pid_t)) : 0;
    for (int i = 0; i < count; i++) if (pids[i] > 0 && getsid(pids[i]) == child) kill(pids[i], SIGHUP);
    if (!is_exited) kill(child, SIGHUP);
    usleep(150000);
    for (int i = 0; i < count; i++) if (pids[i] > 0 && getsid(pids[i]) == child) kill(pids[i], SIGKILL);
    free(pids);
    if (!is_exited) {
        kill(child, SIGKILL);
        // 即使内核中的进程退出较慢，也不能让整个辅助程序永久卡在收尾。
        double deadline = monotonic_time() + 1;
        while (waitpid(child, NULL, WNOHANG) == 0 && monotonic_time() < deadline) usleep(10000);
    }
}
static bool receive_frames(void) {
    uint8_t bytes[65536]; ssize_t n = read(client, bytes, sizeof(bytes));
    if (n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN)) { disconnect_client(); return true; }
    if (n <= 0) return true;
    if (!append(&input, bytes, (size_t)n)) { disconnect_client(); return true; }
    size_t consumed = 0;
    while (input.count - consumed >= 5) {
        uint32_t count; memcpy(&count, input.bytes + consumed + 1, 4); count = ntohl(count);
        if (count > 1024 * 1024) { disconnect_client(); return true; }
        if (input.count - consumed < count + 5) break;
        char type = (char)input.bytes[consumed]; uint8_t *value = input.bytes + consumed + 5;
        if (type == 'K') return false;
        if (type == 'A' && !is_attached) {
            resize_terminal(value, count);
            is_attached = true;
            if (!send_status() || !send_snapshot() || !send_command() || !frame('H', NULL, 0)) {
                disconnect_client(); return true;
            }
        } else if (type == 'I' && is_attached && !is_exited) enqueue_keyboard(value, count);
        else if (type == 'W' && is_attached) resize_terminal(value, count);
        else if (type == 'C' && is_attached) set_colors(value, count);
        else if (type == 'P') {
            if (!send_status() || !send_command() || !frame('H', NULL, 0)) { disconnect_client(); return true; }
        }
        consumed += count + 5;
        if (client < 0) return true;
    }
    memmove(input.bytes, input.bytes + consumed, input.count - consumed); input.count -= consumed;
    return true;
}
int main(int argc, char **argv) {
    if (argc < 6 || argv[1][0] != '/') return 64;
    const char *folder = argv[1];
    struct stat info;
    if (lstat(folder, &info) || !S_ISDIR(info.st_mode) || info.st_uid != getuid() || (info.st_mode & 077) != 0) return 77;
    // Foundation 启动的短命父进程立即退出；后台进程不继承 GUI 的生命期。
    pid_t daemon = fork(); if (daemon < 0) return 71; if (daemon > 0) return 0;
    if (setsid() < 0) return 71;
    signal(SIGPIPE, SIG_IGN); signal(SIGHUP, SIG_IGN);
    int null_fd = open("/dev/null", O_RDWR);
    for (int fd = 0; fd < 3; fd++) dup2(null_fd, fd);
    if (null_fd > 2) close(null_fd);
    char path[108], lock_path[1024];
    if (snprintf(path, sizeof(path), "%s/s", folder) >= (int)sizeof(path)) return 64;
    snprintf(lock_path, sizeof(lock_path), "%s/lock", folder);
    int lock_fd = open(lock_path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (lock_fd < 0 || flock(lock_fd, LOCK_EX | LOCK_NB)) return 75;
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un address = {0}; address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    unlink(path); umask(077);
    if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof(address)) || listen(listener, 4)) return 71;
    fcntl(listener, F_SETFD, FD_CLOEXEC);
    int inspector = socket(AF_UNIX, SOCK_STREAM, 0);
    char inspect_path[108]; snprintf(inspect_path, sizeof(inspect_path), "%s/p", folder);
    strlcpy(address.sun_path, inspect_path, sizeof(address.sun_path)); unlink(inspect_path);
    if (inspector < 0 || bind(inspector, (struct sockaddr *)&address, sizeof(address)) || listen(inspector, 4)) return 71;
    fcntl(inspector, F_SETFD, FD_CLOEXEC);
    struct winsize size = { .ws_col = (unsigned short)atoi(argv[2]), .ws_row = (unsigned short)atoi(argv[3]) };
    if (size.ws_col < 2) size.ws_col = 80; if (size.ws_row < 2) size.ws_row = 24;
    if (ghostty_terminal_new(NULL, &terminal, size.ws_col, size.ws_row) != GHOSTTY_SUCCESS) return 71;
    size_t history = (size_t)strtoull(argv[4], NULL, 10), continuation = 1024 * 1024;
    if (history < 10000000 || history > 1000000000) history = 128000000;
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &history);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation);
    // 老版本的日志和重新连接前的画面只作为显示历史，不作为输入执行。
    char history_path[1024]; snprintf(history_path, sizeof(history_path), "%s/initial-output", folder);
    int history_fd = open(history_path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    struct stat history_info;
    if (history_fd >= 0) {
        if (!fstat(history_fd, &history_info) && S_ISREG(history_info.st_mode) && history_info.st_uid == getuid() && history_info.st_size <= 16 * 1024 * 1024) {
            uint8_t bytes[65536]; ssize_t n;
            while ((n = read(history_fd, bytes, sizeof(bytes))) > 0) ghostty_terminal_vt_write(terminal, bytes, (size_t)n);
        }
        close(history_fd); unlink(history_path);
    }
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void *)reply_to_pty);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, (const void *)query_color_scheme);
    child = forkpty(&master, NULL, NULL, &size);
    if (child == 0) {
        close(listener); close(inspector); close(lock_fd); signal(SIGHUP, SIG_DFL); signal(SIGPIPE, SIG_DFL);
        execv(argv[5], argv + 5); _exit(127);
    }
    if (child < 0) return 71;
    fcntl(master, F_SETFL, O_NONBLOCK);
    bool is_open = true; double last_status = 0;
    while (is_open) {
        struct pollfd fds[4] = {
            {listener, POLLIN, 0}, {master, POLLIN | (keyboard.count > keyboard_sent ? POLLOUT : 0), 0},
            {client, POLLIN | (output.count > sent ? POLLOUT : 0), 0}, {inspector, POLLIN, 0}
        };
        int ready = poll(fds, 4, 100);
        if (ready < 0 && errno != EINTR) break;
        if (fds[3].revents & POLLIN) inspect_session(inspector);
        if (fds[0].revents & POLLIN) {
            int peer = accept(listener, NULL, NULL); uid_t uid; gid_t gid;
            if (peer < 0) continue;
            if (getpeereid(peer, &uid, &gid) || uid != getuid() || client >= 0) { close(peer); continue; }
            client = peer; fcntl(client, F_SETFL, O_NONBLOCK);
            int no_pipe = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &no_pipe, sizeof(no_pipe));
        }
        if (client >= 0 && (fds[2].revents & (POLLIN | POLLHUP))) is_open = receive_frames();
        if (client >= 0 && (fds[2].revents & (POLLERR | POLLNVAL))) disconnect_client();
        if (!is_open) break;
        if (master >= 0 && (fds[1].revents & (POLLIN | POLLHUP))) {
            uint8_t bytes[65536]; ssize_t n = read(master, bytes, sizeof(bytes));
            if (n > 0) {
                track_command(bytes, (size_t)n);
                ghostty_terminal_vt_write(terminal, bytes, (size_t)n);
                if (is_attached && !frame('O', bytes, (size_t)n)) disconnect_client();
            } else if (n == 0 || (n < 0 && errno == EIO)) { close(master); master = -1; }
        }
        if (master >= 0 && (fds[1].revents & POLLOUT) && keyboard.count > keyboard_sent) {
            ssize_t n = write(master, keyboard.bytes + keyboard_sent, keyboard.count - keyboard_sent);
            if (n > 0) keyboard_sent += (size_t)n;
            if (keyboard_sent == keyboard.count) keyboard.count = keyboard_sent = 0;
        }
        if (client >= 0 && output.count > sent) {
            ssize_t n = write(client, output.bytes + sent, output.count - sent);
            if (n > 0) sent += (size_t)n;
            else if (n < 0 && errno != EAGAIN && errno != EINTR) disconnect_client();
            if (sent == output.count) {
                output.count = sent = 0;
                if (is_exit_sent) is_open = false;
            }
        }
        if (!is_exited) {
            int status = 0;
            if (waitpid(child, &status, WNOHANG) == child) {
                is_exited = true; exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
            }
        }
        if (is_attached && is_exited && master < 0 && !is_exit_sent) {
            uint32_t code = htonl((uint32_t)exit_code);
            if (!frame('X', &code, sizeof(code))) disconnect_client(); else is_exit_sent = true;
        }
        if (sent >= 65536) compact(&output, &sent);
        if (keyboard_sent >= 65536) compact(&keyboard, &keyboard_sent);
        if (monotonic_time() - last_status >= 0.5) {
            last_status = monotonic_time();
            if (is_attached && (!send_status() || !send_command())) disconnect_client();
        }
    }
    terminate_session();
    if (master >= 0) close(master);
    close(listener); unlink(path); close(inspector); unlink(inspect_path);
    char cleanup[1024];
    const char *files[] = {"bridge/s", "bridge/token", "bridge", "lock"};
    for (size_t i = 0; i < sizeof(files) / sizeof(files[0]); i++) {
        snprintf(cleanup, sizeof(cleanup), "%s/%s", folder, files[i]);
        if (i == 2) rmdir(cleanup); else unlink(cleanup);
    }
    rmdir(folder);
    // EOF 表示目录也已清理，客户端可以安全启动替代会话。
    disconnect_client(); close(lock_fd);
    ghostty_terminal_free(terminal); free(output.bytes); free(input.bytes); free(keyboard.bytes);
    return 0;
}
