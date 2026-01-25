plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.furry.player"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.furry.player"
        minSdk = 23
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    sourceSets {
        getByName("main") {
            // 复用已有 Kotlin JNI 接口定义
            java.srcDir(file("${rootProject.projectDir}/../furry_android/kotlin"))
            // 直接打包由 build.sh 产出的 JNI 动态库
            jniLibs.srcDir(file("${rootProject.projectDir}/../../dist/android"))
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    // 最小工程：不引入 AndroidX
}
