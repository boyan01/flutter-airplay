// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <epoxy/egl.h>
#include <gdk/gdk.h>
#include <string>

// Flutter 3.47 uses EGL directly, so gdk_gl_context_get_current() may be null.
// Own a shared EGL context for video resources; it can be cleaned up on GTK's
// thread without stealing the engine's raster context. Older/GDK fixtures keep
// their GdkGLContext alive for cleanup instead.
class TextureGlContext {
 public:
  ~TextureGlContext() {
    if (egl_context_ != EGL_NO_CONTEXT) eglDestroyContext(egl_display_, egl_context_);
    if (gdk_context_) g_object_unref(gdk_context_);
  }
  bool Initialize(std::string& error) {
    egl_display_ = eglGetCurrentDisplay();
    if (egl_display_ != EGL_NO_DISPLAY) {
      const auto engine = eglGetCurrentContext();
      EGLint client = EGL_OPENGL_ES_API;
      if (!eglQueryContext(egl_display_, engine, EGL_CONTEXT_CLIENT_TYPE, &client)) {
        error = "Cannot query Flutter EGL client API"; return false;
      }
      const auto previous_api = eglQueryAPI(); eglBindAPI(client);
      // Flutter uses surfaceless contexts. Match its config and share group.
      EGLint id = 0; eglQueryContext(egl_display_, engine, EGL_CONFIG_ID, &id);
      const EGLint config_attributes[]{EGL_CONFIG_ID, id, EGL_NONE};
      EGLConfig config = nullptr; EGLint count = 0;
      eglChooseConfig(egl_display_, config_attributes, &config, 1, &count);
      const EGLint attributes[]{EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
      egl_context_ = eglCreateContext(egl_display_, config, engine,
          client == EGL_OPENGL_ES_API ? attributes : nullptr);
      eglBindAPI(previous_api);
      if (egl_context_ == EGL_NO_CONTEXT) { error = "Cannot create shared Linux video EGL context"; return false; }
      return true;
    }
    auto* current = gdk_gl_context_get_current();
    if (!current) { error = "Flutter GL context is unavailable"; return false; }
    gdk_context_ = GDK_GL_CONTEXT(g_object_ref(current)); return true;
  }
  bool shared() const { return egl_context_ != EGL_NO_CONTEXT; }
  class Scope {
   public:
    explicit Scope(TextureGlContext& owner) : owner_(owner) {
      if (owner_.egl_context_ != EGL_NO_CONTEXT) {
        previous_display_ = eglGetCurrentDisplay(); previous_context_ = eglGetCurrentContext();
        draw_ = eglGetCurrentSurface(EGL_DRAW); read_ = eglGetCurrentSurface(EGL_READ);
        previous_api_ = eglQueryAPI();
        EGLint client = EGL_OPENGL_ES_API;
        eglQueryContext(owner_.egl_display_, owner_.egl_context_, EGL_CONTEXT_CLIENT_TYPE, &client);
        eglBindAPI(client);
        current_ = eglMakeCurrent(owner_.egl_display_, EGL_NO_SURFACE, EGL_NO_SURFACE, owner_.egl_context_);
      } else {
        previous_gdk_ = gdk_gl_context_get_current();
        if (previous_gdk_) g_object_ref(previous_gdk_);
        gdk_gl_context_make_current(owner_.gdk_context_); current_ = true;
      }
    }
    ~Scope() {
      if (owner_.egl_context_ != EGL_NO_CONTEXT) {
        if (previous_display_ != EGL_NO_DISPLAY) eglMakeCurrent(previous_display_, draw_, read_, previous_context_);
        else eglMakeCurrent(owner_.egl_display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglBindAPI(previous_api_);
      } else if (previous_gdk_) {
        gdk_gl_context_make_current(previous_gdk_); g_object_unref(previous_gdk_);
      } else gdk_gl_context_clear_current();
    }
    bool current() const { return current_; }
    bool shared() const { return owner_.egl_context_ != EGL_NO_CONTEXT; }
   private:
    TextureGlContext& owner_;
    EGLDisplay previous_display_ = EGL_NO_DISPLAY;
    EGLContext previous_context_ = EGL_NO_CONTEXT;
    EGLSurface draw_ = EGL_NO_SURFACE, read_ = EGL_NO_SURFACE;
    EGLenum previous_api_ = EGL_OPENGL_ES_API;
    GdkGLContext* previous_gdk_ = nullptr;
    bool current_ = false;
  };
 private:
  EGLDisplay egl_display_ = EGL_NO_DISPLAY;
  EGLContext egl_context_ = EGL_NO_CONTEXT;
  GdkGLContext* gdk_context_ = nullptr;
};
