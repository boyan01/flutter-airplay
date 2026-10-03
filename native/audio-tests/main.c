/* Project diagnostics regression: synthetic ALAC, no microphone or user media. */
#include <stdio.h>
#include <string.h>
#include <gst/app/gstappsink.h>
#include "audio_renderer.c"

static int decoded_reports, output_reports, mute_reports;
static void capture(void *context, int level, const char *message) {
    puts(message);
    if (strstr(message, "decoded_level RMS")) decoded_reports++;
    if (strstr(message, "output_level RMS")) output_reports++;
    if (strstr(message, "muted by sender")) mute_reports++;
}
static void require(bool condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
    printf("PASS: %s\n", message);
}
static void drain_messages(void) {
    while (g_main_context_iteration(NULL, FALSE)) {}
}
int main(void) {
    require(gstreamer_init(), "GStreamer dependencies");
    logger_t *test_logger = logger_init();
    logger_set_level(test_logger, LOGGER_INFO);
    logger_set_callback(test_logger, capture, NULL);
    bool disabled_sync = false;
    audio_renderer_init(test_logger, "fakesink", &disabled_sync, &disabled_sync, "");
    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
    guint watches[2];
    for (int i = 0; i < 2; i++) watches[i] = audio_renderer_listen(loop, i);
    unsigned char compression = 2;
    audio_renderer_start(&compression);
    GstElement *decoded_level = gst_bin_get_by_name(GST_BIN(renderer->pipeline), "decoded_level");
    GstElement *output_level = gst_bin_get_by_name(GST_BIN(renderer->pipeline), "output_level");
    g_object_set(decoded_level, "interval", (guint64) GST_SECOND, NULL);
    g_object_set(output_level, "interval", (guint64) GST_SECOND, NULL);
    gst_object_unref(decoded_level);
    gst_object_unref(output_level);

    GError *error = NULL;
    GstElement *encoder = gst_parse_launch(
        "audiotestsrc num-buffers=1000 samplesperbuffer=352 volume=0.25 ! "
        "audio/x-raw,rate=44100,channels=2 ! audioconvert ! avenc_alac ! appsink name=encoded sync=false", &error);
    require(encoder && !error, "Synthetic ALAC encoder");
    GstElement *encoded = gst_bin_get_by_name(GST_BIN(encoder), "encoded");
    gst_element_set_state(encoder, GST_STATE_PLAYING);
    int frames = 0;
    GstSample *sample;
    while ((sample = gst_app_sink_try_pull_sample(GST_APP_SINK(encoded), GST_SECOND))) {
        if (frames == 0) {
            /* Use the encoder's own cookie; real AirPlay keeps its upstream cookie. */
            g_object_set(renderer->appsrc, "caps", gst_sample_get_caps(sample), NULL);
        }
        GstMapInfo map;
        GstBuffer *buffer = gst_sample_get_buffer(sample);
        require(gst_buffer_map(buffer, &map, GST_MAP_READ), "Encoded buffer accessible");
        int length = (int) map.size;
        unsigned short sequence = frames++;
        uint64_t timestamp = (uint64_t) g_get_real_time() * 1000;
        audio_renderer_render_buffer(map.data, &length, &sequence, &timestamp);
        gst_buffer_unmap(buffer, &map);
        gst_sample_unref(sample);
        drain_messages();
    }
    gst_app_src_end_of_stream(GST_APP_SRC(renderer->appsrc));
    gint64 deadline = g_get_monotonic_time() + 3 * G_USEC_PER_SEC;
    while (g_get_monotonic_time() < deadline && !output_reports) {
        drain_messages();
        g_usleep(1000);
    }
    require(frames > 0, "Synthetic compressed input produced");
    require(g_atomic_int_get(&renderer->encoded_buffers) == frames, "All encoded frames counted");
    require(g_atomic_int_get(&renderer->decoded_buffers) > 0, "ALAC decoded to PCM");
    require(g_atomic_int_get(&renderer->push_failures) == 0, "No GStreamer input flow errors");
    require(decoded_reports > 0 && output_reports > 0, "Pre/post volume signal levels observable");
    audio_renderer_set_volume(0.0);
    gdouble volume = 1.0;
    g_object_get(renderer->volume, "volume", &volume, NULL);
    require(volume == 0.0 && mute_reports == 1, "Sender mute preserved and reported");
    int empty_length = 0;
    unsigned short sequence = 0;
    uint64_t timestamp = 0;
    audio_renderer_render_buffer(NULL, &empty_length, &sequence, &timestamp);
    require(g_atomic_int_get(&renderer->encoded_buffers) == frames, "Empty audio ignored safely");
    gst_element_set_state(encoder, GST_STATE_NULL);
    gst_object_unref(encoded);
    gst_object_unref(encoder);
    for (int i = 0; i < 2; i++) g_source_remove(watches[i]);
    audio_renderer_destroy();
    g_main_loop_unref(loop);
    logger_destroy(test_logger);
    puts("All synthetic audio diagnostics checks passed. iPhone AAC-ELD is a separate validation.");
    return 0;
}
