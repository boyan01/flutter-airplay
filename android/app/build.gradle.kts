import java.time.Instant

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release credentials exist only in the invoking process environment. In
// particular, a missing release key must never fall back to Android's debug key.
val releaseSigningNames = listOf(
    "AIRPLAY_ANDROID_KEYSTORE_PATH", "ANDROID_KEYSTORE_PASSWORD",
    "ANDROID_KEY_ALIAS", "ANDROID_KEY_PASSWORD",
)
val releaseSigning = releaseSigningNames.associateWith { System.getenv(it)?.takeIf { value -> value.isNotEmpty() } }
val hasReleaseSigning = releaseSigning.values.all { it != null }
require(releaseSigning.values.all { it == null } || hasReleaseSigning) {
    "Android release signing requires AIRPLAY_ANDROID_KEYSTORE_PATH, " +
        "ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS and ANDROID_KEY_PASSWORD together."
}

android {
    buildFeatures { buildConfig = true }
    namespace = "tech.soit.flutterairplay"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = providers.gradleProperty("airplay.ndkVersion").get()

    sourceSets.getByName("main").assets.srcDir(layout.buildDirectory.dir("generated/licenseAssets").get().asFile)
    sourceSets.getByName("main").java.srcDir("../../native/backends/android/java")

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

    if (hasReleaseSigning) {
        signingConfigs {
            create("release") {
                storeFile = file(releaseSigning.getValue("AIRPLAY_ANDROID_KEYSTORE_PATH")!!)
                storePassword = releaseSigning.getValue("ANDROID_KEYSTORE_PASSWORD")!!
                keyAlias = releaseSigning.getValue("ANDROID_KEY_ALIAS")!!
                keyPassword = releaseSigning.getValue("ANDROID_KEY_PASSWORD")!!
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            // Unsigned local release builds remain possible; the release
            // packaging script requires and verifies a real signing key.
            signingConfig = if (hasReleaseSigning) signingConfigs.getByName("release") else null
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
    implementation("androidx.core:core:1.17.0")
    testImplementation("junit:junit:4.13.2")
}

val copySharedLicenses by tasks.registering(Sync::class) {
    from(rootProject.projectDir.parentFile.resolve("assets/licenses"))
    into(layout.buildDirectory.dir("generated/licenseAssets/licenses"))
}

val prepareNativePlayer by tasks.registering(Exec::class) {
    workingDir(rootProject.projectDir.parentFile)
    environment("ANDROID_HOME", androidComponents.sdkComponents.sdkDirectory.get().asFile.absolutePath)
    commandLine(if (System.getProperty("os.name").startsWith("Windows")) "python" else "python3",
        "scripts/ensure_native.py", "android")
}

// Run before JNI merge tasks, including their input snapshots, in every variant.
tasks.named("preBuild") {
    dependsOn(prepareNativePlayer, copySharedLicenses)
}
