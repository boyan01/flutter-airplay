// SPDX-License-Identifier: GPL-3.0-only
#include "frame_texture.h"
#include "gl_context.h"
#include "../../native/playback/texture_stats.h"

#include <cstring>
#include <deque>
#include <epoxy/gl.h>
#include <memory>
#include <mutex>
#include <vector>

namespace airplay_texture {
struct Pixels {
  uint32_t width = 1;
  uint32_t height = 1;
  std::vector<uint8_t> rgba{0, 0, 0, 255};
  AirplayLinuxVideoFrame native{};
  ~Pixels() { if (native.native_frame && native.release) native.release(native.native_frame); }
};
struct TextureData {
  std::mutex mutex;
  airplay::TextureStats stats;
  int64_t notification_ns = 0, marked_ns = 0, last_populate_ns = 0;
  FlTextureRegistrar* pump_registrar = nullptr;
  bool registered = false, pumping = false, pump_pending = false;
  GSource* pump_source = nullptr;
  GMainContext* pump_context = g_main_context_ref_thread_default();
  uint64_t repaint_requests = 0;
  ~TextureData() { if (pump_registrar) g_object_unref(pump_registrar); g_main_context_unref(pump_context); }
  uint64_t notification_requests = 0, notification_coalesced = 0, notifications = 0;
  uint64_t populate_calls = 0, replaced_during_populate = 0;
  airplay::TimingSamples mark_to_populate, populate_gap, populate_cost;
  struct QueuedFrame { std::shared_ptr<const Pixels> pixels; uint64_t sequence; int64_t received_ns; };
  std::deque<QueuedFrame> frames;
  QueuedFrame selected{};
  std::shared_ptr<const Pixels> pending = std::make_shared<Pixels>();
  // Only the raster thread changes this reference. Producer updates and Clear
  // cannot free the buffer Flutter uploads after CopyPixels returns.
  std::shared_ptr<const Pixels> raster;
  std::unique_ptr<airplay::LinuxGpuRenderer> renderer;
  std::unique_ptr<TextureGlContext> context;
  std::string path, error;
  uint32_t gl_name = 0;
  bool error_pending = false;
  uint64_t gpu_frames = 0, gpu_errors = 0;
  airplay::TimingSamples gpu_cost;
};
}  // namespace airplay_texture

using airplay_texture::Pixels;
using airplay_texture::TextureData;

typedef struct _AirplayFrameTexture {
  FlPixelBufferTexture parent_instance;
  TextureData* data;
} AirplayFrameTexture;
typedef struct _AirplayFrameTextureClass {
  FlPixelBufferTextureClass parent_class;
} AirplayFrameTextureClass;

G_DEFINE_TYPE(AirplayFrameTexture, airplay_frame_texture,
              fl_pixel_buffer_texture_get_type())

static gboolean CopyPixels(FlPixelBufferTexture* texture, const uint8_t** buffer,
                           uint32_t* width, uint32_t* height, GError**) {
  auto* data = reinterpret_cast<AirplayFrameTexture*>(texture)->data;
  {
    std::lock_guard<std::mutex> lock(data->mutex);
    data->raster = data->pending; data->stats.acquire();
  }
  *buffer = data->raster->rgba.data();
  *width = data->raster->width;
  *height = data->raster->height;
  return TRUE;
}

static void Finalize(GObject* object) {
  delete reinterpret_cast<AirplayFrameTexture*>(object)->data;
  G_OBJECT_CLASS(airplay_frame_texture_parent_class)->finalize(object);
}

static void airplay_frame_texture_class_init(AirplayFrameTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = CopyPixels;
  G_OBJECT_CLASS(klass)->finalize = Finalize;
}

static void airplay_frame_texture_init(AirplayFrameTexture* self) {
  self->data = new TextureData();
}

// GL output retains decoded frames instead of copying RGBA on the producer.
// GPU work and native-frame release happen on Flutter's raster context.
typedef struct _AirplayGlTexture { FlTextureGL parent_instance; TextureData* data; } AirplayGlTexture;
typedef struct _AirplayGlTextureClass { FlTextureGLClass parent_class; } AirplayGlTextureClass;
G_DEFINE_TYPE(AirplayGlTexture, airplay_gl_texture, fl_texture_gl_get_type())

// A raster-completion request keeps texture-only redraws on the engine's own
// frame cadence. All embedder calls stay on GTK's platform thread. Stop after
// two input periods without a frame; producer notifications restart naturally.
static void RequestNextFrame(FlTextureGL* texture, TextureData* data) {
  std::lock_guard<std::mutex> lock(data->mutex);
  if (!data->pump_registrar || !data->registered || !data->pumping || data->pump_pending) return;
  data->pump_pending = true;
  auto* source = g_idle_source_new();
  data->pump_source = source;
  g_source_set_priority(source, G_PRIORITY_DEFAULT);
  g_source_set_callback(source, [](gpointer value) -> gboolean {
    auto* texture = FL_TEXTURE_GL(value);
    auto* data = reinterpret_cast<AirplayGlTexture*>(texture)->data;
    bool mark = false;
    GSource* source = nullptr;
    {
      std::lock_guard<std::mutex> lock(data->mutex);
      data->pump_pending = false;
      source = data->pump_source; data->pump_source = nullptr;
      const auto now = airplay::TimingSamples::now_ns();
      mark = data->registered && data->pumping && data->stats.received_ns &&
          (now - data->stats.received_ns < 33333334 || !data->frames.empty());
      if (!mark && data->frames.empty()) data->pumping = false;
      if (mark) {
        ++data->repaint_requests; ++data->notifications;
        if (!data->marked_ns) data->marked_ns = now;
      }
    }
    if (source) g_source_unref(source);
    if (mark) fl_texture_registrar_mark_texture_frame_available(data->pump_registrar, FL_TEXTURE(texture));
    return G_SOURCE_REMOVE;
  }, g_object_ref(texture), [](gpointer value) { g_object_unref(value); });
  g_source_attach(source, data->pump_context);
}

static gboolean Populate(FlTextureGL* texture, uint32_t* target, uint32_t* name,
                         uint32_t* width, uint32_t* height, GError** error) {
  auto* data = reinterpret_cast<AirplayGlTexture*>(texture)->data;
  const auto started_ns = airplay::TimingSamples::now_ns();
  // Include failures and cached reads in callback cost. TimingSamples measure
  // CPU wall duration, not completion of asynchronous GPU commands.
  struct PopulateTimer {
    TextureData* data;
    int64_t started;
    ~PopulateTimer() {
      std::lock_guard<std::mutex> lock(data->mutex);
      data->populate_cost.add(airplay::TimingSamples::now_ns() - started);
    }
  } timer{data, started_ns};
  std::shared_ptr<const Pixels> pixels;
  uint64_t received_sequence = 0;
  {
    std::lock_guard<std::mutex> lock(data->mutex);
    received_sequence = data->stats.sequence;
    ++data->populate_calls;
    if (data->last_populate_ns) data->populate_gap.add(started_ns - data->last_populate_ns);
    data->last_populate_ns = started_ns;
    if (data->marked_ns) {
      data->mark_to_populate.add(started_ns - data->marked_ns);
      data->marked_ns = 0;
    }
    if (data->pump_registrar) {
      const bool drain_last = data->frames.size() == 1 &&
          started_ns - data->stats.received_ns >= 33333334;
      // One frame of jitter reserve avoids repeating then skipping a frame
      // when the producer and Flutter refresh clocks cross in phase.
      if (data->frames.size() > 1 || !data->selected.pixels || drain_last) {
        if (!data->frames.empty()) { data->selected = data->frames.front(); data->frames.pop_front(); }
      }
      pixels = data->selected.pixels ? data->selected.pixels : data->pending;
    } else pixels = data->pending;
    // Account for the selected frame before conversion: a producer replacement
    // during conversion must not hide a frame actually consumed by Flutter.
    if (data->pump_registrar && data->selected.pixels)
      data->stats.acquire(data->selected.sequence, data->selected.received_ns);
    else data->stats.acquire();
  }
  if (!data->renderer) {
    auto context = std::make_unique<TextureGlContext>();
    std::string detail;
    if (!context->Initialize(detail)) {
      { std::lock_guard<std::mutex> lock(data->mutex); data->error = detail; data->error_pending = true; ++data->gpu_errors; }
      g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, detail.c_str()); return FALSE;
    }
    data->context = std::move(context);
    data->renderer = std::make_unique<airplay::LinuxGpuRenderer>();
  }
  // Flutter may acquire the same frame repeatedly; reuse its already converted texture.
  if (data->raster != pixels) {
    const auto started = airplay::TimingSamples::now_ns();
    auto frame = pixels->native;
    if (!frame.native_frame) frame = {pixels->rgba.data(), int(pixels->width*4), int(pixels->width), int(pixels->height)};
    std::string detail;
    uint32_t result = 0;
    bool rendered = false;
    const bool shared = data->context->shared();
    const bool fences = shared && epoxy_gl_version() >= 30;
    GLsync engine_done = nullptr, video_done = nullptr;
    if (shared) {
      if (fences) { engine_done = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0); glFlush(); }
      if (!engine_done) glFinish();
    }
    {
      TextureGlContext::Scope context(*data->context);
      if (!context.current()) detail = "Cannot make Linux video GL context current";
      else {
        // Protect the output from the previous engine sampling it, then make
        // this frame's writes visible in the shared engine context. GPU waits
        // preserve ordering without a CPU readback or full-frame stall.
        if (engine_done) glWaitSync(engine_done, 0, GL_TIMEOUT_IGNORED);
        rendered = data->renderer->render(frame, result, detail);
        if (rendered && shared) {
          if (fences) { video_done = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0); glFlush(); }
          if (!video_done) glFinish();
        }
      }
    }
    if (video_done) { glWaitSync(video_done, 0, GL_TIMEOUT_IGNORED); glDeleteSync(video_done); }
    if (engine_done) glDeleteSync(engine_done);
    if (!rendered) {
      { std::lock_guard<std::mutex> lock(data->mutex); data->error = detail; data->error_pending = true; ++data->gpu_errors; }
      g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, detail.c_str()); return FALSE;
    }
    data->raster = pixels;
    { std::lock_guard<std::mutex> lock(data->mutex);
      ++data->gpu_frames; data->gpu_cost.add(airplay::TimingSamples::now_ns()-started);
      data->path = data->renderer->path(); data->error.clear(); data->error_pending = false;
    }
    data->gl_name = result;
  }
  // Keep the GL name beside the subclass, never ask the renderer to upload twice.
  *name = data->gl_name;
  *target = GL_TEXTURE_2D; *width = pixels->width; *height = pixels->height;
  { std::lock_guard<std::mutex> lock(data->mutex); if (data->stats.sequence != received_sequence) ++data->replaced_during_populate; }
  RequestNextFrame(texture, data);
  return TRUE;
}

static void GlFinalize(GObject* object) {
  auto* data = reinterpret_cast<AirplayGlTexture*>(object)->data;
  if (data->context) {
    { TextureGlContext::Scope context(*data->context); data->renderer.reset(); }
    data->context.reset();
  }
  delete data;
  G_OBJECT_CLASS(airplay_gl_texture_parent_class)->finalize(object);
}
static void airplay_gl_texture_class_init(AirplayGlTextureClass* klass) {
  FL_TEXTURE_GL_CLASS(klass)->populate = Populate;
  G_OBJECT_CLASS(klass)->finalize = GlFinalize;
}
static void airplay_gl_texture_init(AirplayGlTexture* self) { self->data = new TextureData(); }

FrameTexture::FrameTexture(FlTextureRegistrar* registrar, bool gpu, bool frame_pump)
    : registrar_(FL_TEXTURE_REGISTRAR(g_object_ref(registrar))),
      texture_(FL_TEXTURE(g_object_new(gpu ? airplay_gl_texture_get_type() : airplay_frame_texture_get_type(), nullptr))), gpu_(gpu) {
  if (gpu_ && frame_pump) reinterpret_cast<AirplayGlTexture*>(texture_)->data->pump_registrar =
      FL_TEXTURE_REGISTRAR(g_object_ref(registrar_));
}

FrameTexture::~FrameTexture() {
  auto* data = gpu_ ? reinterpret_cast<AirplayGlTexture*>(texture_)->data : reinterpret_cast<AirplayFrameTexture*>(texture_)->data;
  GSource* source = nullptr;
  {
    std::lock_guard<std::mutex> lock(data->mutex);
    data->registered = data->pumping = false;
    source = data->pump_source; data->pump_source = nullptr;
  }
  // Cancel while the engine/context is alive, before unregistering the texture.
  if (source) { g_source_destroy(source); g_source_unref(source); }
  if (registered_)
    fl_texture_registrar_unregister_texture(registrar_, FL_TEXTURE(texture_));
  g_object_unref(texture_);
  g_object_unref(registrar_);
}

bool FrameTexture::Register() {
  if (!registered_)
    registered_ = fl_texture_registrar_register_texture(registrar_, FL_TEXTURE(texture_));
  auto* data = gpu_ ? reinterpret_cast<AirplayGlTexture*>(texture_)->data : reinterpret_cast<AirplayFrameTexture*>(texture_)->data;
  { std::lock_guard<std::mutex> lock(data->mutex); data->registered = registered_; }
  return registered_;
}

int64_t FrameTexture::identifier() const {
  return registered_ ? fl_texture_get_id(FL_TEXTURE(texture_)) : -1;
}

static std::shared_ptr<const Pixels> CopyFrame(const AirplayLinuxVideoFrame& frame) {
  if (!frame.data || frame.width <= 0 || frame.height <= 0 ||
      frame.width > 4096 || frame.height > 4096 ||
      frame.stride < frame.width * 4) return nullptr;
  auto pixels = std::make_shared<Pixels>();
  pixels->width = static_cast<uint32_t>(frame.width);
  pixels->height = static_cast<uint32_t>(frame.height);
  const size_t row_bytes = static_cast<size_t>(frame.width) * 4;
  pixels->rgba.resize(row_bytes * frame.height);
  for (int y = 0; y < frame.height; ++y) {
    std::memcpy(pixels->rgba.data() + static_cast<size_t>(y) * row_bytes,
                frame.data + static_cast<size_t>(y) * frame.stride, row_bytes);
  }
  return pixels;
}

bool FrameTexture::Receive(const AirplayLinuxVideoFrame& frame) {
  std::shared_ptr<const Pixels> pixels;
  if (gpu_ && frame.native_frame) {
    if (!frame.retain || !frame.release || frame.width < 1 || frame.height < 1 || frame.width > 4096 || frame.height > 4096) return false;
    auto retained = std::make_shared<Pixels>(); retained->native = frame;
    retained->native.native_frame = frame.retain(frame.native_frame);
    if (!retained->native.native_frame) return false;
    retained->width = frame.width; retained->height = frame.height;
    pixels = std::move(retained);
  } else pixels = CopyFrame(frame);
  if (!pixels) return false;
  auto* data = gpu_ ? reinterpret_cast<AirplayGlTexture*>(texture_)->data : reinterpret_cast<AirplayFrameTexture*>(texture_)->data;
  std::lock_guard<std::mutex> lock(data->mutex);
  if (data->pump_registrar && (data->pending->width != pixels->width || data->pending->height != pixels->height)) {
    data->stats.overwritten += data->frames.size();
    data->frames.clear(); data->selected = {};
  }
  data->pending = std::move(pixels);
  if (data->pump_registrar) {
    const bool overflow = data->frames.size() >= 3;
    if (overflow) data->frames.pop_front();
    data->stats.receive(overflow);
    data->frames.push_back({data->pending, data->stats.sequence, data->stats.received_ns});
  } else data->stats.receive();
  data->pumping = true;
  return true;
}

void FrameTexture::Clear() {
  auto* data = gpu_ ? reinterpret_cast<AirplayGlTexture*>(texture_)->data : reinterpret_cast<AirplayFrameTexture*>(texture_)->data;
  std::lock_guard<std::mutex> lock(data->mutex);
  data->pumping = false; data->frames.clear(); data->selected = {};
  data->pending = std::make_shared<Pixels>(); data->stats.clear(); data->notification_ns = data->marked_ns = data->last_populate_ns = 0; data->error.clear(); data->error_pending = false;
}

void FrameTexture::NotificationRequested(bool coalesced) {
  auto* data = gpu_ ? reinterpret_cast<AirplayGlTexture*>(texture_)->data : reinterpret_cast<AirplayFrameTexture*>(texture_)->data;
  std::lock_guard<std::mutex> lock(data->mutex);
  ++data->notification_requests;
  if (coalesced) ++data->notification_coalesced;
  else data->notification_ns = airplay::TimingSamples::now_ns();
}

std::string FrameTexture::Diagnostics() {
  auto* data = gpu_ ? reinterpret_cast<AirplayGlTexture*>(texture_)->data : reinterpret_cast<AirplayFrameTexture*>(texture_)->data;
  std::lock_guard<std::mutex> lock(data->mutex);
  auto report = data->stats.report(gpu_ ? "Linux GL" : "Linux pixel", data->pending->width, data->pending->height);
  if (gpu_ && !report.empty()) {
    report += " output_path=[" + data->path + "] gpu_frames=" + std::to_string(data->gpu_frames)
        + " gpu_errors=" + std::to_string(data->gpu_errors) + data->gpu_cost.text("gpu_output");
    if (!data->error.empty()) report += " output_error=[" + data->error + "]";
    report += " notification_requests=" + std::to_string(data->notification_requests)
        + " notification_coalesced=" + std::to_string(data->notification_coalesced)
        + " notifications=" + std::to_string(data->notifications)
        + " queued_frames=" + std::to_string(data->frames.size())
        + " repaint_requests=" + std::to_string(data->repaint_requests)
        + " populate_calls=" + std::to_string(data->populate_calls)
        + " replaced_during_populate=" + std::to_string(data->replaced_during_populate)
        + data->mark_to_populate.text("mark_to_populate")
        + data->populate_gap.text("populate_gap") + data->populate_cost.text("populate_cost");
    data->gpu_frames = data->gpu_errors = 0; data->gpu_cost = {};
    data->notification_requests = data->notification_coalesced = data->notifications = 0;
    data->populate_calls = data->replaced_during_populate = data->repaint_requests = 0;
    data->mark_to_populate = {}; data->populate_gap = {}; data->populate_cost = {};
  }
  return report;
}

void FrameTexture::Notify() {
  auto* data = gpu_ ? reinterpret_cast<AirplayGlTexture*>(texture_)->data : reinterpret_cast<AirplayFrameTexture*>(texture_)->data;
  {
    std::lock_guard<std::mutex> lock(data->mutex);
    if (data->notification_ns) data->stats.notify_delay.add(airplay::TimingSamples::now_ns() - data->notification_ns);
    data->notification_ns = 0;
    ++data->notifications;
    // Keep the oldest unconsumed mark; replacing it with every new mark would
    // conceal time spent waiting for Flutter to call Populate.
    if (!data->marked_ns) data->marked_ns = airplay::TimingSamples::now_ns();
  }
  if (registered_)
    fl_texture_registrar_mark_texture_frame_available(registrar_, FL_TEXTURE(texture_));
}

std::string FrameTexture::TakeError() {
  if (!gpu_) return {};
  auto* data = reinterpret_cast<AirplayGlTexture*>(texture_)->data;
  std::lock_guard<std::mutex> lock(data->mutex);
  if (!data->error_pending) return {};
  data->error_pending = false;
  return data->error;
}
