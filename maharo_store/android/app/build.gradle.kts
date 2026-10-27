plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing — the PERMANENT keystore (see G:/Maharo/keys/README-CREDENTIALS.txt).
// Never distribute a debug-signed build again: every key change strands all
// installed apps (update blocked with "package conflicts with existing package").
val releaseKeystore = System.getenv("MAHARO_ANDROID_KEYSTORE")
val releaseKeyAlias = System.getenv("MAHARO_ANDROID_KEY_ALIAS")
val releaseStorePassword = System.getenv("MAHARO_ANDROID_STORE_PASSWORD")
val releaseKeyPassword = System.getenv("MAHARO_ANDROID_KEY_PASSWORD")
val hasReleaseSigning = listOf(releaseKeystore, releaseKeyAlias, releaseStorePassword, releaseKeyPassword)
    .all { !it.isNullOrBlank() }
// Explicit opt-in for local QA only: a debug-signed release build.
val allowDebugReleaseSigning =
    System.getenv("MAHARO_ALLOW_DEBUG_RELEASE_SIGNING")?.toBooleanStrictOrNull() == true
// SHA-256 fingerprints (comma-separated, colons allowed) of the certificates
// trusted to sign app.maharo — the same variable the main app uses for its
// own signer allowlist. The store refuses to install an APK signed by any
// other certificate, and refuses every install when this is empty.
val trustedAppCertSha256 = System.getenv("MAHARO_ANDROID_TRUSTED_CERT_SHA256")
    ?.split(',')
    ?.map { it.trim().replace(":", "").lowercase() }
    ?.filter { it.isNotEmpty() }
    .orEmpty()
val releaseRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}

if (trustedAppCertSha256.any { !it.matches(Regex("^[0-9a-f]{64}$")) }) {
    throw GradleException(
        "MAHARO_ANDROID_TRUSTED_CERT_SHA256 must contain one or more comma-separated " +
            "SHA-256 certificate fingerprints (64 hex characters each)."
    )
}
if (releaseRequested && !hasReleaseSigning && !allowDebugReleaseSigning) {
    throw GradleException(
        "Release signing is not configured. Set MAHARO_ANDROID_KEYSTORE, " +
            "MAHARO_ANDROID_KEY_ALIAS, MAHARO_ANDROID_STORE_PASSWORD and " +
            "MAHARO_ANDROID_KEY_PASSWORD. For a local QA build only, set " +
            "MAHARO_ALLOW_DEBUG_RELEASE_SIGNING=true."
    )
}
if (releaseRequested && !hasReleaseSigning && allowDebugReleaseSigning) {
    println("WARNING: MAHARO_ALLOW_DEBUG_RELEASE_SIGNING=true — DEBUG-signed release for local QA. Never distribute this artifact.")
}
if (releaseRequested && hasReleaseSigning && trustedAppCertSha256.isEmpty()) {
    throw GradleException(
        "A signed Store release requires MAHARO_ANDROID_TRUSTED_CERT_SHA256: the SHA-256 " +
            "fingerprint of the certificate that signs the app.maharo APKs this store installs."
    )
}

android {
    namespace = "app.maharo.maharo_store"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    buildFeatures {
        buildConfig = true
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseKeystore!!)
                keyAlias = releaseKeyAlias
                storePassword = releaseStorePassword
                keyPassword = releaseKeyPassword
            }
        }
    }

    defaultConfig {
        applicationId = "app.maharo.store"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
        buildConfigField(
            "String",
            "MAHARO_TRUSTED_APP_CERT_SHA256",
            "\"${trustedAppCertSha256.joinToString(",")}\"",
        )
    }

    buildTypes {
        release {
            // Without release signing a release build stops above, unless
            // MAHARO_ALLOW_DEBUG_RELEASE_SIGNING=true was set explicitly.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // R8 stays off: the JNI-based path_provider_android, sqflite and
            // permission_handler keep rules have not been verified with a
            // build and device run here (SK-STORE-05b).
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        if (!hasReleaseSigning) {
            logger.warn("Store release artifact is DEBUG-signed — local testing only.")
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
