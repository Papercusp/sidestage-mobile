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
        versionName = providers.gradleProperty("papercupReleaseVersion").getOrElse("0.1.0")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        manifestPlaceholders["usesCleartextTraffic"] = "false"

        buildConfigField(
            "String",
            "SIDESTAGE_API_BASE_URL",
            buildConfigString(
                providers.gradleProperty("sidestageApiBaseUrl").getOrElse("http://10.0.2.2:3100"),
            ),
        )
        // No media base URL: playback addresses are SERVER-computed
        // (EventSummary.playbackUrl, D-035) — the client derives nothing.
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

    // Reuse the organization-wide Android release identity. Key material stays
    // outside the repo; the producer refuses an unsigned output later.
    val releaseKeystorePath = providers.gradleProperty("PAPERCUP_RELEASE_KEYSTORE").orNull
        ?: System.getenv("PAPERCUP_RELEASE_KEYSTORE")
    val hasReleaseKeystore = releaseKeystorePath != null && file(releaseKeystorePath).exists()
    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = providers.gradleProperty("PAPERCUP_RELEASE_KEYSTORE_PASSWORD").orNull
                    ?: System.getenv("PAPERCUP_RELEASE_KEYSTORE_PASSWORD")
                keyAlias = providers.gradleProperty("PAPERCUP_RELEASE_KEY_ALIAS").orNull
                    ?: System.getenv("PAPERCUP_RELEASE_KEY_ALIAS") ?: "papercup"
                keyPassword = providers.gradleProperty("PAPERCUP_RELEASE_KEY_PASSWORD").orNull
                    ?: System.getenv("PAPERCUP_RELEASE_KEY_PASSWORD") ?: storePassword
            }
        }
    }

    lint {
        lintConfig = file("lint.xml")
        abortOnError = true
        warningsAsErrors = false
        checkAllWarnings = false
    }

    buildTypes {
        getByName("debug") {
            manifestPlaceholders["usesCleartextTraffic"] = "true"
        }
        getByName("release") {
            isMinifyEnabled = true
            signingConfigs.findByName("release")?.also { signingConfig = it }
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

val releaseSigningInputNames =
    listOf(
        "PAPERCUP_RELEASE_KEYSTORE",
        "PAPERCUP_RELEASE_KEYSTORE_PASSWORD",
        "PAPERCUP_RELEASE_KEY_ALIAS",
        "PAPERCUP_RELEASE_KEY_PASSWORD",
    )

val validateReleaseSigning by
    tasks.registering {
        group = "verification"
        description = "Fail unless every external Android release-signing input is configured."
        doLast {
            val values =
                releaseSigningInputNames.associateWith { name ->
                    providers.gradleProperty(name).orNull
                        ?: System.getenv(name)?.takeIf { it.isNotBlank() }
                }
            val missing = values.filterValues { it == null }.keys
            require(missing.isEmpty()) {
                "Android release signing preflight failed; missing external inputs: ${missing.joinToString(", ")}"
            }
            val keystore = file(values.getValue("PAPERCUP_RELEASE_KEYSTORE")!!)
            require(keystore.isFile) {
                "Android release signing preflight failed; keystore does not exist: $keystore"
            }
        }
    }

tasks.matching { it.name == "assembleRelease" || it.name == "bundleRelease" }.configureEach {
    dependsOn(validateReleaseSigning)
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

    // WHEP live playback (WI-39800): libwebrtc via Stream's maintained
    // distribution (org.webrtc upstream stopped publishing google-webrtc).
    // Signaling + reconnect policy live in sidestage-core (D-036); this is
    // only the engine and the SurfaceViewRenderer track attachment.
    implementation("io.getstream:stream-webrtc-android:1.3.10")

    testImplementation("junit:junit:4.13.2")

    androidTestImplementation(composeBom)
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")

    debugImplementation(composeBom)
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
