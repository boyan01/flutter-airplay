// SPDX-License-Identifier: GPL-3.0-only
#include "../../playback/platform.h"
#include "ffmpeg_video.h"
#include "../../playback/video_scheduler.h"
#include "ffmpeg_colors.h"
#include "../../playback/timing_stats.h"
#ifdef _WIN32
#include "../windows/windows_video.h"
#include "../windows/windows_gpu.h"
#else
#include "../linux/linux_video.h"
#endif
#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <new>
#include <utility>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/buffer.h>
#include <libavutil/error.h>
#include <libavutil/pixdesc.h>
#include <libavutil/hwcontext.h>
#ifdef _WIN32
#include <libavutil/hwcontext_d3d11va.h>
#endif
#include <libswscale/swscale.h>
}

#ifndef AV_CODEC_FLAG_COPY_OPAQUE
#error "Software video requires FFmpeg 6 or newer (libavcodec >= 60)"
#endif

namespace airplay {
namespace {
constexpr int kMaxDimension = 4096;
constexpr size_t kMaxPacketBytes = 4 * 1024 * 1024;
constexpr size_t kMaxParameterBytes = 256 * 1024;
constexpr size_t kMaxNals = 4096;
constexpr AVRational kNanoseconds{1, 1000000000};

struct PacketTiming {
    int64_t deadline;
    uint64_t generation;
    int64_t received_ns;
    int64_t decode_started_ns;
};
struct Nal {
    const uint8_t *data;
    size_t size;
    unsigned type;
};
struct PacketDeleter {
    void operator()(AVPacket *packet) const { av_packet_free(&packet); }
};

size_t start_code(const uint8_t *data, size_t size, size_t offset) {
    if (size - offset < 3 || data[offset] || data[offset + 1]) return 0;
    if (data[offset + 2] == 1) return 3;
    return size - offset >= 4 && data[offset + 2] == 0 && data[offset + 3] == 1 ? 4 : 0;
}

bool inspect_annex_b(const std::vector<uint8_t> &bytes, bool hevc, std::vector<Nal> &nals,
                     bool &picture, bool &keyframe) {
    size_t offset = 0;
    // Annex B permits leading_zero_8bits before the first start code.
    while (offset < bytes.size() && !start_code(bytes.data(), bytes.size(), offset)) {
        if (bytes[offset++]) return false;
    }
    if (offset == bytes.size()) return false;
    while (offset < bytes.size()) {
        const auto begin = offset + start_code(bytes.data(), bytes.size(), offset);
        offset = begin;
        while (offset < bytes.size() && !start_code(bytes.data(), bytes.size(), offset)) ++offset;
        size_t end = offset;
        while (end > begin && bytes[end - 1] == 0) --end; // trailing_zero_8bits
        if (end == begin || nals.size() >= kMaxNals) return false;
        const unsigned type = hevc ? (bytes[begin] >> 1) & 63 : bytes[begin] & 31;
        if ((bytes[begin] & 0x80) || (hevc ? end - begin < 2 || !(bytes[begin + 1] & 7) : !type || type >= 24)) return false;
        nals.push_back({bytes.data() + begin, end - begin, type});
        picture |= hevc ? type <= 31 : type >= 1 && type <= 5;
        keyframe |= hevc ? type >= 16 && type <= 23 : type == 5;
    }
    return true;
}

AVPixelFormat software_format(AVCodecContext *, const AVPixelFormat *formats) {
    for (; *formats != AV_PIX_FMT_NONE; ++formats) {
        const auto *description = av_pix_fmt_desc_get(*formats);
        if (description && !(description->flags & AV_PIX_FMT_FLAG_HWACCEL)
            && sws_isSupportedInput(*formats)) return *formats;
    }
    return AV_PIX_FMT_NONE;
}

int bounded_buffer(AVCodecContext *context, AVFrame *frame, int flags) {
    if (frame->width < 1 || frame->height < 1 || frame->width > kMaxDimension
        || frame->height > kMaxDimension) return AVERROR(EINVAL);
    return avcodec_default_get_buffer2(context, frame, flags);
}

} // namespace

class FFmpegVideo final : public VideoOutput {
public:
    explicit FFmpegVideo(VideoCallbacks callbacks) : callbacks_(std::move(callbacks)) {}
#ifdef _WIN32
    FFmpegVideo(VideoCallbacks callbacks, const WindowsVideoOptions *options) : FFmpegVideo(std::move(callbacks)) {
        if (options) { adapter_ = options->adapter; gpu_requested_ = options->gpu; }
    }
#endif
#ifndef _WIN32
    FFmpegVideo(VideoCallbacks callbacks, const LinuxVideoOptions &options) : FFmpegVideo(std::move(callbacks)) {
        hardware_requested_ = options.hardware; native_output_ = options.gpu_output;
    }
#endif
    ~FFmpegVideo() override { release(); }
    bool supports_hevc() const override {
        const auto *decoder = avcodec_find_decoder_by_name("hevc");
        return decoder && decoder->id == AV_CODEC_ID_HEVC;
    }

    // The source's SPS owns the dimensions. A screen-size notification is not
    // a crop request and must not discard references during a rotation.
    void size(int, int) override {}
    VideoScheduler::Stats stats() const override { return scheduler_.stats(); }
    const char *decoder_name() const override {
#ifndef _WIN32
        if (active_hardware_ == AV_HWDEVICE_TYPE_CUDA) return "FFmpeg NVDEC";
        if (active_hardware_ == AV_HWDEVICE_TYPE_VAAPI) return "FFmpeg VAAPI";
#endif
#ifdef _WIN32
        return "FFmpeg";
#else
        return "FFmpeg software";
#endif
    }
    bool can_decode() const override { return scheduler_.can_decode(); }
    int64_t next_deadline() const override { return scheduler_.next_deadline(); }

    void reset() override {
        // Recreate rather than flush: flush retains SPS/PPS from the old sender.
        // Drop delayed frames; resetting must never publish the previous stream.
        release();
        parameters_.clear();
        parameter_bytes_ = 0;
        waiting_for_keyframe_ = true;
        failed_ = false;
    }

    bool decode(const VideoPacket &input) override {
        if (input.hevc != hevc_) { reset(); hevc_ = input.hevc; }
        scheduler_.begin(input.generation);
        if (failed_) return false;
        try {
            if (input.bytes.empty() || input.bytes.size() > kMaxPacketBytes)
                return fail("Invalid video packet size");
            std::vector<Nal> nals;
            bool picture = false, keyframe = false;
            if (!inspect_annex_b(input.bytes, hevc_, nals, picture, keyframe))
                return fail("Malformed video Annex B packet");

            if (!picture || (waiting_for_keyframe_ && !keyframe)) {
                // UxPlay sends parameter sets in their own packet. libavcodec expects
                // complete access units, so pass headers with the next picture.
                for (const auto &nal : nals) {
                    if (hevc_ ? nal.type < 32 || nal.type > 34 : nal.type != 7 && nal.type != 8) continue;
                    if (nal.size < 2) return fail("Truncated video parameter set");
                    const auto duplicate = std::find_if(parameters_.begin(), parameters_.end(),
                        [&](const auto &saved) {
                            return saved.size() == nal.size && !std::memcmp(saved.data(), nal.data, nal.size);
                        });
                    if (duplicate != parameters_.end()) {
                        // Preserve update order even when the sender switches
                        // A -> B -> A using the same parameter-set identifier.
                        std::rotate(duplicate, duplicate + 1, parameters_.end());
                        continue;
                    }
                    if (nal.size + 4 > kMaxParameterBytes - parameter_bytes_)
                        return fail("Too many pending video parameter sets");
                    parameters_.emplace_back(nal.data, nal.data + nal.size);
                    parameter_bytes_ += nal.size + 4;
                }
                return true;
            }

            if (!codec_ && !open()) return false;
            std::unique_ptr<AVPacket, PacketDeleter> packet(av_packet_alloc());
            if (!packet) return fail("Cannot allocate video packet");
            const auto bytes = parameter_bytes_ + input.bytes.size();
            int status = av_new_packet(packet.get(), static_cast<int>(bytes));
            if (status < 0) return fail("Cannot allocate video input", status);
            size_t offset = 0;
            for (const auto &parameter : parameters_) {
                const uint8_t prefix[] = {0, 0, 0, 1};
                std::memcpy(packet->data + offset, prefix, sizeof(prefix));
                offset += sizeof(prefix);
                std::memcpy(packet->data + offset, parameter.data(), parameter.size());
                offset += parameter.size();
            }
            std::memcpy(packet->data + offset, input.bytes.data(), input.bytes.size());
            // av_new_packet also zeroes AV_INPUT_BUFFER_PADDING_SIZE bytes.
            packet->pts = input.deadline;
            packet->dts = AV_NOPTS_VALUE;
            packet->time_base = kNanoseconds;
            if (keyframe) packet->flags |= AV_PKT_FLAG_KEY;
            packet->opaque_ref = av_buffer_alloc(sizeof(PacketTiming));
            if (!packet->opaque_ref) return fail("Cannot allocate video frame timing");
            const PacketTiming timing{input.deadline, input.generation, input.received_ns, monotonic_ns()};
            std::memcpy(packet->opaque_ref->data, &timing, sizeof(timing));

            if (!stats_started_) stats_started_ = monotonic_ns();
            auto send = [&] {
                const auto start = monotonic_ns();
                const int result = avcodec_send_packet(codec_, packet.get());
                send_cost_.add(monotonic_ns() - start);
                return result;
            };
            status = send();
            if (status == AVERROR(EAGAIN)) {
                if (!receive()) return false;
                status = send();
            }
            if (status < 0) return fail("video packet rejected", status);
            parameters_.clear();
            parameter_bytes_ = 0;
            waiting_for_keyframe_ = false;
            return receive();
        } catch (const std::bad_alloc &) {
            return fail("Cannot allocate video working memory");
        }
    }

    void drain() override {
        // Called continuously by player.cpp, not an end-of-stream operation.
        // Sending a null packet here would finalize every picture's decoder.
        if (codec_ && !failed_) receive();
        scheduler_.drain();
        const auto schedule = scheduler_.diagnostics();
        if (!schedule.empty() && callbacks_.log) callbacks_.log(schedule.c_str());
        report_decode();
    }

private:
    bool fail(const char *message, int error = 0) {
#ifndef _WIN32
        if (error && codec_ && codec_->hw_device_ctx && !hardware_disabled_ &&
            (error == AVERROR_EXTERNAL || error == AVERROR(EIO) || error == AVERROR(ENODEV) || error == AVERROR(ENOSYS))) {
            hardware_disabled_ = true;
            if (callbacks_.log) callbacks_.log("Linux hardware decoder failed; recovery will use software decoding at the next keyframe");
        }
#endif
        failed_ = true;
        if (callbacks_.log) {
            if (!error) callbacks_.log(message);
            else {
                char detail[AV_ERROR_MAX_STRING_SIZE]{};
                char text[256]{};
                av_strerror(error, detail, sizeof(detail));
                std::snprintf(text, sizeof(text), "%s: %s", message, detail);
                callbacks_.log(text);
            }
        }
        return false;
    }

    bool open() {
        // The bundled decoder can use D3D11 without the Windows HEVC extension.
        // Hardware probing is opt-in; deterministic software fixtures stay CPU-only.
        const AVCodec *decoder = avcodec_find_decoder_by_name(hevc_ ? "hevc" : "h264");
        if (!decoder || decoder->id != (hevc_ ? AV_CODEC_ID_HEVC : AV_CODEC_ID_H264))
            return fail("FFmpeg software video decoder is unavailable");
        codec_ = avcodec_alloc_context3(decoder);
        frame_ = av_frame_alloc();
        if (!codec_ || !frame_) return fail("Cannot allocate video decoder");
        codec_->pkt_timebase = kNanoseconds;
        codec_->flags |= AV_CODEC_FLAG_COPY_OPAQUE;
        // Slice threads avoid the extra frame latency of frame threading while
        // retaining normal H.264 picture reordering for streams with B frames.
        codec_->thread_count = 2;
        codec_->thread_type = FF_THREAD_SLICE;
        codec_->get_format = software_format;
#ifdef _WIN32
        if (gpu_requested_ && gpu_.create(adapter_.Get())) {
            bool supported = false;
            for (int i = 0; const auto *config = avcodec_get_hw_config(decoder, i); ++i) {
                if (config->device_type == AV_HWDEVICE_TYPE_D3D11VA &&
                    (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) { supported = true; break; }
            }
            AVBufferRef *device = supported ? av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_D3D11VA) : nullptr;
            if (device) {
                auto *context = reinterpret_cast<AVHWDeviceContext *>(device->data);
                auto *d3d = static_cast<AVD3D11VADeviceContext *>(context->hwctx);
                d3d->device = gpu_.device(); d3d->device->AddRef();
                if (av_hwdevice_ctx_init(device) >= 0) {
                    codec_->hw_device_ctx = device;
                    codec_->get_format = [](AVCodecContext *context, const AVPixelFormat *formats) {
                        for (const auto *format = formats; *format != AV_PIX_FMT_NONE; ++format)
                            if (*format == AV_PIX_FMT_D3D11) return *format;
                        // libavcodec calls again without D3D11 if driver/profile
                        // negotiation failed. Choose a supported CPU layout.
                        return software_format(context, formats);
                    };
                } else av_buffer_unref(&device);
            }
        }
#else
        codec_->opaque = this;
        active_hardware_ = AV_HWDEVICE_TYPE_NONE;
        if (hardware_requested_ && !hardware_disabled_) {
            for (auto type : {AV_HWDEVICE_TYPE_CUDA, AV_HWDEVICE_TYPE_VAAPI}) {
                AVPixelFormat pixel = AV_PIX_FMT_NONE;
                for (int i = 0; const auto *config = avcodec_get_hw_config(decoder, i); ++i)
                    if (config->device_type == type && (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) {
                        pixel = config->pix_fmt; break;
                    }
                if (pixel == AV_PIX_FMT_NONE) continue;
                AVBufferRef *device = nullptr;
                const int result = av_hwdevice_ctx_create(&device, type, nullptr, nullptr, 0);
                if (result < 0) {
                    if (callbacks_.log) {
                        char reason[AV_ERROR_MAX_STRING_SIZE]{}; av_strerror(result, reason, sizeof(reason));
                        const auto message = std::string("Linux hardware probe ") + av_hwdevice_get_type_name(type) + ": " + reason;
                        callbacks_.log(message.c_str());
                    }
                    continue;
                }
                codec_->hw_device_ctx = device; hardware_format_ = pixel;
                codec_->get_format = [](AVCodecContext *context, const AVPixelFormat *formats) {
                    auto *self = static_cast<FFmpegVideo *>(context->opaque);
                    for (auto *format = formats; *format != AV_PIX_FMT_NONE; ++format)
                        if (*format == self->hardware_format_) return *format;
                    self->active_hardware_ = AV_HWDEVICE_TYPE_NONE;
                    if (self->callbacks_.log) self->callbacks_.log("Linux hardware format unavailable; using software decoding");
                    return software_format(context, formats);
                };
                break;
            }
        }
#endif
        codec_->get_buffer2 = bounded_buffer;
        codec_->max_pixels = int64_t(kMaxDimension) * kMaxDimension;
        codec_->err_recognition = AV_EF_BITSTREAM | AV_EF_BUFFER | AV_EF_EXPLODE;
        const int status = avcodec_open2(codec_, decoder, nullptr);
        if (status < 0) {
#ifndef _WIN32
            if (codec_->hw_device_ctx && !hardware_disabled_) {
                hardware_disabled_ = true; avcodec_free_context(&codec_); av_frame_free(&frame_);
                if (callbacks_.log) callbacks_.log("Linux hardware decoder initialization failed; reopening with software decoding");
                return open();
            }
#endif
            return fail("Cannot open video decoder", status);
        }
#ifdef _WIN32
        if (callbacks_.log) callbacks_.log(codec_->hw_device_ctx ? "FFmpeg HEVC decoder ready; D3D11 preferred with CPU fallback"
                                               : hevc_ ? "FFmpeg software HEVC decoder ready; borrowed RGBA output"
                                               : "FFmpeg software H.264 decoder ready; borrowed RGBA output");
#else
        if (callbacks_.log) callbacks_.log(codec_->hw_device_ctx
            ? "Linux FFmpeg hardware device ready; decoder activation is reported on the first frame"
            : "Linux FFmpeg software decoder ready; hardware unavailable or disabled");
#endif
        return true;
    }

    bool receive() {
        for (;;) {
            const auto start = monotonic_ns();
            const int status = avcodec_receive_frame(codec_, frame_);
            const auto cost = monotonic_ns() - start;
            if (status == AVERROR(EAGAIN)) {
                // Polls can vastly outnumber pictures; keep them out of the
                // successful receive average, but retain expensive empty polls.
                if (cost > kSecond / 60) empty_receive_cost_.add(cost);
                return true;
            }
            receive_cost_.add(cost);
            if (status < 0) return fail("Video frame decoding failed", status);
            const bool good = render();
            av_frame_unref(frame_);
            if (!good) return false;
        }
    }

    bool render() {
        const int width = frame_->width, height = frame_->height;
        if (width < 1 || height < 1 || width > kMaxDimension || height > kMaxDimension)
            return fail("Unsupported video frame dimensions");
        if ((frame_->flags & AV_FRAME_FLAG_CORRUPT) || frame_->decode_error_flags)
            return fail("Corrupt video frame discarded");
        if (!frame_->opaque_ref || frame_->opaque_ref->size != sizeof(PacketTiming))
            return fail("Video frame has no matching packet timing");
        PacketTiming timing{};
        std::memcpy(&timing, frame_->opaque_ref->data, sizeof(timing));
        if (output_width_ != width || output_height_ != height) {
            scheduler_.flush();
            output_width_ = width; output_height_ = height;
        }
        ++decoded_frames_; stats_width_ = width; stats_height_ = height;
        const auto decoded = monotonic_ns();
        if (timing.decode_started_ns) decode_observed_.add(decoded - timing.decode_started_ns);
        if (timing.received_ns) arrival_to_decode_.add(decoded - timing.received_ns);

#ifndef _WIN32
        const auto format = static_cast<AVPixelFormat>(frame_->format);
        const auto *description = av_pix_fmt_desc_get(format);
        if (description && (description->flags & AV_PIX_FMT_FLAG_HWACCEL)) {
            active_hardware_ = format == AV_PIX_FMT_CUDA ? AV_HWDEVICE_TYPE_CUDA : AV_HWDEVICE_TYPE_VAAPI;
        } else active_hardware_ = AV_HWDEVICE_TYPE_NONE;
        if (!hardware_reported_ && callbacks_.log) {
            const auto message = std::string("Linux video decoder active: ") + decoder_name();
            callbacks_.log(message.c_str()); hardware_reported_ = true;
        }
        if (native_output_) {
            auto *retained = av_frame_clone(frame_);
            if (!retained) return fail("Cannot retain native Linux video frame");
            const auto picture = std::shared_ptr<AVFrame>(retained, [](AVFrame *value) { av_frame_free(&value); });
            scheduler_.enqueue(timing.deadline, timing.generation,
                [this, picture, width, height, timing](bool show) {
                    AirplayLinuxVideoFrame output{nullptr, 0, width, height, picture.get(),
                        [](void *value) -> void * { return av_frame_clone(static_cast<AVFrame *>(value)); },
                        [](void *value) { auto *frame = static_cast<AVFrame *>(value); av_frame_free(&frame); }};
                    if (show && callbacks_.frame) callbacks_.frame(&output, width, height, timing.deadline, timing.generation);
                });
            return true;
        }
        if (description && (description->flags & AV_PIX_FMT_FLAG_HWACCEL)) {
            AVFrame *software = av_frame_alloc();
            if (!software) return fail("Cannot allocate Linux download frame");
            const int result = av_hwframe_transfer_data(software, frame_, 0);
            const int properties = result < 0 ? result : av_frame_copy_props(software, frame_);
            if (properties < 0) { av_frame_free(&software); return fail("Cannot download Linux hardware frame", properties); }
            av_frame_unref(frame_); av_frame_move_ref(frame_, software); av_frame_free(&software);
        }
#endif

#ifdef _WIN32
        if (gpu_requested_ && timing.deadline < monotonic_ns() - kVideoLateToleranceNs) { ++late_before_convert_; return true; }
        if (frame_->format == AV_PIX_FMT_D3D11) {
            const bool supported_color = frame_->colorspace == AVCOL_SPC_BT709 ||
                frame_->colorspace == AVCOL_SPC_BT470BG || frame_->colorspace == AVCOL_SPC_SMPTE170M ||
                frame_->colorspace == AVCOL_SPC_UNSPECIFIED;
            const auto begin = monotonic_ns();
            const bool bt709 = frame_->colorspace == AVCOL_SPC_BT709;
            auto texture = supported_color ? gpu_.convert(reinterpret_cast<ID3D11Texture2D *>(frame_->data[0]),
                UINT(reinterpret_cast<uintptr_t>(frame_->data[1])), 0, 0, UINT(width), UINT(height),
                bt709, frame_->color_range == AVCOL_RANGE_JPEG) : ComPtr<ID3D11Texture2D>{};
            if (texture) {
                ++gpu_frames_; gpu_conversion_.add(monotonic_ns() - begin);
                if (!gpu_reported_ && callbacks_.log) {
                    callbacks_.log("FFmpeg D3D11 HEVC active: hardware decode -> GPU color conversion -> Flutter shared texture");
                    gpu_reported_ = true;
                }
                scheduler_.enqueue(timing.deadline, timing.generation,
                    [this, texture, width, height, timing](bool show) {
                        WindowsVideoFrame output{nullptr, size_t(width), size_t(height), 0, texture.Get()};
                        if (show && callbacks_.frame) callbacks_.frame(&output, width, height, timing.deadline, timing.generation);
                    });
                return true;
            }
            // Preserve playback for a color space/video processor the GPU cannot
            // convert. Transfer only on this fallback, never on the normal path.
            AVFrame *software = av_frame_alloc();
            if (!software) return fail("Cannot allocate D3D11 fallback frame");
            const int transfer = av_hwframe_transfer_data(software, frame_, 0);
            if (transfer < 0) { av_frame_free(&software); return fail("Cannot read D3D11 video frame", transfer); }
            const int properties = av_frame_copy_props(software, frame_);
            if (properties < 0) { av_frame_free(&software); return fail("Cannot preserve D3D11 frame metadata", properties); }
            av_frame_unref(frame_); av_frame_move_ref(frame_, software); av_frame_free(&software);
        }
        if (gpu_requested_ && !cpu_reported_ && callbacks_.log) {
            callbacks_.log("FFmpeg video output is using CPU RGBA conversion; D3D11 decoding/output unavailable for this format");
            cpu_reported_ = true;
        }
#endif

        const auto conversion_start = monotonic_ns();
        const int status = colors_.convert(*frame_);
        cpu_conversion_.add(monotonic_ns() - conversion_start);
        if (status < 0) return fail("Cannot convert video to RGBA", status);
        auto *retained = av_frame_clone(colors_.rgba());
        if (!retained) return fail("Cannot retain converted video frame");
        const auto rgba = std::shared_ptr<AVFrame>(retained, [](AVFrame *value) { av_frame_free(&value); });
        scheduler_.enqueue(timing.deadline, timing.generation,
            [this, rgba, width, height, timing](bool show) {
#ifdef _WIN32
                WindowsVideoFrame output{rgba->data[0], size_t(width), size_t(height), size_t(rgba->linesize[0])};
#else
                AirplayLinuxVideoFrame output{rgba->data[0], rgba->linesize[0], width, height};
#endif
                if (show && callbacks_.frame) callbacks_.frame(&output, width, height, timing.deadline, timing.generation);
            });
        return true;
    }

    void release() {
        scheduler_.clear();
#ifndef _WIN32
        active_hardware_ = AV_HWDEVICE_TYPE_NONE; hardware_reported_ = false;
#endif
        output_width_ = output_height_ = 0;
        avcodec_free_context(&codec_);
        av_frame_free(&frame_);
        colors_.reset();
        stats_started_ = 0; decoded_frames_ = late_before_convert_ = 0;
        send_cost_ = {}; receive_cost_ = {}; empty_receive_cost_ = {};
        decode_observed_ = {}; arrival_to_decode_ = {}; cpu_conversion_ = {};
#ifdef _WIN32
        gpu_frames_ = 0; gpu_conversion_ = {};
#endif
    }

    void report_decode() {
        const auto now = monotonic_ns();
        if (!stats_started_ || now - stats_started_ < 5 * kSecond) return;
        if (callbacks_.log && (decoded_frames_ || send_cost_.count)) {
            char counts[240];
            std::snprintf(counts, sizeof(counts),
                "FFmpeg video stats: interval_ms=%lld decoded=%llu late_before_convert=%llu cpu_converted=%llu size=%dx%d",
                static_cast<long long>((now - stats_started_) / 1000000), static_cast<unsigned long long>(decoded_frames_),
                static_cast<unsigned long long>(late_before_convert_), static_cast<unsigned long long>(cpu_conversion_.count),
                stats_width_, stats_height_);
            auto message = std::string(counts) + send_cost_.text("send") + receive_cost_.text("receive")
                + empty_receive_cost_.text("slow_empty_receive") + decode_observed_.text("decode_observed")
                + arrival_to_decode_.text("arrival_to_decode") + cpu_conversion_.text("cpu_conversion");
#ifdef _WIN32
            message += " gpu_converted=" + std::to_string(gpu_frames_) + gpu_conversion_.text("gpu_conversion");
            gpu_frames_ = 0; gpu_conversion_ = {};
#endif
            callbacks_.log(message.c_str());
        }
        stats_started_ = now; decoded_frames_ = late_before_convert_ = 0;
        send_cost_ = {}; receive_cost_ = {}; empty_receive_cost_ = {};
        decode_observed_ = {}; arrival_to_decode_ = {}; cpu_conversion_ = {};
    }

    VideoCallbacks callbacks_;
    VideoScheduler scheduler_;
    int output_width_ = 0, output_height_ = 0;
    AVCodecContext *codec_ = nullptr;
    AVFrame *frame_ = nullptr;
    FFmpegColors colors_;
    TimingSamples send_cost_, receive_cost_, empty_receive_cost_, decode_observed_, arrival_to_decode_, cpu_conversion_;
    int64_t stats_started_ = 0;
    uint64_t decoded_frames_ = 0, late_before_convert_ = 0;
    int stats_width_ = 0, stats_height_ = 0;
#ifdef _WIN32
    WindowsGpuVideo gpu_;
    ComPtr<IDXGIAdapter> adapter_;
    bool gpu_requested_ = false, gpu_reported_ = false, cpu_reported_ = false;
    uint64_t gpu_frames_ = 0;
    TimingSamples gpu_conversion_;
#endif
#ifndef _WIN32
    bool hardware_requested_ = false, native_output_ = false, hardware_reported_ = false, hardware_disabled_ = false;
    AVPixelFormat hardware_format_ = AV_PIX_FMT_NONE;
    AVHWDeviceType active_hardware_ = AV_HWDEVICE_TYPE_NONE;
#endif
    std::vector<std::vector<uint8_t>> parameters_;
    size_t parameter_bytes_ = 0;
    bool waiting_for_keyframe_ = true;
    bool failed_ = false;
    bool hevc_ = false;
};

std::unique_ptr<VideoOutput> make_ffmpeg_video_output(VideoCallbacks callbacks) {
    return std::make_unique<FFmpegVideo>(std::move(callbacks));
}
#ifdef _WIN32
std::unique_ptr<VideoOutput> make_ffmpeg_video_output(VideoCallbacks callbacks, const WindowsVideoOptions *options) {
    return std::make_unique<FFmpegVideo>(std::move(callbacks), options);
}
#else
std::unique_ptr<VideoOutput> make_ffmpeg_video_output(VideoCallbacks callbacks, const LinuxVideoOptions &options) {
    return std::make_unique<FFmpegVideo>(std::move(callbacks), options);
}
#endif
} // namespace airplay
