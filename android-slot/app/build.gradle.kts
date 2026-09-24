plugins {
    id("com.android.application")
}

android {
    namespace = "com.example.slotgame"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.example.slotgame"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // The game itself lives in ../slot-game (index.html + images/),
    // so the web version and the app always share the same code.
    sourceSets {
        getByName("main") {
            assets.srcDirs("../../slot-game")
        }
    }
}
