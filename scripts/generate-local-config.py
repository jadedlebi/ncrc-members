#!/usr/bin/env python3
"""Write js/config.local.js from repo-root .env (gitignored). Used by dev-local.sh."""
from __future__ import annotations

import json
import sys
from pathlib import Path

KEYS = (
    "MAPBOX_PUBLIC_ACCESS_TOKEN",
    "MAPBOX_STYLE_URL",
    "MAPBOX_TILESET_URL",
    "STATE_BOUNDARIES_TILESET_URL",
    "STATE_BOUNDARIES_SOURCE_LAYER",
    "MEMBERS_SOURCE_LAYER",
    "MEMBERS_STATE_COUNTS_URL",
    "MEMBERS_STATE_COUNTS_REFRESH_SEC",
)


def read_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip()
        if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
            val = val[1:-1]
        env[key] = val
    return env


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    env_path = root / ".env"
    if not env_path.is_file():
        print(f"Missing {env_path}; copy .env.example to .env and fill values.", file=sys.stderr)
        return 1
    env = read_env(env_path)
    out = root / "js" / "config.local.js"
    lines = [
        "// Optional overrides for localhost (scripts/dev-local.sh). Empty = use docker-style config.js only.",
        "'use strict';",
        "(function () {",
    ]
    for k in KEYS:
        v = env.get(k, "")
        lines.append(f"  window.{k} = {json.dumps(v)};")
    lines.append("})();")
    lines.append("")
    out.write_text("\n".join(lines), encoding="utf-8")
    print(f"Wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
