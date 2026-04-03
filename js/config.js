// Overwritten at container startup (see docker/docker-entrypoint.sh).
// For local dev, copy .env.example to .env and use a small script, or set these here (do not commit secrets).
window.MAPBOX_PUBLIC_ACCESS_TOKEN = window.MAPBOX_PUBLIC_ACCESS_TOKEN || '';
window.MAPBOX_STYLE_URL = window.MAPBOX_STYLE_URL || '';
window.MAPBOX_TILESET_URL = window.MAPBOX_TILESET_URL || '';
window.STATE_BOUNDARIES_TILESET_URL = window.STATE_BOUNDARIES_TILESET_URL || '';
window.STATE_BOUNDARIES_SOURCE_LAYER = window.STATE_BOUNDARIES_SOURCE_LAYER || '';
window.MEMBERS_SOURCE_LAYER = window.MEMBERS_SOURCE_LAYER || '';
window.MEMBERS_STATE_COUNTS_URL = window.MEMBERS_STATE_COUNTS_URL || '';
window.MEMBERS_STATE_COUNTS_REFRESH_SEC = window.MEMBERS_STATE_COUNTS_REFRESH_SEC || '';
