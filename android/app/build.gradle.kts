plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.boyan01.flutter_airplay"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.github.boyan01.flutter_airplay"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        ndk { abiFilters.clear(); abiFilters.add("arm64-v8a") }
        minSdk = 26
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

// A Flutter APK without the separately built JNI library would compile but
// crash at launch. Fail packaging with the exact recovery command instead.
tasks.configureEach {
    if (name in listOf("packageDebug", "packageProfile", "packageRelease")) {
        doFirst {
            check(file("src/main/jniLibs/arm64-v8a/libairplay_player.so").isFile) {
                "Missing Android receiver/player library. From repository root, run " +
                    "ANDROID_HOME=\$HOME/Library/Android/sdk ./android-prototype/scripts/build_native.sh arm64-v8a, " +
                    "python3 android/scripts/fetch_deps.py, then ./android/scripts/build_native.sh."
            }
        }
    }
}
