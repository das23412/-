import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名配置：仓库根目录存在 key.properties（由 GitHub Actions secrets 注入，
// 或本地开发者手工放置）时用发布签名。密钥库不在仓库里，绝不提交。
// 本地日常调试用 flutter run 即可（debug 构建自动使用本机 debug 密钥）。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.moyue.reader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                // 密钥库为 PKCS12 格式（2026-09 密钥轮换后生成）
                storeType = "pkcs12"
            }
        }
    }

    defaultConfig {
        applicationId = "com.moyue.reader"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            if (!keystorePropertiesFile.exists()) {
                // 拒绝用随机/公共签名出正式包：装上去的包要么无法覆盖安装，
                // 要么任何人都能伪造同签名更新
                throw GradleException(
                    "缺少 android/key.properties：正式构建必须配置发布签名" +
                        "（GitHub Secrets 注入或本地手工放置，见 docs/发布检查清单.md）"
                )
            }
            signingConfig = signingConfigs.getByName("release")
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
    // FileProvider（应用内更新安装 APK 用）
    implementation("androidx.core:core:1.13.1")
}
