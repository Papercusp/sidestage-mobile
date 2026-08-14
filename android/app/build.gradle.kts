// SPDX-License-Identifier: MIT
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

fun buildConfigString(value: String): String = "\"${value.replace("\\", "\\\\").replace("\"", "\\\"")}\""

val generateUniFfiKotlin by
    tasks.registering(Exec::class) {
        val repositoryRoot =
            rootProject.layout.projectDirectory
                .dir("..")
                .asFile
        workingDir(repositoryRoot)
        commandLine("make", "bindings-kotlin")
        inputs.file(repositoryRoot.resolve("crates/sidestage-bindings/src/sidestage.udl"))
        inputs.file(repositoryRoot.resolve("crates/sidestage-bindings/uniffi.toml"))
        inputs.file(repositoryRoot.resolve("Cargo.lock"))
        outputs.file(repositoryRoot.resolve("android/app/src/main/kotlin/uniffi/sidestage/sidestage.kt"))
    }

android {
    namespace = "com.sidestage.mobile"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.sidestage.mobile"
        minSdk = 33
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        buildConfigField(
            "String",
            "SIDESTAGE_API_BASE_URL",
            buildConfigString(
                providers.gradleProperty("sidestageApiBaseUrl").getOrElse("http://10.0.2.2:3100"),
            ),
        )
        buildConfigField(
            "String",
            "SIDESTAGE_MEDIA_BASE_URL",
            buildConfigString(
                providers.gradleProperty("sidestageMediaBaseUrl").getOrElse("http://10.0.2.2:8888"),
            ),
        )
        buildConfigField(
            "String",
            "SIDESTAGE_BUYER_ID",
            buildConfigString(
                providers.gradleProperty("sidestageBuyerId").getOrElse("buyer-ff39f82b"),
            ),
        )

        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
        }
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

tasks.named("preBuild").configure {
    dependsOn(generateUniFfiKotlin)
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.10.01")

    implementation(composeBom)
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.core:core-ktx:1.15.0")

    // UniFFI's generated Kotlin bindings load libsidestage through JNA.
    implementation("net.java.dev.jna:jna:5.19.1@aar")

    testImplementation("junit:junit:4.13.2")

    androidTestImplementation(composeBom)
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")

    debugImplementation(composeBom)
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
