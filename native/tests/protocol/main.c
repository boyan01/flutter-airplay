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
static void test_sound_after_silence(logger_t *log) {
    raop_callbacks_t callbacks = {0};
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
    raop_ntp_destroy(ntp);
}
int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    test_hevc_configuration();
    logger_t *log = logger_init();
    logger_set_level(log, LOGGER_INFO);
    logger_set_callback(log, capture, NULL);
    raop_callbacks_t callbacks = {0};
    unsigned char test_key[16] = {0}, test_iv[16] = {0};
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
    }
    raop_rtp_destroy(audio);
    test_sound_after_silence(log);
    logger_destroy(log);
    puts("All RTP restart, silence transition, retransmission and FLUSH checks passed.");
}
