/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef RECEIVER_FRAMES_H
#define RECEIVER_FRAMES_H
#include <gst/gst.h>
void receiver_frames_attach(GstElement *pipeline, const char *sink_name);
void receiver_frames_reset(void);
void receiver_frames_shutdown(void);
#endif
