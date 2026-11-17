plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.hyeonslab.triage_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Published Android application ID. Must be a valid Java package (no
        // hyphens), so it differs from the Apple bundle id (com.hyeons-lab.*).
        applicationId = "com.hyeonslab.triage_client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Point the debug signing config at a committed keystore (see
        // app/debug.keystore) instead of the per-machine ~/.android/debug.keystore
        // Gradle would otherwise auto-generate. That gives every build — CI and
        // local — one stable signing identity, so a freshly built APK installs
        // over an earlier one instead of failing INSTALL_FAILED_UPDATE_INCOMPATIBLE.
        // These are the well-known Android debug credentials, not secrets.
        getByName("debug") {
            storeFile = file("debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        release {
            // Signed with the debug keystore so `flutter build apk --release` and
            // the CI artifact install without release-signing secrets. Swap in a
            // real release signingConfig before publishing to a store.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
