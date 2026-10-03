/* Airplay Receiver local integration. GPL-3.0-or-later; see ../LICENSE. */
#ifndef RECEIVER_DIAGNOSTICS_H
#define RECEIVER_DIAGNOSTICS_H
#include <gst/gst.h>
#include "../lib/logger.h"

/* Metadata only. PTS lead is scheduled absolute time minus the shared clock. */
static inline void receiver_report_timing(logger_t *log, const char *media,
                                         GstElement *pipeline, GstElement *source,
                                         const char *queue_name, guint64 timestamp,
                                         gboolean synchronized) {
    GstClock *clock = gst_element_get_clock(pipeline);
    if (!clock) return;
    GstClockTime now = gst_clock_get_time(clock);
    GstClockTime base = gst_element_get_base_time(source);
    guint64 source_time = 0, source_bytes = 0, queue_time = 0;
    g_object_get(source, "current-level-bytes", &source_bytes, NULL);
    if (g_object_class_find_property(G_OBJECT_GET_CLASS(source), "current-level-time")) {
        g_object_get(source, "current-level-time", &source_time, NULL);
    }
    GstElement *queue = gst_bin_get_by_name(GST_BIN(pipeline), queue_name);
    if (queue) {
        g_object_get(queue, "current-level-time", &queue_time, NULL);
        gst_object_unref(queue);
    }
    gboolean live = FALSE;
    GstClockTime minimum = 0, maximum = GST_CLOCK_TIME_NONE;
    GstQuery *latency = gst_query_new_latency();
    if (gst_element_query(pipeline, latency)) gst_query_parse_latency(latency, &live, &minimum, &maximum);
    gst_query_unref(latency);
    logger_log(log, LOGGER_INFO,
               "Sync diagnostic: %s sync=%d clock=%s pts_lead_ms=%.1f base_ms=%.1f appsrc_ms=%.1f queue_ms=%.1f queued_bytes=%" G_GUINT64_FORMAT " min_latency_ms=%.1f",
               media, synchronized, GST_OBJECT_NAME(clock),
               (double) ((gint64) timestamp - (gint64) now) / GST_MSECOND,
               (double) base / GST_MSECOND, (double) source_time / GST_MSECOND,
               (double) queue_time / GST_MSECOND, source_bytes, (double) minimum / GST_MSECOND);
    gst_object_unref(clock);
}
#endif
