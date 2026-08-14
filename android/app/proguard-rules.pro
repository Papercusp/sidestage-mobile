# SPDX-License-Identifier: MIT

# UniFFI and JNA resolve generated types and native symbols by name.
-keep class uniffi.** { *; }
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.Structure { *; }
-keep class * implements com.sun.jna.Library { *; }
-keep class * implements com.sun.jna.Callback { *; }
-dontwarn java.awt.**
-dontwarn com.sun.jna.platform.**

-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}
