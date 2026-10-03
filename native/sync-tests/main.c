/* Synthetic encoded A/V timing regression; no user content, speaker or window. */
#include <stdio.h>
#include <math.h>
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include "../../vendor/UxPlay/renderers/audio_renderer.h"
#include "../../vendor/UxPlay/renderers/video_renderer.h"
GstElement *test_audio_pipeline(void);
GstElement *test_audio_source(void);
GstElement *test_video_pipeline(void);
GstElement *test_video_source(void);
#define MAX_FRAMES 96

typedef struct {
    GstElement *pipeline;
    gint count;
    gint invalid_pts;
    guint64 deadline[MAX_FRAMES];
    guint64 played[MAX_FRAMES];
} Trace;
static void require(bool condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
    printf("PASS: %s\n", message);
}
static void log_metadata(void *context, int level, const char *message) { puts(message); }
static void handoff(GstElement *sink, GstBuffer *buffer, GstPad *pad, gpointer data) {
    Trace *trace = data;
    gint index = g_atomic_int_get(&trace->count);
    if (index >= MAX_FRAMES) return;
    if (!GST_BUFFER_PTS_IS_VALID(buffer)) g_atomic_int_inc(&trace->invalid_pts);
    trace->deadline[index] = gst_element_get_base_time(trace->pipeline) + GST_BUFFER_PTS(buffer);
    GstClock *clock = gst_element_get_clock(trace->pipeline);
    trace->played[index] = gst_clock_get_time(clock);
    gst_object_unref(clock);
    g_atomic_int_inc(&trace->count);
}
static GstElement *encoder(const char *description, GstElement **output) {
    GError *error = NULL;
    GstElement *pipeline = gst_parse_launch(description, &error);
    require(pipeline && !error, "Synthetic encoder pipeline");
    *output = gst_bin_get_by_name(GST_BIN(pipeline), "encoded");
    gst_element_set_state(pipeline, GST_STATE_PLAYING);
    return pipeline;
}
static void run_cycle(logger_t *log, int cycle, int frames, int width, int height) {
    bool enabled = true;
    audio_renderer_init(log, "fakesink name=audio_sink signal-handoffs=true", &enabled, &enabled, "");
    unsigned char compression = 2;
    audio_renderer_start(&compression);
    /* Deliberately stagger the starts; absolute timestamps must cancel base-time differences. */
    g_usleep(150000);
    videoflip_t transforms[2] = {NONE, NONE};
    video_renderer_init(log, "Airplay Receiver Sync Test", transforms, "h264parse", "", "avdec_h264", "videoconvert",
                        "fakesink", " signal-handoffs=true", false, true, false, false, 3, NULL);
    video_renderer_start();
    require(video_renderer_choose_codec(false, false) == 0, "H264 renderer selected");
    GstElement *audio_pipeline = test_audio_pipeline(), *video_pipeline = test_video_pipeline();
    GstClock *audio_clock = gst_element_get_clock(audio_pipeline), *video_clock = gst_element_get_clock(video_pipeline);
    require(audio_clock == video_clock, "Both real renderer pipelines share one GstSystemClock");
    gst_object_unref(video_clock);
    guint64 scheduled_start = gst_clock_get_time(audio_clock) + 500 * GST_MSECOND;
    gst_object_unref(audio_clock);
    require(gst_element_get_base_time(video_pipeline) - gst_element_get_base_time(audio_pipeline) >= 100 * GST_MSECOND,
            "Test contains distinct pipeline base times");
    Trace audio = {.pipeline = audio_pipeline}, video = {.pipeline = video_pipeline};
    GstElement *audio_sink = gst_bin_get_by_name(GST_BIN(audio_pipeline), "audio_sink");
    GstElement *video_sink = gst_bin_get_by_name(GST_BIN(video_pipeline), "fakesink_h264");
    gboolean audio_sync = FALSE, video_sync = FALSE;
    g_object_get(audio_sink, "sync", &audio_sync, NULL);
    g_object_get(video_sink, "sync", &video_sync, NULL);
    require(audio_sync && video_sync, "Both output sinks synchronize to timestamps");
    g_signal_connect(audio_sink, "handoff", G_CALLBACK(handoff), &audio);
    g_signal_connect(video_sink, "handoff", G_CALLBACK(handoff), &video);
    GstElement *audio_output, *video_output;
    GstElement *audio_encoder = encoder("audiotestsrc num-buffers=1500 samplesperbuffer=352 volume=0.25 ! audio/x-raw,rate=44100,channels=2 ! audioconvert ! avenc_alac ! appsink name=encoded sync=false", &audio_output);
    gchar *description = g_strdup_printf("videotestsrc num-buffers=%d ! video/x-raw,width=%d,height=%d,framerate=10/1 ! x264enc tune=zerolatency key-int-max=1 ! h264parse ! video/x-h264,stream-format=byte-stream,alignment=au ! appsink name=encoded sync=false", frames, width, height);
    GstElement *video_encoder = encoder(description, &video_output);
    g_free(description);
    for (int i = 0; i < frames; i++) {
        GstSample *a = gst_app_sink_try_pull_sample(GST_APP_SINK(audio_output), GST_SECOND);
        GstSample *v = gst_app_sink_try_pull_sample(GST_APP_SINK(video_output), GST_SECOND);
        require(a && v, "Both compressed samples generated");
        if (i == 0) g_object_set(test_audio_source(), "caps", gst_sample_get_caps(a), NULL);
        GstMapInfo am, vm;
        gst_buffer_map(gst_sample_get_buffer(a), &am, GST_MAP_READ);
        gst_buffer_map(gst_sample_get_buffer(v), &vm, GST_MAP_READ);
        int audio_length = am.size, video_length = vm.size, nals = 1;
        unsigned short sequence = i;
        guint64 audio_time = scheduled_start + i * 100 * GST_MSECOND;
        guint64 video_time = audio_time;
        audio_renderer_render_buffer(am.data, &audio_length, &sequence, &audio_time);
        require(video_renderer_render_buffer(vm.data, &video_length, &nals, &video_time) == 0, "Valid future video timestamp accepted");
        gst_buffer_unmap(gst_sample_get_buffer(a), &am);
        gst_buffer_unmap(gst_sample_get_buffer(v), &vm);
        gst_sample_unref(a); gst_sample_unref(v);
    }
    gint64 timeout = g_get_monotonic_time() + (frames * 100 + 2000) * 1000;
    while (g_get_monotonic_time() < timeout && (g_atomic_int_get(&audio.count) < frames || g_atomic_int_get(&video.count) < frames)) {
        while (g_main_context_iteration(NULL, FALSE)) {}
        g_usleep(1000);
    }
    require(audio.count == frames && video.count == frames, "Every synthetic decoded frame played");
    require(!audio.invalid_pts && !video.invalid_pts, "Decoded audio and video retain PTS");
    double max_skew = 0.0, first_skew = 0.0, last_skew = 0.0;
    for (int i = 0; i < frames; i++) {
        require(audio.deadline[i] == video.deadline[i], "Equal absolute presentation targets despite staggered starts");
        double skew = ((gint64) audio.played[i] - (gint64) video.played[i]) / (double) GST_MSECOND;
        max_skew = fmax(max_skew, fabs(skew));
        if (!i) first_skew = skew;
        if (i == frames - 1) last_skew = skew;
    }
    printf("Cycle %d, synthetic %dx%d: frames=%d maximum A/V handoff skew=%.3f ms, first=%.3f ms last=%.3f ms\n", cycle, width, height, frames, max_skew, first_skew, last_skew);
    require(max_skew < 60.0, "Synthetic handoff skew below 60 ms with no accumulating queue drift");
    gst_element_set_state(audio_encoder, GST_STATE_NULL); gst_element_set_state(video_encoder, GST_STATE_NULL);
    gst_object_unref(audio_output); gst_object_unref(video_output);
    gst_object_unref(audio_encoder); gst_object_unref(video_encoder);
    gst_object_unref(audio_sink); gst_object_unref(video_sink);
    audio_renderer_destroy(); video_renderer_destroy();
}
int main(void) {
    gst_init(NULL, NULL);
    logger_t *log = logger_init();
    logger_set_level(log, LOGGER_INFO); logger_set_callback(log, log_metadata, NULL);
    run_cycle(log, 1, 96, 320, 180);
    run_cycle(log, 2, 12, 180, 320);
    logger_destroy(log);
    puts("Synthetic shared-clock/decode/PTS scheduling and fresh portrait session passed. Actual iPhone sync remains separate.");
}
