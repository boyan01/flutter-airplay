/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "receiver_frames.h"
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* One frame in flight and one replaceable pending frame. No socket I/O on the
 * GStreamer streaming thread; audio and the shared presentation clock stay native. */
typedef struct { uint64_t epoch; uint32_t header[8]; unsigned char pixels[]; } frame_t;
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t wake = PTHREAD_COND_INITIALIZER;
static pthread_t worker;
static frame_t *pending;
static int running, started, connection = -1;
static char socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
static uint32_t sequence;
static uint64_t epoch;

static int send_all(int fd, const void *data, size_t size, uint64_t frame_epoch) {
    const unsigned char *bytes = data;
    while (size) {
        pthread_mutex_lock(&mutex);
        int active = running && epoch == frame_epoch;
        pthread_mutex_unlock(&mutex);
        if (!active) return 0;
#ifdef MSG_NOSIGNAL
        ssize_t n = send(fd, bytes, size, MSG_NOSIGNAL);
#else
        ssize_t n = send(fd, bytes, size, 0);
#endif
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 0;
        bytes += n;
        size -= (size_t)n;
    }
    return 1;
}
static void *deliver(void *unused) {
    (void)unused;
    for (;;) {
        pthread_mutex_lock(&mutex);
        while (running && !pending) pthread_cond_wait(&wake, &mutex);
        if (!running) { pthread_mutex_unlock(&mutex); break; }
        frame_t *frame = pending;
        pending = NULL;
        int fd = connection;
        pthread_mutex_unlock(&mutex);
        if (fd < 0) {
            fd = socket(AF_UNIX, SOCK_STREAM, 0);
            if (fd >= 0) {
                struct timeval timeout = {0, 200000};
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
#ifdef SO_NOSIGPIPE
                int yes = 1;
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
                struct sockaddr_un address = {0};
                address.sun_family = AF_UNIX;
                memcpy(address.sun_path, socket_path, strlen(socket_path) + 1);
                if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
                    close(fd); fd = -1;
                }
            }
            pthread_mutex_lock(&mutex);
            connection = fd;
            pthread_mutex_unlock(&mutex);
        }
        if (fd >= 0 && (!send_all(fd, frame->header, sizeof(frame->header), frame->epoch) ||
                       !send_all(fd, frame->pixels, GUINT32_FROM_LE(frame->header[5]), frame->epoch))) {
            pthread_mutex_lock(&mutex);
            close(fd); connection = -1;
            pthread_mutex_unlock(&mutex);
        }
        free(frame);
    }
    pthread_mutex_lock(&mutex);
    if (connection >= 0) close(connection);
    connection = -1;
    pthread_mutex_unlock(&mutex);
    return NULL;
}
static GstFlowReturn on_sample(GstAppSink *sink, gpointer unused) {
    (void)unused;
    GstSample *sample = gst_app_sink_pull_sample(sink);
    if (!sample) return GST_FLOW_OK;
    GstVideoInfo info;
    GstVideoFrame mapped;
    GstBuffer *buffer = gst_sample_get_buffer(sample);
    if (!gst_video_info_from_caps(&info, gst_sample_get_caps(sample)) ||
        GST_VIDEO_INFO_FORMAT(&info) != GST_VIDEO_FORMAT_BGRA ||
        info.width <= 0 || info.height <= 0 || info.width > 4096 || info.height > 4096 ||
        !gst_video_frame_map(&mapped, &info, buffer, GST_MAP_READ)) {
        gst_sample_unref(sample); return GST_FLOW_OK;
    }
    uint32_t stride = (uint32_t)info.width * 4;
    uint32_t size = stride * (uint32_t)info.height;
    frame_t *frame = malloc(sizeof(*frame) + size);
    if (frame) {
        const unsigned char *pixels = GST_VIDEO_FRAME_PLANE_DATA(&mapped, 0);
        int source_stride = GST_VIDEO_FRAME_PLANE_STRIDE(&mapped, 0);
        for (int y = 0; y < info.height; ++y)
            memcpy(frame->pixels + y * stride, pixels + (ptrdiff_t)y * source_stride, stride);
        pthread_mutex_lock(&mutex);
        frame->epoch = epoch;
        uint32_t header[8] = {0x31565046, 1, (uint32_t)info.width, (uint32_t)info.height,
                              stride, size, ++sequence, 0};
        for (int i = 0; i < 8; ++i) frame->header[i] = GUINT32_TO_LE(header[i]);
        if (running) { free(pending); pending = frame; pthread_cond_signal(&wake); }
        else free(frame);
        pthread_mutex_unlock(&mutex);
    }
    gst_video_frame_unmap(&mapped);
    gst_sample_unref(sample);
    return GST_FLOW_OK;
}
void receiver_frames_attach(GstElement *pipeline, const char *sink_name) {
    const char *path = getenv("FLUTTER_AIRPLAY_FRAME_SOCKET");
    if (!path || strlen(path) >= sizeof(socket_path)) return;
    if (!started) {
        memcpy(socket_path, path, strlen(path) + 1);
        running = 1;
        if (pthread_create(&worker, NULL, deliver, NULL)) { running = 0; return; }
        started = 1;
    }
    GstElement *sink = gst_bin_get_by_name(GST_BIN(pipeline), sink_name);
    if (sink && GST_IS_APP_SINK(sink)) {
        g_object_set(sink, "emit-signals", TRUE, "max-buffers", 1u, "drop", TRUE,
                     "wait-on-eos", FALSE, NULL);
        g_signal_connect(sink, "new-sample", G_CALLBACK(on_sample), NULL);
    }
    if (sink) gst_object_unref(sink);
}
void receiver_frames_reset(void) {
    pthread_mutex_lock(&mutex);
    ++epoch;
    free(pending); pending = NULL;
    if (connection >= 0) shutdown(connection, SHUT_RDWR);
    pthread_mutex_unlock(&mutex);
}
void receiver_frames_shutdown(void) {
    if (!started) return;
    pthread_mutex_lock(&mutex);
    running = 0;
    free(pending); pending = NULL;
    if (connection >= 0) shutdown(connection, SHUT_RDWR);
    pthread_cond_signal(&wake);
    pthread_mutex_unlock(&mutex);
    pthread_join(worker, NULL);
    started = 0;
}
