import com.android.build.api.dsl.ApplicationExtension
import com.android.build.api.variant.ApplicationAndroidComponentsExtension
import com.android.build.api.variant.FilterConfiguration
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val localProperties = Properties().apply {
    val localPropertiesFile = rootProject.file("local.properties")
    if (localPropertiesFile.exists()) {
        localPropertiesFile.inputStream().use { load(it) }
    }
}

fun xclientEnv(name: String): String? = System.getenv(name)?.takeIf { it.isNotBlank() }

val xclientKeystore: File? = xclientEnv("XCLIENT_KEYSTORE_B64")?.let { encoded ->
    layout.buildDirectory.file("xclient/release.jks").get().asFile.apply {
        parentFile.mkdirs()
        writeBytes(Base64.getMimeDecoder().decode(encoded))
    }
}
val releaseStoreFile = xclientKeystore ?: file("keystore.jks")
val releaseStorePassword =
    xclientEnv("XCLIENT_KEYSTORE_PASSWORD") ?: localProperties.getProperty("storePassword")
val releaseKeyAlias = xclientEnv("XCLIENT_KEY_ALIAS") ?: localProperties.getProperty("keyAlias")
val releaseKeyPassword =
    xclientEnv("XCLIENT_KEY_PASSWORD") ?: localProperties.getProperty("keyPassword")
val hasReleaseSigning = releaseStoreFile.exists() &&
    releaseStorePassword != null &&
    releaseKeyAlias != null &&
    releaseKeyPassword != null
if (!hasReleaseSigning && xclientEnv("XCLIENT_REQUIRE_RELEASE_SIGNING") == "true") {
    throw GradleException(
        "XCLIENT_REQUIRE_RELEASE_SIGNING is set but the release keystore is incomplete",
    )
}
val xclientBrand = xclientEnv("XCLIENT_BRAND")

extensions.configure<ApplicationExtension> {
    namespace = "com.follow.clash"
    compileSdk = libs.versions.compileSdk.get().toInt()
    ndkVersion = libs.versions.ndkVersion.get()

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.follow.clash"
        minSdk = flutter.minSdkVersion
        targetSdk = libs.versions.targetSdk.get().toInt()
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = releaseStoreFile
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
            applicationIdSuffix = ".dev"
        }

        release {
            isMinifyEnabled = true
            isShrinkResources = true
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                signingConfig = signingConfigs.getByName("debug")
                applicationIdSuffix = ".dev"
            }

            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    // Unit tests live under android/tests/ instead of each module's src/test.
    sourceSets.getByName("test").java.directories.apply {
        clear()
        add("../tests/app")
    }
}

if (xclientBrand != null) {
    extensions.configure<ApplicationAndroidComponentsExtension> {
        onVariants { variant ->
            variant.outputs.forEach { output ->
                val abi = output.filters.find { it.filterType == FilterConfiguration.FilterType.ABI }
                    ?.identifier ?: "universal"
                val suffix = if (variant.buildType == "release") "" else "-${variant.buildType}"
                output.outputFileName.set(output.versionName.map { version ->
                    "$xclientBrand-android-$abi-v$version$suffix.apk"
                })
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(project(":service"))
    implementation(project(":common"))
    implementation(project(":core"))
    implementation(libs.core.splashscreen)
    implementation(libs.gson)
    implementation(libs.smali.dexlib2) {
        exclude(group = "com.google.guava", module = "guava")
    }
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
