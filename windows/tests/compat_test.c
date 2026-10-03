// SPDX-License-Identifier: GPL-3.0-only
#include "posix.h"
#undef NDEBUG
#include <assert.h>
struct signal_context { pthread_cond_t *condition; pthread_mutex_t *mutex; int signalled; };
static void *signal_thread(void *opaque) {
    struct signal_context *context = (struct signal_context *)opaque;
    pthread_mutex_lock(context->mutex); context->signalled = 1;
    pthread_cond_signal(context->condition); pthread_mutex_unlock(context->mutex); return NULL;
}
int main(void) {
    WSADATA data; assert(WSAStartup(MAKEWORD(2, 2), &data) == 0);
    const int descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP); assert(descriptor > 0);
    struct sockaddr_in address = {0}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(descriptor, (const struct sockaddr *)&address, sizeof(address)) == 0);
    int length = sizeof(address); assert(getsockname(descriptor, (struct sockaddr *)&address, &length) == 0);
    const char packet[] = "loopback";
    assert(sendto(descriptor, packet, sizeof(packet), 0, (const struct sockaddr *)&address, length) == sizeof(packet));
    fd_set set; FD_ZERO(&set); FD_SET(descriptor, &set); struct timeval timeout = {1, 0};
    assert(select(descriptor + 1, &set, NULL, NULL, &timeout) == 1 && FD_ISSET(descriptor, &set));
    char bytes[16]; assert(recvfrom(descriptor, bytes, sizeof(bytes), 0, NULL, NULL) == sizeof(packet));
    assert(memcmp(bytes, packet, sizeof(packet)) == 0); assert(closesocket(descriptor) == 0);
    pthread_mutex_t mutex; pthread_cond_t condition; pthread_t thread;
    pthread_mutex_init(&mutex, NULL); pthread_cond_init(&condition, NULL); pthread_mutex_lock(&mutex);
    struct signal_context context = {&condition, &mutex, 0};
    assert(pthread_create(&thread, NULL, signal_thread, &context) == 0);
    struct timespec deadline; clock_gettime(CLOCK_REALTIME, &deadline); deadline.tv_sec += 2;
    while (!context.signalled) assert(pthread_cond_timedwait(&condition, &mutex, &deadline) == 0);
    pthread_mutex_unlock(&mutex); pthread_join(thread, NULL); pthread_mutex_destroy(&mutex);
    pthread_cond_destroy(&condition); WSACleanup(); puts("Win32 socket mapping, loopback and pthread adapters passed");
}
