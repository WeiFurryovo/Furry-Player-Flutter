pluginManagement {
    repositories {
        // 无法直连 Google 时使用镜像源
        maven(url = "https://maven.aliyun.com/repository/google")
        maven(url = "https://maven.aliyun.com/repository/central")
        maven(url = "https://maven.aliyun.com/repository/gradle-plugin")
        maven(url = "https://mirrors.cloud.tencent.com/nexus/repository/maven-public/")
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        maven(url = "https://maven.aliyun.com/repository/google")
        maven(url = "https://maven.aliyun.com/repository/central")
        maven(url = "https://mirrors.cloud.tencent.com/nexus/repository/maven-public/")
    }
}

rootProject.name = "furry-android-app"
include(":app")
