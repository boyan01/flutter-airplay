/* Synthetic regression for a hours-future audio head and same-codec stream restart. */
#include <stdio.h>
#include <gst/app/gstappsink.h>
#include "audio_renderer.c"
static gint played;
static int resets;
static void require(bool condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
    printf("PASS: %s\n", message);
}
static void capture(void *context, int level, const char *message) {
    puts(message);
    if (strstr(message, "flushed playback")) resets++;
}
static void handoff(GstElement *sink, GstBuffer *buffer, GstPad *pad, gpointer context) {
    g_atomic_int_inc(&played);
}
static void wait_count(gint *counter, int target) {
    gint64 deadline = g_get_monotonic_time() + 2 * G_USEC_PER_SEC;
    while (g_atomic_int_get(counter) < target && g_get_monotonic_time() < deadline) {
        while (g_main_context_iteration(NULL, FALSE)) {}
        g_usleep(1000);
    }
    require(g_atomic_int_get(counter) >= target, "Expected audio progress before timeout");
}
static void inject_blocked_head(GstSample *sample) {
    GstBuffer *buffer = gst_buffer_copy(gst_sample_get_buffer(sample));
    /* Deliberately bypass the guarded public renderer to recreate an already queued bad head. */
    GST_BUFFER_PTS(buffer) = gst_element_get_current_clock_time(renderer->pipeline) +
                            27675143ULL * GST_MSECOND - gst_audio_pipeline_base_time;
    require(gst_app_src_push_buffer(GST_APP_SRC(renderer->appsrc), buffer) == GST_FLOW_OK,
            "Old hours-future head reproduced in synchronized sink");
}
static void push_valid(GstSample *sample, guint64 time, unsigned short sequence) {
    GstMapInfo map;
    gst_buffer_map(gst_sample_get_buffer(sample), &map, GST_MAP_READ);
    int length = map.size;
    audio_renderer_render_buffer(map.data, &length, &sequence, &time);
    gst_buffer_unmap(gst_sample_get_buffer(sample), &map);
}
int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    require(gstreamer_init(), "GStreamer initialized");
    logger_t *log = logger_init();
    logger_set_level(log, LOGGER_INFO); logger_set_callback(log, capture, NULL);
    bool enabled = true;
    audio_renderer_init(log, "fakesink name=audio_sink signal-handoffs=true", &enabled, &enabled, "");
    unsigned char compression = 8;
    audio_renderer_start(&compression);
    unsigned char probe[16] = {0x8c};
    int length = sizeof(probe);
    unsigned short sequence = 0;
    uint64_t time = gst_element_get_current_clock_time(renderer->pipeline) + 27675143ULL * GST_MSECOND;
    audio_renderer_render_buffer(probe, &length, &sequence, &time);
    time = gst_element_get_current_clock_time(renderer->pipeline) - 3 * GST_SECOND;
    audio_renderer_render_buffer(probe, &length, &sequence, &time);
    guint64 queued_bytes = 1;
    g_object_get(renderer->appsrc, "current-level-bytes", &queued_bytes, NULL);
    require(renderer->rejected_timestamps == 2 && renderer->encoded_buffers == 0 && queued_bytes == 0,
            "Far-future and stale mirror timestamps rejected before queueing");
    require(renderer->next_discontinuity, "Next valid mirror frame marked discontinuous");

    compression = 2;
    audio_renderer_start(&compression);
    GstElement *sink = gst_bin_get_by_name(GST_BIN(renderer->pipeline), "audio_sink");
    g_signal_connect(sink, "handoff", G_CALLBACK(handoff), NULL);
    audio_renderer_set_volume(0.6);
    gdouble original_volume = 0.0;
    g_object_get(renderer->volume, "volume", &original_volume, NULL);
    GError *error = NULL;
    GstElement *encoder = gst_parse_launch("audiotestsrc num-buffers=120 samplesperbuffer=352 ! audio/x-raw,rate=44100,channels=2 ! audioconvert ! avenc_alac ! appsink name=encoded sync=false", &error);
    require(encoder && !error, "Synthetic ALAC source");
    GstElement *output = gst_bin_get_by_name(GST_BIN(encoder), "encoded");
    gst_element_set_state(encoder, GST_STATE_PLAYING);
    GstSample *sample = gst_app_sink_try_pull_sample(GST_APP_SINK(output), GST_SECOND);
    require(sample != NULL, "Synthetic compressed frame available");
    g_object_set(renderer->appsrc, "caps", gst_sample_get_caps(sample), NULL);
    inject_blocked_head(sample);
    wait_count(&renderer->decoded_buffers, 1);
    require(played == 0, "Hours-future decoded head has not played");
    gint64 started = g_get_monotonic_time();
    audio_renderer_start(&compression);
    require(g_get_monotonic_time() - started < G_USEC_PER_SEC, "Same-codec SETUP cancels blocked clock wait promptly");
    gdouble volume = 0.0;
    g_object_get(renderer->volume, "volume", &volume, NULL);
    require(volume == original_volume && resets == 1, "Stream restart preserves sender volume");
    guint64 start = gst_element_get_current_clock_time(renderer->pipeline) + 100 * GST_MSECOND;
    for (int i = 0; i < 6; i++) push_valid(sample, start + i * 100 * GST_MSECOND, i);
    wait_count(&played, 6);
    require(renderer->push_failures == 0, "Valid decoded audio plays after same-codec restart");

    int before = renderer->decoded_buffers;
    inject_blocked_head(sample);
    wait_count(&renderer->decoded_buffers, before + 1);
    audio_renderer_flush();
    start = gst_element_get_current_clock_time(renderer->pipeline) + 100 * GST_MSECOND;
    push_valid(sample, start, 7);
    wait_count(&played, 7);
    require(resets == 2, "FLUSH also clears a blocked head and resumes valid audio");
    gst_sample_unref(sample);
    gst_element_set_state(encoder, GST_STATE_NULL);
    gst_object_unref(output); gst_object_unref(encoder); gst_object_unref(sink);
    audio_renderer_destroy(); logger_destroy(log);
    puts("All bad-PTS rejection, same-codec SETUP and FLUSH recovery checks passed.");
}
