// SPDX-License-Identifier: GPL-3.0-or-later
// G2's fixed wall clock: reads of the realtime clock return G2_CLOCK_EPOCH, and only timerfds
// on that clock move with it (libfaketime moves every timer, mutter's monotonic frame timer too).
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <sys/time.h>
#include <sys/timerfd.h>
#include <time.h>

static int (*real_clock_gettime)(clockid_t, struct timespec *);
static int (*real_gettimeofday)(struct timeval *restrict, void *restrict);
static time_t (*real_time)(time_t *);
static int (*real_timespec_get)(struct timespec *, int);
static int (*real_timerfd_create)(int, int);
static int (*real_timerfd_settime)(int, int, const struct itimerspec *, struct itimerspec *);
static unsigned char realtime_timerfd[65536];

// Other libraries' constructors may read the clock before this one's would run.
static long long fixed_epoch(void)
{
    static long long epoch = -1;

    if (__atomic_load_n(&epoch, __ATOMIC_ACQUIRE) < 0) {
        const char *value = getenv("G2_CLOCK_EPOCH");

        real_clock_gettime = (int (*)(clockid_t, struct timespec *))dlsym(RTLD_NEXT, "clock_gettime");
        real_gettimeofday = (int (*)(struct timeval *restrict, void *restrict))dlsym(RTLD_NEXT, "gettimeofday");
        real_time = (time_t (*)(time_t *))dlsym(RTLD_NEXT, "time");
        real_timespec_get = (int (*)(struct timespec *, int))dlsym(RTLD_NEXT, "timespec_get");
        real_timerfd_create = (int (*)(int, int))dlsym(RTLD_NEXT, "timerfd_create");
        real_timerfd_settime = (int (*)(int, int, const struct itimerspec *, struct itimerspec *))
            dlsym(RTLD_NEXT, "timerfd_settime");
        __atomic_store_n(&epoch, value ? atoll(value) : 0, __ATOMIC_RELEASE);
    }
    return __atomic_load_n(&epoch, __ATOMIC_ACQUIRE);
}

int clock_gettime(clockid_t clock, struct timespec *ts)
{
    long long epoch = fixed_epoch();

    if (epoch > 0 && (clock == CLOCK_REALTIME || clock == CLOCK_REALTIME_COARSE)) {
        ts->tv_sec = (time_t)epoch;
        ts->tv_nsec = 0;
        return 0;
    }
    return real_clock_gettime(clock, ts);
}

int gettimeofday(struct timeval *restrict tv, void *restrict tz)
{
    long long epoch = fixed_epoch();
    int result = real_gettimeofday(tv, tz);

    if (epoch > 0 && result == 0) {
        tv->tv_sec = (time_t)epoch;
        tv->tv_usec = 0;
    }
    return result;
}

time_t time(time_t *out)
{
    long long epoch = fixed_epoch();

    if (epoch <= 0)
        return real_time(out);
    if (out)
        *out = (time_t)epoch;
    return (time_t)epoch;
}

int timespec_get(struct timespec *ts, int base)
{
    long long epoch = fixed_epoch();

    if (epoch <= 0 || base != TIME_UTC)
        return real_timespec_get(ts, base);
    ts->tv_sec = (time_t)epoch;
    ts->tv_nsec = 0;
    return base;
}

int timerfd_create(int clock, int flags)
{
    int fd;

    fixed_epoch();
    fd = real_timerfd_create(clock, flags);
    if (fd >= 0 && fd < (int)sizeof(realtime_timerfd))
        __atomic_store_n(&realtime_timerfd[fd], clock == CLOCK_REALTIME, __ATOMIC_RELEASE);
    return fd;
}

// GnomeWallClock arms one for the next minute: unmoved, it is already due and fires forever.
// gnome-shell's time-change source tries -1 (refused) and then 2106: neither may move.
int timerfd_settime(int fd, int flags, const struct itimerspec *value, struct itimerspec *old)
{
    long long epoch = fixed_epoch();
    struct itimerspec moved;
    struct timespec now;

    if (epoch <= 0 || !(flags & TFD_TIMER_ABSTIME) || fd < 0 || fd >= (int)sizeof(realtime_timerfd) ||
        !__atomic_load_n(&realtime_timerfd[fd], __ATOMIC_ACQUIRE) ||
        value->it_value.tv_sec < 0 || value->it_value.tv_nsec < 0 || value->it_value.tv_nsec >= 1000000000L ||
        (value->it_value.tv_sec == 0 && value->it_value.tv_nsec == 0))
        return real_timerfd_settime(fd, flags, value, old);
    real_clock_gettime(CLOCK_REALTIME, &now);
    moved = *value;
    moved.it_value.tv_nsec += now.tv_nsec;
    if (moved.it_value.tv_nsec >= 1000000000L) {
        moved.it_value.tv_nsec -= 1000000000L;
        now.tv_sec++;
    }
    if (__builtin_add_overflow(value->it_value.tv_sec, now.tv_sec - (time_t)epoch, &moved.it_value.tv_sec))
        return real_timerfd_settime(fd, flags, value, old);
    return real_timerfd_settime(fd, flags, &moved, old);
}
