// 直接调用后台终端的快照导出，再交给新的 Ghostty 终端恢复。
#define main session_host_main
#include "../Sources/SessionHost/main.c"
#undef main

static const char *long_line =
    "HISTORY_BEGIN_0123456789_abcdefghijklmnopqrstuvwxyz_ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789_HISTORY_END";

static bool same_styled_text(GhosttyTerminal original, GhosttyTerminal restored, bool is_unwrapped) {
    GhosttyFormatterTerminalOptions options = GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
    // 同时比较样式序列，防止文本正确但颜色、粗体或下划线在恢复时丢失。
    options.emit = GHOSTTY_FORMATTER_FORMAT_VT;
    options.unwrap = is_unwrapped;
    options.trim = true;
    options.extra = (GhosttyFormatterTerminalExtra)GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalExtra);
    options.extra.screen = (GhosttyFormatterScreenExtra)GHOSTTY_INIT_SIZED(GhosttyFormatterScreenExtra);
    Buffer texts[2] = {{0}, {0}};
    GhosttyTerminal terminals[2] = {original, restored};
    bool is_valid = true;
    for (size_t i = 0; i < 2 && is_valid; i++) {
        GhosttyFormatter formatter = NULL;
        is_valid = ghostty_formatter_terminal_new(NULL, &formatter, terminals[i], options) == GHOSTTY_SUCCESS;
        if (is_valid) {
            GhosttyWriter writer = {.write = buffer_write, .userdata = &texts[i]};
            is_valid = ghostty_formatter_format(formatter, writer) == GHOSTTY_SUCCESS && append(&texts[i], "", 1);
        }
        if (formatter) ghostty_formatter_free(formatter);
    }
    if (is_valid && strcmp((char *)texts[0].bytes, (char *)texts[1].bytes)) {
        fprintf(stderr, "FAIL: restored history changed its %s lines:\nEXPECTED:\n%s\nACTUAL:\n%s\n",
            is_unwrapped ? "logical" : "visible", texts[0].bytes, texts[1].bytes);
        is_valid = false;
    }
    free(texts[0].bytes); free(texts[1].bytes);
    return is_valid;
}

static bool check_reflow(uint16_t source_columns, uint16_t restored_columns, bool is_wrap_enabled) {
    if (ghostty_terminal_new(NULL, &terminal, source_columns, 24) != GHOSTTY_SUCCESS) return false;
    size_t continuation = 1024 * 1024;
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation);
    const char *style = "\x1b[1;4;38;2;200;120;40;48;5;4m";
    ghostty_terminal_vt_write(terminal, (const uint8_t *)style, strlen(style));
    ghostty_terminal_vt_write(terminal, (const uint8_t *)long_line, strlen(long_line));
    const char *filler = "\x1b[0m\r\nSCROLLBACK_FILLER";
    for (int i = 0; i < 36; i++) ghostty_terminal_vt_write(terminal, (const uint8_t *)filler, strlen(filler));
    const char *tail = "\x1b[0m\r\n中文文本与终端历史中文文本与终端历史中文文本与终端历史\r\nHARD_LINE_A\r\nHARD_LINE_B\r\n";
    ghostty_terminal_vt_write(terminal, (const uint8_t *)tail, strlen(tail));
    if (!is_wrap_enabled) ghostty_terminal_vt_write(terminal, (const uint8_t *)"\x1b[?7l", 5);
    output.count = sent = 0;
    bool is_valid = send_snapshot();
    if (!is_valid) fputs("FAIL: snapshot export\n", stderr);
    GhosttyTerminal restored = NULL;
    is_valid = is_valid && ghostty_terminal_new(NULL, &restored, source_columns, 24) == GHOSTTY_SUCCESS;
    if (is_valid) {
        ghostty_terminal_vt_write(restored, output.bytes + 5, output.count - 5);
        GhosttyTerminalModeConfig wrap = {.mode = GHOSTTY_MODE_WRAPAROUND};
        is_valid = ghostty_terminal_get(restored, GHOSTTY_TERMINAL_DATA_MODE, &wrap) == GHOSTTY_SUCCESS
            && wrap.value == is_wrap_enabled && same_styled_text(terminal, restored, true);
        // 对比从未断开的原终端，自动换行关闭时也必须保持同样的文本和布局。
        const uint16_t widths[] = {restored_columns, 32, 160};
        for (size_t i = 0; i < sizeof(widths) / sizeof(widths[0]) && is_valid; i++) {
            ghostty_terminal_resize(terminal, widths[i], 24, 0, 0);
            ghostty_terminal_resize(restored, widths[i], 24, 0, 0);
            is_valid = same_styled_text(terminal, restored, true) && same_styled_text(terminal, restored, false);
        }
    }
    if (restored) ghostty_terminal_free(restored);
    ghostty_terminal_free(terminal); terminal = NULL;
    return is_valid;
}

int main(void) {
    bool is_valid = check_reflow(48, 160, true);
    is_valid = check_reflow(48, 160, false) && is_valid;
    is_valid = check_reflow(160, 48, true) && is_valid;
    free(output.bytes);
    if (!is_valid) return 1;
    puts("PASS: restored colored/CJK history preserves logical and visible lines across narrow/wide resizes, hard newlines and wrap mode");
    return 0;
}
