// SPDX-License-Identifier: GPL-3.0-only
#include "platform.h"
#include <VideoToolbox/VideoToolbox.h>
#include <CoreVideo/CoreVideo.h>

namespace airplay {
class MacVideo final : public VideoOutput {
public:
    explicit MacVideo(VideoCallbacks callbacks) : callbacks_(std::move(callbacks)) {}
    ~MacVideo() override { reset(); }
    void size(int, int) override {} // SPS and decoded pixel buffers own actual dimensions.
    void drain() override {}
    void reset() override {
        close_session(); sps_.clear(); pps_.clear();
    }
    bool decode(const VideoPacket &packet) override {
        auto nals = split_nals(packet.bytes.data(), packet.bytes.size());
        bool picture = false, keyframe = false, changed = false;
        std::vector<uint8_t> sample;
        for (const auto &nal : nals) {
            const auto type = nal[0] & 31;
            if (type == 7 || type == 8) {
                auto &parameter = type == 7 ? sps_ : pps_;
                if (parameter != nal) { parameter = nal; changed = true; }
                continue;
            }
            picture |= type == 1 || type == 5; keyframe |= type == 5;
            const uint32_t length = uint32_t(nal.size());
            sample.insert(sample.end(), {uint8_t(length >> 24), uint8_t(length >> 16), uint8_t(length >> 8), uint8_t(length)});
            sample.insert(sample.end(), nal.begin(), nal.end());
        }
        if (changed) close_session();
        if (!picture) return true;
        if (!session_) {
            if (!keyframe || sps_.empty() || pps_.empty()) return true;
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
        Context context{this, packet.deadline, packet.generation};
        auto status = VTDecompressionSessionDecodeFrame(session_, buffer, kVTDecodeFrame_EnableAsynchronousDecompression,
                                                        &context, nullptr);
        if (!status) status = VTDecompressionSessionWaitForAsynchronousFrames(session_);
        CFRelease(buffer);
        return status == noErr;
    }
private:
    struct Context { MacVideo *video; int64_t deadline; uint64_t generation; };
    static void decoded(void *, void *opaque, OSStatus status, VTDecodeInfoFlags, CVImageBufferRef image, CMTime, CMTime) {
        auto *context = static_cast<Context *>(opaque);
        if (!status && image) context->video->callbacks_.frame(image, int(CVPixelBufferGetWidth(image)),
            int(CVPixelBufferGetHeight(image)), context->deadline, context->generation);
    }
    bool open() {
        const uint8_t *parameters[] = {sps_.data(), pps_.data()};
        const size_t lengths[] = {sps_.size(), pps_.size()};
        if (CMVideoFormatDescriptionCreateFromH264ParameterSets(nullptr, 2, parameters, lengths, 4, &format_)) return false;
        auto attributes = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        const int32_t pixel_format = kCVPixelFormatType_32BGRA;
        auto number = CFNumberCreate(nullptr, kCFNumberSInt32Type, &pixel_format);
        auto properties = CFDictionaryCreate(nullptr, nullptr, nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(attributes, kCVPixelBufferPixelFormatTypeKey, number);
        CFDictionarySetValue(attributes, kCVPixelBufferIOSurfacePropertiesKey, properties);
        CFDictionarySetValue(attributes, kCVPixelBufferMetalCompatibilityKey, kCFBooleanTrue);
        auto specification = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(specification, kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder, kCFBooleanTrue);
        VTDecompressionOutputCallbackRecord callback{decoded, this};
        auto status = VTDecompressionSessionCreate(nullptr, format_, specification, attributes, &callback, &session_);
        CFRelease(specification); CFRelease(attributes); CFRelease(number); CFRelease(properties);
        if (status) { close_session(); return false; }
        VTSessionSetProperty(session_, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
        callbacks_.log("VideoToolbox H.264 decoder ready; direct CVPixelBuffer output");
        return true;
    }
    void close_session() {
        if (session_) { VTDecompressionSessionWaitForAsynchronousFrames(session_); VTDecompressionSessionInvalidate(session_); CFRelease(session_); session_ = nullptr; }
        if (format_) { CFRelease(format_); format_ = nullptr; }
    }
    VideoCallbacks callbacks_;
    std::vector<uint8_t> sps_, pps_;
    VTDecompressionSessionRef session_ = nullptr;
    CMVideoFormatDescriptionRef format_ = nullptr;
};
std::unique_ptr<VideoOutput> make_video_output(void *, const char *, const char *, VideoCallbacks cb) {
    return std::make_unique<MacVideo>(std::move(cb));
}
} // namespace airplay
