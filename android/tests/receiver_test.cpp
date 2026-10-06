// SPDX-License-Identifier: GPL-3.0-or-later
#include "receiver.h"
#include "dns_sd.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cassert>
#include <cstring>
#include <iostream>
#include <string>
static std::string request(int port, const char *text) {
    int fd = socket(AF_INET, SOCK_STREAM, 0); assert(fd >= 0);
    timeval timeout{3, 0}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    sockaddr_in addr{}; addr.sin_family = AF_INET; addr.sin_port = htons(port);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    assert(connect(fd, (sockaddr *)&addr, sizeof(addr)) == 0);
    assert(send(fd, text, strlen(text), 0) == (ssize_t)strlen(text));
    char bytes[32768]; ssize_t n = recv(fd, bytes, sizeof(bytes), 0);
    assert(n > 0); close(fd); return std::string(bytes, (size_t)n);
}
int main(int argc, char **argv) {
    TXTRecordRef txt; TXTRecordCreate(&txt, 0, nullptr);
    assert(TXTRecordSetValue(&txt, "pw", 5, "false") == 0);
    assert(TXTRecordSetValue(&txt, "pw", 4, "true") == 0);
    assert(TXTRecordGetLength(&txt) == 8);
    assert(!memcmp((const char *)TXTRecordGetBytesPtr(&txt) + 1, "pw=true", 7));
    assert(TXTRecordSetValue(&txt, "a=b", 1, "x") == -1);
    TXTRecordDeallocate(&txt);
    // Destruction must also work before raop_init2 creates the HTTP server.
    raop_callbacks_t callbacks{};
    callbacks.audio_process = [](void *, raop_ntp_t *, audio_decode_struct *) {};
    callbacks.video_process = [](void *, raop_ntp_t *, video_decode_struct *) {};
    for (int i = 0; i < 3; ++i) {
        raop_t *partial = raop_init(&callbacks);
        assert(partial);
        raop_destroy(partial);
    }
    // DNS object metadata survives unregister and is released by destroy.
    const char name[] = "Synthetic lifetime";
    const char address[6] = {2, 0, 0, 0, 0, 1};
    char public_key[] = "00112233445566778899aabbccddeeff";
    int error = 0;
    dnssd_t *dns = dnssd_init(name, sizeof(name) - 1, address, sizeof(address), &error, 0);
    assert(dns && error == 0);
    dnssd_set_pk(dns, public_key);
    for (int i = 0; i < 3; ++i) {
        assert(dnssd_register_raop(dns, 7000) == 0);
        assert(dnssd_register_airplay(dns, 7000) == 0);
        dnssd_unregister_raop(dns);
        dnssd_unregister_airplay(dns);
        int length = 0;
        assert(!memcmp(dnssd_get_name(dns, &length), name, sizeof(name) - 1));
        assert(length == sizeof(name) - 1);
        assert(!memcmp(dnssd_get_hw_addr(dns, &length), address, sizeof(address)));
        assert(length == sizeof(address));
    }
    dnssd_destroy(dns);
    dns = dnssd_init(name, sizeof(name) - 1, address, sizeof(address), &error, 0);
    assert(dns && error == 0);
    dnssd_destroy(dns);
    std::cout << "PASS: partial receiver destruction and DNS unregister/re-register lifetime\n";
    airplay::Receiver receiver;
    uint8_t identity[6] = {2, 0, 0, 0, 0, 1};
    assert(receiver.start("", identity, "") == -1);
    if (argc == 2 && !strcmp(argv[1], "--expect-bind-failure")) {
        // Run only in an environment that denies listener creation. This
        // exercises real partial core startup and DNS storage cleanup.
        for (int i = 0; i < 3; i++) {
            assert(receiver.start("Synthetic denied bind", identity, "") == -1);
            receiver.stop(); receiver.stop();
        }
        std::cout << "PASS: denied-bind partial startup and 3 cleanup/retry cycles\n";
        return 0;
    }
    for (int i = 0; i < 3; ++i) {
        int port = receiver.start("Synthetic Android core", identity, ""); assert(port > 0);
        assert(receiver.start("duplicate", identity, "") == -1);
        auto info = request(port, "GET /info RTSP/1.0\r\nCSeq: 1\r\n\r\n");
        assert(info.find("200 OK") != std::string::npos);
        assert(info.find("application/x-apple-binary-plist") != std::string::npos);
        auto options = request(port, "OPTIONS * RTSP/1.0\r\nCSeq: 2\r\n\r\n");
        assert(options.find("200 OK") != std::string::npos);
        assert(options.find("Public:") != std::string::npos);
        assert(!receiver.txt(false).empty() && !receiver.txt(true).empty());
        receiver.stop(); receiver.stop(); assert(receiver.txt(false).empty());
    }
    std::cout << "PASS: TXT replacement, real core /info + OPTIONS and 3 receiver lifecycles\n";
}
