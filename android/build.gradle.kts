allprojects {
    repositories {
        // 国内镜像优先（阿里云）
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/public")
        maven("https://maven.aliyun.com/repository/gradle-plugin")
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

// 部分依赖库要求 compileSdk>=34，这里统一把低版本库模块提到 34，避免构建失败
subprojects {
    plugins.withId("com.android.library") {
        val ext = extensions.findByName("android")
        if (ext is com.android.build.gradle.BaseExtension) {
            val cur = ext.compileSdkVersion ?: 0
            if (cur in 1..33) {
                ext.compileSdkVersion(34)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
