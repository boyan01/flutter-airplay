// SPDX-License-Identifier: GPL-3.0-only
#include "../../../../../native/include/airplay/receiver.h"
#include "../../../../../native/backends/android/android_audio.h"
#include <jni.h>
#include <android/native_window_jni.h>
#include <android/log.h>
#include <array>
#include <map>
#include <memory>
#include <cstring>
#include <mutex>
#include <string>

namespace {
struct Host {
    JavaVM *vm = nullptr;
    jobject target = nullptr;
    jmethodID event = nullptr, decoders = nullptr, publish = nullptr, unpublish = nullptr, end_video = nullptr;
    std::mutex surface_lock;
    ANativeWindow *window = nullptr;
    uint64_t handle = 0;
    ~Host();
};
struct Env {
    Host *host;
    JNIEnv *env = nullptr;
    bool attached;
    explicit Env(Host *h) : host(h), attached(h->vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
        if (attached) h->vm->AttachCurrentThread(&env, nullptr);
    }
    ~Env() {
        if (env && env->ExceptionCheck()) {
            env->ExceptionClear();
            __android_log_print(ANDROID_LOG_ERROR, "FlutterAirPlay", "Native host callback failed");
        }
        if (attached) host->vm->DetachCurrentThread();
    }
};
Host::~Host() {
    airplay_receiver_destroy(handle);
    if (window) ANativeWindow_release(window);
    Env scope(this); if (scope.env && target) scope.env->DeleteGlobalRef(target);
}
std::mutex hosts_lock;
std::map<uint64_t, std::shared_ptr<Host>> hosts;
std::shared_ptr<Host> get(uint64_t handle) {
    std::lock_guard<std::mutex> guard(hosts_lock);
    auto found = hosts.find(handle); return found == hosts.end() ? nullptr : found->second;
}
void fail(JNIEnv *env, const char *message) {
    auto cls = env->FindClass("java/lang/IllegalStateException");
    if (cls) { env->ThrowNew(cls, message); env->DeleteLocalRef(cls); }
}
std::string utf8(JNIEnv *env, jstring value) {
    if (!value) return "";
    auto cls = env->FindClass("java/lang/String");
    auto method = env->GetMethodID(cls, "getBytes", "(Ljava/lang/String;)[B");
    auto encoding = env->NewStringUTF("UTF-8");
    auto bytes = static_cast<jbyteArray>(env->CallObjectMethod(value, method, encoding));
    std::string text;
    if (bytes) { text.resize(env->GetArrayLength(bytes)); env->GetByteArrayRegion(bytes, 0, text.size(), reinterpret_cast<jbyte *>(text.data())); }
    env->DeleteLocalRef(bytes); env->DeleteLocalRef(encoding); env->DeleteLocalRef(cls); return text;
}
jbyteArray bytes(JNIEnv *env, const uint8_t *data, size_t size) {
    auto result = env->NewByteArray(size);
    if (result && size) env->SetByteArrayRegion(result, 0, size, reinterpret_cast<const jbyte *>(data));
    return result;
}
jbyteArray bytes(JNIEnv *env, const char *text) { return bytes(env, reinterpret_cast<const uint8_t *>(text), strlen(text)); }
}
extern "C" JNIEXPORT jlong JNICALL Java_tech_soit_flutterairplay_PlaybackHost_createNative(
    JNIEnv *env, jobject target, jstring metadata, jbyteArray identity, jstring key) {
    if (env->GetArrayLength(identity) != 6 || !airplay::initialize_android_audio(env)) { fail(env, "Cannot initialize native audio"); return 0; }
    auto host = std::make_shared<Host>(); env->GetJavaVM(&host->vm); host->target = env->NewGlobalRef(target);
    auto cls = env->GetObjectClass(target);
    host->event = env->GetMethodID(cls, "onNativeEvent", "([B)V");
    host->decoders = env->GetMethodID(cls, "selectDecoders", "(II)[Ljava/lang/String;");
    host->publish = env->GetMethodID(cls, "publishNative", "(J[B[BI[B[B)V");
    host->unpublish = env->GetMethodID(cls, "unpublishNative", "()V");
    host->end_video = env->GetMethodID(cls, "endVideo", "(Z)V");
    env->DeleteLocalRef(cls);
    if (env->ExceptionCheck()) return 0;
    AirplayReceiverHost hooks{}; hooks.context = host.get();
    hooks.create_player = [](void *context, AirplayCallbacks callbacks, int width, int height, int audio_mode, char *error, size_t capacity) {
        auto *self = static_cast<Host *>(context); Env scope(self);
        if (!scope.env) return static_cast<AirplayPlayer *>(nullptr);
        auto selected = static_cast<jobjectArray>(scope.env->CallObjectMethod(self->target, self->decoders, width, height));
        if (scope.env->ExceptionCheck() || !selected || scope.env->GetArrayLength(selected) != 3) {
            snprintf(error, capacity, "Cannot select Android video decoders"); return static_cast<AirplayPlayer *>(nullptr);
        }
        std::array<std::string, 3> names;
        for (size_t i = 0; i < names.size(); ++i) {
            auto name = static_cast<jstring>(scope.env->GetObjectArrayElement(selected, i));
            names[i] = utf8(scope.env, name); scope.env->DeleteLocalRef(name);
        }
        scope.env->DeleteLocalRef(selected);
        std::lock_guard<std::mutex> guard(self->surface_lock);
        if (!self->window) { snprintf(error, capacity, "Playback surface has not been prepared"); return static_cast<AirplayPlayer *>(nullptr); }
        auto *player = airplay_player_create(callbacks, self->window, names[0].c_str(), names[1].c_str());
        if (player && (!airplay_player_set_hevc_decoder(player, names[2].c_str()) || !airplay_player_set_audio_output(player, audio_mode))) {
            airplay_player_destroy(player); snprintf(error, capacity, "Cannot configure Android codecs/output"); return static_cast<AirplayPlayer *>(nullptr);
        }
        return player;
    };
    hooks.end_video = [](void *context, bool restarting) {
        if (restarting) return;
        auto *self = static_cast<Host *>(context);
        { std::lock_guard<std::mutex> guard(self->surface_lock);
          if (self->window) ANativeWindow_release(self->window); self->window = nullptr; }
        Env scope(self); if (scope.env) scope.env->CallVoidMethod(self->target, self->end_video, JNI_FALSE);
    };
    hooks.set_surface = [](void *context, AirplayPlayer *player, void *surface) {
        auto *self = static_cast<Host *>(context); auto *window = static_cast<ANativeWindow *>(surface);
        if (player && (!window || !airplay_player_set_surface(player, window))) return false;
        if (window) ANativeWindow_acquire(window);
        std::lock_guard<std::mutex> guard(self->surface_lock);
        if (self->window) ANativeWindow_release(self->window); self->window = window; return true;
    };
    hooks.publish = [](void *context, uint64_t epoch, const char *name, const uint8_t *id, uint16_t port,
                       const uint8_t *video, size_t video_size, const uint8_t *audio, size_t audio_size, char *error, size_t capacity) {
        auto *self = static_cast<Host *>(context); Env scope(self);
        if (!scope.env) return -1;
        auto label = bytes(scope.env, name), identity = bytes(scope.env, id, 6);
        auto video_txt = bytes(scope.env, video, video_size), audio_txt = bytes(scope.env, audio, audio_size);
        scope.env->CallVoidMethod(self->target, self->publish, static_cast<jlong>(epoch), label, identity, static_cast<jint>(port), video_txt, audio_txt);
        scope.env->DeleteLocalRef(label); scope.env->DeleteLocalRef(identity);
        scope.env->DeleteLocalRef(video_txt); scope.env->DeleteLocalRef(audio_txt);
        if (scope.env->ExceptionCheck()) { snprintf(error, capacity, "Cannot publish Android discovery services"); return -1; }
        return 0;
    };
    hooks.unpublish = [](void *context) { auto *self = static_cast<Host *>(context); Env scope(self); if (scope.env) scope.env->CallVoidMethod(self->target, self->unpublish); };
    hooks.event = [](void *context, const char *json) {
        auto *self = static_cast<Host *>(context); Env scope(self); if (!scope.env) return;
        auto text = bytes(scope.env, json); scope.env->CallVoidMethod(self->target, self->event, text); scope.env->DeleteLocalRef(text);
    };
    uint8_t id[6]; env->GetByteArrayRegion(identity, 0, 6, reinterpret_cast<jbyte *>(id));
    char error[512]{};
    host->handle = airplay_receiver_create(hooks, utf8(env, metadata).c_str(), utf8(env, key).c_str(), id, error, sizeof(error));
    if (!host->handle) { fail(env, error); return 0; }
    std::lock_guard<std::mutex> guard(hosts_lock); hosts.emplace(host->handle, host); return host->handle;
}
extern "C" JNIEXPORT void JNICALL Java_tech_soit_flutterairplay_PlaybackHost_stopNative(JNIEnv *env, jobject, jlong handle) {
    char error[512]{}; if (!airplay_receiver_stop(handle, error, sizeof(error))) fail(env, error);
}
extern "C" JNIEXPORT void JNICALL Java_tech_soit_flutterairplay_PlaybackHost_requestStartNative(JNIEnv *, jobject, jlong handle) {
    airplay_receiver_request_start(handle);
}
extern "C" JNIEXPORT void JNICALL Java_tech_soit_flutterairplay_PlaybackHost_requestStopNative(JNIEnv *, jobject, jlong handle) {
    airplay_receiver_request_stop(handle);
}
extern "C" JNIEXPORT void JNICALL Java_tech_soit_flutterairplay_PlaybackHost_logNative(JNIEnv *env, jobject, jlong handle, jstring message) {
    airplay_receiver_log(handle, utf8(env, message).c_str());
}
extern "C" JNIEXPORT void JNICALL Java_tech_soit_flutterairplay_PlaybackHost_discoveryNative(JNIEnv *env, jobject, jlong handle, jlong epoch, jboolean ready, jstring error, jstring name) {
    airplay_receiver_discovery(handle, epoch, ready, utf8(env, error).c_str(), utf8(env, name).c_str());
}
extern "C" JNIEXPORT void JNICALL Java_tech_soit_flutterairplay_PlaybackHost_updateNative(JNIEnv *env, jobject, jlong handle, jstring json) {
    airplay_receiver_update(handle, utf8(env, json).c_str());
}
extern "C" JNIEXPORT jboolean JNICALL Java_tech_soit_flutterairplay_PlaybackHost_setSurfaceNative(JNIEnv *env, jobject, jlong handle, jobject surface) {
    auto host = get(handle); if (!host) return JNI_FALSE;
    auto *window = surface ? ANativeWindow_fromSurface(env, surface) : nullptr;
    // The shared worker changes both the player and host window atomically.
    const bool changed = airplay_receiver_set_surface(handle, window);
    if (window) ANativeWindow_release(window); return changed ? JNI_TRUE : JNI_FALSE;
}
extern "C" JNIEXPORT void JNICALL Java_tech_soit_flutterairplay_PlaybackHost_disposeNative(JNIEnv *, jobject, jlong handle) {
    std::shared_ptr<Host> host;
    { std::lock_guard<std::mutex> guard(hosts_lock); auto found = hosts.find(handle);
      if (found == hosts.end()) return; host = std::move(found->second); hosts.erase(found); }
}
