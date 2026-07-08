plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.example.synctune"
    compileSdk = 34

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    kotlinOptions {
        jvmTarget = "1.8"
    }
}

dependencies {
    implementation(project(":core"))
    implementation("androidx.core:core-ktx:1.9.0")
    implementation("androidx.documentfile:documentfile:1.0.1")
    implementation("net.jthink:jaudiotagger:3.0.1")
    implementation("androidx.annotation:annotation:1.6.0")
}
