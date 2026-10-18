#!/usr/bin/env bash
# Runs the RoomVibe backend on this Mac for a local demo and points the app at it.
#
#   scripts/run_local.sh [--sim] [--port N]
#
#   --sim     the app runs in the Simulator: serve and connect on 127.0.0.1 only
#   --port N  port to serve on (default 8000)
#
# Reads provider keys and APP_SHARED_SECRET from backend/.env (gitignored; see backend/.env.example).
# Variables already set in the shell override .env.
# Writes RoomVibe/Core/Networking/APIConfig.json (gitignored, mode 0600). The app bundles that file, so
# rebuild the app after it changes. The phone and the Mac must be on the same Wi-Fi.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backend="$root/backend"
config="$root/RoomVibe/Core/Networking/APIConfig.json"
port=8000
sim=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim) sim=1; shift ;;
    --port) port="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done
if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
  echo "--port must be a number from 1 to 65535" >&2
  exit 2
fi

# Python environment: create it once, then install requirements whenever they change.
if [[ ! -x "$backend/.venv/bin/python" ]]; then
  echo "Creating backend/.venv"
  python3 -m venv "$backend/.venv"
fi
stamp="$backend/.venv/.requirements.installed"
if [[ ! -f "$stamp" || "$backend/requirements.txt" -nt "$stamp" ]]; then
  echo "Installing backend requirements"
  "$backend/.venv/bin/pip" install -q -r "$backend/requirements.txt"
  touch "$stamp"
fi

# backend/.env is parsed, never sourced, with python-dotenv (the backend's own parser: inline
# comments and quotes handled, no variable or command interpolation). Only the backend's known
# settings (the names in backend/.env.example) are taken, passed back NUL-separated.
known=" APP_SHARED_SECRET MOCK LLM_API_KEY LLM_MODEL IMAGE_API_KEY IMAGE_MODEL IMAGE_SIZE SHOPPING_API_KEY"
known+=" BROWSER_USE_API_KEY BROWSER_USE_MODEL BROWSER_USE_MAX_COST FAL_KEY"
known+=" MAX_UPLOAD_MB MAX_RESPONSE_MB USDZ_MAX_MB USDZ_MAX_FACES "
if [[ -f "$backend/.env" ]]; then
  while IFS= read -r -d '' pair; do
    key="${pair%%=*}"
    [[ "$known" == *" $key "* ]] || continue
    [[ -n "${!key+x}" ]] && continue                      # the shell's value wins
    export "$pair"                                        # plain assignment: the value is not expanded
  done < <("$backend/.venv/bin/python" - "$backend/.env" <<'PY'
import sys
from dotenv import dotenv_values
for key, value in dotenv_values(sys.argv[1], interpolate=False).items():
    if value is not None and key.isidentifier() and "\0" not in value:
        sys.stdout.write(f"{key}={value}\0")
PY
)
fi
export MOCK="${MOCK:-1}"

if [[ $sim == 1 ]]; then
  host=127.0.0.1
  bind=127.0.0.1
else
  host="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
  bind=0.0.0.0
  if [[ -z "$host" ]]; then
    echo "Could not find this Mac's LAN IP (en0/en1). Join Wi-Fi, or use --sim for the Simulator." >&2
    exit 1
  fi
fi

secret_note=set
if [[ -z "${APP_SHARED_SECRET:-}" ]]; then
  if [[ "$MOCK" != "1" ]]; then
    echo "MOCK=$MOCK needs APP_SHARED_SECRET. Set one in backend/.env, for example:" >&2
    echo "  echo \"APP_SHARED_SECRET=\$(openssl rand -hex 16)\" >> backend/.env" >&2
    exit 1
  fi
  if [[ $sim == 0 ]]; then
    # The server is reachable from the whole Wi-Fi network: never leave it unauthenticated, even in mock.
    APP_SHARED_SECRET="$(openssl rand -hex 16)"
    export APP_SHARED_SECRET
    secret_note="generated a session secret (rebuild the app)"
  else
    secret_note=empty
  fi
fi

# The secret is bundled into the app build through this file. That is accepted for a local demo.
# The file is written owner-only and never printed.
python3 - "$config" "http://$host:$port" <<'PY'
import json, os, sys
path, url = sys.argv[1], sys.argv[2]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.fchmod(fd, 0o600)  # the file may already exist with wider permissions
with os.fdopen(fd, "w") as f:
    json.dump({"baseURL": url, "secret": os.environ.get("APP_SHARED_SECRET", "")}, f)
    f.write("\n")
PY

echo "App config: RoomVibe/Core/Networking/APIConfig.json -> http://$host:$port (secret: $secret_note)"
echo "Rebuild and run the app so it bundles the new config."
echo "Health check: http://$host:$port/health  (MOCK=$MOCK, listening on $bind)"
echo

cd "$backend"
exec "$backend/.venv/bin/fastapi" run main.py --host "$bind" --port "$port"
