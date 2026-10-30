import java.time.Instant
import java.util.Properties

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

val ndkVersionName = providers.gradleProperty("airplay.ndkVersion").get()
val flutterSdk = Properties().apply {
    rootProject.file("local.properties").reader().use { load(it) }
}.getProperty("flutter.sdk")

android {
    // prefab: the lychee_player plugin's AAR publishes the core the player links.
    buildFeatures { buildConfig = true; prefab = true }
    namespace = "tech.soit.flutterairplay"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = ndkVersionName

    sourceSets.getByName("main").assets.srcDir(layout.buildDirectory.dir("generated/sharedAssets").get().asFile)

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
        externalNativeBuild {
            cmake {
                arguments(
                    "-DANDROID_STL=c++_shared",
                    "-DFLUTTER_ROOT=$flutterSdk",
                )
                targets("airplay_player")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
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
    // The core the lychee_player plugin depends on, for prefab; its version is
    // the plugin's (the compile classpath follows the runtime one below).
    implementation("io.github.boyan01.lychee:lychee")
    implementation("androidx.core:core:1.17.0")
    testImplementation("junit:junit:4.13.2")
}

androidComponents.onVariants { variant ->
    configurations.named("${variant.name}CompileClasspath") {
        shouldResolveConsistentlyWith(configurations.getByName("${variant.name}RuntimeClasspath"))
    }
}

val copySharedAssets by tasks.registering(Sync::class) {
    from(rootProject.projectDir.parentFile.resolve("assets/licenses")) {
        into("licenses")
    }
    from(layout.projectDirectory.file("src/main/res/drawable-xhdpi/tv_banner.png"))
    into(layout.buildDirectory.dir("generated/sharedAssets"))
}

tasks.named("preBuild") {
    dependsOn(copySharedAssets)
}
