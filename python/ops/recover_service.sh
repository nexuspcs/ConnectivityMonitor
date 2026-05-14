#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <username>"
  exit 1
fi

USER_NAME="$1"
SERVICE="connectivity-monitor@${USER_NAME}"

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
curl -fsS "http://127.0.0.1:8080/api/status" | python3 -m json.tool
