# Android playback migration and historical acceptance

The former `android-player/` Flutter application has been retired. Its native
player, pinned dependency lock and license assets now live under `android/`.
The only product Flutter entry point is root `lib/main.dart`. Build commands,
shared bridge and current acceptance are in [ANDROID_UI.md](ANDROID_UI.md).
The JNI validation foundation remains under `android-prototype/`.

## Validation record

Build/installation/discovery observations must be recorded separately from
real sender playback. A built APK or registered NSD services alone do not prove
an iPhone connection, visible mirrored frames, audible sound, or A/V sync.
The earlier core harness and synthetic regression results belong to
`docs/ANDROID.md` and are not playback acceptance evidence for this app.

Completed on 2026-10-03: arm64 native library build; Flutter analyze with no
issues; Gradle release APK build and release lint-vital checks; APK signature
verification; successful installation and launch on a physical Xiaomi 14
(23127PN0CC, Android 16/API 36, arm64). The visible app reached ready after
both NSD registrations completed, showing **Flutter AirPlay Android** as its
receiver name. App-scoped runtime logs contained no crash at startup. This
is actual receiver startup/discovery observation, not an iPhone playback claim.
After the discovery correction below, the user confirmed actual iPhone
discovery/connection, visible mirrored image and audible sound. Synchronization,
rotation, reconnect and sustained-playback acceptance remain separate.

The APK contains only arm64 native libraries (receiver/player, Flutter app,
Flutter engine), nine bundled license files, and is 26,746,428 bytes.
SHA-256: `3eaccb6173e1f3aa856e33ac56dfd6414bde6476d6c3f6b30dae7c4d7465e87a`.

Discovery correction: the initial APK cleared feature bit 7 by mistake.
UxPlay's feature table defines bit 7 as screen mirroring; HLS uses bits 0/4.
Version 0.1.1+2 retains bit 7, disables HLS 0/4 and HEVC 42. The updated APK
was installed and restarted on the physical device. An independent LAN DNS-SD
lookup confirmed `features=0x5A7FFEE6,0x0` (initial incorrect value
`0x5A7FFE66,0x0`) and a reachable advertised TCP endpoint. The user subsequently confirmed: **已看到并连接，有画面和声音**. This
is real user acceptance of discovery, connection, image and sound on the
connected physical device, rather than a synthetic playback claim.

The historical results above belong to the former standalone APK. They do not
establish real sender playback acceptance for the new shared-UI APK.
