# Android receiver restart regression

This test runs the real Flutter model, Android foreground service, JNI receiver
and DNS-SD registration on an authorized arm64 Android device. It performs three
renames and three immediate stop/start cycles. Each cycle must return to
`waiting` with a live receiver and texture. Cleanup restores the original name
and auto-start preference, then leaves reception stopped.

Build the native library first as described in the root `AGENTS.md`. Use the
Flutter version pinned in `.fvmrc`. The application should have auto-start
enabled for this test.

Build the test entry point and replace the installed application while retaining
its data and permissions:

```sh
fvm flutter pub get
fvm flutter build apk --debug --target-platform android-arm64 \
  --target integration_test/android_receiver_restart_test.dart
adb install -r -t build/app/outputs/flutter-apk/app-debug.apk
adb shell am force-stop tech.soit.flutterairplay
adb shell am start -n tech.soit.flutterairplay/.MainActivity
```

Connect the host driver to the running app's Dart VM service. Forward the device
VM service port with `adb forward`, keeping the authentication path from the
service URI. Pass the resulting local URL:

```sh
fvm flutter drive --driver=test_driver/integration_test.dart \
  --use-existing-app="$RECEIVER_VM_SERVICE_URL"
```

Always install with `adb install -r` and attach with `--use-existing-app`.
The default `flutter drive` flow uninstalls its application during cleanup and
can also fall back to uninstalling it after an installation failure.

After testing, build the normal Release entry point and replace the test APK
with `adb install -r`. These checks establish receiver lifecycle and registration
behavior; they do not validate iPhone video, audible sound or synchronization.
