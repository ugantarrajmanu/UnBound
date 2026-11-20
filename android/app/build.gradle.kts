import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "app.unbound.client"
    compileSdk = 36

    defaultConfig {
        applicationId = "app.unbound.client"
        minSdk = 26
        targetSdk = 36
        versionCode = 2
        versionName = "1.0.1"
    }

    // Release signing comes from the environment (see scripts/package.sh); never commit keys.
    val keystorePath = System.getenv("UNBOUND_KEYSTORE")
    signingConfigs {
        if (keystorePath != null) {
            create("release") {
                storeFile = file(keystorePath)
                storePassword = System.getenv("UNBOUND_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("UNBOUND_KEY_ALIAS") ?: "unbound"
                keyPassword = System.getenv("UNBOUND_KEY_PASSWORD") ?: System.getenv("UNBOUND_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
            if (keystorePath != null) signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-ktx:1.9.3")
    testImplementation("junit:junit:4.13.2")
}
