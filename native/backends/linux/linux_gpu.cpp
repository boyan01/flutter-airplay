// SPDX-License-Identifier: GPL-3.0-only
#include "linux_video.h"
#include "../ffmpeg/ffmpeg_colors.h"
#include <epoxy/gl.h>
#include <array>
#include <cstring>
#include <vector>
extern "C" {
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#ifdef AIRPLAY_CUDA_INTEROP
#include <ffnvcodec/dynlink_cuda.h>
#include <libavutil/hwcontext_cuda.h>
#endif
}
#ifdef AIRPLAY_CUDA_INTEROP
#include <dlfcn.h>
#endif

namespace airplay {
namespace {
// populate runs inside Flutter's GL context. Restore every state we touch so
// Skia's cached bindings remain valid (particularly on NVIDIA drivers).
struct GlState {
    GLint program, vao, draw, read, active, unpack, row, pbo, viewport[4], textures[3], samplers[3];
    GLboolean mask[4];
    const bool samplers_available = !epoxy_is_desktop_gl() || epoxy_gl_version() >= 33;
    const std::array<GLenum, 7> caps{GL_BLEND, GL_DEPTH_TEST, GL_STENCIL_TEST, GL_SCISSOR_TEST,
        GL_CULL_FACE, GL_FRAMEBUFFER_SRGB, GL_RASTERIZER_DISCARD};
    std::array<GLboolean, 7> enabled{}, available{};
    GlState() {
        glGetIntegerv(GL_CURRENT_PROGRAM, &program); glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao);
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw); glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read);
        glGetIntegerv(GL_ACTIVE_TEXTURE, &active); glGetIntegerv(GL_UNPACK_ALIGNMENT, &unpack);
        glGetIntegerv(GL_UNPACK_ROW_LENGTH, &row); glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &pbo);
        glGetIntegerv(GL_VIEWPORT, viewport); glGetBooleanv(GL_COLOR_WRITEMASK, mask);
        for (int i = 0; i < 3; ++i) {
            glActiveTexture(GL_TEXTURE0 + i); glGetIntegerv(GL_TEXTURE_BINDING_2D, &textures[i]);
            if (samplers_available) { glGetIntegerv(GL_SAMPLER_BINDING, &samplers[i]); glBindSampler(i, 0); }
        }
        for (size_t i = 0; i < caps.size(); ++i) {
            available[i] = caps[i] != GL_FRAMEBUFFER_SRGB || epoxy_is_desktop_gl() || epoxy_has_gl_extension("GL_EXT_sRGB_write_control");
            if (!available[i]) continue;
            enabled[i] = glIsEnabled(caps[i]); glDisable(caps[i]); }
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0); glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    }
    ~GlState() {
        for (int i = 0; i < 3; ++i) { glActiveTexture(GL_TEXTURE0 + i); glBindTexture(GL_TEXTURE_2D, textures[i]); if (samplers_available) glBindSampler(i, samplers[i]); }
        glActiveTexture(active); glUseProgram(program); glBindVertexArray(vao);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, draw); glBindFramebuffer(GL_READ_FRAMEBUFFER, read);
        glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, pbo); glPixelStorei(GL_UNPACK_ALIGNMENT, unpack); glPixelStorei(GL_UNPACK_ROW_LENGTH, row);
        glColorMask(mask[0], mask[1], mask[2], mask[3]);
        for (size_t i = 0; i < caps.size(); ++i) if (enabled[i]) glEnable(caps[i]);
    }
};
GLuint shader(GLenum type, const char *source, std::string &error) {
    const GLuint value = glCreateShader(type); glShaderSource(value, 1, &source, nullptr); glCompileShader(value);
    GLint ok = 0; glGetShaderiv(value, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[1024]{}; glGetShaderInfoLog(value, sizeof(log), nullptr, log); error = log; glDeleteShader(value); return 0; }
    return value;
}
struct FrameFree { void operator()(AVFrame *value) const { av_frame_free(&value); } };
}

struct LinuxGpuRenderer::Impl {
    GLuint planes[3]{}, output = 0, program = 0, framebuffer = 0, vao = 0;
    int width = 0, height = 0, allocated_width = 0, allocated_height = 0, layout = -1;
    FFmpegColors colors;
    std::vector<uint8_t> packed;
    const char *mode = "OpenGL RGBA upload";
    bool allow_cuda, allocated_yuv = false;
    explicit Impl(bool cuda_interop) : allow_cuda(cuda_interop) {}
#ifdef AIRPLAY_CUDA_INTEROP
    void *library = nullptr;
    tcuCtxPushCurrent_v2 *push = nullptr;
    tcuCtxPopCurrent_v2 *pop = nullptr;
    tcuGraphicsGLRegisterImage *reg = nullptr;
    tcuGraphicsUnregisterResource *unreg = nullptr;
    tcuGraphicsMapResources *map = nullptr;
    tcuGraphicsUnmapResources *unmap = nullptr;
    tcuGraphicsSubResourceGetMappedArray *array = nullptr;
    tcuMemcpy2D_v2 *copy = nullptr;
    tcuStreamSynchronize *sync = nullptr;
    bool cuda_attempted = false, cuda_failed = false;
    std::array<CUgraphicsResource, 3> cuda_planes{};
    CUcontext registered_context = nullptr;
    AVBufferRef *registered_device = nullptr;
    bool release_cuda_planes() {
        // Keep ownership on failure: never reuse registrations with another
        // CUDA context or replace GL storage that is still registered.
        if (registered_context && (!push || push(registered_context) != CUDA_SUCCESS)) return false;
        bool ok = true;
        if (registered_context) {
            for (auto &resource : cuda_planes) {
                if (resource && unreg(resource) != CUDA_SUCCESS) ok = false;
                else resource = nullptr;
            }
            CUcontext previous = nullptr;
            if (pop(&previous) != CUDA_SUCCESS) ok = false;
        }
        if (!ok) return false;
        registered_context = nullptr;
        av_buffer_unref(&registered_device);
        return true;
    }
    bool load_cuda() {
        if (cuda_attempted) return library && push && pop && reg && unreg && map && unmap && array && copy && sync;
        cuda_attempted = true; library = dlopen("libcuda.so.1", RTLD_NOW | RTLD_LOCAL);
        if (!library) return false;
#define LOAD(member, symbol) member = reinterpret_cast<decltype(member)>(dlsym(library, symbol))
        LOAD(push, "cuCtxPushCurrent_v2"); LOAD(pop, "cuCtxPopCurrent_v2");
        LOAD(reg, "cuGraphicsGLRegisterImage"); LOAD(unreg, "cuGraphicsUnregisterResource");
        LOAD(map, "cuGraphicsMapResources"); LOAD(unmap, "cuGraphicsUnmapResources");
        LOAD(array, "cuGraphicsSubResourceGetMappedArray"); LOAD(copy, "cuMemcpy2D_v2"); LOAD(sync, "cuStreamSynchronize");
#undef LOAD
        return push && pop && reg && unreg && map && unmap && array && copy && sync;
    }
    bool cuda_upload(const AVFrame &frame, int count, int bytes, bool interleaved) {
        if (cuda_failed || !load_cuda() || !frame.hw_frames_ctx) return false;
        auto *frames = reinterpret_cast<AVHWFramesContext *>(frame.hw_frames_ctx->data);
        auto *device = static_cast<AVCUDADeviceContext *>(frames->device_ctx->hwctx);
        // Registrations belong to both the GL storage and CUDA device context.
        // Retain the device while registered resources outlive a decoder session.
        if (registered_context && registered_context != device->cuda_ctx && !release_cuda_planes()) {
            cuda_failed = true; return false;
        }
        if (!registered_context) {
            registered_device = av_buffer_ref(frames->device_ref);
            if (!registered_device) { cuda_failed = true; return false; }
            registered_context = device->cuda_ctx;
        }
        if (push(device->cuda_ctx) != CUDA_SUCCESS) { cuda_failed = true; return false; }
        bool ok = sync(device->stream) == CUDA_SUCCESS;
        for (int i = 0; i < count && ok; ++i) {
            auto &resource = cuda_planes[i];
            ok = resource || reg(&resource, planes[i], GL_TEXTURE_2D,
                CU_GRAPHICS_REGISTER_FLAGS_WRITE_DISCARD) == CUDA_SUCCESS;
            if (!ok) break;
            const bool mapped = map(1, &resource, nullptr) == CUDA_SUCCESS;
            CUarray destination = nullptr;
            ok = mapped && array(&destination, resource, 0, 0) == CUDA_SUCCESS;
            if (ok) {
                CUDA_MEMCPY2D region{};
                region.srcMemoryType = CU_MEMORYTYPE_DEVICE;
                region.srcDevice = reinterpret_cast<CUdeviceptr>(frame.data[i]); region.srcPitch = frame.linesize[i];
                region.dstMemoryType = CU_MEMORYTYPE_ARRAY; region.dstArray = destination;
                region.WidthInBytes = size_t(i ? (width + 1) / 2 : width) * bytes * (i && interleaved ? 2 : 1);
                region.Height = i ? (height + 1) / 2 : height;
                ok = copy(&region) == CUDA_SUCCESS;
            }
            if (mapped && unmap(1, &resource, nullptr) != CUDA_SUCCESS) ok = false;
        }
        CUcontext previous = nullptr;
        if (pop(&previous) != CUDA_SUCCESS) ok = false;
        if (!ok) {
            release_cuda_planes();
            cuda_failed = true; // avoid retrying an incompatible GL adapter every frame
        }
        return ok;
    }
#endif
    ~Impl() {
#ifdef AIRPLAY_CUDA_INTEROP
        release_cuda_planes();
#endif
        glDeleteTextures(3, planes); if (output) glDeleteTextures(1, &output);
        if (program) glDeleteProgram(program);
        if (framebuffer) glDeleteFramebuffers(1, &framebuffer);
        if (vao) glDeleteVertexArrays(1, &vao);
#ifdef AIRPLAY_CUDA_INTEROP
        if (library) dlclose(library);
#endif
    }
    bool initialize(std::string &error) {
        if (program) return true;
        const char *vertex = R"(#version 150
out vec2 uv;
void main() { vec2 p=vec2((gl_VertexID<<1)&2, gl_VertexID&2); uv=p; gl_Position=vec4(p*2.0-1.0,0,1); }
)";
        const char *fragment = R"(#version 150
in vec2 uv;
out vec4 pixel;
uniform sampler2D yPlane, uPlane, vPlane;
uniform int interleaved;
uniform vec3 offset, scale;
uniform vec4 coefficients;
uniform float sampleScale;
void main() {
    float y=texture(yPlane,uv).r;
    vec2 c=interleaved==1 ? texture(uPlane,uv).rg : vec2(texture(uPlane,uv).r,texture(vPlane,uv).r);
    vec3 v=(vec3(y,c)*sampleScale-offset)*scale;
    pixel=vec4(v.x+coefficients.x*v.z, v.x+coefficients.y*v.y+coefficients.z*v.z, v.x+coefficients.w*v.y,1);
}
)";
        std::string vertex_source(vertex), fragment_source(fragment);
        if (!epoxy_is_desktop_gl()) {
            vertex_source.replace(0, std::strlen("#version 150"), "#version 300 es");
            fragment_source.replace(0, std::strlen("#version 150"), "#version 300 es\nprecision highp float;");
        }
        const auto vs = shader(GL_VERTEX_SHADER, vertex_source.c_str(), error); if (!vs) return false;
        const auto fs = shader(GL_FRAGMENT_SHADER, fragment_source.c_str(), error); if (!fs) { glDeleteShader(vs); return false; }
        const GLuint candidate = glCreateProgram(); glAttachShader(candidate, vs); glAttachShader(candidate, fs);
        glLinkProgram(candidate); glDeleteShader(vs); glDeleteShader(fs);
        GLint ok = 0; glGetProgramiv(candidate, GL_LINK_STATUS, &ok);
        if (!ok) { error = "Cannot link Linux YUV shader"; glDeleteProgram(candidate); return false; }
        program = candidate; glGenTextures(3, planes); glGenTextures(1, &output);
        glGenFramebuffers(1, &framebuffer); glGenVertexArrays(1, &vao); return true;
    }
    void texture(GLuint name, int w, int h, GLenum internal, GLenum channels, GLenum type, const void *pixels) {
        glBindTexture(GL_TEXTURE_2D, name);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D, 0, internal, w, h, 0, channels, type, pixels);
    }
    // Handles positive/padded and negative CPU strides without interpreting GPU pointers.
    void upload(GLuint name, const uint8_t *data, int stride, int w, int h, int channels, int bytes) {
        const size_t row_bytes = size_t(w) * channels * bytes;
        const void *pixels = data;
        if (stride < 0 || size_t(stride) != row_bytes) {
            packed.resize(row_bytes * h);
            for (int y = 0; y < h; ++y) std::memcpy(packed.data() + row_bytes*y, data + int64_t(y)*stride, row_bytes);
            pixels = packed.data();
        }
        glBindTexture(GL_TEXTURE_2D, name); glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, channels == 2 ? GL_RG : GL_RED,
            bytes == 2 ? GL_UNSIGNED_SHORT : GL_UNSIGNED_BYTE, pixels);
    }
    bool render(const AirplayLinuxVideoFrame &input, std::string &error) {
        GlState restore;
        if (!initialize(error)) return false;
        glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
        auto *frame = static_cast<AVFrame *>(input.native_frame);
        std::unique_ptr<AVFrame, FrameFree> downloaded;
        AVPixelFormat format = frame ? static_cast<AVPixelFormat>(frame->format) : AV_PIX_FMT_RGBA;
        bool hardware = frame && frame->hw_frames_ctx;
        if (hardware) format = reinterpret_cast<AVHWFramesContext *>(frame->hw_frames_ctx->data)->sw_format;
        int bytes = 1, count = 3; bool interleaved = false, supported = true;
        switch (format) {
            case AV_PIX_FMT_NV12: interleaved = true; count = 2; break;
            case AV_PIX_FMT_P010LE: interleaved = true; count = 2; bytes = 2; break;
            case AV_PIX_FMT_YUV420P: case AV_PIX_FMT_YUVJ420P: break;
            case AV_PIX_FMT_YUV420P10LE: bytes = 2; break;
            default: supported = false; break;
        }
        if (bytes == 2 && !epoxy_is_desktop_gl() && !epoxy_has_gl_extension("GL_EXT_texture_norm16")) supported = false;
        if (frame && frame->colorspace != AVCOL_SPC_UNSPECIFIED && frame->colorspace != AVCOL_SPC_BT709 &&
            frame->colorspace != AVCOL_SPC_BT470BG && frame->colorspace != AVCOL_SPC_SMPTE170M &&
            frame->colorspace != AVCOL_SPC_BT2020_NCL) supported = false;
        width = input.width; height = input.height;
        // Reallocate on dimension/format changes; planes stay cached between frames.
        const int next_layout = int(format);
        glActiveTexture(GL_TEXTURE0);
        if (allocated_width != width || allocated_height != height || layout != next_layout || allocated_yuv != supported) {
#ifdef AIRPLAY_CUDA_INTEROP
            // Unregister before replacing GL storage, including fallback layouts.
            if (!release_cuda_planes()) {
                error = "Cannot unregister Linux CUDA/OpenGL planes before resizing"; return false;
            }
#endif
            texture(output, width, height, GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
            if (supported) for (int i = 0; i < count; ++i) {
                const int channels = i && interleaved ? 2 : 1;
                texture(planes[i], i ? (width+1)/2 : width, i ? (height+1)/2 : height,
                    bytes == 2 ? (channels == 2 ? GL_RG16 : GL_R16) : (channels == 2 ? GL_RG8 : GL_R8),
                    channels == 2 ? GL_RG : GL_RED, bytes == 2 ? GL_UNSIGNED_SHORT : GL_UNSIGNED_BYTE, nullptr);
            }
            layout = next_layout; allocated_width = width; allocated_height = height; allocated_yuv = supported;
#ifdef AIRPLAY_CUDA_INTEROP
            cuda_failed = false;
#endif
        }
        bool on_gpu = false;
#ifdef AIRPLAY_CUDA_INTEROP
        if (allow_cuda && hardware && frame->format == AV_PIX_FMT_CUDA && supported)
            on_gpu = cuda_upload(*frame, count, bytes, interleaved);
#endif
        if (hardware && !on_gpu) {
            downloaded.reset(av_frame_alloc());
            if (!downloaded || av_hwframe_transfer_data(downloaded.get(), frame, 0) < 0 || av_frame_copy_props(downloaded.get(), frame) < 0) {
                error = "Cannot download Linux hardware frame after GPU interop fallback"; return false;
            }
            frame = downloaded.get();
        }
        if (!supported) {
            const uint8_t *data = input.data; int stride = input.stride;
            if (frame) {
                if (colors.convert(*frame) < 0) { error = "Cannot convert Linux fallback frame to RGBA"; return false; }
                data = colors.rgba()->data[0]; stride = colors.rgba()->linesize[0];
            }
            packed.resize(size_t(width)*height*4);
            for (int y=0; y<height; ++y) std::memcpy(packed.data()+size_t(y)*width*4, data+int64_t(y)*stride, size_t(width)*4);
            glBindTexture(GL_TEXTURE_2D, output);
            glTexSubImage2D(GL_TEXTURE_2D,0,0,0,width,height,GL_RGBA,GL_UNSIGNED_BYTE,packed.data());
            mode = "CPU RGBA fallback -> OpenGL"; return true;
        }
        if (!on_gpu) for (int i=0; i<count; ++i)
            upload(planes[i], frame->data[i], frame->linesize[i], i ? (width+1)/2 : width,
                i ? (height+1)/2 : height, i && interleaved ? 2 : 1, bytes);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, output, 0);
        if (glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) { error = "Linux GPU framebuffer is incomplete"; return false; }
        glViewport(0,0,width,height); glUseProgram(program); glBindVertexArray(vao);
        for (int i=0; i<count; ++i) { glActiveTexture(GL_TEXTURE0+i); glBindTexture(GL_TEXTURE_2D,planes[i]); }
        glUniform1i(glGetUniformLocation(program,"yPlane"),0); glUniform1i(glGetUniformLocation(program,"uPlane"),1);
        glUniform1i(glGetUniformLocation(program,"vPlane"),2); glUniform1i(glGetUniformLocation(program,"interleaved"),interleaved);
        const bool full = frame->color_range == AVCOL_RANGE_JPEG || format == AV_PIX_FMT_YUVJ420P;
        const float maximum = bytes == 2 ? 1023.f : 255.f, factor = bytes == 2 ? 4.f : 1.f;
        glUniform3f(glGetUniformLocation(program,"offset"),full ? 0.f : 16.f*factor/maximum,128.f*factor/maximum,128.f*factor/maximum);
        glUniform3f(glGetUniformLocation(program,"scale"),full ? 1.f : maximum/(219.f*factor),full ? 1.f : maximum/(224.f*factor),full ? 1.f : maximum/(224.f*factor));
        glUniform1f(glGetUniformLocation(program,"sampleScale"),bytes == 1 ? 1.f : 65535.f/(1023.f*(format==AV_PIX_FMT_P010LE ? 64.f : 1.f)));
        float kr=.299f, kb=.114f;
        if (frame->colorspace==AVCOL_SPC_BT709) { kr=.2126f; kb=.0722f; }
        if (frame->colorspace==AVCOL_SPC_BT2020_NCL) { kr=.2627f; kb=.0593f; }
        const float kg=1.f-kr-kb;
        glUniform4f(glGetUniformLocation(program,"coefficients"),2*(1-kr),-2*kb*(1-kb)/kg,-2*kr*(1-kr)/kg,2*(1-kb));
        glDrawArrays(GL_TRIANGLES,0,3);
        mode = on_gpu ? "NVDEC -> CUDA/OpenGL -> GPU YUV conversion (no CPU download)"
            : hardware ? "Hardware decode -> YUV download -> GPU YUV conversion" : "Software decode -> GPU YUV conversion";
        return true;
    }
};
LinuxGpuRenderer::LinuxGpuRenderer(bool cuda_interop) : impl_(std::make_unique<Impl>(cuda_interop)) {}
LinuxGpuRenderer::~LinuxGpuRenderer() = default;
bool LinuxGpuRenderer::render(const AirplayLinuxVideoFrame &frame, uint32_t &texture, std::string &error) {
    try {
    if (frame.width < 1 || frame.height < 1 || frame.width > 4096 || frame.height > 4096 ||
        (!frame.native_frame && (!frame.data || frame.stride < frame.width*4))) { error="Invalid Linux GPU frame"; return false; }
    if (!impl_->render(frame,error)) return false;
    texture=impl_->output; return true;
    } catch (const std::exception &failure) { error = failure.what(); return false; }
}
const char *LinuxGpuRenderer::path() const { return impl_->mode; }
} // namespace airplay
