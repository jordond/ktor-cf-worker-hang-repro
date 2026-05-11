plugins {
    kotlin("multiplatform") version "2.3.21"
}

kotlin {
    js(IR) {
        binaries.executable()
        useEsModules()
        nodejs {
            // Cloudflare Workers target. index.mjs imports the compiled mjs.
        }
    }

    sourceSets {
        val jsMain by getting {
            dependencies {
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
                implementation("io.ktor:ktor-client-core:3.4.3")
                implementation("io.ktor:ktor-client-js:3.4.3")
            }
        }
    }
}
