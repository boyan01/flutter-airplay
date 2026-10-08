// SPDX-License-Identifier: GPL-3.0-only
#include "../../playback/platform.h"
#include "../../playback/video_scheduler.h"
#include <VideoToolbox/VideoToolbox.h>
#include <CoreVideo/CoreVideo.h>
#include <TargetConditionals.h>
#include <cstdio>
#include <unordered_map>

namespace airplay {
class MacVideo final : public VideoOutput {
public:
    explicit MacVideo(VideoCallbacks callbacks) : callbacks_(std::move(callbacks)) {}
    ~MacVideo() override { reset(); }
    bool supports_hevc() const override {
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
    }
    void size(int, int) override {} // SPS and decoded pixel buffers own actual dimensions.
    VideoScheduler::Stats stats() const override { return scheduler_.stats(); }
    const char *decoder_name() const override { return "VideoToolbox"; }
    bool can_decode() const override {
        std::lock_guard<std::mutex> guard(pending_lock_);
        return contexts_.size() + scheduler_.stats().pending < 16;
    }
    int64_t next_deadline() const override { return scheduler_.next_deadline(); }
    void drain() override {
        scheduler_.drain();
        const auto schedule = scheduler_.diagnostics();
        if (!schedule.empty() && callbacks_.log) callbacks_.log(schedule.c_str());
        report_stats(false);
    }
    void reset() override {
        close_session(); vps_.clear(); sps_.clear(); pps_.clear(); hevc_ = false;
        report_stats(true);
        stats_started_ = 0; submitted_ = decoded_ = encoded_bytes_ = 0;
        callback_errors_ = no_image_ = dropped_ = 0;
        last_callback_status_ = noErr; last_callback_flags_ = 0;
        max_queue_ns_ = max_decode_ns_ = 0;
    }
    bool decode(const VideoPacket &packet) override {
        if (packet.hevc != hevc_) { reset(); hevc_ = packet.hevc; }
        scheduler_.begin(packet.generation);
        const auto entered = monotonic_ns();
        if (!stats_started_) stats_started_ = entered;
        if (packet.received_ns) max_queue_ns_ = std::max(max_queue_ns_, entered - packet.received_ns);
        auto nals = split_nal_views(packet.bytes.data(), packet.bytes.size());
        bool picture = false, keyframe = false, changed = false;
        std::vector<uint8_t> sample;
        sample.reserve(packet.bytes.size());
        for (const auto &nal : nals) {
            if (hevc_ && (nal.size() < 2 || (nal[0] & 0x80) || !(nal[1] & 7))) return false;
            const auto type = hevc_ ? (nal[0] >> 1) & 63 : nal[0] & 31;
            if (hevc_ ? type >= 32 && type <= 34 : type == 7 || type == 8) {
                auto &parameter = hevc_ && type == 32 ? vps_ : type == (hevc_ ? 33 : 7) ? sps_ : pps_;
                if (parameter.size() != nal.size() || !std::equal(parameter.begin(), parameter.end(), nal.data())) {
                    parameter.assign(nal.data(), nal.data() + nal.size()); changed = true;
                }
                continue;
            }
            picture |= hevc_ ? type <= 31 : type == 1 || type == 5;
            keyframe |= hevc_ ? type >= 16 && type <= 23 : type == 5;
            const uint32_t length = uint32_t(nal.size());
            sample.insert(sample.end(), {uint8_t(length >> 24), uint8_t(length >> 16), uint8_t(length >> 8), uint8_t(length)});
            sample.insert(sample.end(), nal.data(), nal.data() + nal.size());
        }
        if (changed) { close_session(); scheduler_.begin(packet.generation); }
        if (!picture) return true;
        if (!session_) {
            if (!keyframe || sps_.empty() || pps_.empty() || (hevc_ && vps_.empty())) return true;
            if (!open()) return false;
        }
        CMBlockBufferRef block = nullptr;
        if (CMBlockBufferCreateWithMemoryBlock(nullptr, nullptr, sample.size(), nullptr, nullptr, 0,
                                              sample.size(), 0, &block)) return false;
        CMBlockBufferReplaceDataBytes(sample.data(), block, 0, sample.size());
        CMSampleTimingInfo timing{ kCMTimeInvalid, CMTimeMake(packet.deadline, kSecond), kCMTimeInvalid };
        size_t length = sample.size(); CMSampleBufferRef buffer = nullptr;
        const auto created = CMSampleBufferCreateReady(nullptr, block, format_, 1, 1, &timing, 1, &length, &buffer);
        CFRelease(block);
        if (created) return false;
        ++submitted_; encoded_bytes_ += packet.bytes.size();
        auto context = std::make_shared<Context>(Context{this, packet.deadline, packet.generation, monotonic_ns()});
        {
            std::lock_guard<std::mutex> guard(pending_lock_);
            contexts_.emplace(context.get(), context);
        }
        VTDecodeInfoFlags info = 0;
        auto status = VTDecompressionSessionDecodeFrame(session_, buffer, kVTDecodeFrame_EnableAsynchronousDecompression,
                                                        context.get(), &info);
        CFRelease(buffer);
        if (status || ((info & kVTDecodeInfo_FrameDropped) && !(info & kVTDecodeInfo_Asynchronous))) {
            std::lock_guard<std::mutex> guard(pending_lock_);
            contexts_.erase(context.get());
        }
        if (status) {
            char text[192];
            std::snprintf(text, sizeof(text), "VideoToolbox decode submission failed: codec=%s status=%d keyframe=%d bytes=%zu",
                hevc_ ? "HEVC" : "H.264", int(status), int(keyframe), packet.bytes.size());
            callbacks_.log(text);
        }
        return status == noErr;
    }
private:
    struct Context { MacVideo *video; int64_t deadline; uint64_t generation; int64_t submitted; };
    static void decoded(void *, void *opaque, OSStatus status, VTDecodeInfoFlags flags, CVImageBufferRef image, CMTime, CMTime) {
        auto *context = static_cast<Context *>(opaque);
        auto *self = context->video;
        // Keep the context alive through callbacks, including synchronous output.
        std::shared_ptr<Context> owned;
        {
            std::lock_guard<std::mutex> guard(self->pending_lock_);
            auto entry = self->contexts_.find(context);
            if (entry == self->contexts_.end()) return;
            owned = entry->second;
            // Erase only after enqueueing output, so capacity includes this frame.
        }
        if (status || !image) {
            bool first;
            {
                std::lock_guard<std::mutex> guard(self->pending_lock_);
                first = !self->callback_errors_ && !self->no_image_;
                self->callback_errors_ += status != noErr;
                self->no_image_ += !image;
                self->dropped_ += bool(flags & kVTDecodeInfo_FrameDropped);
                self->last_callback_status_ = status; self->last_callback_flags_ = flags;
                self->contexts_.erase(context);
            }
            // At most one detailed failure per statistics interval, followed
            // by aggregate counts. A broken GOP can fail every input frame.
            if (first) {
                char text[192];
                std::snprintf(text, sizeof(text), "VideoToolbox output missing: codec=%s status=%d flags=%u image=%d",
                    self->hevc_ ? "HEVC" : "H.264", int(status), unsigned(flags), int(image != nullptr));
                self->callbacks_.log(text);
            }
            return;
        }
        // The callback must not wait for presentation: WaitForAsynchronousFrames
        // would keep the receive worker from decoding the rest of a burst.
        std::lock_guard<std::mutex> guard(self->pending_lock_);
        ++self->decoded_;
        self->max_decode_ns_ = std::max(self->max_decode_ns_, monotonic_ns() - context->submitted);
        auto frame = std::shared_ptr<__CVBuffer>(CVPixelBufferRetain(image),
            [](CVPixelBufferRef value) { CVPixelBufferRelease(value); });
        const auto due = context->deadline;
        const auto generation = context->generation;
        self->scheduler_.enqueue(due, generation, [self, frame, due, generation](bool show) {
            if (show && self->callbacks_.frame) self->callbacks_.frame(frame.get(),
                int(CVPixelBufferGetWidth(frame.get())), int(CVPixelBufferGetHeight(frame.get())), due, generation);
        });
        self->contexts_.erase(context);
    }

    bool open() {
        if (hevc_) {
            const uint8_t *parameters[] = {vps_.data(), sps_.data(), pps_.data()};
            const size_t lengths[] = {vps_.size(), sps_.size(), pps_.size()};
            if (CMVideoFormatDescriptionCreateFromHEVCParameterSets(nullptr, 3, parameters, lengths, 4, nullptr, &format_)) return false;
        } else {
            const uint8_t *parameters[] = {sps_.data(), pps_.data()};
            const size_t lengths[] = {sps_.size(), pps_.size()};
            if (CMVideoFormatDescriptionCreateFromH264ParameterSets(nullptr, 2, parameters, lengths, 4, &format_)) return false;
        }
        auto attributes = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
#if TARGET_OS_OSX
        const int32_t pixel_format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
#else
        const int32_t pixel_format = kCVPixelFormatType_32BGRA;
#endif
        auto number = CFNumberCreate(nullptr, kCFNumberSInt32Type, &pixel_format);
        auto properties = CFDictionaryCreate(nullptr, nullptr, nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(attributes, kCVPixelBufferPixelFormatTypeKey, number);
        CFDictionarySetValue(attributes, kCVPixelBufferIOSurfacePropertiesKey, properties);
        CFDictionarySetValue(attributes, kCVPixelBufferMetalCompatibilityKey, kCFBooleanTrue);
        CFMutableDictionaryRef specification = nullptr;
        // iPadOS 15/16 choose their decoder without the hardware-selection keys
        // introduced in iOS 17. HEVC advertisement still checks hardware support.
        if (__builtin_available(macOS 10.9, iOS 17.0, tvOS 17.0, *)) {
            specification = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFDictionarySetValue(specification, kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder, kCFBooleanTrue);
            if (hevc_) CFDictionarySetValue(specification, kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder, kCFBooleanTrue);
        }
        VTDecompressionOutputCallbackRecord callback{decoded, this};
        auto status = VTDecompressionSessionCreate(nullptr, format_, specification, attributes, &callback, &session_);
        if (specification) CFRelease(specification);
        CFRelease(attributes); CFRelease(number); CFRelease(properties);
        if (status) { close_session(); return false; }
        VTSessionSetProperty(session_, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
        CFTypeRef hardware = nullptr;
        OSStatus queried = kVTPropertyNotSupportedErr;
        if (__builtin_available(macOS 10.9, iOS 17.0, tvOS 17.0, *)) {
            queried = VTSessionCopyProperty(session_, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                           nullptr, &hardware);
        }
        const bool accelerated = !queried && hardware && CFGetTypeID(hardware) == CFBooleanGetTypeID()
            && CFBooleanGetValue(static_cast<CFBooleanRef>(hardware));
        char text[160];
        std::snprintf(text, sizeof(text), "VideoToolbox %s decoder ready; direct CVPixelBuffer output; hardware=%s",
            hevc_ ? "HEVC" : "H.264",
            queried ? "unknown" : accelerated ? "yes" : "no");
        if (hardware) CFRelease(hardware);
        callbacks_.log(text);
        return true;
    }
    void close_session() {
        if (session_) { VTDecompressionSessionWaitForAsynchronousFrames(session_); VTDecompressionSessionInvalidate(session_); CFRelease(session_); session_ = nullptr; }
        if (format_) { CFRelease(format_); format_ = nullptr; }
        std::lock_guard<std::mutex> guard(pending_lock_);
        contexts_.clear();
        scheduler_.clear();
    }
    void report_stats(bool final) {
        const auto now = monotonic_ns();
        if (!stats_started_ || (!final && now - stats_started_ < 5 * kSecond)) return;
        std::lock_guard<std::mutex> guard(pending_lock_);
        char text[640];
        std::snprintf(text, sizeof(text),
            "VideoToolbox video stats: interval_ms=%lld input=%llu decoded=%llu max_queue_ms=%.1f max_decode_observed_ms=%.1f input_mbps=%.2f callback_errors=%llu no_image=%llu dropped=%llu last_callback_status=%d last_callback_flags=%u%s",
            static_cast<long long>((now - stats_started_) / 1000000),
            static_cast<unsigned long long>(submitted_), static_cast<unsigned long long>(decoded_),
            max_queue_ns_ / 1e6, max_decode_ns_ / 1e6,
            double(encoded_bytes_) * 8 * 1000 / (now - stats_started_),
            static_cast<unsigned long long>(callback_errors_), static_cast<unsigned long long>(no_image_),
            static_cast<unsigned long long>(dropped_), int(last_callback_status_), unsigned(last_callback_flags_), final ? " final" : "");
        callbacks_.log(text);
        stats_started_ = now; submitted_ = decoded_ = encoded_bytes_ = 0;
        callback_errors_ = no_image_ = dropped_ = 0;
        last_callback_status_ = noErr; last_callback_flags_ = 0;
        max_queue_ns_ = max_decode_ns_ = 0;
    }
    mutable std::mutex pending_lock_;
    std::unordered_map<Context *, std::shared_ptr<Context>> contexts_;
    // VideoToolbox can callback in decode order; retain the existing reorder
    // headroom so future reference pictures do not block earlier B-frames.
#if TARGET_OS_OSX
    // Feed the native timed surface early; its host clock controls presentation.
    VideoScheduler scheduler_{50000000, 16};
#else
    VideoScheduler scheduler_{2000000, 16};
#endif
    int64_t stats_started_ = 0, max_queue_ns_ = 0, max_decode_ns_ = 0;
    uint64_t submitted_ = 0, decoded_ = 0, encoded_bytes_ = 0;
    uint64_t callback_errors_ = 0, no_image_ = 0, dropped_ = 0;
    OSStatus last_callback_status_ = noErr;
    VTDecodeInfoFlags last_callback_flags_ = 0;
    VideoCallbacks callbacks_;
    bool hevc_ = false;
    std::vector<uint8_t> vps_, sps_, pps_;
    VTDecompressionSessionRef session_ = nullptr;
    CMVideoFormatDescriptionRef format_ = nullptr;
};
std::unique_ptr<VideoOutput> make_video_output(void *, const char *, const char *, VideoCallbacks cb) {
    return std::make_unique<MacVideo>(std::move(cb));
}
} // namespace airplay
