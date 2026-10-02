#!/usr/bin/env bash
# Static analysis gate (same gate as CI).
#
# `flutter analyze` does not generate the gitignored l10n output (lib/l10n/gen),
# so a fresh clone / worktree fails with `uri_does_not_exist` until `flutter pub
# get` regenerates it (pubspec.yaml has flutter: generate: true). This script
# runs pub get first, then the strict analyze gate.
set -euo pipefail

cd "$(dirname "$0")/.."

export PATH="${FLUTTER_HOME:-$HOME/development/flutter}/bin:$PATH"

flutter pub get
flutter analyze --fatal-infos
