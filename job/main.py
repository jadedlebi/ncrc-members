#!/usr/bin/env python3
"""Export HubSpot companies from BigQuery to GeoJSON and upload to Mapbox (replaces tileset)."""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

from google.cloud import bigquery

from state_normalize import normalize_state

MAPBOX_UPLOAD_BASE = "https://api.mapbox.com/uploads/v1"


def load_sql() -> str:
    path = Path(os.environ.get("QUERY_PATH", Path(__file__).resolve().parent / "query.sql"))
    return path.read_text()


def table_ref() -> str:
    raw = os.environ["BQ_TABLE"].strip()
    if raw.startswith("`"):
        return raw
    return f"`{raw}`"


def row_to_feature(row: dict) -> dict:
    lon = float(row["longitude"])
    lat = float(row["latitude"])
    props = {
        "company_na": row.get("company_na") or "",
        "address": row.get("address") or "",
        "city": row.get("city") or "",
        "state": normalize_state(row.get("state")),
        "zip1": row.get("zip1") or "",
        "url": row.get("url") or "",
    }
    return {
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": [lon, lat]},
        "properties": props,
    }


def mapbox_credentials(username: str, token: str) -> dict:
    import requests

    r = requests.post(
        f"{MAPBOX_UPLOAD_BASE}/{username}/credentials",
        params={"access_token": token},
        timeout=120,
    )
    r.raise_for_status()
    return r.json()


def mapbox_stage_upload(creds: dict, body: bytes) -> str:
    import boto3

    s3 = boto3.client(
        "s3",
        aws_access_key_id=creds["accessKeyId"],
        aws_secret_access_key=creds["secretAccessKey"],
        aws_session_token=creds["sessionToken"],
        region_name="us-east-1",
    )
    s3.put_object(
        Bucket=creds["bucket"],
        Key=creds["key"],
        Body=body,
        ContentType="application/geo+json",
    )
    return creds["url"]


def mapbox_create_upload(
    username: str, token: str, staged_url: str, tileset: str, name: str
) -> dict:
    import requests

    r = requests.post(
        f"{MAPBOX_UPLOAD_BASE}/{username}",
        params={"access_token": token},
        json={"url": staged_url, "tileset": tileset, "name": name},
        headers={"Content-Type": "application/json"},
        timeout=120,
    )
    r.raise_for_status()
    return r.json()


def mapbox_upload_status(username: str, token: str, upload_id: str) -> dict:
    import requests

    r = requests.get(
        f"{MAPBOX_UPLOAD_BASE}/{username}/{upload_id}",
        params={"access_token": token},
        timeout=120,
    )
    r.raise_for_status()
    return r.json()


def mapbox_wait_upload(
    username: str, token: str, upload_id: str, timeout_sec: int = 3600
) -> dict:
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        st = mapbox_upload_status(username, token, upload_id)
        if st.get("error"):
            raise RuntimeError(st["error"])
        if st.get("complete"):
            return st
        time.sleep(2)
    raise TimeoutError(f"Upload {upload_id} did not complete within {timeout_sec}s")


def main() -> int:
    project = os.environ.get("GCP_PROJECT") or os.environ.get("GOOGLE_CLOUD_PROJECT")
    if not project:
        print("Set GCP_PROJECT or GOOGLE_CLOUD_PROJECT", file=sys.stderr)
        return 1

    skip_upload = os.environ.get("SKIP_MAPBOX_UPLOAD", "").strip().lower() in ("1", "true", "yes")
    token = ""
    username = ""
    tileset = ""
    upload_name = os.environ.get("MAPBOX_UPLOAD_NAME", "ncrc-members-weekly")
    if not skip_upload:
        token = os.environ["MAPBOX_ACCESS_TOKEN"]
        tileset = os.environ["MAPBOX_TILESET"].strip()
        if "." not in tileset:
            print("MAPBOX_TILESET must be username.tilesetname (e.g. myorg.ncrc_members)", file=sys.stderr)
            return 1
        username = tileset.split(".", 1)[0]

    sql = load_sql().replace("__BQ_TABLE__", table_ref())
    bq = bigquery.Client(project=project)
    job_config = bigquery.QueryJobConfig(use_legacy_sql=False)
    features = []
    for r in bq.query(sql, job_config=job_config).result():
        d = {k: r[k] for k in r.keys()}
        try:
            features.append(row_to_feature(d))
        except (KeyError, TypeError, ValueError) as e:
            print(f"skip row: {e}", file=sys.stderr)

    fc = {"type": "FeatureCollection", "features": features}
    body = json.dumps(fc, ensure_ascii=False).encode("utf-8")
    print(f"Built GeoJSON with {len(features)} features ({len(body)} bytes)")

    state_counts: dict[str, int] = {}
    for f in features:
        s = f["properties"].get("state")
        if s:
            state_counts[s] = state_counts.get(s, 0) + 1
    counts_path = os.environ.get("STATE_COUNTS_JSON_PATH", "").strip()
    if not counts_path:
        counts_path = str(Path(__file__).resolve().parent.parent / "data" / "state_counts.json")
    try:
        p = Path(counts_path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(state_counts, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        print(f"Wrote per-state counts ({len(state_counts)} keys) to {p}")
    except OSError as e:
        print(f"Could not write state counts to {counts_path}: {e}", file=sys.stderr)

    if skip_upload:
        print("SKIP_MAPBOX_UPLOAD=1 — skipping Mapbox upload (data/state_counts.json written).")
        return 0

    creds = mapbox_credentials(username, token)
    staged_url = mapbox_stage_upload(creds, body)
    print("Staged GeoJSON to Mapbox S3 bucket")

    created = mapbox_create_upload(username, token, staged_url, tileset, upload_name)
    upload_id = created["id"]
    print(f"Started Mapbox upload {upload_id} → tileset {tileset}")

    final = mapbox_wait_upload(username, token, upload_id)
    print(f"Tileset ready: mapbox://{final.get('tileset', tileset)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
