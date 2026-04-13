allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

fun ensureAndroidNamespace(project: org.gradle.api.Project) {
    val androidExt = project.extensions.findByName("android") ?: return

    val namespaceGetter = androidExt.javaClass.methods.firstOrNull {
        it.name == "getNamespace" && it.parameterCount == 0
    }
    val currentNamespace = namespaceGetter?.invoke(androidExt) as? String
    if (!currentNamespace.isNullOrBlank()) {
        return
    }

    val manifestFile = project.file("src/main/AndroidManifest.xml")
    val manifestPackage = if (manifestFile.exists()) {
        val match = Regex("package\\s*=\\s*\"([^\"]+)\"")
            .find(manifestFile.readText())
        match?.groupValues?.getOrNull(1)
    } else {
        null
    }

    val fallbackNamespace = manifestPackage
        ?: "autogen.${project.name.replace('-', '_')}"

    val namespaceSetter = androidExt.javaClass.methods.firstOrNull {
        it.name == "setNamespace" && it.parameterCount == 1
    }
    namespaceSetter?.invoke(androidExt, fallbackNamespace)
}

fun alignAndroidCompileOptions(project: org.gradle.api.Project) {
    val androidExt = project.extensions.findByName("android") ?: return
    val compileOptions = androidExt.javaClass.methods
        .firstOrNull { it.name == "getCompileOptions" && it.parameterCount == 0 }
        ?.invoke(androidExt)
        ?: return

    val setSourceCompatibility = compileOptions.javaClass.methods.firstOrNull {
        it.name == "setSourceCompatibility" && it.parameterCount == 1
    }
    val setTargetCompatibility = compileOptions.javaClass.methods.firstOrNull {
        it.name == "setTargetCompatibility" && it.parameterCount == 1
    }

    setSourceCompatibility?.invoke(compileOptions, JavaVersion.VERSION_17)
    setTargetCompatibility?.invoke(compileOptions, JavaVersion.VERSION_17)
}

fun sanitizeLegacyLibraryManifest(project: org.gradle.api.Project) {
    val manifestFile = project.file("src/main/AndroidManifest.xml")
    if (!manifestFile.exists()) return

    val original = manifestFile.readText()
    if (!original.contains("<manifest")) return

    val manifestTagMatch = Regex("<manifest\\b[^>]*>").find(original)
    if (manifestTagMatch == null) return

    val cleanedManifestTag = manifestTagMatch.value
        .replace(Regex("""\s+package\s*=\s*"[^"]*"""), "")
        .replace("\"\">", "\">")

    val updated = original.replaceRange(
        manifestTagMatch.range.first,
        manifestTagMatch.range.last + 1,
        cleanedManifestTag,
    )

    if (updated != original) {
        manifestFile.writeText(updated)
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    plugins.withId("com.android.application") {
        ensureAndroidNamespace(this@subprojects)
        alignAndroidCompileOptions(this@subprojects)
    }
    plugins.withId("com.android.library") {
        val libProject = this@subprojects
        ensureAndroidNamespace(libProject)
        alignAndroidCompileOptions(libProject)
        sanitizeLegacyLibraryManifest(libProject)
        libProject.afterEvaluate {
            widenFlutterAngleNativeAbis(libProject)
        }
    }

    tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile::class.java)
        .configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }

    tasks.withType(JavaCompile::class.java).configureEach {
        sourceCompatibility = "17"
        targetCompatibility = "17"
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

/// flutter_angle (three_js) mac dinh chi `abiFilters arm64-v8a` — may ao x86_64 se khong co .so => UnsatisfiedLinkError.
fun widenFlutterAngleNativeAbis(project: org.gradle.api.Project) {
    if (project.name != "flutter_angle") {
        return
    }
    val androidExt = project.extensions.findByName("android") ?: return
    try {
        val defaultConfig = androidExt.javaClass.methods
            .firstOrNull { it.name == "getDefaultConfig" && it.parameterCount == 0 }
            ?.invoke(androidExt)
            ?: return
        val ndk = defaultConfig.javaClass.methods
            .firstOrNull { it.name == "getNdk" && it.parameterCount == 0 }
            ?.invoke(defaultConfig)
            ?: return
        val abis = linkedSetOf("arm64-v8a", "armeabi-v7a", "x86_64")
        val setAbi = ndk.javaClass.methods.firstOrNull {
            it.name == "setAbiFilters" && it.parameterCount == 1
        }
        if (setAbi != null) {
            setAbi.invoke(ndk, abis)
            return
        }
        val getAbi = ndk.javaClass.methods.firstOrNull {
            it.name == "getAbiFilters" && it.parameterCount == 0
        }
        val existing = getAbi?.invoke(ndk)
        if (existing is MutableSet<*>) {
            @Suppress("UNCHECKED_CAST")
            val filters = existing as MutableSet<String>
            filters.clear()
            filters.addAll(abis)
        }
    } catch (_: Throwable) {
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
