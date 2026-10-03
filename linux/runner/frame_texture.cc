// SPDX-License-Identifier: GPL-3.0-only
#include "frame_texture.h"

#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

namespace airplay_texture {
struct Pixels {
  uint32_t width = 1;
  uint32_t height = 1;
  std::vector<uint8_t> rgba{0, 0, 0, 255};
};
struct TextureData {
  std::mutex mutex;
  std::shared_ptr<const Pixels> pending = std::make_shared<Pixels>();
  // Only the raster thread changes this reference. Producer updates and Clear
  // cannot free the buffer Flutter uploads after CopyPixels returns.
  std::shared_ptr<const Pixels> raster;
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
    data->raster = data->pending;
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

FrameTexture::FrameTexture(FlTextureRegistrar* registrar)
    : registrar_(FL_TEXTURE_REGISTRAR(g_object_ref(registrar))),
      texture_(FL_PIXEL_BUFFER_TEXTURE(
          g_object_new(airplay_frame_texture_get_type(), nullptr))) {}

FrameTexture::~FrameTexture() {
  if (registered_)
    fl_texture_registrar_unregister_texture(registrar_, FL_TEXTURE(texture_));
  g_object_unref(texture_);
  g_object_unref(registrar_);
}

bool FrameTexture::Register() {
  if (!registered_)
    registered_ = fl_texture_registrar_register_texture(registrar_, FL_TEXTURE(texture_));
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
  auto pixels = CopyFrame(frame);
  if (!pixels) return false;
  auto* data = reinterpret_cast<AirplayFrameTexture*>(texture_)->data;
  std::lock_guard<std::mutex> lock(data->mutex);
  data->pending = std::move(pixels);
  return true;
}

void FrameTexture::Clear() {
  auto* data = reinterpret_cast<AirplayFrameTexture*>(texture_)->data;
  std::lock_guard<std::mutex> lock(data->mutex);
  data->pending = std::make_shared<Pixels>();
}

void FrameTexture::Notify() {
  if (registered_)
    fl_texture_registrar_mark_texture_frame_available(registrar_, FL_TEXTURE(texture_));
}
