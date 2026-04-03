#!/bin/sh
set -e
# Cloud Run: set MAPBOX_PUBLIC_ACCESS_TOKEN and tileset/style URLs via env or Secret Manager → env.
TS_URL="${MAPBOX_TILESET_URL:-}"
SRC_LAYER="${MEMBERS_SOURCE_LAYER:-ncrc-members-weekly}"
PUB="${MAPBOX_PUBLIC_ACCESS_TOKEN:-}"
STYLE_URL="${MAPBOX_STYLE_URL:-}"
STATE_TS="${STATE_BOUNDARIES_TILESET_URL:-}"
STATE_LAYER="${STATE_BOUNDARIES_SOURCE_LAYER:-State_Shoreline-al2frv}"
COUNTS_URL="${MEMBERS_STATE_COUNTS_URL:-}"
COUNTS_REFRESH="${MEMBERS_STATE_COUNTS_REFRESH_SEC:-0}"
{
  printf '%s\n' '// Generated at container start — see .env.example'
  printf "window.MAPBOX_PUBLIC_ACCESS_TOKEN = '%s';\n" "$(printf '%s' "$PUB" | sed "s/'/\\\\'/g")"
  printf "window.MAPBOX_STYLE_URL = '%s';\n" "$(printf '%s' "$STYLE_URL" | sed "s/'/\\\\'/g")"
  printf "window.MAPBOX_TILESET_URL = '%s';\n" "$(printf '%s' "$TS_URL" | sed "s/'/\\\\'/g")"
  printf "window.STATE_BOUNDARIES_TILESET_URL = '%s';\n" "$(printf '%s' "$STATE_TS" | sed "s/'/\\\\'/g")"
  printf "window.STATE_BOUNDARIES_SOURCE_LAYER = '%s';\n" "$(printf '%s' "$STATE_LAYER" | sed "s/'/\\\\'/g")"
  printf "window.MEMBERS_SOURCE_LAYER = '%s';\n" "$(printf '%s' "$SRC_LAYER" | sed "s/'/\\\\'/g")"
  printf "window.MEMBERS_STATE_COUNTS_URL = '%s';\n" "$(printf '%s' "$COUNTS_URL" | sed "s/'/\\\\'/g")"
  printf "window.MEMBERS_STATE_COUNTS_REFRESH_SEC = '%s';\n" "$(printf '%s' "$COUNTS_REFRESH" | sed "s/'/\\\\'/g")"
} > /usr/share/nginx/html/js/config.js
# Second script in index.html — keep a no-op in production so nothing overrides config.js above.
{
  printf '%s\n' '// Cloud Run: all Mapbox config is in config.js (no overrides here).'
  printf '%s\n' 'void 0;'
} > /usr/share/nginx/html/js/config.local.js
exec nginx -g 'daemon off;'
