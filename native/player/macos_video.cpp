// SPDX-License-Identifier: GPL-3.0-only
#include "platform.h"
#include <VideoToolbox/VideoToolbox.h>
#include <CoreVideo/CoreVideo.h>
#include <TargetConditionals.h>
#include <cstdio>

namespace airplay {
class MacVideo final : public VideoOutput {
public:
    explicit MacVideo(VideoCallbacks callbacks) : callbacks_(std::move(callbacks)) {}
    ~MacVideo() override { reset(); }
    bool supports_hevc() const override {
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
    }
    void size(int, int) override {} // SPS and decoded pixel buffers own actual dimensions.
    int64_t next_deadline() const override {
        std::lock_guard<std::mutex> guard(pending_lock_);
        if (pending_.empty()) return 0;
        return std::min_element(pending_.begin(), pending_.end(),
            [](const Pending &a, const Pending &b) { return a.due < b.due; })->due;
    }
    void drain() override {
        while (true) {
            Pending output;
            {
                std::lock_guard<std::mutex> guard(pending_lock_);
                if (pending_.empty()) break;
                auto next = std::min_element(pending_.begin(), pending_.end(),
                    [](const Pending &a, const Pending &b) { return a.due < b.due; });
                if (next->due > monotonic_ns()) break;
                output = *next; pending_.erase(next);
            }
            const auto now = monotonic_ns();
            max_late_ns_ = std::max(max_late_ns_, now - output.due);
            if (output.due <= last_presented_due_) ++order_drop_;
            else if (output.due < now - 150000000) ++late_drop_;
            else {
                ++presented_;
                if (last_release_ns_) max_release_gap_ns_ = std::max(max_release_gap_ns_, now - last_release_ns_);
                last_release_ns_ = now;
                if (last_presented_due_) {
                    const auto gap = output.due - last_presented_due_;
                    pts_gap_total_ns_ += gap; ++pts_gaps_;
                    max_pts_gap_ns_ = std::max(max_pts_gap_ns_, gap);
                }
                last_presented_due_ = output.due;
                callbacks_.frame(output.frame, int(CVPixelBufferGetWidth(output.frame)),
                    int(CVPixelBufferGetHeight(output.frame)), output.due, output.generation);
            }
            CVPixelBufferRelease(output.frame);
        }
        report_stats(false);
    }
    void reset() override {
        close_session(); vps_.clear(); sps_.clear(); pps_.clear(); hevc_ = false;
        report_stats(true);
        stats_started_ = 0; submitted_ = decoded_ = presented_ = late_drop_ = order_drop_ = overflow_drop_ = 0;
        pts_gap_total_ns_ = max_pts_gap_ns_ = 0; pts_gaps_ = encoded_bytes_ = 0;
        peak_pending_ = 0; last_release_ns_ = max_release_gap_ns_ = max_queue_ns_ = max_decode_ns_ = max_late_ns_ = 0;
    }
    bool decode(const VideoPacket &packet) override {
        if (packet.hevc != hevc_) { reset(); hevc_ = packet.hevc; }
        const auto entered = monotonic_ns();
        if (!stats_started_) stats_started_ = entered;
        if (packet.received_ns) max_queue_ns_ = std::max(max_queue_ns_, entered - packet.received_ns);
        auto nals = split_nals(packet.bytes.data(), packet.bytes.size());
        bool picture = false, keyframe = false, changed = false;
        std::vector<uint8_t> sample;
        for (const auto &nal : nals) {
            if (hevc_ && (nal.size() < 2 || (nal[0] & 0x80) || !(nal[1] & 7))) return false;
            const auto type = hevc_ ? (nal[0] >> 1) & 63 : nal[0] & 31;
            if (hevc_ ? type >= 32 && type <= 34 : type == 7 || type == 8) {
                auto &parameter = hevc_ && type == 32 ? vps_ : type == (hevc_ ? 33 : 7) ? sps_ : pps_;
                if (parameter != nal) { parameter = nal; changed = true; }
                continue;
            }
            picture |= hevc_ ? type <= 31 : type == 1 || type == 5;
            keyframe |= hevc_ ? type >= 16 && type <= 23 : type == 5;
            const uint32_t length = uint32_t(nal.size());
            sample.insert(sample.end(), {uint8_t(length >> 24), uint8_t(length >> 16), uint8_t(length >> 8), uint8_t(length)});
            sample.insert(sample.end(), nal.begin(), nal.end());
        }
        if (changed) close_session();
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
        Context context{this, packet.deadline, packet.generation, monotonic_ns()};
        auto status = VTDecompressionSessionDecodeFrame(session_, buffer, kVTDecodeFrame_EnableAsynchronousDecompression,
                                                        &context, nullptr);
        if (!status) status = VTDecompressionSessionWaitForAsynchronousFrames(session_);
        CFRelease(buffer);
        return status == noErr;
    }
private:
    struct Pending { CVPixelBufferRef frame = nullptr; int64_t due = 0; uint64_t generation = 0; };
    struct Context { MacVideo *video; int64_t deadline; uint64_t generation; int64_t submitted; };
    static void decoded(void *, void *opaque, OSStatus status, VTDecodeInfoFlags, CVImageBufferRef image, CMTime, CMTime) {
        auto *context = static_cast<Context *>(opaque);
        if (status || !image) return;
        auto *self = context->video;
        // The callback must not wait for presentation: WaitForAsynchronousFrames
        // would keep the receive worker from decoding the rest of a burst.
        std::lock_guard<std::mutex> guard(self->pending_lock_);
        ++self->decoded_;
        self->max_decode_ns_ = std::max(self->max_decode_ns_, monotonic_ns() - context->submitted);
        self->pending_.push_back({CVPixelBufferRetain(image), context->deadline, context->generation});
        self->peak_pending_ = std::max(self->peak_pending_, self->pending_.size());
        // Bound retained pixel buffers during overload or far-future input.
        if (self->pending_.size() > 16) {
            auto oldest = std::min_element(self->pending_.begin(), self->pending_.end(),
                [](const Pending &a, const Pending &b) { return a.due < b.due; });
            CVPixelBufferRelease(oldest->frame); self->pending_.erase(oldest); ++self->overflow_drop_;
        }
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
        const int32_t pixel_format = kCVPixelFormatType_32BGRA;
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
        for (const auto &output : pending_) CVPixelBufferRelease(output.frame);
        pending_.clear(); last_presented_due_ = 0;
    }
    void report_stats(bool final) {
        const auto now = monotonic_ns();
        if (!stats_started_ || (!final && now - stats_started_ < 5 * kSecond)) return;
        if (!(submitted_ || decoded_ || presented_ || late_drop_ || order_drop_ || overflow_drop_)) return;
        std::lock_guard<std::mutex> guard(pending_lock_);
        char text[640];
        std::snprintf(text, sizeof(text),
            "Mac video stats: interval_ms=%lld input=%llu decoded=%llu presented=%llu late_drop=%llu order_drop=%llu overflow_drop=%llu pending=%zu peak_pending=%zu max_queue_ms=%.1f max_decode_observed_ms=%.1f max_release_gap_ms=%.1f max_late_ms=%.1f pts_gap_avg_ms=%.1f max_pts_gap_ms=%.1f input_mbps=%.2f%s",
            static_cast<long long>((now - stats_started_) / 1000000),
            static_cast<unsigned long long>(submitted_), static_cast<unsigned long long>(decoded_),
            static_cast<unsigned long long>(presented_), static_cast<unsigned long long>(late_drop_),
            static_cast<unsigned long long>(order_drop_), static_cast<unsigned long long>(overflow_drop_),
            pending_.size(), peak_pending_, max_queue_ns_ / 1000000.0, max_decode_ns_ / 1000000.0,
            max_release_gap_ns_ / 1000000.0, max_late_ns_ / 1000000.0,
            pts_gaps_ ? double(pts_gap_total_ns_) / pts_gaps_ / 1e6 : 0.0, max_pts_gap_ns_ / 1e6,
            double(encoded_bytes_) * 8 * 1000 / (now - stats_started_), final ? " final" : "");
        callbacks_.log(text);
        stats_started_ = now; submitted_ = decoded_ = presented_ = late_drop_ = order_drop_ = overflow_drop_ = 0;
        pts_gap_total_ns_ = max_pts_gap_ns_ = 0; pts_gaps_ = encoded_bytes_ = 0;
        peak_pending_ = pending_.size(); max_queue_ns_ = max_decode_ns_ = max_release_gap_ns_ = max_late_ns_ = 0;
    }
    mutable std::mutex pending_lock_;
    std::vector<Pending> pending_;
    int64_t stats_started_ = 0, last_presented_due_ = 0, last_release_ns_ = 0;
    int64_t max_queue_ns_ = 0, max_decode_ns_ = 0, max_release_gap_ns_ = 0, max_late_ns_ = 0;
    uint64_t submitted_ = 0, decoded_ = 0, presented_ = 0, late_drop_ = 0, order_drop_ = 0, overflow_drop_ = 0;
    int64_t pts_gap_total_ns_ = 0, max_pts_gap_ns_ = 0;
    uint64_t pts_gaps_ = 0, encoded_bytes_ = 0;
    size_t peak_pending_ = 0;
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
