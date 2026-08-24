import java.io.File

// SPDX-License-Identifier: MIT
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

// Android Gradle Plugin only consults environment variables and
// local.properties when locating the SDK.  Keep direct Gradle invocations
// usable on a developer machine whose shell does not export either variable,
// while preserving an explicitly configured SDK (including an invalid one so
// that its diagnostic is not silently masked).
val configuredAndroidSdk =
    sequenceOf(
        System.getenv("ANDROID_SDK_ROOT"),
        System.getenv("ANDROID_HOME"),
    ).firstOrNull { !it.isNullOrBlank() }

val discoveredAndroidSdk =
    configuredAndroidSdk?.let(::File)?.takeIf(File::isDirectory)
        ?: if (configuredAndroidSdk == null) {
            val home = System.getProperty("user.home")
            sequenceOf(
                home?.let { File(it, "Android/Sdk") },
                home?.let { File(it, "Library/Android/sdk") },
                System.getenv("LOCALAPPDATA")?.let { File(it, "Android/Sdk") },
                File("/opt/android-sdk"),
                File("/usr/lib/android-sdk"),
            ).filterNotNull().firstOrNull(File::isDirectory)
        } else {
            null
        }

if (discoveredAndroidSdk != null && System.getProperty("android.home").isNullOrBlank()) {
    // AGP's injected SDK source reads the android.home system property. This
    // avoids generating a machine-specific local.properties file.
    System.setProperty("android.home", discoveredAndroidSdk.absolutePath)
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "SideStage"
include(":app")
