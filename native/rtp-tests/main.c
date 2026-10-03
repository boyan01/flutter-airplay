/* Exercise the real RTP stop/start lifecycle with loopback and synthetic keys. */
#include <stdio.h>
#include "raop_rtp.c"
static void require(bool condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
    printf("PASS: %s\n", message);
}
static void capture(void *context, int level, const char *message) { puts(message); }
int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
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
    logger_destroy(log);
    puts("All real RTP restart epoch checks passed.");
}
