#!/usr/bin/env python3
"""HTTP service: BigQuery aggregate → JSON map of USPS state code → count (for MEMBERS_STATE_COUNTS_URL)."""

from __future__ import annotations

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from google.cloud import bigquery

from state_normalize import normalize_state

_QUERY_PATH = Path(__file__).resolve().parent / "state_counts_query.sql"

_cache_lock = threading.Lock()
_fetch_lock = threading.Lock()
# Monotonic expiry + payload; None means empty cache.
_cache_entry: dict[str, object] | None = None


def table_ref() -> str:
    raw = os.environ["BQ_TABLE"].strip()
    if raw.startswith("`"):
        return raw
    return f"`{raw}`"


def load_sql() -> str:
    return _QUERY_PATH.read_text()


def _cache_ttl_sec() -> float:
    """0 = disable in-memory cache (every request runs BigQuery)."""
    return float(os.environ.get("STATE_COUNTS_CACHE_TTL_SEC", "300"))


def fetch_state_counts() -> dict[str, int]:
    project = os.environ.get("GCP_PROJECT") or os.environ.get("GOOGLE_CLOUD_PROJECT")
    if not project:
        raise RuntimeError("Set GCP_PROJECT or GOOGLE_CLOUD_PROJECT")

    sql = load_sql().replace("__BQ_TABLE__", table_ref())
    bq = bigquery.Client(project=project)
    job_config = bigquery.QueryJobConfig(use_legacy_sql=False)
    counts: dict[str, int] = {}
    for row in bq.query(sql, job_config=job_config).result():
        raw = row["state"]
        n = int(row["c"])
        abbr = normalize_state(raw) if raw is not None else ""
        if not abbr:
            continue
        counts[abbr] = counts.get(abbr, 0) + n
    return dict(sorted(counts.items()))


def get_state_counts_cached(bypass_cache: bool) -> tuple[dict[str, int], bool]:
    """Return (counts, cache_hit). BigQuery runs only on miss when TTL > 0."""
    ttl = _cache_ttl_sec()
    if ttl <= 0 or bypass_cache:
        return fetch_state_counts(), False

    now = time.monotonic()
    global _cache_entry
    with _cache_lock:
        if _cache_entry is not None:
            expires_at = float(_cache_entry["expires_at"])
            if now < expires_at:
                return dict(_cache_entry["data"]), True  # type: ignore[arg-type]

    # Only one BigQuery refresh at a time; re-check cache after waiting (another thread may have filled it).
    with _fetch_lock:
        now = time.monotonic()
        with _cache_lock:
            if _cache_entry is not None:
                expires_at = float(_cache_entry["expires_at"])
                if now < expires_at:
                    return dict(_cache_entry["data"]), True  # type: ignore[arg-type]

        data = fetch_state_counts()

        with _cache_lock:
            _cache_entry = {
                "data": data,
                "expires_at": time.monotonic() + ttl,
            }
            return data, False


class Handler(BaseHTTPRequestHandler):
    server_version = "ncrc-members-counts/1.0"

    def log_message(self, format: str, *args) -> None:
        print(f"[counts] {self.address_string()} - {format % args}", file=sys.stderr)

    def _send_json(
        self,
        code: int,
        body: bytes,
        *,
        cache_control: str | None = None,
        x_cache: str | None = None,
    ) -> None:
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Cache-Control", cache_control or "no-store")
        if x_cache:
            self.send_header("X-Cache", x_cache)
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)
        bypass = False
        for key in ("nocache", "refresh", "skip_cache"):
            v = qs.get(key, [""])[0].lower()
            if v in ("1", "true", "yes"):
                bypass = True
                break

        if path in ("/", "/state-counts", "/state_counts.json"):
            try:
                counts, cache_hit = get_state_counts_cached(bypass_cache=bypass)
                body = json.dumps(counts, ensure_ascii=False).encode("utf-8")
                ttl = _cache_ttl_sec()
                if ttl > 0:
                    # Let browsers/CDNs cache briefly; server-side TTL bounds freshness vs BigQuery cost.
                    max_age = max(0, int(ttl))
                    cc = f"public, max-age={max_age}"
                else:
                    cc = "no-store"
                self._send_json(
                    200,
                    body,
                    cache_control=cc,
                    x_cache="HIT" if cache_hit else "MISS",
                )
            except Exception as e:
                msg = json.dumps({"error": str(e)}, ensure_ascii=False).encode("utf-8")
                self._send_json(500, msg)
            return
        if path == "/health":
            self._send_json(200, b'{"ok":true}')
            return
        self._send_json(404, b'{"error":"not found"}')


def main() -> int:
    port = int(os.environ.get("PORT", "8080"))
    host = os.environ.get("HOST", "0.0.0.0")
    ttl = _cache_ttl_sec()
    print(
        f"State counts server listening on http://{host}:{port}/ "
        f"(STATE_COUNTS_CACHE_TTL_SEC={ttl}, nocache=1 bypasses cache)",
        file=sys.stderr,
    )
    server = HTTPServer((host, port), Handler)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
