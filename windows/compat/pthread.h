// SPDX-License-Identifier: GPL-3.0-only
// The receive core only needs joinable threads, mutexes and timed conditions.
#pragma once
#include <winsock2.h>
#include <windows.h>
#include <time.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <process.h>

typedef HANDLE pthread_t;
typedef CRITICAL_SECTION pthread_mutex_t;
typedef CONDITION_VARIABLE pthread_cond_t;
struct airplay_thread_start { void *(*run)(void *); void *context; };
static unsigned __stdcall airplay_thread_entry(void *opaque) {
    struct airplay_thread_start *start = (struct airplay_thread_start *)opaque;
    void *(*run)(void *) = start->run; void *context = start->context;
    free(start); run(context); return 0;
}
static inline int pthread_create(pthread_t *thread, const void *attributes, void *(*run)(void *), void *context) {
    (void)attributes;
    struct airplay_thread_start *start = (struct airplay_thread_start *)malloc(sizeof(*start));
    if (!start) return ENOMEM;
    start->run = run; start->context = context;
    *thread = (HANDLE)_beginthreadex(NULL, 0, airplay_thread_entry, start, 0, NULL);
    if (!*thread) { free(start); return EAGAIN; }
    return 0;
}
static inline int pthread_join(pthread_t thread, void **result) {
    (void)result; if (!thread) return EINVAL;
    const DWORD status = WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread); return status == WAIT_OBJECT_0 ? 0 : EINVAL;
}
static inline int pthread_mutex_init(pthread_mutex_t *mutex, const void *attributes) {
    (void)attributes; InitializeCriticalSection(mutex); return 0;
}
static inline int pthread_mutex_lock(pthread_mutex_t *mutex) { EnterCriticalSection(mutex); return 0; }
static inline int pthread_mutex_unlock(pthread_mutex_t *mutex) { LeaveCriticalSection(mutex); return 0; }
static inline int pthread_mutex_destroy(pthread_mutex_t *mutex) { DeleteCriticalSection(mutex); return 0; }
static inline int pthread_cond_init(pthread_cond_t *condition, const void *attributes) {
    (void)attributes; InitializeConditionVariable(condition); return 0;
}
static inline int pthread_cond_signal(pthread_cond_t *condition) { WakeConditionVariable(condition); return 0; }
static inline int pthread_cond_destroy(pthread_cond_t *condition) { (void)condition; return 0; }
#ifndef CLOCK_REALTIME
#define CLOCK_REALTIME 0
#define CLOCK_MONOTONIC 1
#endif
static inline int clock_gettime(int kind, struct timespec *time) {
    if (!time) { errno = EINVAL; return -1; }
    if (kind == CLOCK_MONOTONIC) {
        LARGE_INTEGER ticks, frequency; QueryPerformanceCounter(&ticks); QueryPerformanceFrequency(&frequency);
        time->tv_sec = (time_t)(ticks.QuadPart / frequency.QuadPart);
        time->tv_nsec = (long)((ticks.QuadPart % frequency.QuadPart) * 1000000000 / frequency.QuadPart);
    } else if (kind == CLOCK_REALTIME) {
        FILETIME raw; ULARGE_INTEGER ticks;
        GetSystemTimePreciseAsFileTime(&raw); ticks.LowPart = raw.dwLowDateTime; ticks.HighPart = raw.dwHighDateTime;
        const uint64_t unix_ticks = ticks.QuadPart - 116444736000000000ULL;
        time->tv_sec = (time_t)(unix_ticks / 10000000); time->tv_nsec = (long)(unix_ticks % 10000000) * 100;
    } else { errno = EINVAL; return -1; }
    return 0;
}
static inline int pthread_cond_timedwait(pthread_cond_t *condition, pthread_mutex_t *mutex, const struct timespec *deadline) {
    struct timespec now; clock_gettime(CLOCK_REALTIME, &now);
    const int64_t remaining = ((int64_t)deadline->tv_sec - now.tv_sec) * 1000000000 + deadline->tv_nsec - now.tv_nsec;
    DWORD milliseconds = remaining > 0 ? (DWORD)((remaining + 999999) / 1000000) : 0;
    if (SleepConditionVariableCS(condition, mutex, milliseconds)) return 0;
    return GetLastError() == ERROR_TIMEOUT ? ETIMEDOUT : EINVAL;
}
