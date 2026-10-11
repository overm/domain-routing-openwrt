/* Research fixture, not an installable offload service.
 * The active worker and standby inherit the SAME netlink socket after fork.
 * A standby retains table ownership on worker death, closes admission, then
 * serves commands on the inherited root-only UNIX socket. Commands are serial.
 * Both-process failure deliberately remains outside this single-fault model.
 */
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE 1
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

struct nft_ctx;
extern struct nft_ctx *nft_ctx_new(unsigned int);
extern void nft_ctx_free(struct nft_ctx *);
extern int nft_run_cmd_from_filename(struct nft_ctx *, const char *);
extern int nft_run_cmd_from_buffer(struct nft_ctx *, const char *);

static struct nft_ctx *ctx;
static int listener, life_write = -1, standby = 0, gate_error = 0;
static pid_t child = -1;
static char close_gate[256];
static unsigned long long epoch;

static int rotate_epoch(void)
{
    epoch = 0;
    return getrandom(&epoch, sizeof(epoch), 0) != sizeof(epoch) || !epoch;
}

static int line(int fd, char *buffer, size_t size)
{
    size_t used = 0;
    struct pollfd p = { .fd = fd, .events = POLLIN };
    while (used + 1 < size) {
        if (poll(&p, 1, 3000) <= 0) return -1;
        ssize_t n = read(fd, buffer + used, 1);
        if (n != 1) return -1;
        if (buffer[used] == '\n') { buffer[used] = 0; return 0; }
        used++;
    }
    return -1;
}

static void reply(int fd, const char *message)
{
    size_t left = strlen(message);
    while (left) {
        ssize_t n = write(fd, message, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return;
        message += n;
        left -= (size_t)n;
    }
}

static int identifier(const char *s)
{
    if (!*s || strlen(s) > 63) return 0;
    for (; *s; s++)
        if (!((*s >= 'a' && *s <= 'z') || (*s >= 'A' && *s <= 'Z') ||
              (*s >= '0' && *s <= '9') || *s == '_')) return 0;
    return 1;
}

static void serve(void);

static int spawn_standby(void)
{
    int pair[2];
    if (pipe(pair)) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(pair[0]); close(pair[1]); return -1; }
    if (!pid) {
        close(pair[1]);
        if (life_write >= 0) close(life_write);
        standby = 1;
        child = -1;
        /* Do not keep the SSH stdout channel alive on worker death. */
        if (!freopen("/dev/null", "r", stdin) ||
            !freopen("/dev/null", "w", stdout)) _exit(2);
        char command;
        ssize_t n;
        do { n = read(pair[0], &command, 1); } while (n < 0 && errno == EINTR);
        close(pair[0]);
        if (n == 1 && command == 'R') { nft_ctx_free(ctx); _exit(0); }
        gate_error = rotate_epoch();
        if (nft_run_cmd_from_buffer(ctx, close_gate)) gate_error = 1;
        serve();
        nft_ctx_free(ctx);
        _exit(0);
    }
    close(pair[0]);
    if (life_write >= 0) close(life_write);
    life_write = pair[1];
    child = pid;
    return 0;
}

static void detect_child_loss(void)
{
    if (!standby && child > 0 && waitpid(child, NULL, WNOHANG) == child) {
        child = -1;
        gate_error = rotate_epoch();
        if (nft_run_cmd_from_buffer(ctx, close_gate)) gate_error = 1;
    }
}

static void serve(void)
{
    struct pollfd p = { .fd = listener, .events = POLLIN };
    for (;;) {
        detect_child_loss();
        int ready = poll(&p, 1, 100);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) continue;
        int fd = accept(listener, NULL, NULL);
        if (fd < 0) continue;
        char command[16384], answer[128];
        if (line(fd, command, sizeof(command))) { close(fd); continue; }
        char *action = command;
        if (strcmp(command, "STATUS") && strcmp(command, "EPOCH")) {
            char *end;
            if (strncmp(command, "DO ", 3)) { reply(fd, "STALE\n"); close(fd); continue; }
            unsigned long long requested = strtoull(command + 3, &end, 10);
            if (end == command + 3 || *end != ' ' || !epoch || requested != epoch) {
                reply(fd, "STALE\n"); close(fd); continue;
            }
            action = end + 1;
        }
        if (!strcmp(action, "EPOCH")) {
            snprintf(answer, sizeof(answer), "EPOCH %llu\n", epoch);
            reply(fd, answer);
        } else if (!strcmp(action, "STATUS")) {
            snprintf(answer, sizeof(answer), "%s %s %ld\n",
                     standby ? "HELD" : "ACTIVE",
                     gate_error ? "ERROR" : (!standby && child < 0 ? "NO_STANDBY" : "OK"),
                     (long)child);
            reply(fd, answer);
        } else if (!strcmp(action, "REPLACE") && !standby && child < 0) {
            reply(fd, spawn_standby() ? "ERR\n" : "OK\n");
        } else if (!strncmp(action, "NFT ", 4)) {
            /* Deliberately a raw lab command channel, never expose to LuCI. */
            int result = nft_run_cmd_from_buffer(ctx, action + 4);
            reply(fd, result ? "ERR\n" : "OK\n");
        } else if (!strcmp(action, "STOP")) {
            /* Harness must drain/delete every flowtable BEFORE issuing STOP. */
            if (!standby && life_write >= 0) reply(life_write, "R");
            reply(fd, "OK\n");
            close(fd);
            return;
        } else reply(fd, "ERR\n");
        close(fd);
    }
}

static int exchange(const char *path, const char *command, char *buffer, size_t size)
{
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    if (strlen(path) >= sizeof(addr.sun_path)) return -1;
    strcpy(addr.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect(fd, (void *)&addr, sizeof(addr))) { close(fd); return -1; }
    reply(fd, command); reply(fd, "\n");
    int result = line(fd, buffer, size);
    close(fd);
    return result;
}

int main(int argc, char **argv)
{
    signal(SIGPIPE, SIG_IGN);
    if (argc == 4 && (!strcmp(argv[1], "--client") || !strcmp(argv[1], "--wire"))) {
        char buffer[256];
        char wire[16384];
        const char *command = argv[3];
        if (!strcmp(argv[1], "--client") && strcmp(command, "STATUS") && strcmp(command, "EPOCH")) {
            if (exchange(argv[2], "EPOCH", buffer, sizeof(buffer)) || strncmp(buffer, "EPOCH ", 6)) return 2;
            int size = snprintf(wire, sizeof(wire), "DO %s %s", buffer + 6, command);
            if (size < 0 || (size_t)size >= sizeof(wire)) return 2;
            command = wire;
        }
        if (exchange(argv[2], command, buffer, sizeof(buffer))) return 2;
        puts(buffer);
        return !strcmp(buffer, "ERR") || !strcmp(buffer, "STALE");
    }
    if (argc != 5 || !identifier(argv[3]) || !identifier(argv[4])) return 2;
    snprintf(close_gate, sizeof(close_gate), "flush chain inet %s %s", argv[3], argv[4]);
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    if (strlen(argv[2]) >= sizeof(addr.sun_path)) return 2;
    strcpy(addr.sun_path, argv[2]);
    umask(0077);
    listener = socket(AF_UNIX, SOCK_STREAM, 0);
    /* Refuse an existing path; recovery must connect to the standby. */
    if (listener < 0 || bind(listener, (void *)&addr, sizeof(addr)) || listen(listener, 8)) return 2;
    if (rotate_epoch()) return 2;
    ctx = nft_ctx_new(0);
    if (!ctx || nft_run_cmd_from_filename(ctx, argv[1])) return 2;
    if (spawn_standby()) return 2;
    printf("READY %ld %ld\n", (long)getpid(), (long)child);
    fflush(stdout);
    serve();
    nft_ctx_free(ctx);
    return 0;
}
