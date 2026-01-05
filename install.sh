#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-install}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$ROOT/config/server.json"
MANIFEST="$ROOT/config/mods.json"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing $2 ($1)" >&2
    exit 1
  fi
}

ensure_dir() {
  for path in "$@"; do
    mkdir -p "$path"
  done
}

read_config() {
  python3 - "$CONFIG" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
print(cfg.get("server_dir", "server"))
print(cfg.get("minecraft_version", "latest"))
print(cfg.get("fabric_loader_version", "latest"))
print(cfg.get("fabric_installer_version", "latest"))
print(cfg.get("java_memory", "2G"))
print(cfg.get("java_additional_args", ""))
print(cfg.get("mcdreforged_version", "latest"))
print(cfg.get("accept_eula", True))
PY
}

mapfile -t CFG < <(read_config)
SERVER_DIR="$ROOT/${CFG[0]}"
MC_VERSION="${CFG[1]}"
LOADER_VERSION="${CFG[2]}"
INSTALLER_VERSION="${CFG[3]}"
JAVA_MEM="${CFG[4]}"
JAVA_ARGS="${CFG[5]}"
MCDR_VERSION="${CFG[6]}"
ACCEPT_EULA="${CFG[7]}"

DOWNLOADS_DIR="$SERVER_DIR/downloads"
MODS_DIR="$SERVER_DIR/mods"
PLUGINS_DIR="$SERVER_DIR/plugins"
MCDR_CONFIG_DIR="$SERVER_DIR/config"
MCDR_CONFIG_PATH="$MCDR_CONFIG_DIR/config.yml"
MCDR_PERMISSION_PATH="$MCDR_CONFIG_DIR/permission.yml"

require_cmd java "Java runtime"
require_cmd python3 "Python 3"
require_cmd curl "curl"

ensure_dir "$SERVER_DIR" "$DOWNLOADS_DIR" "$MODS_DIR" "$PLUGINS_DIR"

build_start_command() {
  JAVA_CMD=("java" "-Xmx${JAVA_MEM}")
  if [[ -n "$JAVA_ARGS" ]]; then
    read -r -a extra_args <<<"${JAVA_ARGS}"
    JAVA_CMD+=("${extra_args[@]}")
  fi
  JAVA_CMD+=("-jar" "fabric-server-launch.jar" "nogui")
}

resolve_mc_version() {
  if [[ "$MC_VERSION" != "latest" ]]; then
    echo "$MC_VERSION"
    return
  fi
  python3 <<'PY'
import json, urllib.request
data = json.load(urllib.request.urlopen("https://meta.fabricmc.net/v2/versions/game"))
for entry in data:
    if entry.get("stable"):
        print(entry["version"])
        break
PY
}

resolve_fabric_versions() {
  python3 - <<'PY'
import json, os, urllib.request, sys
mc_version = os.environ["MCV"]
loader = os.environ["LOADER"]
installer = os.environ["INSTALLER"]
loader_data = json.load(urllib.request.urlopen(f"https://meta.fabricmc.net/v2/versions/loader/{mc_version}"))
if not loader_data:
    print(f"Unable to resolve Fabric loader versions for Minecraft {mc_version}", file=sys.stderr)
    sys.exit(1)
loader_entry = loader_data[0]
loader_version = loader if loader != "latest" else loader_entry["loader"]["version"]
if installer != "latest":
    installer_version = installer
else:
    installer_data = json.load(urllib.request.urlopen("https://meta.fabricmc.net/v2/versions/installer"))
    if not installer_data:
        print("Unable to resolve Fabric installer version (empty installer list)", file=sys.stderr)
        sys.exit(1)
    installer_version = installer_data[0]["version"]
print(loader_version)
print(installer_version)
PY
}

download_file() {
  local url="$1"
  local dest="$2"
  echo "Downloading $url -> $dest"
  curl -L --retry 3 --fail -o "$dest" "$url"
}

install_fabric_server() {
  local mc="$1"
  local loader="$2"
  local installer="$3"
  ensure_dir "$DOWNLOADS_DIR"
  local installer_name="fabric-installer-$installer.jar"
  local installer_path="$DOWNLOADS_DIR/$installer_name"
  if [[ ! -f "$installer_path" ]]; then
    local installer_url="https://maven.fabricmc.net/net/fabricmc/fabric-installer/$installer/fabric-installer-$installer.jar"
    download_file "$installer_url" "$installer_path"
  fi
  pushd "$SERVER_DIR" >/dev/null
  echo "Running Fabric installer for $mc (loader $loader, installer $installer)"
  java -jar "$installer_path" server -mcversion "$mc" -loader "$loader" -downloadMinecraft -dir .
  popd >/dev/null
}

ensure_eula() {
  if [[ "$ACCEPT_EULA" != "True" && "$ACCEPT_EULA" != "true" ]]; then
    return
  fi
  echo "eula=true" >"$SERVER_DIR/eula.txt"
}

install_mods() {
  MC_TARGET="$1" MANIFEST_PATH="$MANIFEST" MODS_PATH="$MODS_DIR" python3 <<'PY'
import json, os, pathlib, urllib.request
mc_version = os.environ["MC_TARGET"]
manifest_path = pathlib.Path(os.environ["MANIFEST_PATH"])
mods_dir = pathlib.Path(os.environ["MODS_PATH"])
if not manifest_path.exists():
    print(f"Mod manifest not found: {manifest_path}")
    exit(0)
manifest = json.load(manifest_path.open())
mods = manifest.get("mods", [])
if not mods:
    print("No mods defined in manifest")
    exit(0)
mods_dir.mkdir(parents=True, exist_ok=True)
for mod in mods:
    slug = mod.get("slug") or mod.get("id")
    if not slug:
        print(f"Skipping manifest entry without slug/id: {mod}")
        continue
    query = f"https://api.modrinth.com/v2/project/{slug}/version?loaders=[\"fabric\"]&game_versions=[\"{mc_version}\"]"
    try:
        versions = json.load(urllib.request.urlopen(query))
    except Exception as e:
        print(f"Failed to query Modrinth for {slug}: {e}")
        continue
    if not versions:
        print(f"No versions available for {slug} ({mc_version})")
        continue
    release = next((v for v in versions if v.get("version_type") == "release"), versions[0])
    files = release.get("files") or []
    file = next((f for f in files if f.get("primary")), files[0] if files else None)
    if not file:
        print(f"No downloadable files for {slug}")
        continue
    filename = file.get("filename") or f"{slug}-{release.get('version_number','latest')}.jar"
    dest = mods_dir / filename
    for existing in mods_dir.glob(f"{slug}*.jar"):
        try:
            existing.unlink()
        except Exception:
            pass
    print(f"Installing {slug} {release.get('version_number')}")
    try:
        with urllib.request.urlopen(file["url"]) as resp, open(dest, "wb") as outf:
            outf.write(resp.read())
    except Exception as e:
        print(f"Failed to download {slug}: {e}")
PY
}

install_mcdr() {
  local version="$1"
  local pkg="mcdreforged"
  if [[ "$version" != "latest" ]]; then
    pkg="mcdreforged==$version"
  fi
  echo "Installing $pkg via pip"
  python3 -m pip install --upgrade --user "$pkg"
}

ensure_mcdr_config() {
  local start_cmd="$1"
  mkdir -p "$MCDR_CONFIG_DIR"
  local legacy_path="$SERVER_DIR/config/mcdreforged/config.yml"
  local legacy_perm="$SERVER_DIR/config/mcdreforged/permission.yml"
  if [[ -f "$MCDR_CONFIG_PATH" ]]; then
    echo "MCDReforged config already exists at $MCDR_CONFIG_PATH; leaving unchanged."
  elif [[ -f "$legacy_path" ]]; then
    cp "$legacy_path" "$MCDR_CONFIG_PATH"
    echo "Copied existing config from $legacy_path to $MCDR_CONFIG_PATH"
  else
    cat >"$MCDR_CONFIG_PATH" <<EOF
language: en_us
encoding: utf8
working_directory: "."
start_command: $start_cmd
stop_command: stop
EOF
    echo "Created default MCDReforged config at $MCDR_CONFIG_PATH"
  fi
  if [[ ! -f "$MCDR_PERMISSION_PATH" ]]; then
    if [[ -f "$legacy_perm" ]]; then
      cp "$legacy_perm" "$MCDR_PERMISSION_PATH"
      echo "Copied existing permission file from $legacy_perm to $MCDR_PERMISSION_PATH"
    else
      cat >"$MCDR_PERMISSION_PATH" <<'EOF'
default:
  level: 0
players: {}
EOF
      echo "Created default MCDReforged permission file at $MCDR_PERMISSION_PATH"
    }
  fi
}

MCV_RESOLVED="$(resolve_mc_version)"
export MCV="$MCV_RESOLVED" LOADER="$LOADER_VERSION" INSTALLER="$INSTALLER_VERSION"
mapfile -t FABRIC_VER < <(resolve_fabric_versions)
RESOLVED_LOADER="${FABRIC_VER[0]}"
RESOLVED_INSTALLER="${FABRIC_VER[1]}"
build_start_command
START_CMD_STR="${JAVA_CMD[*]}"

case "$ACTION" in
  install)
    install_fabric_server "$MCV_RESOLVED" "$RESOLVED_LOADER" "$RESOLVED_INSTALLER"
    ensure_eula
    install_mods "$MCV_RESOLVED"
    install_mcdr "$MCDR_VERSION"
    ensure_mcdr_config "$START_CMD_STR"
    echo "Install complete. Configure and start MCDReforged inside $SERVER_DIR."
    ;;
  update-mods)
    install_mods "$MCV_RESOLVED"
    echo "Mod update complete."
    ;;
  *)
    echo "Unknown action: $ACTION" >&2
    echo "Usage: $0 [install|update-mods]" >&2
    exit 1
    ;;
esac
