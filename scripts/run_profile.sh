#!/usr/bin/env bash
# Run the app on a connected device/emulator in profile mode.
#
# Solves the two environment issues that break manual `flutter run --profile`:
#   1. Flutter is not on PATH (lives at ~/development/flutter/bin)
#   2. System default Java 26's jlink is incompatible with AGP's
#      JdkImageTransform — must use JDK 17/21.
#
# Usage:
#   ./scripts/run_profile.sh                 # profile mode, auto device
#   ./scripts/run_profile.sh -d <device-id>   # target a specific device
#
# Env overrides: FLUTTER_HOME, JAVA_HOME, ANDROID_SDK_ROOT
set -euo pipefail

cd "$(dirname "$0")/.."

export PATH="${FLUTTER_HOME:-$HOME/development/flutter}/bin:$PATH"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/development/android-sdk}"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export JAVA_HOME="${JAVA_HOME:-$HOME/development/jdk21}"
export PATH="$JAVA_HOME/bin:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$PATH"

exec flutter run --profile "$@"