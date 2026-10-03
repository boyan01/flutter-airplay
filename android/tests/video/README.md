# Android video regression

Run the pixel regression on one connected Android device using the configured
JDK and Gradle executable:

```sh
JAVA_HOME="/path/to/jdk" GRADLE_BIN="/path/to/gradle" ./android/scripts/test_video.sh
```

The script builds the current product `VideoPipeline` and `EglCore` in a small
instrumentation application. It installs that application and removes it after
the test. Confirm the device's USB installation prompt if required.

The fixture keeps the same output `Surface` while resizing its buffer from
64×128 to 128×64 and back. It sends solid red frames through the product's EGL
pipeline and reads back the output pixels. Each size must retain at least 99%
red coverage. This catches a viewport that still uses the previous buffer size.

Build output is stored under `build/android-video-tests/`. Logs and results are
stored under `artifacts/android/`. The test uses synthetic frames; it does not
validate AirPlay negotiation, MediaCodec decoding, Flutter layout, audio or
synchronization. Test real mirroring separately on the packaged application.
