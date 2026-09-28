#!/usr/bin/env bash
# Refresh the pinned opencode OpenAPI specs. `opencode_openapi_v2.json` is the
# authoritative contract reference for the v2 migration (fetched from a running
# v2 server's /openapi.json); `opencode_openapi.json` keeps the v1 legacy spec
# for history and is not updated anymore.
#
# Why hand-written, not generated: opencode's spec is complex (discriminated
# unions, SSE). Off-the-shelf `openapi-generator -g dart-dio` produces ~8k
# analyzer warnings (built_value boilerplate). The app therefore uses a
# hand-written typed client in lib/data/api/. This script keeps the specs
# pinned and the regeneration capability available.
#
# Usage:
#   tool/gen_client.sh              # refresh opencode_openapi_v2.json (pinned ref)
#   tool/gen_client.sh --generate   # also emit reference dart-dio client → .gen_ref/
#
# Env overrides:
#   OPENCODE_SPEC_URL   spec source (default: local persistent v2 server)
#   OPENCODE_SPEC_AUTH  Basic auth value for the spec source, e.g. "opencode:<pw>"
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC_URL="${OPENCODE_SPEC_URL:-http://localhost:15120/openapi.json}"
SPEC_AUTH="${OPENCODE_SPEC_AUTH:-opencode:1234321}"

echo ">> fetching v2 spec from $SPEC_URL"
curl -fL -u "$SPEC_AUTH" "$SPEC_URL" -o "$ROOT/opencode_openapi_v2.json"
echo ">> spec: $(wc -c < "$ROOT/opencode_openapi_v2.json") bytes → opencode_openapi_v2.json"

if [[ "${1:-}" == "--generate" ]]; then
  echo ">> generating dart-dio reference client (needs java + npx)"
  rm -rf "$ROOT/.gen_ref"
  npx --yes @openapitools/openapi-generator-cli@latest generate \
    -g dart-dio -i "$ROOT/opencode_openapi_v2.json" -o "$ROOT/.gen_ref" \
    --skip-validate-spec
  echo ">> reference client at $ROOT/.gen_ref (NOT imported by the app)"
fi
