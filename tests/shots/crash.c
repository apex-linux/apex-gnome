// SPDX-License-Identifier: GPL-3.0-or-later
// A G2 shell that dies on a signal prints its frames to its log before the default action, so a
// crash leaves a backtrace even where the core goes to a pipe the container cannot reach.
#define _GNU_SOURCE
#include <execinfo.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define FRAMES 64
#define WAIT_STEPS 200

static const int fatal[] = {SIGSEGV, SIGBUS, SIGABRT, SIGFPE, SIGILL};
static struct sigaction previous[NSIG];
static char line[160];
static int first_signal;
static int written;
static __thread int writing __attribute__((tls_model("initial-exec")));

static void put(const char *text)
{
    size_t length = strlen(text);

    while (length > 0) {
        ssize_t done = write(STDERR_FILENO, text, length);

        if (done <= 0)
            return;
        text += done;
        length -= (size_t)done;
    }
}

static void die(int signal_number)
{
    struct sigaction default_action = {.sa_handler = SIG_DFL};
    sigset_t unblock;

    sigemptyset(&default_action.sa_mask);
    sigaction(signal_number, &default_action, NULL);
    sigemptyset(&unblock);
    sigaddset(&unblock, signal_number);
    sigprocmask(SIG_UNBLOCK, &unblock, NULL);
    raise(signal_number);
}

static void on_fatal(int signal_number, siginfo_t *info, void *context)
{
    int none = 0;
    void *frames[FRAMES];
    const char *name = sigabbrev_np(signal_number);
    const struct sigaction *earlier = &previous[signal_number];

    if (!__atomic_compare_exchange_n(&first_signal, &none, signal_number, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        // The unwinder faulted under this handler, or another thread crashed first: its signal decides.
        struct timespec step = {.tv_nsec = 10 * 1000 * 1000};

        for (int i = 0; !writing && i < WAIT_STEPS && !__atomic_load_n(&written, __ATOMIC_ACQUIRE); i++)
            nanosleep(&step, NULL);
        die(__atomic_load_n(&first_signal, __ATOMIC_ACQUIRE));
        return;
    }
    writing = 1;
    put(line);
    put(name ? name : "?");
    put("\n");
    backtrace_symbols_fd(frames, backtrace(frames, FRAMES), STDERR_FILENO);
    put("APEXG2-CRASH end\n");
    __atomic_store_n(&written, 1, __ATOMIC_RELEASE);
    writing = 0;
    if (earlier->sa_flags & SA_SIGINFO ? earlier->sa_sigaction != NULL :
        earlier->sa_handler != SIG_DFL && earlier->sa_handler != SIG_IGN) {
        __atomic_store_n(&written, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&first_signal, 0, __ATOMIC_RELEASE);
        if (earlier->sa_flags & SA_SIGINFO)
            earlier->sa_sigaction(signal_number, info, context);
        else
            earlier->sa_handler(signal_number);
        return;
    }
    die(signal_number);
}

__attribute__((constructor)) static void install(void)
{
    static char alternate[1 << 16];
    stack_t stack = {.ss_sp = alternate, .ss_size = sizeof(alternate)};
    struct sigaction action = {.sa_sigaction = on_fatal, .sa_flags = SA_SIGINFO | SA_ONSTACK};
    char comm[32] = "?";
    FILE *file = fopen("/proc/self/comm", "r");
    void *warm[1];

    if (file) {
        if (fgets(comm, sizeof(comm), file))
            comm[strcspn(comm, "\n")] = '\0';
        fclose(file);
    }
    snprintf(line, sizeof(line), "APEXG2-CRASH %s[%d] SIG", comm, (int)getpid());
    // backtrace() loads libgcc on its first call, which must not happen inside the handler.
    backtrace(warm, 1);
    sigaltstack(&stack, NULL);
    sigemptyset(&action.sa_mask);
    for (size_t i = 0; i < sizeof(fatal) / sizeof(fatal[0]); i++)
        sigaction(fatal[i], &action, &previous[fatal[i]]);
}
