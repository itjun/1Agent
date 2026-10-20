#include <errno.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Fail closed at the OS process-launch boundary; no real SSH or user login shell runs. */
static int guarded_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                         const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]) {
    if (strcmp(path, "/usr/bin/ssh") == 0) {
        const char *fixture = getenv("ONEAGENT_REMOTE_FIXTURE");
        const char *prefix = "/private/tmp/oneagent-files-routing.";
        if (!fixture || strncmp(fixture, prefix, strlen(prefix)) != 0) return EPERM;
        return posix_spawn(pid, fixture, actions, attributes, argv, envp);
    }
    if (strcmp(path, "/bin/zsh") == 0) {
        char *arguments[] = {"/usr/bin/printf", "/usr/bin:/bin\n", NULL};
        return posix_spawn(pid, "/usr/bin/printf", actions, attributes, arguments, envp);
    }
    return EPERM;
}

/* Foundation checks X_OK before posix_spawn. The real programs remain denied by
 * the independent sandbox; this only lets the call reach the fixture redirect. */
static int guarded_access(const char *path, int mode) {
    if (mode == X_OK && (strcmp(path, "/usr/bin/ssh") == 0 || strcmp(path, "/bin/zsh") == 0)) return 0;
    return access(path, mode);
}

static int guarded_spawnp(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                          const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]) {
    return guarded_spawn(pid, path, actions, attributes, argv, envp);
}

__attribute__((used)) static struct { const void *replacement; const void *original; }
interpositions[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)guarded_spawn, (const void *)posix_spawn},
    {(const void *)guarded_spawnp, (const void *)posix_spawnp},
    {(const void *)guarded_access, (const void *)access}
};
