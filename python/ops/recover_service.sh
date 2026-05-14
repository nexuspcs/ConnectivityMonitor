#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <username> [web_port]"
  exit 1
fi

USER_NAME="$1"
SERVICE="connectivity-monitor@${USER_NAME}"
PORT="${2:-}"

if [[ -z "${PORT}" ]]; then
  CONFIG_PATH="/home/${USER_NAME}/ConnectivityMonitor/monitor_config.json"
  if [[ -f "${CONFIG_PATH}" ]]; then
    if ! PORT="$(python3 - "${CONFIG_PATH}" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        print(json.load(f).get("web_port", 8080))
except Exception as exc:
    print(f"ERROR: could not parse config: {exc}", file=sys.stderr)
    sys.exit(1)
PY
    )"; then
      echo "Falling back to port 8080 due to config parse failure." >&2
      PORT="8080"
    fi
  else
    PORT="8080"
  fi
fi

echo "Reloading systemd units..."
sudo systemctl daemon-reload

echo "Enabling and restarting ${SERVICE}..."
sudo systemctl enable "${SERVICE}"
sudo systemctl restart "${SERVICE}"

echo "Service status:"
sudo systemctl --no-pager --full status "${SERVICE}" | cat

echo "Recent logs:"
sudo journalctl --no-pager -u "${SERVICE}" -n 50 | cat

echo "API health:"
if ! curl -fsS "http://127.0.0.1:${PORT}/api/status" | python3 -m json.tool; then
  echo "ERROR: API health check failed on port ${PORT}" >&2
  exit 2
fi
