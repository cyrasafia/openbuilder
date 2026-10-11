#!/usr/bin/env bash
# Build the Android release APK with an auto-incrementing build number.
#
# Versioning scheme (see docs/plan/plan-overview.md):
#   pubspec.yaml: version: A.B.C+N
#     - A.B.C = version name (manual only; upgrade with --set-version)
#     - N     = Android versionCode (must be >= 1), +1/build
#
# This script keeps the version name and bumps N by 1 on every build. The new
# version is kept only after a successful build. To upgrade the version name,
# pass: ./scripts/build.sh --set-version 0.10.1
set -euo pipefail

cd "$(dirname "$0")/.."

PUBSPEC="pubspec.yaml"

set_version=""
if [[ "${1:-}" == "--set-version" ]]; then
  set_version="${2:?usage: build.sh [--set-version A.B.C]}"
fi

# Read current version line.
line=$(grep -m1 '^version:' "$PUBSPEC")
ver="${line#version: }"           # A.B.C+N
base="${ver%%+*}"                 # A.B.C
cur_code="${ver#*+}"
[[ "$cur_code" =~ ^[0-9]+$ ]] || cur_code=0

new_name="$base"
if [[ -n "$set_version" ]]; then
  [[ "$set_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "error: 版本号须为 A.B.C 三段式：$set_version" >&2
    exit 1
  }
  [[ "$set_version" != "$base" ]] || {
    echo "error: 版本号未变化：$set_version" >&2
    exit 1
  }
  new_name="$set_version"
fi

code=$((cur_code + 1))
new_ver="${new_name}+${code}"
echo "Building version ${new_ver}"
if [[ "$new_name" != "$base" ]]; then
  echo "Version name ${base} -> ${new_name}（构建成功后打 tag v${new_name} 并推送）"
fi

# Env.
export PATH="${FLUTTER_HOME:-$HOME/development/flutter}/bin:$PATH"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/development/android-sdk}"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export JAVA_HOME="${JAVA_HOME:-$HOME/development/jdk21}"
export PATH="$JAVA_HOME/bin:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$PATH"

flutter build apk --release --build-name="$new_name" --build-number="$code"

# Rename the release APK to <app name>-<version>.apk (name derived from android:label "Open Builder").
app_name="OpenBuilder"
apk_dir="build/app/outputs/flutter-apk"
apk_dst="$apk_dir/${app_name}-${new_name}-${code}.apk"
if [[ -e "$apk_dst" ]]; then
  echo "error: 目标产物已存在，疑似上次版本写回未完成：$apk_dst" >&2
  exit 1
fi
mv -f "$apk_dir/app-release.apk" "$apk_dst"
echo "Release APK: $(pwd)/$apk_dst"

perl -i -pe "s{^version: .*\$}{version: ${new_ver}}" "$PUBSPEC"