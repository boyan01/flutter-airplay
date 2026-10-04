// SPDX-License-Identifier: GPL-3.0-only
#include "android_audio.h"
#include "audio_clock.h"
#include <oboe/Oboe.h>
#include <condition_variable>
#include <deque>
#include <future>
#include <thread>
#include <sstream>

namespace airplay {
namespace {
JavaVM *vm = nullptr;
jclass sink_class = nullptr;
jmethodID constructor, write_pcm, presentation, interrupt_sink, release_sink, sample_rate, buffer_frames, underruns;
std::mutex java_lock;
struct Env {
    JNIEnv *env = nullptr;
    bool attached = false;
    Env() {
        if (vm && vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK)
            attached = vm->AttachCurrentThread(&env, nullptr) == JNI_OK;
    }
    ~Env() { if (attached) vm->DetachCurrentThread(); }
    bool failed() {
        if (!env || !env->ExceptionCheck()) return !env;
        env->ExceptionClear(); return true;
    }
};
struct Commands {
    std::mutex lock;
    std::condition_variable wake;
    std::deque<std::function<void()>> queue;
    bool closed = false;
    void post(std::function<void()> task) {
        std::lock_guard<std::mutex> guard(lock);
        if (!closed) { queue.push_back(std::move(task)); wake.notify_one(); }
    }
};
class Pull final : public oboe::AudioStreamDataCallback, public oboe::AudioStreamErrorCallback {
public:
    explicit Pull(std::shared_ptr<AudioBuffer> buffer) : buffer(std::move(buffer)) {}
    oboe::DataCallbackResult onAudioReady(oboe::AudioStream *stream, void *data, int32_t count) override {
        const auto now = monotonic_ns();
        auto due = now + int64_t(stream->getBufferSizeInFrames()) * kSecond / stream->getSampleRate();
        int64_t position = 0, timestamp = 0;
        if (stream->getTimestamp(CLOCK_MONOTONIC, &position, &timestamp) == oboe::Result::OK) {
            auto estimate = timestamp + (stream->getFramesWritten() - position) * kSecond / stream->getSampleRate();
            if (estimate >= now && estimate < now + kSecond / 2) due = estimate;
        }
        read(static_cast<int16_t *>(data), count, due);
        return oboe::DataCallbackResult::Continue;
    }
    void read(int16_t *pcm, int count, int64_t due) {
        buffer->read(pcm, count, clock.next(count, due));
        ++callbacks; frames += count;
        for (int i = 0; i < count; ++i) {
            int peak = std::max(std::abs(int(pcm[i * 2])), std::abs(int(pcm[i * 2 + 1])));
            if (peak) ++nonzero;
            auto previous = peak_sample.load();
            while (peak > previous && !peak_sample.compare_exchange_weak(previous, peak)) {}
        }
    }
    void onErrorAfterClose(oboe::AudioStream *, oboe::Result error) override { if (report) report(error); }
    std::function<void(oboe::Result)> report;
    AudioClock clock;
    std::shared_ptr<AudioBuffer> buffer;
    std::atomic<uint64_t> callbacks{0}, frames{0}, nonzero{0};
    std::atomic<int> peak_sample{0};
};

class AndroidAudio final : public AudioOutput {
public:
    AndroidAudio(std::shared_ptr<AudioBuffer> buffer, int mode, std::function<void(const char *)> log)
        : buffer_(std::move(buffer)), mode_(mode), log_(std::move(log)), commands_(std::make_shared<Commands>()) {
        control_ = std::thread([this] {
            for (;;) {
                std::function<void()> task;
                { std::unique_lock<std::mutex> guard(commands_->lock);
                  commands_->wake.wait(guard, [&] { return commands_->closed || !commands_->queue.empty(); });
                  if (commands_->queue.empty() && commands_->closed) break;
                  task = std::move(commands_->queue.front()); commands_->queue.pop_front(); }
                task();
            }
        });
    }
    ~AndroidAudio() override {
        stop();
        { std::lock_guard<std::mutex> guard(commands_->lock); commands_->closed = true; }
        commands_->wake.notify_one(); control_.join();
    }
    bool start() override { return call<bool>([this] {
        if (active_) return true;
        stopped_ = false;
        if (compatibility_ || mode_ == 2) return openTrack();
        if (openAAudio()) return true;
        return mode_ == 0 && fallback("AAudio open/start failure");
    }); }
    void stop() override { call<bool>([this] { stopped_ = true; closeOutput(); return true; }); }
    std::string diagnostics() override { return call<std::string>([this] {
        std::ostringstream out;
        out << "Android audio output: selected=" << (mode_ == 0 ? "auto" : mode_ == 1 ? "AAudio" : "AudioTrack")
            << " actual=" << backend_ << " state=" << (active_ ? "running" : "closed")
            << " rate=" << rate_ << " channels=2 buffer_frames=" << size_ << " burst_frames=" << burst_
            << " performance=" << performance_ << " fallbacks=" << fallbacks_ << " restarts=" << restarts_
            << " write_errors=" << write_errors_.load() << " written_frames=" << written_.load();
        if (stream_) {
            auto xruns = stream_->getXRunCount();
            out << " api=" << oboe::convertToText(stream_->getAudioApi()) << " xruns=" << (xruns ? xruns.value() : -1);
        } else if (sink_) {
            Env scope; auto count = scope.env->CallIntMethod(sink_, underruns);
            if (!scope.failed()) out << " xruns=" << count;
        }
        if (pull_) out << " callbacks_total=" << pull_->callbacks.load() << " frames_total=" << pull_->frames.load()
            << " nonzero_frames_total=" << pull_->nonzero.load() << " peak_since_report=" << pull_->peak_sample.exchange(0);
        out << " pcm_late_drop_total=" << buffer_->late_drops() << " pcm_stale_drop_total=" << buffer_->stale_drops()
            << " gain=" << buffer_->gain() << " last_result=" << last_result_;
        return out.str();
    }); }
    void inject(int error, bool fail_open) {
        call<bool>([this, error, fail_open] {
            if (fail_open) fail_open_ = true;
            if (!fail_open) {
                if (backend_ == "AudioTrack" && active_) {
                    if (error == 0) write_limit_ = 128;
                    else if (error == int(oboe::Result::ErrorInternal)) inject_write_error_ = true;
                } else handleError(generation_, static_cast<oboe::Result>(error));
            }
            return true;
        });
    }
private:
    template<class T, class F> T call(F function) {
        auto task = std::make_shared<std::packaged_task<T()>>(std::move(function));
        auto result = task->get_future();
        commands_->post([task] { (*task)(); });
        return result.get();
    }
    void report(const std::string &text) { last_result_ = text; if (log_) log_(text.c_str()); }
    std::shared_ptr<Pull> newPull() {
        auto result = std::make_shared<Pull>(buffer_);
        const auto generation = ++generation_;
        std::weak_ptr<Commands> commands = commands_;
        result->report = [commands, this, generation](oboe::Result error) {
            if (auto queue = commands.lock()) queue->post([this, generation, error] { handleError(generation, error); });
        };
        return result;
    }
    bool openAAudio() {
        backend_ = "AAudio"; pull_ = newPull();
        if (fail_open_) { report("AAudio injected open failure"); return false; }
        if (!oboe::AudioStreamBuilder::isAAudioSupported()) {
            report("AAudio unavailable"); return false;
        }
        oboe::AudioStreamBuilder builder;
        builder.setAudioApi(oboe::AudioApi::AAudio)->setDirection(oboe::Direction::Output)
            ->setSharingMode(oboe::SharingMode::Shared)->setFormat(oboe::AudioFormat::I16)
            ->setChannelCount(2)->setSampleRate(kSampleRate)
            ->setSampleRateConversionQuality(oboe::SampleRateConversionQuality::Medium)
            ->setPerformanceMode(oboe::PerformanceMode::LowLatency)->setUsage(oboe::Usage::Media)
            ->setDataCallback(pull_)->setErrorCallback(pull_);
        auto opened = builder.openStream(stream_);
        if (opened != oboe::Result::OK) { report(std::string("AAudio open: ") + oboe::convertToText(opened)); return false; }
        if (stream_->getAudioApi() != oboe::AudioApi::AAudio) {
            closeOutput(); report("Requested AAudio API unavailable"); return false;
        }
        stream_->setBufferSizeInFrames(stream_->getFramesPerBurst() * 3);
        rate_ = stream_->getSampleRate(); size_ = stream_->getBufferSizeInFrames(); burst_ = stream_->getFramesPerBurst();
        performance_ = oboe::convertToText(stream_->getPerformanceMode());
        auto started = stream_->requestStart();
        active_ = started == oboe::Result::OK;
        report(std::string("AAudio start: ") + oboe::convertToText(started) + " api=AAudio rate=" +
            std::to_string(rate_) + " buffer_frames=" + std::to_string(size_) +
            " burst_frames=" + std::to_string(burst_) + " performance=" + performance_);
        if (!active_) closeOutput();
        return active_;
    }
    bool openTrack() {
        backend_ = "AudioTrack"; pull_ = newPull(); performance_ = "None"; burst_ = 0;
        Env scope;
        if (!scope.env || !sink_class) { report("AudioTrack JNI unavailable"); return false; }
        auto local = scope.env->NewObject(sink_class, constructor);
        if (scope.failed() || !local) { report("AudioTrack initialization failed"); return false; }
        sink_ = scope.env->NewGlobalRef(local); scope.env->DeleteLocalRef(local);
        rate_ = scope.env->CallIntMethod(sink_, sample_rate);
        size_ = scope.env->CallIntMethod(sink_, buffer_frames);
        if (scope.failed()) { closeOutput(); report("AudioTrack parameters failed"); return false; }
        writer_stop_ = false; inject_write_error_ = false; write_limit_ = 882; active_ = true;
        writer_ = std::thread([this, generation = generation_] { writeLoop(generation); });
        report("AudioTrack start: OK rate=" + std::to_string(rate_) + " buffer_frames=" + std::to_string(size_) + " performance=None");
        return true;
    }
    void writeLoop(uint64_t generation) {
        Env scope;
        auto samples = scope.env ? scope.env->NewShortArray(882) : nullptr;
        bool failed = scope.failed() || !samples;
        int16_t pcm[882];
        while (!writer_stop_ && !failed) {
            auto due = scope.env->CallLongMethod(sink_, presentation);
            if (scope.failed()) { failed = true; break; }
            pull_->read(pcm, 441, due);
            scope.env->SetShortArrayRegion(samples, 0, 882, pcm);
            if (scope.failed()) { failed = true; break; }
            int offset = 0;
            while (offset < 882 && !writer_stop_) {
                if (inject_write_error_.exchange(false)) { failed = true; break; }
                int count = scope.env->CallIntMethod(sink_, write_pcm, samples, offset,
                    std::min(882 - offset, write_limit_.load()));
                if (scope.failed() || count <= 0 || count > 882 - offset || count % 2) { failed = true; break; }
                offset += count; written_ += count / 2;
            }
        }
        if (samples) scope.env->DeleteLocalRef(samples);
        if (failed && !writer_stop_) {
            ++write_errors_;
            commands_->post([this, generation] {
                if (!stopped_ && generation == generation_) { closeOutput(); report("Audio output error: AudioTrack write failed; video continues"); }
            });
        }
    }
    void closeOutput() {
        ++generation_; active_ = false;
        if (stream_) { stream_->stop(); stream_->close(); stream_.reset(); }
        if (sink_) {
            writer_stop_ = true;
            Env scope;
            scope.env->CallVoidMethod(sink_, interrupt_sink); scope.failed();
            if (writer_.joinable()) writer_.join();
            scope.env->CallVoidMethod(sink_, release_sink); scope.failed();
            scope.env->DeleteGlobalRef(sink_); sink_ = nullptr;
        }
        // Only reset after the callback/writer has finished consuming PCM.
        if (pull_) pull_->clock.reset();
    }
    bool fallback(const std::string &reason) {
        closeOutput(); compatibility_ = true; ++fallbacks_;
        report("Audio fallback: reason=" + reason + " from=AAudio to=AudioTrack");
        bool result = openTrack();
        report(std::string("Audio fallback result: ") + (result ? "OK" : "FAILED; audio output error; video continues"));
        return result;
    }
    void handleError(uint64_t generation, oboe::Result error) {
        if (stopped_ || generation != generation_ || backend_ != "AAudio") return;
        std::string reason = oboe::convertToText(error);
        closeOutput();
        if (mode_ == 0 && error == oboe::Result::ErrorTimeout) { fallback(reason); return; }
        if (error == oboe::Result::ErrorDisconnected) {
            ++restarts_;
            if (openAAudio()) { report("AAudio route reopen: OK"); return; }
            if (mode_ == 0) { fallback(reason + "; reopen failed"); return; }
        }
        report("Audio output error: " + reason + "; video continues");
    }
    std::shared_ptr<AudioBuffer> buffer_;
    const int mode_;
    std::function<void(const char *)> log_;
    std::shared_ptr<Commands> commands_;
    std::thread control_, writer_;
    std::shared_ptr<Pull> pull_;
    std::shared_ptr<oboe::AudioStream> stream_;
    jobject sink_ = nullptr;
    std::atomic<bool> writer_stop_{true}, inject_write_error_{false};
    std::atomic<int> write_limit_{882};
    std::atomic<uint64_t> write_errors_{0}, written_{0};
    bool stopped_ = true, active_ = false, compatibility_ = false, fail_open_ = false;
    uint64_t generation_ = 0, fallbacks_ = 0, restarts_ = 0;
    int rate_ = 0, size_ = 0, burst_ = 0;
    std::string backend_ = "none", performance_ = "none", last_result_ = "none";
};
}
bool initialize_android_audio(JNIEnv *env) {
    std::lock_guard<std::mutex> guard(java_lock);
    if (sink_class) return true;
    env->GetJavaVM(&vm);
    auto cls = env->FindClass("tech/soit/flutterairplay/audio/AudioTrackSink");
    if (!cls) return false;
    constructor = env->GetMethodID(cls, "<init>", "()V");
    write_pcm = env->GetMethodID(cls, "write", "([SII)I");
    presentation = env->GetMethodID(cls, "presentationTimeNs", "()J");
    interrupt_sink = env->GetMethodID(cls, "interrupt", "()V");
    release_sink = env->GetMethodID(cls, "release", "()V");
    sample_rate = env->GetMethodID(cls, "sampleRate", "()I");
    buffer_frames = env->GetMethodID(cls, "bufferFrames", "()I");
    underruns = env->GetMethodID(cls, "underruns", "()I");
    if (env->ExceptionCheck()) { env->DeleteLocalRef(cls); return false; }
    sink_class = static_cast<jclass>(env->NewGlobalRef(cls)); env->DeleteLocalRef(cls);
    return sink_class != nullptr;
}
std::unique_ptr<AudioOutput> make_android_audio_output(std::shared_ptr<AudioBuffer> buffer, int mode,
        std::function<void(const char *)> log) {
    return std::make_unique<AndroidAudio>(std::move(buffer), mode, std::move(log));
}
std::unique_ptr<AudioOutput> make_audio_output(std::shared_ptr<AudioBuffer> buffer) {
    return make_android_audio_output(std::move(buffer), 0);
}
void android_audio_test_failure(AudioOutput &output, int error, bool fail_open) {
    static_cast<AndroidAudio &>(output).inject(error, fail_open);
}
} // namespace airplay
