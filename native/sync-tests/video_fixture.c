/* Test-only introspection; the shipped core has no test API. */
#include "video_renderer.c"
GstElement *test_video_pipeline(void) { return renderer->pipeline; }
GstElement *test_video_source(void) { return renderer->appsrc; }
