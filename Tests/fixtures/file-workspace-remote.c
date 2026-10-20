#include <stdio.h>
#include <string.h>

/* Deterministic remote fixture; never opens a socket, starts a shell, or reads SSH config. */
int main(int argc, char **argv) {
    if (argc < 2) return 64;
    int fixture_host = 0;
    for (int i = 1; i + 1 < argc; ++i) {
        if (strcmp(argv[i], "--") == 0 &&
            (strcmp(argv[i + 1], "fixture-a") == 0 || strcmp(argv[i + 1], "fixture-b") == 0)) fixture_host = 1;
    }
    if (!fixture_host) return 64;
    const char *command = argv[argc - 1];
    if (strcmp(command, "pwd") == 0) {
        puts("/fixture-startup-directory");
        return 0;
    }
    if (strcmp(command, "cd && pwd") == 0) {
        puts("/fixture-remote-home");
        return 0;
    }
    if (strncmp(command, "find ", 5) == 0) {
        static const char row[] = "f\tf\t4\t-rw-r--r--\t0\tfixture.txt\0";
        fwrite(row, 1, sizeof(row) - 1, stdout);
        return 0;
    }
    fprintf(stderr, "Unexpected remote fixture command\n");
    return 65;
}
