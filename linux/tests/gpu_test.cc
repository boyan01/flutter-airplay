// SPDX-License-Identifier: GPL-3.0-only
#include "../../native/include/airplay/linux_video.h"
#include "../../native/backends/ffmpeg/ffmpeg_colors.h"
#include "../../native/playback/platform.h"
#include "../../native/tests/fixtures/video_fixtures.h"
#include "../../native/tests/fixtures/hevc_fixtures.h"
#include <gtk/gtk.h>
#include <epoxy/gl.h>
#include <epoxy/egl.h>
#include <gdk/gdkx.h>
#include <algorithm>
#include <cstdio>
#include <stdexcept>
#include <vector>
#include <thread>
extern "C" {
#include <libavutil/hwcontext.h>
}
static void check(bool condition, const char *message) { if (!condition) throw std::runtime_error(message); }
static void *retain(void *value) { return av_frame_clone(static_cast<AVFrame *>(value)); }
static void release(void *value) { auto *frame = static_cast<AVFrame *>(value); av_frame_free(&frame); }
static void read_texture(uint32_t texture,int width,int height,uint8_t *pixels) {
    GLint previous=0;glGetIntegerv(GL_FRAMEBUFFER_BINDING,&previous);
    GLuint framebuffer=0;glGenFramebuffers(1,&framebuffer);glBindFramebuffer(GL_FRAMEBUFFER,framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0);
    check(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE,"readback framebuffer complete");
    glPixelStorei(GL_PACK_ALIGNMENT,1);glReadPixels(0,0,width,height,GL_RGBA,GL_UNSIGNED_BYTE,pixels);
    glBindFramebuffer(GL_FRAMEBUFFER,previous);glDeleteFramebuffers(1,&framebuffer);
}
static void compare(airplay::LinuxGpuRenderer &renderer, AVFrame &frame) {
    airplay::FFmpegColors cpu;
    check(cpu.convert(frame) == 0, "CPU reference conversion");
    AirplayLinuxVideoFrame descriptor{nullptr, 0, frame.width, frame.height, &frame, retain, release};
    std::string error; uint32_t texture = 0;
    // Exercise state restoration with non-default raster state and bindings.
    glActiveTexture(GL_TEXTURE2); glViewport(3,4,17,19); glEnable(GL_SCISSOR_TEST);
    glPixelStorei(GL_UNPACK_ALIGNMENT,8); glColorMask(GL_FALSE,GL_TRUE,GL_FALSE,GL_TRUE);
    check(renderer.render(descriptor,texture,error), error.c_str());
    GLint active = 0, viewport[4], alignment = 0; GLboolean mask[4];
    glGetIntegerv(GL_ACTIVE_TEXTURE,&active); glGetIntegerv(GL_VIEWPORT,viewport);
    glGetIntegerv(GL_UNPACK_ALIGNMENT,&alignment); glGetBooleanv(GL_COLOR_WRITEMASK,mask);
    check(active==GL_TEXTURE2 && viewport[0]==3 && viewport[3]==19 && alignment==8 && glIsEnabled(GL_SCISSOR_TEST) && !mask[0] && mask[1], "restore Flutter GL state");
    std::vector<uint8_t> result(size_t(frame.width)*frame.height*4);
    glBindTexture(GL_TEXTURE_2D,texture); glPixelStorei(GL_PACK_ALIGNMENT,1);
    read_texture(texture,frame.width,frame.height,result.data());
    for (int y : {0, frame.height/2, frame.height-1}) for (int x : {0, frame.width/2, frame.width-1}) {
        const auto *expected=cpu.rgba()->data[0]+y*cpu.rgba()->linesize[0]+x*4;
        const auto *actual=result.data()+(size_t(y)*frame.width+x)*4;
        for (int c=0;c<4;++c) {
            if (std::abs(int(expected[c])-int(actual[c]))>4) {
                std::fprintf(stderr,"pixel mismatch format=%d space=%d range=%d (%d,%d) channel=%d expected=%d actual=%d\n",frame.format,frame.colorspace,frame.color_range,x,y,c,expected[c],actual[c]);
                check(false,"GPU pixel matches CPU color/range/bit-depth reference");
            }
        }
    }
    check(glGetError()==GL_NO_ERROR,"no GL errors");
}
static void colors_test() {
    airplay::LinuxGpuRenderer renderer;
    for (auto format : {AV_PIX_FMT_YUV420P,AV_PIX_FMT_YUV420P10LE,AV_PIX_FMT_NV12,AV_PIX_FMT_P010LE})
    for (auto space : {AVCOL_SPC_BT709,AVCOL_SPC_SMPTE170M,AVCOL_SPC_BT2020_NCL})
    for (auto range : {AVCOL_RANGE_MPEG,AVCOL_RANGE_JPEG}) {
        AVFrame *frame=av_frame_alloc(); frame->format=format; frame->width=32; frame->height=16;
        frame->colorspace=space; frame->color_range=range;
        check(av_frame_get_buffer(frame,32)==0,"allocate YUV test frame");
        const bool ten=format==AV_PIX_FMT_P010LE || format==AV_PIX_FMT_YUV420P10LE;
        const bool nv=format==AV_PIX_FMT_NV12 || format==AV_PIX_FMT_P010LE;
        for (int i=0;i<(nv?2:3);++i) for(int y=0;y<(i?8:16);++y) for(int x=0;x<(i?16:32)*(i&&nv?2:1);++x) {
            const int component=i&&nv ? (x%2?2:1) : i;
            const int sample=component==0 ? (y<8?81:145) : component==1 ? 90 : 180;
            if (ten) reinterpret_cast<uint16_t *>(frame->data[i]+y*frame->linesize[i])[x]=sample*4*(format==AV_PIX_FMT_P010LE?64:1);
            else frame->data[i][y*frame->linesize[i]+x]=sample;
        }
        compare(renderer,*frame);
        // Reuse the same plane layout across unsupported/supported color metadata.
        frame->colorspace=AVCOL_SPC_SMPTE240M;compare(renderer,*frame);
        frame->colorspace=space;compare(renderer,*frame);
        av_frame_free(&frame);
    }
    // Packed RGB exercises fallback and resolution/layout changes.
    AVFrame *rgb=av_frame_alloc(); rgb->format=AV_PIX_FMT_RGBA; rgb->width=4; rgb->height=6;
    check(av_frame_get_buffer(rgb,32)==0,"allocate fallback RGB");
    for(int y=0;y<6;++y) for(int x=0;x<4;++x) { auto*p=rgb->data[0]+y*rgb->linesize[0]+x*4; p[0]=y*30;p[1]=x*40;p[2]=70;p[3]=255; }
    compare(renderer,*rgb); av_frame_free(&rgb);
    std::puts("PASS: GPU YUV color/range/10-bit pixels, RGBA fallback, orientation and GL state restoration");
}
static void hardware_test(bool download) {
    airplay::LinuxGpuRenderer renderer(!download);
    int frames=0; std::string path;
    airplay::TimingSamples output_cost;
    AirplayLinuxVideoOptions options{};
    auto video=airplay::make_video_output(&options,nullptr,nullptr,{
        [&](void *value,int,int,int64_t,uint64_t) {
            const auto &frame=*static_cast<AirplayLinuxVideoFrame *>(value);
            check(frame.native_frame && frame.retain && frame.release,"retained native decoder output");
            auto *owned=static_cast<AVFrame *>(frame.retain(frame.native_frame));
            check(owned,"retain decoded hardware frame");
            AirplayLinuxVideoFrame lease=frame; lease.native_frame=owned;
            uint32_t texture=0; std::string error;
            const auto start=airplay::monotonic_ns();
            check(renderer.render(lease,texture,error),error.c_str());
            if(frames>=5) output_cost.add(airplay::monotonic_ns()-start);
            path=renderer.path();
            if (frames < 5) {
                glBindTexture(GL_TEXTURE_2D,texture);
                std::vector<uint8_t> pixels(size_t(frame.width)*frame.height*4);
                glPixelStorei(GL_PACK_ALIGNMENT,1); read_texture(texture,frame.width,frame.height,pixels.data());
                const int channel=frames==0 || frames==3 ? 0 : frames==4 ? 1 : 2;
                const auto *pixel=pixels.data()+(size_t(frame.height/2)*frame.width+frame.width/2)*4;
                check(pixel[channel]>200 && pixel[(channel+1)%3]<45 && pixel[(channel+2)%3]<45 && pixel[3]==255,"hardware GPU pixels");
            }
            frame.release(owned); ++frames;
        },[](const char *message){std::puts(message);}});
    auto feed=[&](const uint8_t *bytes,size_t size,bool hevc) {
        const auto before=frames;
        check(video->decode({{bytes,bytes+size},airplay::monotonic_ns()+airplay::kSecond,9,0,hevc}),"hardware decode fixture");
        const auto limit=airplay::monotonic_ns()+3*airplay::kSecond;
        while(frames==before && airplay::monotonic_ns()<limit) { video->drain(); std::this_thread::sleep_for(std::chrono::milliseconds(1)); }
        check(frames==before+1,"hardware publishes one frame");
        check(std::string(video->decoder_name())=="FFmpeg NVDEC","actual NVDEC decoder activation");
        check(path.find(download ? "YUV download" : "no CPU download")!=std::string::npos,
              "requested GPU interop/download path is active");
        std::puts(path.c_str());
    };
    feed(hevc_fixtures::landscape,sizeof(hevc_fixtures::landscape),true);
    feed(hevc_fixtures::portrait,sizeof(hevc_fixtures::portrait),true);
    feed(hevc_fixtures::uhd,sizeof(hevc_fixtures::uhd),true);
    video->reset();
    feed(landscape,sizeof(landscape),false);
    feed(hevc_fixtures::main10,sizeof(hevc_fixtures::main10),true);
    video->reset();
    // Warm up the 4K decoder before a paced 60 FPS run; initialization is separate
    // from steady-state throughput. No screen-present claims are made here.
    feed(hevc_fixtures::uhd,sizeof(hevc_fixtures::uhd),true);
    const auto baseline=video->stats(); const auto before=frames; output_cost={};
    const auto anchor=airplay::monotonic_ns()+100000000;
    constexpr int count=120; const auto tick=airplay::kSecond/60;
    for(int i=0;i<count;++i) {
        const auto due=anchor+i*tick;
        check(video->decode({{hevc_fixtures::uhd,hevc_fixtures::uhd+sizeof(hevc_fixtures::uhd)},due,9,0,true}),"paced 4K NVDEC input");
        const auto next=anchor+(i+1)*tick-100000000;
        do { video->drain(); if(airplay::monotonic_ns()>=next) break; std::this_thread::sleep_for(std::chrono::milliseconds(1)); } while(true);
    }
    const auto until=airplay::monotonic_ns()+airplay::kSecond;
    while(frames<before+count && airplay::monotonic_ns()<until) {video->drain();std::this_thread::sleep_for(std::chrono::milliseconds(1));}
    const auto stats=video->stats();
    check(frames==before+count && stats.dropped==baseline.dropped,"sustained 4K60 delivers every scheduled frame");
    std::printf("4K60 frames=%d scheduler_drops=%llu %s\n",count,
        static_cast<unsigned long long>(stats.dropped-baseline.dropped),output_cost.text("gpu_output").c_str());
    video->reset(); video->drain();
    std::puts("PASS: NVDEC H.264/HEVC/4K/Main10, GPU interop pixels, codec switch and reset");
}
int main(int argc,char **argv) {
    try {
        check(gtk_init_check(&argc,&argv),"GTK display available");
        auto *window=gtk_window_new(GTK_WINDOW_TOPLEVEL); gtk_widget_realize(window);
        GError *error=nullptr;
        auto *context=gdk_window_create_gl_context(gtk_widget_get_window(window),&error);
        check(context,"create GL context"); gdk_gl_context_set_required_version(context,3,2);
        check(gdk_gl_context_realize(context,&error),"realize desktop GL context"); gdk_gl_context_make_current(context);
        std::printf("GL renderer: %s\n",glGetString(GL_RENDERER));
        const bool egl_test=argc>1 && std::string(argv[1])=="--hardware-egl";
        EGLDisplay egl_display=EGL_NO_DISPLAY;EGLContext egl_context=EGL_NO_CONTEXT;
        if(egl_test) {
            gdk_gl_context_clear_current();
            egl_display=eglGetPlatformDisplayEXT(EGL_PLATFORM_X11_EXT,gdk_x11_display_get_xdisplay(gdk_display_get_default()),nullptr);
            check(eglInitialize(egl_display,nullptr,nullptr),"initialize EGL");eglBindAPI(EGL_OPENGL_ES_API);
            const EGLint attributes[]{EGL_RENDERABLE_TYPE,EGL_OPENGL_ES2_BIT,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
            EGLConfig config=nullptr;EGLint count=0;check(eglChooseConfig(egl_display,attributes,&config,1,&count)&&count>0,"EGL config");
            const EGLint context_attributes[]{EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
            egl_context=eglCreateContext(egl_display,config,EGL_NO_CONTEXT,context_attributes);
            check(eglMakeCurrent(egl_display,EGL_NO_SURFACE,EGL_NO_SURFACE,egl_context),"EGL current");
            std::printf("EGL client: %s\n",glGetString(GL_VERSION));
        }
        colors_test(); if(argc>1) hardware_test(std::string(argv[1])=="--hardware-download");
        if(egl_test) {eglMakeCurrent(egl_display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);eglDestroyContext(egl_display,egl_context);eglTerminate(egl_display);}
        gdk_gl_context_clear_current(); g_object_unref(context); gtk_widget_destroy(window);
    } catch(const std::exception &error) { std::fprintf(stderr,"FAIL: %s\n",error.what());return 1; }
}
