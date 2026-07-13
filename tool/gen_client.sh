#!/usr/bin/env bash
# Refresh the pinned opencode OpenAPI spec, optionally emit a reference
# dart-dio client for inspection.
#
# Why hand-written, not generated: opencode's spec is complex (discriminated
# unions, SSE). Off-the-shelf `openapi-generator -g dart-dio` produces ~8k
# analyzer warnings (built_value boilerplate). The app therefore uses a
# hand-written typed client in lib/data/api/, added per v2 types. Final
# generator choice is deferred (plan-overview.md §7). This script keeps the spec pinned
# and the regeneration capability available.
#
# Usage:
#   tool/gen_client.sh              # refresh opencode_openapi.json (pinned ref)
#   tool/gen_client.sh --generate   # also emit reference dart-dio client → .gen_ref/
set -euo pipefail

REF="${OPENCODE_SPEC_REF:-v1.17.18}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC_URL="https://raw.githubusercontent.com/anomalyco/opencode/${REF}/packages/sdk/openapi.json"

echo ">> fetching spec @ ${REF}"
curl -fL "$SPEC_URL" -o "$ROOT/opencode_openapi.json"
echo ">> spec: $(wc -c < "$ROOT/opencode_openapi.json") bytes → opencode_openapi.json"

if [[ "${1:-}" == "--generate" ]]; then
  echo ">> generating dart-dio reference client (needs java + npx)"
  rm -rf "$ROOT/.gen_ref"
  npx --yes @openapitools/openapi-generator-cli@latest generate \
    -g dart-dio -i "$ROOT/opencode_openapi.json" -o "$ROOT/.gen_ref" \
    --skip-validate-spec
  echo ">> reference client at $ROOT/.gen_ref (NOT imported by the app)"
fi
