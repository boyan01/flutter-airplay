/* Exercise the real RTP stop/start lifecycle with loopback and synthetic keys. */
#include <stdio.h>
#include <stdatomic.h>
#include "raop_rtp.c"
#undef SECOND_IN_NSECS
#include "raop_rtp_mirror.c"
static void require(bool condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
    printf("PASS: %s\n", message);
}
static void capture(void *context, int level, const char *message) { puts(message); }
static atomic_int delivered;
static atomic_int last_sequence;
static atomic_int flushed;
static atomic_int stopped;
static void audio_stopped(void *context) { atomic_fetch_add(&stopped, 1); }
static void test_hevc_configuration(void) {
    unsigned char payload[0x75 + 3 * 7] = {0};
    const unsigned char *parameters[3]; size_t sizes[3];
    for (int i = 0; i < 3; i++) {
        unsigned char *array = payload + 0x75 + i * 7;
        array[0] = 0xa0 + i; array[2] = 1; array[4] = 2;
        array[5] = (32 + i) << 1; array[6] = 1;
    }
    require(read_hevc_parameters(payload, sizeof(payload), parameters, sizes), "Valid HEVC parameter arrays accepted");
    for (int i = 0; i < 3; i++)
        require(sizes[i] == 2 && parameters[i] == payload + 0x75 + i * 7 + 5,
                "HEVC parameter sizes and pointers preserve the input");
    for (size_t size = 0; size < sizeof(payload); size++)
        if (read_hevc_parameters(payload, size, parameters, sizes)) {
            fprintf(stderr, "FAIL: truncated HEVC configuration accepted at %zu\n", size); exit(1);
        }
    require(true, "Every HEVC configuration truncation rejected");
    payload[0x75 + 3] = 0xff; payload[0x75 + 4] = 0xff;
    require(!read_hevc_parameters(payload, sizeof(payload), parameters, sizes), "Oversized HEVC parameter length rejected");
    payload[0x75 + 3] = 0; payload[0x75 + 4] = 0;
    require(!read_hevc_parameters(payload, sizeof(payload), parameters, sizes), "Empty HEVC parameter rejected");
}
static void receive_flush(void *context) { atomic_fetch_add(&flushed, 1); }
static void receive_audio(void *context, raop_ntp_t *ntp, audio_decode_struct *data) {
    atomic_store(&last_sequence, data->seqnum);
    atomic_fetch_add(&delivered, 1);
}
static void send_audio(int socket, unsigned short port, unsigned short sequence, int length) {
    unsigned char packet[28] = {0x80, 0x60};
    packet[2] = sequence >> 8;
    packet[3] = sequence & 0xff;
    uint32_t timestamp = (uint32_t) sequence * 480;
    for (int i = 0; i < 4; i++) packet[4 + i] = timestamp >> (24 - 8 * i);
    if (length == 16) memcpy(packet + 12, "\x00\x68\x34\x00", 4);
    struct sockaddr_in target = {0};
    target.sin_family = AF_INET;
    target.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    target.sin_port = htons(port);
    require(sendto(socket, packet, length, 0, (struct sockaddr *) &target, sizeof(target)) == length,
            "Synthetic RTP packet sent over loopback");
}
static bool wait_count(atomic_int *counter, int count) {
    uint64_t deadline = raop_ntp_get_local_time() + 100000000ULL;
    while (atomic_load(counter) < count && raop_ntp_get_local_time() < deadline) usleep(1000);
    return atomic_load(counter) >= count;
}
static void test_ntp_synchronization(logger_t *log) {
    unsigned short port = 0;
    int sender = netutils_init_socket(&port, 0, 1);
    require(sender >= 0, "Synthetic NTP sender opened");
    struct timeval timeout = {1, 0};
    require(setsockopt(sender, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0,
            "Synthetic NTP sender has a bounded receive timeout");
    raop_callbacks_t cb = {0};
    timing_protocol_t protocol = NTP;
    raop_ntp_t *ntp = raop_ntp_init(log, &cb, "127.0.0.1", 4, port, &protocol);
    require(ntp != NULL, "NTP client initialized");
    uint64_t now = raop_ntp_get_local_time();
    require(raop_ntp_get_remote_time(ntp) == 0 &&
            raop_ntp_convert_local_time(ntp, now) == 0 &&
            raop_ntp_convert_remote_time(ntp, now) == 0,
            "Clock conversion waits for a valid timing response");
    unsigned short local_port = 0;
    raop_ntp_start(ntp, &local_port);
    unsigned char request[32], response[32] = {0x80, 0xd3};
    struct sockaddr_storage address;
    socklen_t address_len = sizeof(address);
    require(recvfrom(sender, request, sizeof(request), 0, (struct sockaddr *)&address, &address_len) == 32,
            "Real NTP request received over loopback");
    memcpy(response + 8, request + 24, 8);
    /* Model a sender whose clock counts from boot instead of the Unix epoch. */
    byteutils_put_ntp_timestamp(response, 16, 3600ULL * SECOND_IN_NSECS);
    byteutils_put_ntp_timestamp(response, 24, 3600ULL * SECOND_IN_NSECS);
    now = raop_ntp_get_local_time();
    require(sendto(sender, response, sizeof(response), 0, (struct sockaddr *)&address, address_len) == sizeof(response),
            "Synthetic sender replied with matching request reference");
    uint64_t deadline = now + SECOND_IN_NSECS;
    while (!raop_ntp_get_remote_time(ntp) && raop_ntp_get_local_time() < deadline) usleep(1000);
    uint64_t remote = raop_ntp_get_remote_time(ntp);
    require(remote != 0, "Valid NTP response enables remote clock conversion");
    uint64_t adjusted = raop_ntp_adjust_remote_timestamp_offset(ntp, byteutils_get_long_be(response, 24), false);
    uint64_t local = raop_ntp_convert_remote_time(ntp, raop_ntp_timestamp_to_nano_seconds(ntp, adjusted));
    require(llabs((int64_t)(local - now)) < 100000000LL,
            "Sender boot timestamp maps to local receive time within 100ms");
    remote = raop_ntp_convert_local_time(ntp, now);
    require(remote != 0 && raop_ntp_convert_remote_time(ntp, remote) == now,
            "Local and remote clock conversions round trip after synchronization");
    raop_ntp_destroy(ntp);
    CLOSESOCKET(sender);
}
static void test_audio_restart_failure(logger_t *log) {
    raop_callbacks_t cb = {0};
    unsigned char key[16] = {0}, iv[16] = {0};
    raop_rtp_t *audio = raop_rtp_init(log, &cb, NULL, "127.0.0.1", 4, key, iv);
    require(audio != NULL, "Restart failure audio transport initialized");
    unsigned short remote = 0, control = 0, data = 0;
    unsigned char ct = 8;
    unsigned int sr = 44100;
    raop_rtp_start_audio(audio, &remote, &control, &data, &ct, &sr);
    require(raop_rtp_is_running(audio), "Audio transport started before failed restart");
    raop_rtp_stop(audio);
    int holder = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET; address.sin_port = htons(control);
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    require(holder >= 0 && bind(holder, (struct sockaddr *)&address, sizeof(address)) == 0,
            "Previous control port occupied without address reuse");
    data = 0;
    raop_rtp_start_audio(audio, &remote, &control, &data, &ct, &sr);
    require(!raop_rtp_is_running(audio), "Occupied control port rejects restart without a crash");
    CLOSESOCKET(holder);
    control = data = 0;
    raop_rtp_start_audio(audio, &remote, &control, &data, &ct, &sr);
    require(raop_rtp_is_running(audio), "Audio retries successfully after failed port binding");
    raop_rtp_stop(audio);
    raop_rtp_destroy(audio);
}
static void test_sound_after_silence(logger_t *log) {
    const int stops_before = atomic_load(&stopped);
    raop_callbacks_t callbacks = {0};
    callbacks.audio_stop = audio_stopped;
    callbacks.audio_process = receive_audio;
    callbacks.audio_flush = receive_flush;
    unsigned char key[16] = {0}, iv[16] = {0};
    timing_protocol_t protocol = TP_NONE;
    raop_ntp_t *ntp = raop_ntp_init(log, &callbacks, "127.0.0.1", 4, 0, &protocol);
    require(ntp != NULL, "Synthetic sender timing initialized");
    uint64_t offset = 1;
    raop_ntp_set_video_arrival_offset(ntp, &offset);
    raop_rtp_t *audio = raop_rtp_init(log, &callbacks, ntp, "127.0.0.1", 4, key, iv);
    require(audio != NULL, "Synthetic sound-switch transport initialized");
    unsigned short remote_port = 9, control_port = 0, data_port = 0;
    unsigned char compression = 8;
    unsigned int sample_rate = 44100;
    raop_rtp_start_audio(audio, &remote_port, &control_port, &data_port, &compression, &sample_rate);
    int sender = socket(AF_INET, SOCK_DGRAM, 0);
    require(sender >= 0, "Synthetic audio sender opened");
    /* Register the sender's control socket so real resend requests have a target. */
    send_audio(sender, control_port, 99, 12);
    send_audio(sender, data_port, 100, 28);
    require(wait_count(&delivered, 1), "Audio before video switch delivered promptly");
    /* One AAC-ELD no-data marker between clips is enough to block the next sound. */
    send_audio(sender, data_port, 101, 16);
    send_audio(sender, data_port, 102, 28);
    require(wait_count(&delivered, 2) && atomic_load(&last_sequence) == 102,
            "First sound after no-data marker delivered within 100ms instead of waiting for 256 packets");
    /* Repeated markers and header-only silence must never reach the decoder. */
    for (int i = 0; i < 3; i++) send_audio(sender, data_port, 103, 16);
    send_audio(sender, data_port, 104, 12);
    send_audio(sender, data_port, 105, 28);
    require(wait_count(&delivered, 3) && atomic_load(&last_sequence) == 105,
            "Repeated and header-only silence skipped without decoding or delaying new sound");

    /* A real loss still waits for the missing packet, even with silence after it. */
    send_audio(sender, data_port, 107, 16);
    send_audio(sender, data_port, 108, 28);
    require(!wait_count(&delivered, 4), "Genuinely missing audio still waits for retransmission");
    send_audio(sender, data_port, 106, 28);
    require(wait_count(&delivered, 5) && atomic_load(&last_sequence) == 108,
            "Retransmission drains real audio across the no-data marker in order");

    raop_rtp_flush(audio, 10);
    require(wait_count(&flushed, 1), "Real RTP receive thread processed FLUSH");
    require(atomic_load(&stopped) == stops_before, "Temporary FLUSH does not end platform playback");
    send_audio(sender, data_port, 10, 28);
    require(wait_count(&delivered, 6) && atomic_load(&last_sequence) == 10,
            "New sound after FLUSH uses the sender's new sequence immediately");

    /* Exercise modular sequence numbers at the end of a long session. */
    raop_rtp_flush(audio, 65534);
    require(wait_count(&flushed, 2), "Wraparound FLUSH processed");
    send_audio(sender, data_port, 65534, 28);
    require(wait_count(&delivered, 7), "Audio before sequence wrap delivered");
    send_audio(sender, data_port, 65535, 16);
    send_audio(sender, data_port, 0, 28);
    require(wait_count(&delivered, 8) && atomic_load(&last_sequence) == 0,
            "Silence transition preserves audio across 16-bit sequence wrap");
    CLOSESOCKET(sender);
    raop_rtp_destroy(audio);
    require(atomic_load(&stopped) == stops_before + 1, "Transport destruction ends platform playback");
    raop_ntp_destroy(ntp);
}
static atomic_int video_configurations;
static atomic_int video_width;
static atomic_int video_height;
static atomic_int video_resets;
static void video_connection_reset(void *context, int reason) { atomic_fetch_add(&video_resets, 1); }
static int video_configuration(void *context, video_codec_t codec, unsigned short sw, unsigned short sh,
                               unsigned short x, unsigned short y, unsigned short w, unsigned short h) {
    if (codec != VIDEO_CODEC_H264 && codec != VIDEO_CODEC_H265) return -1;
    atomic_store(&video_width, sw);
    atomic_store(&video_height, sh);
    atomic_fetch_add(&video_configurations, 1);
    return 0;
}
static void send_video_configuration(int sender, unsigned short width, unsigned short height) {
    /* Minimal AVCDecoderConfigurationRecord: one two-byte SPS and PPS. */
    unsigned char payload[] = {1, 0x42, 0, 0x1e, 0xff, 0xe1, 0, 2, 0x67, 0, 1, 0, 2, 0x68, 0};
    unsigned char packet[128 + sizeof(payload)] = {0};
    packet[0] = sizeof(payload);
    packet[4] = 1;
    float w = width, h = height;
    memcpy(packet + 16, &w, sizeof(w)); memcpy(packet + 20, &h, sizeof(h));
    memcpy(packet + 40, &w, sizeof(w)); memcpy(packet + 44, &h, sizeof(h));
    memcpy(packet + 56, &w, sizeof(w)); memcpy(packet + 60, &h, sizeof(h));
    memcpy(packet + 128, payload, sizeof(payload));
    size_t sent = 0;
    while (sent < sizeof(packet)) {
        ssize_t n = send(sender, packet + sent, sizeof(packet) - sent, 0);
        require(n > 0, "Synthetic mirror configuration sent over TCP");
        sent += n;
    }
}
static void test_video_rotation(logger_t *log) {
    atomic_store(&video_configurations, 0);
    raop_callbacks_t cb = {0};
    cb.video_set_codec_and_size = video_configuration;
    timing_protocol_t protocol = TP_NONE;
    raop_ntp_t *ntp = raop_ntp_init(log, &cb, "127.0.0.1", 4, 0, &protocol);
    unsigned char key[16] = {0};
    raop_rtp_mirror_t *mirror = raop_rtp_mirror_init(log, &cb, ntp, "127.0.0.1", 4, key);
    require(ntp && mirror, "Synthetic mirror transport initialized");
    unsigned short port = 0;
    raop_rtp_mirror_start(mirror, &port, 0);
    int sender = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET; address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    require(sender >= 0 && port && connect(sender, (struct sockaddr *)&address, sizeof(address)) == 0,
            "Synthetic mirror sender connected");
    send_video_configuration(sender, 640, 360);
    require(wait_count(&video_configurations, 1) && atomic_load(&video_width) == 640 && atomic_load(&video_height) == 360,
            "Initial video codec and dimensions reach the host");
    send_video_configuration(sender, 360, 640);
    require(wait_count(&video_configurations, 2) && atomic_load(&video_width) == 360 && atomic_load(&video_height) == 640,
            "Rotation updates dimensions without reconnecting or changing codec");
    raop_rtp_mirror_destroy(mirror);
    CLOSESOCKET(sender);
    raop_ntp_destroy(ntp);
}
static void test_oversized_video_configuration(logger_t *log, bool hevc) {
    const int resets_before = atomic_load(&video_resets);
    raop_callbacks_t cb = {0};
    cb.video_set_codec_and_size = video_configuration;
    cb.conn_reset = video_connection_reset;
    timing_protocol_t protocol = TP_NONE;
    raop_ntp_t *ntp = raop_ntp_init(log, &cb, "127.0.0.1", 4, 0, &protocol);
    unsigned char key[16] = {0};
    raop_rtp_mirror_t *mirror = raop_rtp_mirror_init(log, &cb, ntp, "127.0.0.1", 4, key);
    require(ntp && mirror, "Oversized configuration mirror initialized");
    unsigned short port = 0;
    raop_rtp_mirror_start(mirror, &port, 0);
    int sender = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET; address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    require(sender >= 0 && port && connect(sender, (struct sockaddr *)&address, sizeof(address)) == 0,
            "Oversized configuration sender connected");
    unsigned char packet[128 + 1152 + 128 + 16] = {0};
    unsigned char *payload = packet + 128;
    size_t payload_size;
    if (hevc) {
        memcpy(payload + 4, "hvc1", 4);
        size_t offset = 0x75;
        for (int i = 0; i < 3; i++) {
            const size_t size = i == 0 ? 1016 : 2;
            payload[offset] = 0xa0 + i; payload[offset + 2] = 1;
            payload[offset + 3] = size >> 8; payload[offset + 4] = size & 0xff;
            payload[offset + 5] = (32 + i) << 1; payload[offset + 6] = 1;
            offset += 5 + size;
        }
        payload_size = offset;
    } else {
        /* Valid lengths whose Annex-B configuration occupies 1030 bytes. */
        const unsigned char header[] = {1, 0x42, 0, 0x1e, 0xff, 0xe1, 3, 0xfc};
        memcpy(payload, header, sizeof(header));
        payload[8] = 0x67; payload[1028] = 1;
        payload[1030] = 2; payload[1031] = 0x68;
        payload_size = 1033;
    }
    for (int i = 0; i < 4; i++) packet[i] = payload_size >> (8 * i);
    packet[4] = 1;
    size_t sent = 0, length = 128 + payload_size;
    /* Queue the next frame too: rejecting the configuration must prevent its use. */
    packet[length] = 16;
    length += 128 + 16;
    while (sent < length) {
        ssize_t n = send(sender, packet + sent, length - sent, 0);
        require(n > 0, "Oversized mirror configuration sent over TCP");
        sent += n;
    }
    require(wait_count(&video_resets, resets_before + 1),
            hevc ? "Oversized HEVC configuration ends the connection and reports reset"
                 : "Oversized H264 configuration ends the connection and reports reset");
    raop_rtp_mirror_stop(mirror);
    require(mirror->joined && mirror->mirror_data_sock == -1,
            "Rejected configuration thread is joined and listener released");
    CLOSESOCKET(sender);
    port = 0;
    raop_rtp_mirror_start(mirror, &port, 0);
    require(port != 0 && !mirror->joined, "Mirror can restart after rejecting an oversized configuration");
    const int configurations_before = atomic_load(&video_configurations);
    sender = socket(AF_INET, SOCK_STREAM, 0);
    address.sin_port = htons(port);
    require(sender >= 0 && connect(sender, (struct sockaddr *)&address, sizeof(address)) == 0,
            "Sender reconnects after oversized configuration rejection");
    send_video_configuration(sender, 640, 360);
    require(wait_count(&video_configurations, configurations_before + 1),
            "Valid configuration reaches the host after mirror restart");
    raop_rtp_mirror_destroy(mirror);
    CLOSESOCKET(sender);
    raop_ntp_destroy(ntp);
}

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    test_hevc_configuration();
    logger_t *log = logger_init();
    logger_set_level(log, LOGGER_INFO);
    logger_set_callback(log, capture, NULL);
    test_ntp_synchronization(log);
    test_audio_restart_failure(log);
    test_oversized_video_configuration(log, false);
    test_oversized_video_configuration(log, true);
    raop_callbacks_t callbacks = {0};
    unsigned char test_key[16] = {0}, test_iv[16] = {0};
    callbacks.audio_stop = audio_stopped;
    raop_rtp_t *audio = raop_rtp_init(log, &callbacks, NULL, "127.0.0.1", 4, test_key, test_iv);
    require(audio != NULL, "Synthetic loopback RTP instance");
    for (int cycle = 1; cycle <= 3; cycle++) {
        /* Simulate the old stream's anchor and a different next-stream RTP origin. */
        audio->initial_sync = true;
        audio->rtp_sync = 1200000000;
        audio->client_ntp_sync = 90000000000000ULL;
        unsigned short remote_port = 0, control_port = 0, data_port = 0;
        unsigned char compression = 8;
        unsigned int sample_rate = 44100;
        raop_rtp_start_audio(audio, &remote_port, &control_port, &data_port, &compression, &sample_rate);
        require(raop_rtp_is_running(audio), "Real UDP thread started");
        require(!audio->initial_sync && audio->rtp_sync == 0 && audio->client_ntp_sync == 0,
                "New stream does not inherit old RTP epoch or clock anchor");
        require(rtp_time_to_client_ntp(audio, 2500000000U) == 0,
                "Unsynced new RTP origin cannot generate an hours-future timestamp");
        raop_rtp_stop(audio);
        require(!raop_rtp_is_running(audio), "Real UDP thread stopped and joined");
        require(atomic_load(&stopped) == cycle, "Ended audio transport stops platform playback exactly once");
        raop_rtp_stop(audio);
        require(atomic_load(&stopped) == cycle, "Repeated transport stop does not stop playback again");
    }
    raop_rtp_destroy(audio);
    test_sound_after_silence(log);
    test_video_rotation(log);
    logger_destroy(log);
    puts("All NTP, RTP restart, video configuration, silence, retransmission and FLUSH checks passed.");
}
