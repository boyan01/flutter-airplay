// SPDX-License-Identifier: GPL-3.0-only
#include "posix.h"
#include <stdbool.h>
#include "httpd.h"
#include "netutils.h"
#undef NDEBUG
#include <assert.h>

static void quiet_log(void *context, int level, const char *message) {
    (void)context; (void)level; (void)message;
}
static void *connected(void *context, unsigned char *local, int local_length,
                       unsigned char *remote, int remote_length, unsigned int zone) {
    (void)local; (void)local_length; (void)remote; (void)remote_length; (void)zone;
    return context;
}
static void request(void *context, http_request_t *input, http_response_t **output) {
    (void)context;
    assert(strcmp(http_request_get_method(input), "GET") == 0);
    assert(strcmp(http_request_get_url(input), "/probe") == 0);
    *output = http_response_create();
    assert(*output);
    http_response_init(*output, "HTTP/1.1", 200, "OK");
    http_response_set_disconnect(*output, 1);
    http_response_finish(*output, "ready", 5);
}
static void disconnected(void *context) { (void)context; }

int main(void) {
    assert(netutils_init() == 0);
    logger_t *logger = logger_init(); assert(logger);
    logger_set_callback(logger, quiet_log, NULL);
    httpd_callbacks_t callbacks = {logger, connected, request, disconnected};
    for (int cycle = 0; cycle < 2; ++cycle) {
        httpd_t *server = httpd_init(logger, &callbacks, 1); assert(server);
        assert(!httpd_is_running(server));
        unsigned short port = 0;
        assert(httpd_start(server, &port) == 1 && port);
        assert(httpd_is_running(server));
        const int client = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP); assert(client > 0);
        struct sockaddr_in address = {0}; address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons(port);
        assert(connect(client, (const struct sockaddr *)&address, sizeof(address)) == 0);
        const char probe[] = "GET /probe HTTP/1.1\r\nHost: localhost\r\n\r\n";
        assert(send(client, probe, sizeof(probe) - 1, 0) == sizeof(probe) - 1);
        char response[512] = {0}; size_t received = 0;
        for (;;) {
            fd_set ready; FD_ZERO(&ready); FD_SET(client, &ready);
            struct timeval timeout = {2, 0};
            assert(select(client + 1, &ready, NULL, NULL, &timeout) == 1);
            const int count = recv(client, response + received, sizeof(response) - 1 - received, 0);
            assert(count >= 0);
            if (!count) break;
            received += count; assert(received < sizeof(response) - 1);
        }
        assert(strstr(response, "HTTP/1.1 200 OK") && strstr(response, "ready"));
        assert(closesocket(client) == 0);
        httpd_stop(server); assert(!httpd_is_running(server));
        httpd_destroy(server);
    }
    logger_destroy(logger); netutils_cleanup();
    puts("Windows HTTP listener initialization, loopback request and teardown passed");
}
