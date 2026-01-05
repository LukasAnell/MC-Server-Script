#!/usr/bin/env bash
set -euo pipefail

MODE="mcdr"
if [[ "${1-}" == "--direct" ]]; then
  MODE="direct"
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$ROOT/config/server.json"

read_config() {
  python3 - "$CONFIG" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
print(cfg.get("server_dir", "server"))
print(cfg.get("java_memory", "2G"))
print(cfg.get("java_additional_args", ""))
PY
}

mapfile -t CFG < <(read_config)
SERVER_DIR="$ROOT/${CFG[0]}"
JAVA_MEM="${CFG[1]}"
JAVA_ARGS="${CFG[2]}"

if [[ ! -d "$SERVER_DIR" ]]; then
  echo "Server directory not found at $SERVER_DIR. Run install.sh first." >&2
  exit 1
fi

build_java_cmd() {
  JAVA_CMD=("java" "-Xmx${JAVA_MEM}")
  if [[ -n "$JAVA_ARGS" ]]; then
    read -r -a extra_args <<<"$JAVA_ARGS"
    JAVA_CMD+=("${extra_args[@]}")
  fi
  JAVA_CMD+=("-jar" "fabric-server-launch.jar" "nogui")
}

start_direct() {
  build_java_cmd
  pushd "$SERVER_DIR" >/dev/null
  "${JAVA_CMD[@]}"
  popd >/dev/null
}

start_mcdr() {
  local mcdr_config=""
  if [[ -f "$SERVER_DIR/config/mcdreforged/config.yml" ]]; then
    mcdr_config="$SERVER_DIR/config/mcdreforged/config.yml"
  elif [[ -f "$SERVER_DIR/config/config.yml" ]]; then
    mcdr_config="$SERVER_DIR/config/config.yml"
  fi
  if [[ -z "$mcdr_config" ]]; then
    build_java_cmd
    echo "MCDReforged config not found. Create server/config/mcdreforged/config.yml with start_command: ${JAVA_CMD[*]}" >&2
    echo "Run with --direct to start without MCDReforged." >&2
    exit 1
  fi
  local mcdr_perm
  mcdr_perm="$(dirname "$mcdr_config")/permission.yml"
  if [[ ! -f "$mcdr_perm" ]]; then
    cat >"$mcdr_perm" <<'EOF'
default:
  level: 0
players: {}
EOF
    echo "Created default MCDReforged permission file at $mcdr_perm"
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Python 3 not found. Install Python 3 or use --direct." >&2
    exit 1
  fi
  pushd "$SERVER_DIR" >/dev/null
  echo "Starting MCDReforged (config: $mcdr_config, permission: $mcdr_perm)"
  python3 -m mcdreforged start --config "$mcdr_config" --permission "$mcdr_perm"
  popd >/dev/null
}

case "$MODE" in
  direct)
    start_direct
    ;;
  mcdr)
    start_mcdr
    ;;
  *)
    echo "Unknown mode" >&2
    exit 1
    ;;
esac
