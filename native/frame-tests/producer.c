/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "receiver_frames.h"
#include <stdlib.h>
#include <stdio.h>
#include "video_renderer.h"
#include <gst/app/gstappsink.h>
GstElement *test_video_pipeline(void);

/* Exercises the shipped renderer's H264 parser/decoder, BGRA caps and PTS sink. */
static int render_encoded(int width, int height, int frames) {
    logger_t *log = logger_init();
    logger_set_level(log, LOGGER_ERR);
    videoflip_t transforms[2] = {NONE, NONE};
    video_renderer_init(log, "Synthetic frame test", transforms, "h264parse", "", "avdec_h264",
                        "videoconvert ! video/x-raw,format=BGRA", "appsink", "", false, true, false, false, 3, NULL);
    video_renderer_start();
    if (video_renderer_choose_codec(false, false)) return 5;
    GstElement *sink = gst_bin_get_by_name(GST_BIN(test_video_pipeline()), "appsink_h264");
    gboolean synchronized = FALSE;
    g_object_get(sink, "sync", &synchronized, NULL);
    gst_object_unref(sink);
    if (!synchronized) return 6;
    char description[512];
    snprintf(description, sizeof(description), "videotestsrc num-buffers=%d pattern=red ! "
             "video/x-raw,width=%d,height=%d,framerate=30/1 ! x264enc tune=zerolatency key-int-max=1 ! "
             "h264parse ! video/x-h264,stream-format=byte-stream,alignment=au ! appsink name=encoded sync=false", frames, width, height);
    GError *error = NULL;
    GstElement *encoder = gst_parse_launch(description, &error);
    if (!encoder || error) return 7;
    GstElement *encoded = gst_bin_get_by_name(GST_BIN(encoder), "encoded");
    gst_element_set_state(encoder, GST_STATE_PLAYING);
    GstClock *clock = gst_element_get_clock(test_video_pipeline());
    guint64 start = gst_clock_get_time(clock) + 200 * GST_MSECOND;
    gst_object_unref(clock);
    int success = 1;
    for (int i = 0; i < frames; ++i) {
        GstSample *sample = gst_app_sink_try_pull_sample(GST_APP_SINK(encoded), GST_SECOND);
        if (!sample) { success = 0; break; }
        GstMapInfo map;
        gst_buffer_map(gst_sample_get_buffer(sample), &map, GST_MAP_READ);
        int length = (int)map.size, nals = 1;
        guint64 pts = start + i * GST_SECOND / 30;
        if (video_renderer_render_buffer(map.data, &length, &nals, &pts)) success = 0;
        gst_buffer_unmap(gst_sample_get_buffer(sample), &map);
        gst_sample_unref(sample);
        g_usleep(33333);
    }
    g_usleep(300000);
    gst_element_set_state(encoder, GST_STATE_NULL);
    gst_object_unref(encoded); gst_object_unref(encoder);
    video_renderer_stop(); video_renderer_destroy(); logger_destroy(log);
    return success ? 0 : 8;
}
int main(int argc, char **argv) {
    if (argc != 5 && argc != 6) return 2;
    setenv("FLUTTER_AIRPLAY_FRAME_SOCKET", argv[1], 1);
    gst_init(NULL, NULL);
    if (argc == 6) {
        for (int cycle = 0; cycle < 2; ++cycle) {
            int result = render_encoded(cycle ? atoi(argv[3]) : atoi(argv[2]),
                                        cycle ? atoi(argv[2]) : atoi(argv[3]), atoi(argv[4]));
            if (result) return result;
        }
        return 0;
    }
    char launch[512];
    snprintf(launch, sizeof(launch), "videotestsrc is-live=true pattern=red num-buffers=%d ! "
             "video/x-raw,format=BGRA,width=%d,height=%d,framerate=30/1 ! appsink name=frames sync=true",
             atoi(argv[4]), atoi(argv[2]), atoi(argv[3]));
    GError *error = NULL;
    GstElement *pipeline = gst_parse_launch(launch, &error);
    if (!pipeline || error) return 3;
    receiver_frames_attach(pipeline, "frames");
    gst_element_set_state(pipeline, GST_STATE_PLAYING);
    GstBus *bus = gst_element_get_bus(pipeline);
    GstMessage *message = gst_bus_timed_pop_filtered(bus, 120 * GST_SECOND,
                                                    GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
    int success = message && GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS;
    gst_element_set_state(pipeline, GST_STATE_NULL);
    receiver_frames_shutdown();
    if (message) gst_message_unref(message);
    gst_object_unref(bus); gst_object_unref(pipeline);
    return success ? 0 : 4;
}
