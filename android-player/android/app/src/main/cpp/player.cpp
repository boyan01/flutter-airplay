// SPDX-License-Identifier: GPL-3.0-only
// Flutter AirPlay Android host for the pinned UxPlay receive core.
#include <jni.h>
#include <atomic>
#include <mutex>
#include <memory>
#include <cstring>
#include <cstdio>
#include <ctime>
#include <android/log.h>
extern "C" {
#include "raop.h"
#include "dnssd.h"
}
#include "audio_engine.h"
#include "log_sink.h"

namespace {
struct Player {
    JavaVM *vm{}; jobject host{};
    jmethodID frame{}, size{}, state{}, reset{};
    raop_t *raop{}; dnssd_t *dns{}; AudioEngine *audio{};
    int64_t wallToMono{};
    std::atomic<bool> closing{false};
    std::atomic<int> connections{0};
    ~Player() {
        closing = true;
        if (raop) raop_destroy(raop); // joins network callbacks before destroying their targets
        if (audio) audio_engine_destroy(audio);
        if (dns) { dnssd_unregister_raop(dns); dnssd_unregister_airplay(dns); dnssd_destroy(dns); }
        if (host) { JNIEnv *env{}; vm->GetEnv((void**)&env, JNI_VERSION_1_6); if (env) env->DeleteGlobalRef(host); }
    }
};
std::mutex lifecycle;
std::unique_ptr<Player> active;
struct Env {
    Player *p; JNIEnv *e{}; bool attached{};
    explicit Env(Player *p):p(p) {
        if (p->vm->GetEnv((void**)&e, JNI_VERSION_1_6)==JNI_EDETACHED)
            attached = p->vm->AttachCurrentThread(&e,nullptr)==JNI_OK;
    }
    ~Env() { if (e && e->ExceptionCheck()) { e->ExceptionClear(); __android_log_print(ANDROID_LOG_ERROR,"FlutterAirPlay","Playback callback failed"); } if(attached)p->vm->DetachCurrentThread(); }
};
void state(Player *p,const char *text) {
    if(p->closing)return; Env env(p); if(!env.e)return;
    auto s=env.e->NewStringUTF(text); env.e->CallVoidMethod(p->host,p->state,s);env.e->DeleteLocalRef(s);
}
int64_t now(clockid_t id) { timespec ts{};clock_gettime(id,&ts);return int64_t(ts.tv_sec)*1000000000LL+ts.tv_nsec; }
void video(void *cls, raop_ntp_t *, video_decode_struct *d) {
    auto p=(Player*)cls;
    if(p->closing || d->data_len<5 || d->data_len>4*1024*1024 || d->data[0]!=0)return;
    Env env(p);if(!env.e)return;
    auto bytes=env.e->NewByteArray(d->data_len);if(!bytes)return;
    env.e->SetByteArrayRegion(bytes,0,d->data_len,(jbyte*)d->data);
    env.e->CallVoidMethod(p->host,p->frame,bytes,(jlong)(int64_t(d->ntp_time_local)+p->wallToMono),(jboolean)d->is_h265);
    env.e->DeleteLocalRef(bytes);
}
void audio(void *cls,raop_ntp_t*,audio_decode_struct*d) {
    auto p=(Player*)cls; if(p->closing || d->data_len<=0 || d->data_len>65536)return;
    audio_engine_decode(p->audio,d->data,d->data_len,d->ct,d->ntp_time_local ? int64_t(d->ntp_time_local)+p->wallToMono : now(CLOCK_MONOTONIC));
}
void format(void *cls,unsigned char *ct,unsigned short *spf,bool*,bool*,uint64_t*) {
    auto p=(Player*)cls;audio_engine_on_format(p->audio,*ct,*spf);
    if(!audio_engine_start(p->audio))state(p,"无法打开音频输出，请停止后重试");
}
void size(void *cls,float *sw,float *sh,float*,float*) {
    auto p=(Player*)cls;if(p->closing)return; Env env(p);if(!env.e)return;
    if(*sw>=1 && *sh>=1 && *sw<=4096 && *sh<=4096)env.e->CallVoidMethod(p->host,p->size,(jint)*sw,(jint)*sh);
}
void videoFlush(void *cls) {auto p=(Player*)cls;if(p->closing)return;Env env(p);if(env.e)env.e->CallVoidMethod(p->host,p->reset);}
void audioFlush(void *cls) { auto p=(Player*)cls;audio_engine_pause(p->audio);audio_engine_start(p->audio); }
void reset(void *cls,reset_type_t) {videoFlush(cls);audioFlush(cls);}
void connReset(void *cls,int) {videoFlush(cls);audioFlush(cls);state((Player*)cls,"连接已断开，等待重新连接");}
void nothing(void*){}
void connected(void *cls){((Player*)cls)->connections.fetch_add(1);}
void disconnected(void *cls){auto p=(Player*)cls;if(p->connections.fetch_sub(1)==1){videoFlush(cls);audio_engine_pause(p->audio);state(p,"等待 iPhone 连接");}}
void mirror(void *cls,bool running){state((Player*)cls,running?"正在接收屏幕镜像":"等待 iPhone 连接");}
double volume(void*){return 0.0;}
void volumeSet(void*,float){} // sender volume never changes Android system volume
int codec(void*,video_codec_t c){return c==VIDEO_CODEC_H264?0:-1;}
void log(void*,int level,const char*){if(level<=3)__android_log_print(ANDROID_LOG_WARN,"FlutterAirPlay","Receiver core warning (%d)",level);}
void fail(JNIEnv *env,const char *message){auto c=env->FindClass("java/lang/IllegalStateException");env->ThrowNew(c,message);env->DeleteLocalRef(c);}
}
extern "C" JNIEXPORT jint JNICALL Java_io_github_boyan01_flutter_1airplay_PlaybackHost_startNative(JNIEnv*env,jobject host,jstring name,jbyteArray identity,jstring key) {
    std::lock_guard<std::mutex> guard(lifecycle);
    if(active){fail(env,"Receiver already running");return 0;}
    if(env->GetArrayLength(identity)!=6){fail(env,"Invalid app identity");return 0;}
    auto p=std::make_unique<Player>(); env->GetJavaVM(&p->vm);p->host=env->NewGlobalRef(host);
    auto klass=env->GetObjectClass(host);
    p->frame=env->GetMethodID(klass,"onVideoData","([BJZ)V");p->size=env->GetMethodID(klass,"onVideoSize","(II)V");
    p->state=env->GetMethodID(klass,"onNativeState","(Ljava/lang/String;)V");p->reset=env->GetMethodID(klass,"onVideoReset","()V");env->DeleteLocalRef(klass);
    if(env->ExceptionCheck())return 0;
    p->wallToMono=now(CLOCK_MONOTONIC)-now(CLOCK_REALTIME);
    p->audio=audio_engine_create(std::make_shared<LogSink>(),44100,2);
    audio_engine_configure(p->audio,0,95,0,true,false,true,false);
    raop_callbacks_t cb{};cb.cls=p.get();cb.audio_process=audio;cb.video_process=video;
    cb.audio_get_format=format;cb.video_report_size=size;cb.audio_flush=audioFlush;cb.video_flush=videoFlush;
    cb.video_pause=videoFlush;cb.video_resume=nothing;cb.conn_feedback=nothing;cb.conn_reset=connReset;cb.video_reset=reset;
    cb.conn_init=connected;cb.conn_destroy=disconnected;cb.mirror_video_running=mirror;
    cb.audio_set_client_volume=volume;cb.audio_set_volume=volumeSet;cb.video_set_codec=codec;
    p->raop=raop_init(&cb);if(!p->raop){fail(env,"Cannot initialize AirPlay core");return 0;}
    raop_set_log_callback(p->raop,log,nullptr);raop_set_log_level(p->raop,3);
    unsigned char hw[6];env->GetByteArrayRegion(identity,0,6,(jbyte*)hw);
    char id[18];snprintf(id,sizeof(id),"%02X:%02X:%02X:%02X:%02X:%02X",hw[0],hw[1],hw[2],hw[3],hw[4],hw[5]);
    const char *k=env->GetStringUTFChars(key,nullptr);int rc=raop_init2(p->raop,1,id,k);env->ReleaseStringUTFChars(key,k);
    if(rc){fail(env,"Cannot initialize private pairing key");return 0;}
    const char *n=env->GetStringUTFChars(name,nullptr);int error=0;
    p->dns=dnssd_init(n,strlen(n),(const char*)hw,6,&error,0);env->ReleaseStringUTFChars(name,n);
    if(!p->dns){fail(env,"Cannot create discovery records");return 0;}
    raop_set_dnssd(p->raop,p->dns);
    dnssd_set_airplay_features(p->dns,0,0); // HLS video
    dnssd_set_airplay_features(p->dns,4,0); // HTTP live streaming
    dnssd_set_airplay_features(p->dns,7,1); // screen mirroring MUST remain advertised
    dnssd_set_airplay_features(p->dns,42,0); // H.264-only sink
    raop_set_plist(p->raop,"width",1920);raop_set_plist(p->raop,"height",1080);raop_set_plist(p->raop,"maxFPS",60);
    unsigned short port=0;
    if(raop_start_httpd(p->raop,&port)<0 || !port){fail(env,"Cannot bind AirPlay receiver");return 0;}
    raop_set_port(p->raop,port);
    if(dnssd_register_raop(p->dns,port)||dnssd_register_airplay(p->dns,port)){fail(env,"Cannot create TXT records");return 0;}
    active=std::move(p);return port;
}
extern "C" JNIEXPORT jbyteArray JNICALL Java_io_github_boyan01_flutter_1airplay_PlaybackHost_txtNative(JNIEnv*env,jobject,jboolean raop) {
    std::lock_guard<std::mutex>guard(lifecycle);if(!active)return env->NewByteArray(0);
    int len=0;const char *s=raop?dnssd_get_raop_txt(active->dns,&len):dnssd_get_airplay_txt(active->dns,&len);
    auto a=env->NewByteArray(len);env->SetByteArrayRegion(a,0,len,(const jbyte*)s);return a;
}
extern "C" JNIEXPORT void JNICALL Java_io_github_boyan01_flutter_1airplay_PlaybackHost_stopNative(JNIEnv*,jobject){std::lock_guard<std::mutex>guard(lifecycle);active.reset();}
