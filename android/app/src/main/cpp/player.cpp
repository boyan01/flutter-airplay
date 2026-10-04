// SPDX-License-Identifier: GPL-3.0-only
#include "player.h"
#include "android_audio.h"
#include <jni.h>
#include <android/native_window_jni.h>
#include <android/log.h>
#include <memory>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace {
struct Host {
    JavaVM *vm = nullptr;
    jobject target = nullptr;
    jmethodID event = nullptr, log = nullptr;
    jint epoch = 0;
    AirplayPlayer *player = nullptr;
    ~Host() {
        airplay_player_destroy(player);
        JNIEnv *env = nullptr;
        bool attached = vm && vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK;
        if (attached) vm->AttachCurrentThread(&env, nullptr);
        if (env && target) env->DeleteGlobalRef(target);
        if (attached) vm->DetachCurrentThread();
    }
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
std::mutex lifecycle;
std::unique_ptr<Host> active;
void fail(JNIEnv *env, const char *message) {
    auto cls = env->FindClass("java/lang/IllegalStateException");
    if (cls) { env->ThrowNew(cls, message); env->DeleteLocalRef(cls); }
}
std::string utf8(JNIEnv *env, jstring value) {
    // Java's modified UTF-8 corrupts supplementary Unicode characters.
    auto cls = env->FindClass("java/lang/String");
    auto method = env->GetMethodID(cls, "getBytes", "(Ljava/lang/String;)[B");
    auto encoding = env->NewStringUTF("UTF-8");
    auto bytes = static_cast<jbyteArray>(env->CallObjectMethod(value, method, encoding));
    std::string text;
    if (bytes) { text.resize(env->GetArrayLength(bytes)); env->GetByteArrayRegion(bytes, 0, text.size(), reinterpret_cast<jbyte *>(text.data())); }
    env->DeleteLocalRef(bytes); env->DeleteLocalRef(encoding); env->DeleteLocalRef(cls);
    return text;
}
jbyteArray bytes(JNIEnv *env, const char *text) {
    const auto size = strlen(text);
    auto result = env->NewByteArray(size);
    if (result) env->SetByteArrayRegion(result, 0, size, reinterpret_cast<const jbyte *>(text));
    return result;
}
void event(void *context, const char *type, const char *detail, int width, int height) {
    auto *host = static_cast<Host *>(context); Env scope(host);
    if (!scope.env) return;
    auto name = scope.env->NewStringUTF(type);
    auto text = bytes(scope.env, detail);
    scope.env->CallVoidMethod(host->target, host->event, host->epoch, name, text, width, height);
    scope.env->DeleteLocalRef(name); scope.env->DeleteLocalRef(text);
}
void log(void *context, int level, const char *message) {
    auto *host = static_cast<Host *>(context); Env scope(host);
    if (!scope.env) return;
    auto text = bytes(scope.env, message);
    scope.env->CallVoidMethod(host->target, host->log, host->epoch, level, text);
    scope.env->DeleteLocalRef(text);
}
}
extern "C" JNIEXPORT jint JNICALL Java_tech_soit_flutterairplay_PlaybackHost_startNative(
        JNIEnv *env, jobject target, jstring name, jbyteArray identity, jstring key,
        jobject surface, jstring decoder, jstring fallback, jstring hevc_decoder, jint epoch, jint width, jint height, jint audio_mode) {
    std::lock_guard<std::mutex> guard(lifecycle);
    if (active || env->GetArrayLength(identity) != 6) { fail(env, "Invalid native receiver lifecycle"); return 0; }
    if (!airplay::initialize_android_audio(env)) return 0;
    auto host = std::make_unique<Host>();
    env->GetJavaVM(&host->vm); host->target = env->NewGlobalRef(target); host->epoch = epoch;
    auto cls = env->GetObjectClass(target);
    host->event = env->GetMethodID(cls, "onNativeEvent", "(ILjava/lang/String;[BII)V");
    host->log = env->GetMethodID(cls, "onNativeLog", "(II[B)V");
    env->DeleteLocalRef(cls);
    if (!host->event || !host->log) return 0;
    uint8_t id[6]; env->GetByteArrayRegion(identity, 0, 6, reinterpret_cast<jbyte *>(id));
    auto label = utf8(env, name), path = utf8(env, key), primary = utf8(env, decoder), backup = utf8(env, fallback);
    const auto hevc = utf8(env, hevc_decoder);
    auto *window = ANativeWindow_fromSurface(env, surface);
    if (!window) { fail(env, "Cannot acquire playback surface"); return 0; }
    AirplayCallbacks callbacks{host.get(), event, nullptr, log};
    // Each side owns its own window reference.
    host->player = airplay_player_create(callbacks, window, primary.c_str(), backup.c_str());
    ANativeWindow_release(window);
    if (!host->player) { fail(env, "Cannot create native player"); return 0; }
    if (!airplay_player_set_hevc_decoder(host->player, hevc.c_str())) {
        fail(env, "Invalid HEVC decoder selection"); return 0;
    }
    if (!airplay_player_set_audio_output(host->player, audio_mode)) {
        fail(env, "Invalid audio output selection"); return 0;
    }
    if (!airplay_player_set_video_size(host->player, width, height)) {
        fail(env, "Invalid video request size"); return 0;
    }
    char error[512]{};
    if (!airplay_player_start(host->player, label.c_str(), id, path.c_str(), error, sizeof(error))) { fail(env, error); return 0; }
    const auto port = airplay_player_port(host->player);
    active = std::move(host);
    return port;
}
extern "C" JNIEXPORT jbyteArray JNICALL Java_tech_soit_flutterairplay_PlaybackHost_txtNative(JNIEnv *env, jobject, jboolean audio) {
    std::lock_guard<std::mutex> guard(lifecycle);
    const auto size = active ? airplay_player_txt(active->player, audio, nullptr, 0) : 0;
    std::vector<uint8_t> txt(size);
    if (size) airplay_player_txt(active->player, audio, txt.data(), txt.size());
    auto result = env->NewByteArray(size);
    if (result && size) env->SetByteArrayRegion(result, 0, size, reinterpret_cast<const jbyte *>(txt.data()));
    return result;
}
extern "C" JNIEXPORT void JNICALL Java_tech_soit_flutterairplay_PlaybackHost_stopNative(JNIEnv *, jobject) {
    std::lock_guard<std::mutex> guard(lifecycle); active.reset();
}

extern "C" JNIEXPORT jboolean JNICALL Java_tech_soit_flutterairplay_PlaybackHost_setSurfaceNative(
        JNIEnv *env, jobject, jobject surface) {
    std::lock_guard<std::mutex> guard(lifecycle);
    if (!active) return JNI_TRUE;
    auto *window = ANativeWindow_fromSurface(env, surface);
    if (!window) return JNI_FALSE;
    const auto changed = airplay_player_set_surface(active->player, window);
    ANativeWindow_release(window);
    return changed ? JNI_TRUE : JNI_FALSE;
}
