plugins {
    id("com.android.application")
    // Kotlin code for running Mihon extensions (android/app/src/main/kotlin).
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.readlist.panel"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Needed by flutter_local_notifications.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.readlist.panel"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // Extensions call into classes Panel itself never uses (the
            // extension API, OkHttp, Jsoup, RxJava...). Without these rules R8
            // would strip or rename them and every extension would crash.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    packaging {
        resources {
            // Same license/metadata files shipped by several of the libraries below.
            excludes += setOf(
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE",
                "META-INF/LICENSE.txt",
                "META-INF/LICENSE.md",
                "META-INF/NOTICE",
                "META-INF/NOTICE.txt",
                "META-INF/NOTICE.md",
                "META-INF/README.md",
                "META-INF/versions/9/OSGI-INF/MANIFEST.MF",
                "kotlin-tooling-metadata.json",
            )
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
    // AppCompat themes in res/values*/styles.xml.
    implementation("androidx.appcompat:appcompat:1.7.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // ---- Runtime for Mihon / Tachiyomi extensions ----
    // Extensions are compiled against stubs and expect the host app to provide
    // these libraries (same artifacts and versions Mihon ships).
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.13.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json-okio:1.13.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-protobuf:1.13.0")
    implementation("com.squareup.okhttp3:okhttp:5.5.1")
    implementation("com.squareup.okhttp3:okhttp-brotli:5.5.1")
    implementation("com.squareup.okio:okio:3.18.2")
    implementation("org.jsoup:jsoup:1.24.1")
    implementation("io.reactivex:rxjava:1.3.8")
    implementation("uy.kohesive.injekt:injekt-core:1.16.1")
    implementation("androidx.preference:preference-ktx:1.2.1")
}

// After `flutter build apk --release`, also save the APK as
// build/app/outputs/flutter-apk/Panel-<version>.apk (version from pubspec.yaml),
// ready to attach to a GitHub release without renaming.
val copyPanelApk = tasks.register<Copy>("copyPanelApk") {
    from(layout.buildDirectory.file("outputs/apk/release/app-release.apk"))
    into(layout.buildDirectory.dir("outputs/flutter-apk"))
    rename { "Panel-${flutter.versionName}.apk" }
}
tasks.matching { it.name == "assembleRelease" }.configureEach {
    finalizedBy(copyPanelApk)
}
