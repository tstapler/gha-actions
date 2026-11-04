#!/usr/bin/env bash
# Build a tiny Kotlin/JVM project and report the flags the Kotlin compile daemon really started with.
# Usage: kotlin-daemon-probe.sh <kotlin-version> <expected-substring>...
# Env:   GRADLE_USER_HOME (gradle.properties there carries kotlin.daemon.jvm.options), GRADLE (default gradle)
# Exit 0 only if every expected substring appears in the KotlinCompileDaemon command line.
# Stdout ends with "KOTLIN_DAEMON_ARGS: <args>" so callers can log it.
set -uo pipefail

kver=$1; shift
gradle=${GRADLE:-gradle}
proj=$(mktemp -d)
trap 'rm -rf "$proj"' EXIT

cat > "$proj/settings.gradle.kts" <<EOF
pluginManagement { repositories { gradlePluginPortal(); mavenCentral() } }
rootProject.name = "probe"
EOF
cat > "$proj/build.gradle.kts" <<EOF
plugins { kotlin("jvm") version "$kver" }
repositories { mavenCentral() }
EOF
if [ -n "${PROJECT_PROPERTIES:-}" ]; then printf '%s\n' "$PROJECT_PROPERTIES" > "$proj/gradle.properties"; fi
mkdir -p "$proj/src/main/kotlin"
echo 'fun main() { println("hi") }' > "$proj/src/main/kotlin/Main.kt"

(cd "$proj" && "$gradle" --no-daemon --console=plain compileKotlin) || { echo "probe build failed"; exit 2; }

args=$(pgrep -af KotlinCompileDaemon | head -n 1)
echo "KOTLIN_DAEMON_ARGS: $args"
rc=0
for want in "$@"; do
  case $args in
    *"$want"*) echo "found:   $want" ;;
    *) echo "MISSING: $want"; rc=1 ;;
  esac
done
exit $rc
