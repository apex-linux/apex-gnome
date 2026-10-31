// SPDX-License-Identifier: GPL-3.0-or-later
// A G2 shell that dies on a signal prints its frames to its log before the default action, so a
// crash leaves a backtrace even where the core goes to a pipe the container cannot reach.
#define _GNU_SOURCE
#include <execinfo.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define FRAMES 64

static const int fatal[] = {SIGSEGV, SIGBUS, SIGABRT, SIGFPE, SIGILL};
static char line[160];

static void put(const char *text)
{
    size_t length = strlen(text);

    while (length > 0) {
        ssize_t written = write(STDERR_FILENO, text, length);

        if (written <= 0)
            return;
        text += written;
        length -= (size_t)written;
    }
}

static void on_fatal(int signal_number)
{
    static volatile sig_atomic_t entered;
    void *frames[FRAMES];
    const char *name = sigabbrev_np(signal_number);
    sigset_t unblock;

    if (!entered++) {
        int count = backtrace(frames, FRAMES);

        put(line);
        put(name ? name : "?");
        put("\n");
        backtrace_symbols_fd(frames, count, STDERR_FILENO);
        put("APEXG2-CRASH end\n");
    }
    // SpiderMonkey's handler sits in front of this one and calls it, so resetting this one's
    // action is not enough: the default action goes back in, and the signal is let through.
    signal(signal_number, SIG_DFL);
    sigemptyset(&unblock);
    sigaddset(&unblock, signal_number);
    sigprocmask(SIG_UNBLOCK, &unblock, NULL);
    raise(signal_number);
}

__attribute__((constructor)) static void install(void)
{
    static char alternate[1 << 16];
    stack_t stack = {.ss_sp = alternate, .ss_size = sizeof(alternate)};
    struct sigaction action = {.sa_handler = on_fatal, .sa_flags = SA_ONSTACK};
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
        sigaction(fatal[i], &action, NULL);
}
