#!/usr/bin/env bash
#
# Local smoke test: build js/config.local.js from .env, serve the static site on http://127.0.0.1:8765/
#
# Usage: ./scripts/dev-local.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

if [[ ! -f "${REPO_ROOT}/.env" ]]; then
  echo "Missing .env — copy .env.example to .env and add Mapbox + tileset values." >&2
  exit 1
fi

python3 "${SCRIPT_DIR}/generate-local-config.py"

echo "Serving ${REPO_ROOT} at http://127.0.0.1:8765/"
echo "Open that URL in a browser (Ctrl+C to stop)."
echo "Tip: restore safe stub before commit (no tokens in git): git checkout -- js/config.local.js"
exec python3 -m http.server 8765 --bind 127.0.0.1
