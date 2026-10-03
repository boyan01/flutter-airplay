// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "pthread.h"
#ifndef SOL_TCP
#define SOL_TCP IPPROTO_TCP
#endif
char *strndup(const char *, size_t);
FILE *airplay_fopen(const char *, const char *);
#ifndef strdup
#define strdup _strdup
#endif
#ifndef strcasecmp
#define strcasecmp _stricmp
#define strncasecmp _strnicmp
#endif
// UxPlay stores descriptors in int. Map them to SOCKET rather than truncate
// Windows' pointer-sized handles; fd_sets continue to contain actual SOCKETs.
int airplay_socket(int, int, int);
int airplay_accept(int, struct sockaddr *, int *);
int airplay_bind(int, const struct sockaddr *, int);
int airplay_connect(int, const struct sockaddr *, int);
int airplay_listen(int, int);
int airplay_getsockname(int, struct sockaddr *, int *);
int airplay_setsockopt(int, int, int, const char *, int);
int airplay_shutdown(int, int);
int airplay_closesocket(int);
int airplay_ioctlsocket(int, long, u_long *);
int airplay_recv(int, char *, int, int);
int airplay_recvfrom(int, char *, int, int, struct sockaddr *, int *);
int airplay_send(int, const char *, int, int);
int airplay_sendto(int, const char *, int, int, const struct sockaddr *, int);
void airplay_fd_set(int, fd_set *);
void airplay_fd_clear(int, fd_set *);
int airplay_fd_isset(int, fd_set *);
#ifndef AIRPLAY_POSIX_IMPLEMENTATION
#define socket airplay_socket
#define accept airplay_accept
#define bind airplay_bind
#define connect airplay_connect
#define listen airplay_listen
#define getsockname airplay_getsockname
#define setsockopt airplay_setsockopt
#define shutdown airplay_shutdown
#define closesocket airplay_closesocket
#define ioctlsocket airplay_ioctlsocket
#define recv airplay_recv
#define recvfrom airplay_recvfrom
#define send airplay_send
#define sendto airplay_sendto
#define fopen airplay_fopen
#undef FD_SET
#undef FD_CLR
#undef FD_ISSET
#define FD_SET(fd, set) airplay_fd_set(fd, set)
#define FD_CLR(fd, set) airplay_fd_clear(fd, set)
#define FD_ISSET(fd, set) airplay_fd_isset(fd, set)
#endif
