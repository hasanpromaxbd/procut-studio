allprojects {
    repositories {
        google()
        mavenCentral()
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
    project.evaluationDependsOn(":app")
}

// ── Plugin compatibility shim ────────────────────────────────────────
//
// file_picker 11.0.2 contains:
//
//     def isAgp9OrAbove = ...
//     if (!isAgp9OrAbove) { apply plugin: 'org.jetbrains.kotlin.android' }
//
// It assumes AGP 9 compiles Kotlin without the Kotlin plugin. AGP 9 does not
// enable built-in Kotlin by default, so the plugin's Kotlin sources are never
// compiled and the app fails to link `FilePickerPlugin` — but only at
// `:app:compileDebugJavaWithJavac`, which makes it look like an app bug.
//
// Applying the plugin ourselves restores the step it skipped. Remove this once
// file_picker ships an AGP 9-aware release.
subprojects {
    plugins.withId("com.android.library") {
        if (project.name == "file_picker" &&
            !plugins.hasPlugin("org.jetbrains.kotlin.android")
        ) {
            apply(plugin = "org.jetbrains.kotlin.android")
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
