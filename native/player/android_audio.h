// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "platform.h"
#include <jni.h>
namespace airplay {
// Initialize on a Java caller thread so FindClass uses the application's loader.
bool initialize_android_audio(JNIEnv *);
std::unique_ptr<AudioOutput> make_android_audio_output(std::shared_ptr<AudioBuffer>, int mode,
    std::function<void(const char *)> log = {});
// Fixture-only access; never exposed through product settings.
// fail_open injects AAudio initialization failure. For AudioTrack, error=0
// limits write chunks; ErrorInternal injects a writer failure.
void android_audio_test_failure(AudioOutput &, int error, bool fail_open = false);
}
