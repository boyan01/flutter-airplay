// SPDX-License-Identifier: GPL-3.0-only
#include "host_test_support.h"
#include <epoxy/gl.h>
#include <epoxy/egl.h>
#include <gdk/gdkx.h>
extern "C" {
#include <libavutil/frame.h>
}

struct NativeLease { int references = 1; };
static void* RetainLease(void* value) { ++static_cast<NativeLease*>(value)->references; return value; }
static void ReleaseLease(void* value) { --static_cast<NativeLease*>(value)->references; }

static void ReadTexture(uint32_t texture, int width, int height, uint8_t* pixels) {
  GLuint framebuffer=0; glGenFramebuffers(1,&framebuffer); glBindFramebuffer(GL_FRAMEBUFFER,framebuffer);
  glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0);
  g_assert_cmpuint(glCheckFramebufferStatus(GL_FRAMEBUFFER),==,GL_FRAMEBUFFER_COMPLETE);
  glPixelStorei(GL_PACK_ALIGNMENT,1);glReadPixels(0,0,width,height,GL_RGBA,GL_UNSIGNED_BYTE,pixels);
  glBindFramebuffer(GL_FRAMEBUFFER,0);glDeleteFramebuffers(1,&framebuffer);
}

int main(int argc, char** argv) {
  main_thread = std::this_thread::get_id();
  g_assert_true(gtk_init_check(&argc, &argv));
  auto* window = gtk_window_new(GTK_WINDOW_TOPLEVEL); gtk_widget_realize(window);
  GError* error = nullptr;
  auto* context = gdk_window_create_gl_context(gtk_widget_get_window(window), &error);
  g_assert_nonnull(context); gdk_gl_context_set_required_version(context, 3, 2);
  g_assert_true(gdk_gl_context_realize(context, &error)); gdk_gl_context_make_current(context);
  const bool use_egl = argc>1 && !strcmp(argv[1], "--egl");
  EGLDisplay egl_display=EGL_NO_DISPLAY; EGLContext egl_context=EGL_NO_CONTEXT;
  if(use_egl) {
    gdk_gl_context_clear_current();
    egl_display=eglGetPlatformDisplayEXT(EGL_PLATFORM_X11_EXT,
        gdk_x11_display_get_xdisplay(gdk_display_get_default()),nullptr);
    g_assert_true(eglInitialize(egl_display,nullptr,nullptr));g_assert_true(eglBindAPI(EGL_OPENGL_ES_API));
    const EGLint attributes[]{EGL_RENDERABLE_TYPE,EGL_OPENGL_ES2_BIT,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
    EGLConfig config=nullptr;EGLint count=0;g_assert_true(eglChooseConfig(egl_display,attributes,&config,1,&count));g_assert_cmpint(count,>,0);
    const EGLint context_attributes[]{EGL_CONTEXT_CLIENT_VERSION,2,EGL_NONE};
    egl_context=eglCreateContext(egl_display,config,EGL_NO_CONTEXT,context_attributes);g_assert_true(egl_context!=EGL_NO_CONTEXT);
    g_assert_true(eglMakeCurrent(egl_display,EGL_NO_SURFACE,EGL_NO_SURFACE,egl_context));
    printf("Flutter-style EGL client: %s\n",glGetString(GL_VERSION));
  }
  auto* registrar = reinterpret_cast<TestRegistrar*>(g_object_new(test_registrar_get_type(), nullptr));
  NativeLease lease;
  {
    FrameTexture output(FL_TEXTURE_REGISTRAR(registrar), true);
    g_assert_true(output.Register());
    // A native frame is retained, replaced and cleared without copying its bytes.
    AirplayLinuxVideoFrame native{nullptr, 0, 2, 2, &lease, RetainLease, ReleaseLease};
    g_assert_true(output.Receive(native)); g_assert_cmpint(lease.references, ==, 2);
    g_assert_true(output.Receive(native)); g_assert_cmpint(lease.references, ==, 2);
    output.Clear(); g_assert_cmpint(lease.references, ==, 1);
    std::vector<uint8_t> borrowed{1,2,3,255,4,5,6,255,99,99,99,99,
                                7,8,9,255,10,11,12,255,99,99,99,99};
    g_assert_true(output.Receive({borrowed.data(),12,2,2})); borrowed.assign(borrowed.size(),0);
    output.NotificationRequested();
    output.NotificationRequested(true);
    output.Notify();
    auto* texture = FL_TEXTURE_GL(registrar->texture);
    auto populate = FL_TEXTURE_GL_GET_CLASS(texture)->populate;
    uint32_t target=0, name=0, width=0, height=0;
    g_assert_true(populate(texture,&target,&name,&width,&height,&error));
    g_assert_no_error(error); g_assert_cmpuint(width,==,2);g_assert_cmpuint(height,==,2);
    const auto previous=name;
    g_assert_true(populate(texture,&target,&name,&width,&height,&error));g_assert_cmpuint(name,==,previous);
    const auto diagnostics = output.Diagnostics();
    for (const auto* field : {"received=1 ", "acquired_new=1 ", "repeated_acquire=1 ",
         "notification_requests=2 ", "notification_coalesced=1 ", "notifications=1 ",
         "populate_calls=2 ", "mark_to_populate_avg_ms=", "populate_gap_avg_ms=",
         "populate_cost_avg_ms="}) g_assert_nonnull(strstr(diagnostics.c_str(), field));
    const auto reset = output.Diagnostics();
    g_assert_nonnull(strstr(reset.c_str(), "populate_calls=0 "));
    g_assert_nonnull(strstr(reset.c_str(), "notifications=0 "));
    uint8_t pixels[16]{};glBindTexture(GL_TEXTURE_2D,name);glPixelStorei(GL_PACK_ALIGNMENT,1);
    ReadTexture(name,2,2,pixels);
    const uint8_t expected[]{1,2,3,255,4,5,6,255,7,8,9,255,10,11,12,255};
    g_assert_cmpmem(pixels,sizeof(pixels),expected,sizeof(expected));
    // Exercise the real decoder lease through the shared EGL shader, after
    // releasing the producer's descriptor and all of its frame references.
    auto* yuv=av_frame_alloc();yuv->format=AV_PIX_FMT_NV12;yuv->width=6;yuv->height=4;
    yuv->colorspace=AVCOL_SPC_SMPTE170M;yuv->color_range=AVCOL_RANGE_MPEG;
    g_assert_cmpint(av_frame_get_buffer(yuv,32),==,0);
    for(int y=0;y<4;++y) memset(yuv->data[0]+y*yuv->linesize[0],41,6);
    for(int y=0;y<2;++y) for(int x=0;x<6;x+=2) {yuv->data[1][y*yuv->linesize[1]+x]=240;yuv->data[1][y*yuv->linesize[1]+x+1]=110;}
    AirplayLinuxVideoFrame picture{nullptr,0,6,4,yuv,
      [](void* value)->void* {return av_frame_clone(static_cast<AVFrame*>(value));},
      [](void* value) {auto* frame=static_cast<AVFrame*>(value);av_frame_free(&frame);}};
    g_assert_true(output.Receive(picture));av_frame_free(&yuv);
    g_assert_true(populate(texture,&target,&name,&width,&height,&error));g_assert_no_error(error);
    g_assert_cmpuint(width,==,6);g_assert_cmpuint(height,==,4);
    uint8_t blue[6*4*4]{};ReadTexture(name,6,4,blue);
    for(int i=0;i<6*4;++i) {g_assert_cmpuint(blue[i*4+2],>,200);g_assert_cmpuint(blue[i*4],<,45);g_assert_cmpuint(blue[i*4+1],<,45);g_assert_cmpuint(blue[i*4+3],==,255);}
    std::thread producer([&]{for(int i=0;i<200;++i){g_assert_true(output.Receive(native));output.Clear();}});
    producer.join(); g_assert_cmpint(lease.references,==,1);
    g_assert_true(populate(texture,&target,&name,&width,&height,&error));
    g_assert_cmpuint(width,==,1);g_assert_cmpuint(height,==,1);
    uint8_t black[4]{};glBindTexture(GL_TEXTURE_2D,name);ReadTexture(name,1,1,black);
    g_assert_cmpuint(black[0],==,0);g_assert_cmpuint(black[3],==,255);
    g_assert_true(output.TakeError().empty());output.Notify();g_assert_cmpuint(registrar->marks,==,2);
    // Main-thread finalization must make its saved raster context current and restore ours.
    if(use_egl) {
      g_assert_true(eglGetCurrentContext()==egl_context);
      eglMakeCurrent(egl_display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
    } else gdk_gl_context_clear_current();
  }
  while (g_main_context_iteration(nullptr, FALSE)) {}
  g_assert_cmpuint(registrar->marks,==,2);
  g_assert_null(gdk_gl_context_get_current());g_assert_null(registrar->texture);g_assert_cmpint(lease.references,==,1);
  // Exercise the bounded queue and main-thread frame pump separately from the
  // immediate-acquisition contract above. Clear and destruction cancel marks.
  if(use_egl) g_assert_true(eglMakeCurrent(egl_display,EGL_NO_SURFACE,EGL_NO_SURFACE,egl_context));
  else gdk_gl_context_make_current(context);
  {
    FrameTexture pumped(FL_TEXTURE_REGISTRAR(registrar), true, true);
    g_assert_true(pumped.Register());
    uint8_t rgba[]{12,34,56,255};
    for(int i=0;i<2;++i) g_assert_true(pumped.Receive({rgba,4,1,1}));
    auto* texture=FL_TEXTURE_GL(registrar->texture);
    auto populate=FL_TEXTURE_GL_GET_CLASS(texture)->populate;
    uint32_t target=0,name=0,width=0,height=0;
    g_assert_true(populate(texture,&target,&name,&width,&height,&error));
    // Refresh input after shader initialization so this is independent of its cost.
    g_assert_true(pumped.Receive({rgba,4,1,1}));
    SpinUntil([&]{return registrar->marks==3;});
    const auto queued=pumped.Diagnostics();
    for(const auto* field : {"received=3 ","acquired_new=1 ","overwritten_before_acquire=0 ","repaint_requests=1 "})
      g_assert_nonnull(strstr(queued.c_str(),field));
    g_assert_true(populate(texture,&target,&name,&width,&height,&error));
    // A stopped producer still presents the final buffered frame, then stops
    // requesting frames. Exercise this without relying on a new producer mark.
    g_usleep(40000);
    SpinUntil([&]{return registrar->marks==4;});
    g_assert_true(populate(texture,&target,&name,&width,&height,&error));
    while(g_main_context_iteration(nullptr,FALSE)) {}
    const auto drained=pumped.Diagnostics();
    g_assert_nonnull(strstr(drained.c_str(),"acquired_new=2 "));
    g_assert_nonnull(strstr(drained.c_str(),"queued_frames=0 "));
    pumped.Clear();
    while(g_main_context_iteration(nullptr,FALSE)) {}
    g_assert_cmpuint(registrar->marks,==,4);
    // Leave a queued request at destruction: no registrar mark or retained texture.
    for(int i=0;i<2;++i) g_assert_true(pumped.Receive({rgba,4,1,1}));
    g_assert_true(populate(texture,&target,&name,&width,&height,&error));
  }
  while(g_main_context_iteration(nullptr,FALSE)) {}
  g_assert_cmpuint(registrar->marks,==,4);g_assert_null(registrar->texture);
  if(use_egl) eglMakeCurrent(egl_display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
  else gdk_gl_context_clear_current();
  if(use_egl) {g_assert_true(eglGetCurrentContext()==EGL_NO_CONTEXT);eglDestroyContext(egl_display,egl_context);eglTerminate(egl_display);}
  g_object_unref(registrar);g_object_unref(context);gtk_widget_destroy(window);
  puts("PASS: Flutter GL texture registration, pixels, cached acquisition, retained leases, concurrent clear and context cleanup");
}
