/* Test-only introspection; the shipped core has no test API. */
#include "audio_renderer.c"
GstElement *test_audio_pipeline(void) { return renderer->pipeline; }
GstElement *test_audio_source(void) { return renderer->appsrc; }
