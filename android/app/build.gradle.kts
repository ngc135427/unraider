plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

val androidReleaseAbis = listOf("armeabi-v7a", "arm64-v8a", "x86_64")

android {
    namespace = "com.ngc.unraider"
    compileSdk = flutter.compileSdkVersion
    // Match plugin requirements (jni); higher NDK is backward compatible.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.ngc.unraider"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters += androidReleaseAbis
        }
    }

    lint {
        checkReleaseBuilds = false
    }

    packaging {
        resources {
            excludes += "META-INF/versions/9/OSGI-INF/MANIFEST.MF"
        }
    }

    splits {
        abi {
            isEnable = true
            reset()
            include(*androidReleaseAbis.toTypedArray())
            isUniversalApk = true
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // SMBJ pulls optional javax.el / JGSS APIs that are absent on Android.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

android.applicationVariants.all {
    val variantName = name
    outputs.all {
        val output = this as com.android.build.gradle.internal.api.ApkVariantOutputImpl
        val abi = output.filters.firstOrNull()?.identifier
        val abiSuffix = abi?.let { "-$it" } ?: ""
        output.outputFileName = "unraider$abiSuffix-$variantName.apk"
    }
}

val renameFlutterApks = tasks.register("renameFlutterApks") {
    doLast {
        val flutterApkDirectory = layout.buildDirectory
            .dir("outputs/flutter-apk")
            .get()
            .asFile
        flutterApkDirectory.listFiles { file ->
            file.isFile && file.name.startsWith("app") && file.name.endsWith(".apk")
        }?.forEach { source ->
            val targetName = source.name.replaceFirst(Regex("^app"), "unraider")
            source.copyTo(flutterApkDirectory.resolve(targetName), overwrite = true)
        }
    }
}

tasks.configureEach {
    if (name.startsWith("assemble")) {
        finalizedBy(renameFlutterApks)
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
    implementation("com.hierynomus:smbj:0.14.0")
    implementation("androidx.work:work-runtime:2.11.2")
    implementation("com.google.guava:guava:33.4.8-android")
}
