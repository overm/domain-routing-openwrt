/* Root-only owner of a private flowtable. No arbitrary nft command RPC.
 * Active, standby and an independent keeper inherit the SAME netlink socket.
 * A lost worker closes admission and rotates the generation. Recovery requires
 * the physical barrier, never merely reopening admission after a crash.
 */
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE 1
#include <errno.h>
#include <dlfcn.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

struct nft_ctx;
static struct nft_ctx *(*nft_ctx_new)(unsigned int);
static int (*nft_run_cmd_from_filename)(struct nft_ctx *, const char *);
static int (*nft_run_cmd_from_buffer)(struct nft_ctx *, const char *);

#ifndef GD_DIRECTORY
#define GD_DIRECTORY "/tmp/getdomains-offload"
#endif
#ifndef GD_EMERGENCY
#define GD_EMERGENCY "/usr/libexec/getdomains-offload emergency"
#endif
#ifndef GD_DEADLINE_SECONDS
#define GD_DEADLINE_SECONDS 180
#endif
#define DIR GD_DIRECTORY
#define SOCK DIR "/owner.sock"
#define CLOSE "flush chain inet gd_offload admission"
static struct nft_ctx *ctx;
static int listener, life = -1, standby;
// Shared metadata fences the keeper against a stalled server and retains the
// actual phase if the worker dies after RETIRE. Only the serving process writes
// phases; the independent keeper may quiesce both servers in an emergency.
static struct lifecycle {
    int degraded, retired, held;
    pid_t backup, keeper, active;
    unsigned long long epoch;
} *state;
#define degraded (state->degraded)
#define retired (state->retired)
#define held (state->held)
#define backup (state->backup)
#define keeper (state->keeper)
#define epoch (state->epoch)

static int generation(void) {
    epoch = 0;
    return getrandom(&epoch, sizeof(epoch), 0) != sizeof(epoch) || !epoch;
}
static void send_line(int fd, const char *s) {
    size_t n = strlen(s);
    while (n) {
        ssize_t k = write(fd, s, n);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) return;
        s += k; n -= (size_t)k;
    }
}
static int read_line(int fd, char *s, size_t size) {
    struct pollfd p = { .fd = fd, .events = POLLIN };
    size_t used = 0;
    while (used + 1 < size) {
        if (poll(&p, 1, 2000) <= 0) return -1;
        if (read(fd, s + used, 1) != 1) return -1;
        if (s[used] == '\n') { s[used] = 0; return 0; }
        used++;
    }
    return -1;
}
static int exchange(const char *command, char *s, size_t size) {
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    strcpy(a.sun_path, SOCK);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect(fd, (void *)&a, sizeof(a))) { close(fd); return -1; }
    send_line(fd, command); send_line(fd, "\n");
    int rc = read_line(fd, s, size); close(fd); return rc;
}
static int closed(void) {
    degraded = 1;
    int rc = generation();
    if (nft_run_cmd_from_buffer(ctx, CLOSE)) rc = 1;
    return rc;
}
static void serve(void);
static int spawn_backup(void) {
    int pipefd[2];
    if (pipe(pipefd)) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(pipefd[0]); close(pipefd[1]); return -1; }
    if (!pid) {
        close(pipefd[1]); if (life >= 0) close(life);
        life = -1;
        standby = 1;
        char byte;
        ssize_t n;
        do { n = read(pipefd[0], &byte, 1); } while (n < 0 && errno == EINTR);
        close(pipefd[0]);
        if (n == 1 && byte == 'R') _exit(0);
        backup = -1; state->active = getpid();
        closed(); serve(); _exit(0);
    }
    close(pipefd[0]); if (life >= 0) close(life);
    life = pipefd[1]; backup = pid; return 0;
}
static int spawn_keeper(void) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (!pid) {
        if (setsid() < 0) _exit(2);
        close(listener); if (life >= 0) close(life);
        /* Holds ownership independently of both serving processes. A missing
         * server closes admission and requests the local watchdog barrier.
         * Never drop this socket merely because a controller stopped. */
        double queued_since = 0;
        for (;;) {
            char answer[128];
            sleep(2);
            int overdue = 0;
            FILE *f = fopen(DIR "/transaction.lock/start", "r");
            long started = 0;
            if (f) { if (fscanf(f, "%ld", &started) != 1) overdue = 1; fclose(f); }
            f = fopen("/proc/uptime", "r");
            double uptime = 0;
            if (f) { if (fscanf(f, "%lf", &uptime) != 1) overdue = 1; fclose(f); }
            if (started && uptime - started >= GD_DEADLINE_SECONDS) overdue = 1;
            // Queue failures before prepare-job also have a bounded recovery.
            // A checked apply intentionally keeps its lock while awaiting the
            // longer native rollback deadline, so exclude that phase here.
            started = 0;
            if (access(DIR "/await-confirm", F_OK) != 0) {
                f = fopen(DIR "/submission.lock/start", "r");
                if (f) { if (fscanf(f, "%ld", &started) != 1) overdue = 1; fclose(f); }
                if (started && uptime - started >= GD_DEADLINE_SECONDS) overdue = 1;
                if (access(DIR "/submission.lock", F_OK) == 0) {
                    if (!queued_since) queued_since = uptime;
                    if (uptime - queued_since >= GD_DEADLINE_SECONDS) overdue = 1;
                } else queued_since = 0;
            } else queued_since = 0;
            pid_t supervisor = 0;
            f = fopen(DIR "/supervisor.pid", "r");
            if (f) { if (fscanf(f, "%d", &supervisor) != 1) overdue = 1; fclose(f); }
            if (supervisor > 0 && kill(supervisor, 0) && errno == ESRCH) overdue = 1;
            if (access(DIR "/maintenance", F_OK) == 0) continue;
            if (overdue || exchange("STATUS", answer, sizeof(answer))) {
                // Do not race a delayed RELEASE on the shared netlink socket.
                // The keeper holds ownership while both writers are stopped.
                degraded = 1;
                pid_t worker = state->active, other = backup;
                if (worker > 0) kill(worker, SIGKILL);
                if (other > 0) kill(other, SIGKILL);
                nft_run_cmd_from_buffer(ctx, CLOSE);
                f = fopen(DIR "/owner-lost", "w");
                if (f) { fputs("keeper\n", f); fclose(f); }
                system(GD_EMERGENCY);
            }
        }
    }
    keeper = pid; return 0;
}
static int drain_ack(void) {
    /* The shell barrier writes this only while Ethernet is held and two PPE
     * samples were empty. Fence acknowledgements across process failover. */
    unsigned long long value = 0;
    FILE *f = fopen(DIR "/drained", "r");
    if (!f) return 0;
    int valid = fscanf(f, "%llu", &value) == 1 && value == epoch;
    fclose(f); return valid;
}
static void serve(void) {
    struct pollfd p = { .fd = listener, .events = POLLIN };
    for (;;) {
        if (!standby && ((backup > 0 && waitpid(backup, NULL, WNOHANG) == backup) ||
                         (keeper > 0 && waitpid(keeper, NULL, WNOHANG) == keeper))) {
            closed();
        }
        if (poll(&p, 1, 100) <= 0) continue;
        int fd = accept(listener, NULL, NULL);
        if (fd < 0) continue;
        char cmd[128], answer[160];
        if (read_line(fd, cmd, sizeof(cmd))) { close(fd); continue; }
        char *action = cmd;
        if (strcmp(cmd, "STATUS") && strcmp(cmd, "EPOCH")) {
            char *end;
            if (strncmp(cmd, "DO ", 3)) { send_line(fd, "STALE\n"); close(fd); continue; }
            unsigned long long requested = strtoull(cmd + 3, &end, 10);
            if (end == cmd + 3 || *end != ' ' || !epoch || requested != epoch) {
                send_line(fd, "STALE\n"); close(fd); continue;
            }
            action = end + 1;
        }
        int rc = -1;
        if (!strcmp(action, "STATUS")) {
            snprintf(answer, sizeof(answer), "%s %s %llu %ld %ld %ld\n",
                     retired ? "RETIRED" : held ? "HELD" : "READY",
                     degraded ? "DEGRADED" : "OK", epoch,
                     (long)getpid(), (long)backup, (long)keeper);
            send_line(fd, answer);
        } else if (!strcmp(action, "EPOCH")) {
            snprintf(answer, sizeof(answer), "EPOCH %llu\n", epoch); send_line(fd, answer);
        } else {
            if (!strcmp(action, "CLOSE")) rc = nft_run_cmd_from_buffer(ctx, CLOSE);
            else if (!strcmp(action, "HOLD")) {
                rc = nft_run_cmd_from_buffer(ctx, CLOSE "; flush chain inet gd_offload guard; add rule inet gd_offload guard counter drop");
                if (!rc) held = 1;
            } else if (!strcmp(action, "RETIRE") && held && drain_ack()) {
                rc = nft_run_cmd_from_buffer(ctx, "delete flowtable inet gd_offload direct");
                if (!rc) retired = 1;
            } else if (!strcmp(action, "CONFIGURE") && retired && held) {
                rc = nft_run_cmd_from_filename(ctx, DIR "/policy.nft");
                if (!rc) retired = 0;
            } else if (!strcmp(action, "RELEASE") && held && !degraded && !retired) {
                rc = nft_run_cmd_from_filename(ctx, DIR "/admission.nft");
                if (!rc) rc = nft_run_cmd_from_buffer(ctx, "flush chain inet gd_offload guard");
                if (!rc) held = 0;
            } else if (!strcmp(action, "OPEN") && !degraded && !held && !retired) {
                rc = nft_run_cmd_from_filename(ctx, DIR "/admission.nft");
            } else if (!strcmp(action, "RECOVER") && held && retired && drain_ack()) {
                /* Replenish both holders only after hardware was revoked. */
                standby = 0;
                if (backup > 0) { kill(backup, SIGKILL); waitpid(backup, NULL, 0); }
                if (keeper > 0) { kill(keeper, SIGKILL); waitpid(keeper, NULL, 0); }
                backup = keeper = -1;
                rc = spawn_backup() || spawn_keeper();
                if (!rc) rc = generation();
                if (!rc) degraded = 0;
            }
            send_line(fd, rc ? "ERR\n" : "OK\n");
        }
        close(fd);
    }
}
int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    // OpenWrt sstrips installed libraries. Resolve the public API at runtime so
    // a build needs only the musl SDK, not unstripped target development files.
    void *library = dlopen("libnftables.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!library) { fputs(dlerror(), stderr); return 2; }
    nft_ctx_new = dlsym(library, "nft_ctx_new");
    nft_run_cmd_from_filename = dlsym(library, "nft_run_cmd_from_filename");
    nft_run_cmd_from_buffer = dlsym(library, "nft_run_cmd_from_buffer");
    if (!nft_ctx_new || !nft_run_cmd_from_filename || !nft_run_cmd_from_buffer) return 2;
    if (argc == 2 && !strcmp(argv[1], "--version")) {
        puts("getdomains-offload-owner 1"); return 0;
    }
    if (argc == 3 && (!strcmp(argv[1], "--client") || !strcmp(argv[1], "--wire"))) {
        char answer[160], cmd[256];
        const char *command = argv[2];
        if (!strcmp(argv[1], "--client") && strcmp(command, "STATUS") && strcmp(command, "EPOCH")) {
            if (exchange("EPOCH", answer, sizeof(answer)) || strncmp(answer, "EPOCH ", 6)) return 2;
            int n = snprintf(cmd, sizeof(cmd), "DO %s %s", answer + 6, command);
            if (n < 0 || (size_t)n >= sizeof(cmd)) return 2;
            command = cmd;
        }
        if (exchange(command, answer, sizeof(answer))) return 2;
        puts(answer); return !strcmp(answer, "ERR") || !strcmp(answer, "STALE");
    }
    if (argc != 2 || strcmp(argv[1], "--serve") || getuid()) return 2;
    state = mmap(NULL, sizeof(*state), PROT_READ | PROT_WRITE,
                 MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (state == MAP_FAILED) return 2;
    backup = keeper = -1;
    state->active = getpid();
    umask(0077);
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    strcpy(addr.sun_path, SOCK);
    listener = socket(AF_UNIX, SOCK_STREAM, 0);
    /* An existing socket must be recovered; never unlink a live owner's name. */
    if (listener < 0 || bind(listener, (void *)&addr, sizeof(addr)) || listen(listener, 8) || generation()) return 2;
    ctx = nft_ctx_new(0);
    if (!ctx || nft_run_cmd_from_filename(ctx, DIR "/initial.nft") || spawn_backup() || spawn_keeper()) return 2;
    serve(); return 0;
}
