pluginManagement {
    includeBuild("build-logic")
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
plugins {
    id("com.gradle.develocity") version "4.6.1"
    id("com.gradle.common-custom-user-data-gradle-plugin") version "2.2"
    id("com.fueledbycaffeine.spotlight") version "1.8.0"
}
rootProject.name = "artifact-cache-docker-gradle-home"
develocity {
    // Set DEVELOCITY_URL in CI (repository secret); without it no Build Scan is published.
    val develocityUrl = providers.environmentVariable("DEVELOCITY_URL").orNull?.takeIf { it.isNotBlank() }
    if (develocityUrl != null) {
        server = develocityUrl
    }
    buildScan {
        publishing.onlyIf { develocityUrl != null }
        uploadInBackground.set(false)
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
include (":core:push")
include (":core:contact")
include (":core:login")
include (":core:identity")
include (":core:checkout")
include (":core:cart")
include (":feature:user")
include (":feature:profile")
include (":feature:feed")
include (":feature:comment")
include (":feature:post")
include (":feature:search")
include (":domain:location")
include (":domain:network")
include (":domain:sync")
include (":domain:share")
include (":domain:group")
include (":domain:message")
include (":repository:notification")
include (":repository:setting")
include (":repository:account")
include (":repository:session")
include (":repository:analytics")
include (":repository:report")
include (":model:log")
include (":model:status")
include (":model:metric")
include (":model:task")
include (":model:calendar")
include (":model:event")
include (":app:app")
