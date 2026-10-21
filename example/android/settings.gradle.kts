pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")

// Build the OpenVPN engine from the openvpn_library submodule when it is
// checked out (git submodule update --init) instead of the JitPack artifact
// pinned by the plugin. Pass -Popenvpn.useJitpack=true to test that artifact.
val openvpnLibrary = file("../../openvpn_library/vpnLib")
val useJitpack = providers.gradleProperty("openvpn.useJitpack").map { it.toBoolean() }.getOrElse(false)
if (openvpnLibrary.exists() && !useJitpack) {
    include(":openvpn_library")
    project(":openvpn_library").projectDir = openvpnLibrary
}
