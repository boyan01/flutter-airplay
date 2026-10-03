// SPDX-License-Identifier: GPL-3.0-only
#define AIRPLAY_POSIX_IMPLEMENTATION
#include "posix.h"
#include <limits.h>
static SRWLOCK socket_lock = SRWLOCK_INIT;
static SOCKET handles[1024];
static unsigned char occupied[1024];
static SOCKET lookup(int descriptor) {
    SOCKET result = INVALID_SOCKET;
    AcquireSRWLockShared(&socket_lock);
    if (descriptor > 0 && descriptor <= 1024 && occupied[descriptor - 1]) result = handles[descriptor - 1];
    ReleaseSRWLockShared(&socket_lock);
    if (result == INVALID_SOCKET) WSASetLastError(WSAENOTSOCK);
    return result;
}
static int retain(SOCKET handle) {
    if (handle == INVALID_SOCKET) return -1;
    AcquireSRWLockExclusive(&socket_lock);
    for (int i = 0; i < 1024; ++i) {
        if (!occupied[i]) { handles[i] = handle; occupied[i] = 1; ReleaseSRWLockExclusive(&socket_lock); return i + 1; }
    }
    ReleaseSRWLockExclusive(&socket_lock); closesocket(handle); WSASetLastError(WSAEMFILE); return -1;
}
char *strndup(const char *value, size_t limit) {
    const size_t length = strnlen(value, limit); char *copy = (char *)malloc(length + 1);
    if (copy) { memcpy(copy, value, length); copy[length] = 0; } return copy;
}
FILE *airplay_fopen(const char *path, const char *mode) {
    const int path_length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    const int mode_length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, mode, -1, NULL, 0);
    if (!path_length || !mode_length) { errno = EINVAL; return NULL; }
    wchar_t *wide_path = (wchar_t *)malloc((size_t)path_length * sizeof(wchar_t));
    wchar_t *wide_mode = (wchar_t *)malloc((size_t)mode_length * sizeof(wchar_t));
    if (!wide_path || !wide_mode) { free(wide_path); free(wide_mode); errno = ENOMEM; return NULL; }
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide_path, path_length);
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, mode, -1, wide_mode, mode_length);
    FILE *file = _wfopen(wide_path, wide_mode); free(wide_path); free(wide_mode); return file;
}
int airplay_socket(int family, int type, int protocol) { return retain(socket(family, type, protocol)); }
int airplay_accept(int descriptor, struct sockaddr *address, int *length) { return retain(accept(lookup(descriptor), address, length)); }
int airplay_bind(int descriptor, const struct sockaddr *address, int length) { return bind(lookup(descriptor), address, length); }
int airplay_connect(int descriptor, const struct sockaddr *address, int length) { return connect(lookup(descriptor), address, length); }
int airplay_listen(int descriptor, int count) { return listen(lookup(descriptor), count); }
int airplay_getsockname(int descriptor, struct sockaddr *address, int *length) { return getsockname(lookup(descriptor), address, length); }
int airplay_setsockopt(int descriptor, int level, int option, const char *value, int length) {
    if (level == SOL_SOCKET && option == SO_REUSEADDR && length == 1) {
        BOOL enabled = *value != 0; return setsockopt(lookup(descriptor), level, option, (const char *)&enabled, sizeof(enabled));
    }
    return setsockopt(lookup(descriptor), level, option, value, length);
}
int airplay_shutdown(int descriptor, int how) { return shutdown(lookup(descriptor), how); }
int airplay_closesocket(int descriptor) {
    SOCKET handle = INVALID_SOCKET;
    AcquireSRWLockExclusive(&socket_lock);
    if (descriptor > 0 && descriptor <= 1024 && occupied[descriptor - 1]) {
        handle = handles[descriptor - 1]; occupied[descriptor - 1] = 0;
    }
    ReleaseSRWLockExclusive(&socket_lock);
    if (handle == INVALID_SOCKET) { WSASetLastError(WSAENOTSOCK); return -1; }
    return closesocket(handle);
}
int airplay_ioctlsocket(int descriptor, long command, u_long *value) { return ioctlsocket(lookup(descriptor), command, value); }
static int receive_result(int result) {
    if (result == SOCKET_ERROR && WSAGetLastError() == WSAETIMEDOUT) WSASetLastError(WSAEWOULDBLOCK);
    return result;
}
int airplay_recv(int descriptor, char *bytes, int length, int flags) { return receive_result(recv(lookup(descriptor), bytes, length, flags)); }
int airplay_recvfrom(int descriptor, char *bytes, int length, int flags, struct sockaddr *address, int *size) {
    return receive_result(recvfrom(lookup(descriptor), bytes, length, flags, address, size));
}
int airplay_send(int descriptor, const char *bytes, int length, int flags) { return send(lookup(descriptor), bytes, length, flags); }
int airplay_sendto(int descriptor, const char *bytes, int length, int flags, const struct sockaddr *address, int size) {
    return sendto(lookup(descriptor), bytes, length, flags, address, size);
}
void airplay_fd_set(int descriptor, fd_set *set) { const SOCKET handle = lookup(descriptor); if (handle != INVALID_SOCKET) FD_SET(handle, set); }
void airplay_fd_clear(int descriptor, fd_set *set) { const SOCKET handle = lookup(descriptor); if (handle != INVALID_SOCKET) FD_CLR(handle, set); }
int airplay_fd_isset(int descriptor, fd_set *set) { const SOCKET handle = lookup(descriptor); return handle != INVALID_SOCKET && FD_ISSET(handle, set); }
