import java.util.Properties

plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties().apply {
    rootProject.file("key.properties").inputStream().use {
        load(it)
    }
}

android {
    namespace = "com.example.community_safe"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.community_safe"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties.getProperty("keyAlias")
                ?: error("Missing keyAlias in key.properties")

            keyPassword = keystoreProperties.getProperty("keyPassword")
                ?: error("Missing keyPassword in key.properties")

            storeFile = file(
                keystoreProperties.getProperty("storeFile")
                    ?: error("Missing storeFile in key.properties")
            )

            storePassword = keystoreProperties.getProperty("storePassword")
                ?: error("Missing storePassword in key.properties")
        }  
    }

        lint {
        checkReleaseBuilds = false
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
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
    implementation(platform("com.google.firebase:firebase-bom:34.19.0"))
    implementation("com.google.firebase:firebase-auth")
    implementation("com.google.firebase:firebase-firestore")
    implementation("androidx.work:work-runtime:2.11.2")
    implementation("com.google.android.gms:play-services-location:21.4.0")
}