import java.time.Instant

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    buildFeatures { buildConfig = true }
    namespace = "tech.soit.flutterairplay"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = providers.gradleProperty("airplay.ndkVersion").get()

    sourceSets.getByName("main").java.srcDir("../../native/player/android")

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        buildConfigField("String", "BUILD_TIME", "\"${Instant.now()}\"")
        applicationId = "tech.soit.flutterairplay"
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

val prepareNativePlayer by tasks.registering(Exec::class) {
    workingDir(rootProject.projectDir.parentFile)
    environment("ANDROID_HOME", androidComponents.sdkComponents.sdkDirectory.get().asFile.absolutePath)
    commandLine(if (System.getProperty("os.name").startsWith("Windows")) "python" else "python3",
        "scripts/ensure_native.py", "android")
}

// Run before JNI merge tasks, including their input snapshots, in every variant.
tasks.named("preBuild") {
    dependsOn(prepareNativePlayer)
}
