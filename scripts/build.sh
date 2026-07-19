#!/usr/bin/env bash
# Build the Android release APK with an auto-incrementing build number.
#
# Versioning scheme (see docs/plan-overview.md):
#   pubspec.yaml: version: A.B.C+N
#     - A.B  = business version (only bumped on explicit request)
#     - C    = build number (patch part of versionName), starts at 0, +1/build
#     - N    = Android versionCode (must be >= 1), +1/build
#
# This script builds with C and N bumped by 1 and keeps the new version only
# after a successful build. To bump the business version (A.B), reset C to 0,
# and keep N increasing, pass: ./scripts/build.sh --bump-business 0.2
set -euo pipefail

cd "$(dirname "$0")/.."

PUBSPEC="pubspec.yaml"

bump_business=""
if [[ "${1:-}" == "--bump-business" ]]; then
  bump_business="${2:?usage: build.sh [--bump-business A.B]}"
fi

# Read current version line.
line=$(grep -m1 '^version:' "$PUBSPEC")
ver="${line#version: }"           # A.B.C+N
base="${ver%%+*}"                 # A.B.C
cur_code="${ver#*+}"
[[ "$cur_code" =~ ^[0-9]+$ ]] || cur_code=0
IFS='.' read -r major minor patch <<<"$base"

if [[ -n "$bump_business" ]]; then
  IFS='.' read -r major minor <<<"$bump_business"
  patch=0
  code=$((cur_code + 1))
else
  patch=$((patch + 1))
  code=$((cur_code + 1))
fi

new_name="${major}.${minor}.${patch}"
new_ver="${new_name}+${code}"
echo "Building version ${new_ver}"

# Env.
export PATH="$HOME/development/flutter/bin:$PATH"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/development/android-sdk}"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export JAVA_HOME="${JAVA_HOME:-$HOME/development/jdk21}"
export PATH="$JAVA_HOME/bin:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$PATH"

flutter build apk --release --build-name="$new_name" --build-number="$code"
perl -i -pe "s{^version: .*\$}{version: ${new_ver}}" "$PUBSPEC"
