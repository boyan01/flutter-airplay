// SPDX-License-Identifier: GPL-3.0-or-later
#include "receiver.h"
#include <jni.h>
#include <memory>
#include <mutex>
// One receiver per app process. Opaque monotonically changing IDs avoid stale
// Java handles dereferencing freed native memory. Never call Java on RTP threads.
static std::mutex apiMutex;
static std::unique_ptr<airplay::Receiver> receiver;
static jlong generation = 0;
extern "C" JNIEXPORT jlong JNICALL
Java_io_github_boyan01_airplay_NativeReceiver_epochNative(JNIEnv *, jclass, jlong handle) {
    std::lock_guard<std::mutex> guard(apiMutex);
    return receiver && handle == generation ? (jlong)receiver->epoch() : -1;
}
extern "C" JNIEXPORT jlong JNICALL
Java_io_github_boyan01_airplay_NativeReceiver_open(JNIEnv *env, jclass,
    jstring name, jbyteArray identity, jstring keyfile) {
    std::lock_guard<std::mutex> guard(apiMutex);
    if (receiver || !name || !identity || env->GetArrayLength(identity) != 6 || !keyfile) return 0;
    uint8_t id[6]; env->GetByteArrayRegion(identity, 0, 6, (jbyte *)id);
    if (env->ExceptionCheck()) return 0;
    const char *n = env->GetStringUTFChars(name, nullptr);
    if (!n) return 0;
    const char *k = env->GetStringUTFChars(keyfile, nullptr);
    if (!k) { env->ReleaseStringUTFChars(name, n); return 0; }
    auto next = std::make_unique<airplay::Receiver>();
    int port = next->start(n, id, k);
    env->ReleaseStringUTFChars(name, n); env->ReleaseStringUTFChars(keyfile, k);
    if (port <= 0) return 0;
    receiver = std::move(next); ++generation;
    // Port fits the low 16 bits; generation occupies the rest.
    generation = (generation & ~0xffffLL) + 0x10000 + port;
    return generation;
}
extern "C" JNIEXPORT void JNICALL
Java_io_github_boyan01_airplay_NativeReceiver_closeNative(JNIEnv *, jclass, jlong handle) {
    std::lock_guard<std::mutex> guard(apiMutex);
    if (receiver && handle == generation) receiver.reset();
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_io_github_boyan01_airplay_NativeReceiver_txtNative(JNIEnv *env, jclass, jlong handle, jboolean audio) {
    std::lock_guard<std::mutex> guard(apiMutex);
    if (!receiver || handle != generation) return nullptr;
    auto bytes = receiver->txt(audio);
    jbyteArray out = env->NewByteArray((jsize)bytes.size());
    if (out) env->SetByteArrayRegion(out, 0, (jsize)bytes.size(), (const jbyte *)bytes.data());
    return out;
}
extern "C" JNIEXPORT jobject JNICALL
Java_io_github_boyan01_airplay_NativeReceiver_pollNative(JNIEnv *env, jclass, jlong handle) {
    std::lock_guard<std::mutex> guard(apiMutex);
    if (!receiver || handle != generation) return nullptr;
    airplay::Packet packet;
    if (!receiver->poll(packet)) return nullptr;
    jclass cls = env->FindClass("io/github/boyan01/airplay/EncodedPacket");
    if (!cls) return nullptr;
    jmethodID ctor = env->GetMethodID(cls, "<init>", "(IIJJIJ[B)V");
    if (!ctor) return nullptr;
    jbyteArray bytes = env->NewByteArray((jsize)packet.bytes.size());
    if (!bytes) return nullptr;
    env->SetByteArrayRegion(bytes, 0, (jsize)packet.bytes.size(), (const jbyte *)packet.bytes.data());
    if (env->ExceptionCheck()) return nullptr;
    return env->NewObject(cls, ctor, packet.kind, packet.codec, (jlong)packet.pts,
        (jlong)packet.rtp, packet.sync, (jlong)packet.epoch, bytes);
}
