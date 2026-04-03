// Safe default for clone/open in browser without .env. Local dev: ./scripts/dev-local.sh overwrites from .env.
// Do not commit real tokens here — use Secret Manager + Cloud Run env for production.
'use strict';
(function () {
  window.MAPBOX_PUBLIC_ACCESS_TOKEN = "";
  window.MAPBOX_STYLE_URL = "";
  window.MAPBOX_TILESET_URL = "";
  window.STATE_BOUNDARIES_TILESET_URL = "";
  window.STATE_BOUNDARIES_SOURCE_LAYER = "";
  window.MEMBERS_SOURCE_LAYER = "";
  window.MEMBERS_STATE_COUNTS_URL = "";
  window.MEMBERS_STATE_COUNTS_REFRESH_SEC = "";
})();
