# Minecraft Fabric Server Scripts

- Cross-platform scripts to bootstrap a Fabric server with Modrinth mods and MCDReforged as the default wrapper.
- Default behavior pulls the latest stable Minecraft/Fabric versions and installs a starter Modrinth modset.

## Prerequisites
- Java 17 or 21 in `PATH`.
- Python 3.10+ with `pip` (needed for MCDReforged and JSON parsing in Linux script).
- Windows: PowerShell 7+; Linux: bash, curl (wget also works if you swap curl in the script).

## Quick start
- Windows: `powershell -ExecutionPolicy Bypass -File install.ps1`
- Linux: `chmod +x install.sh && ./install.sh`
- Mod updates only: `install.ps1 -Action update-mods` or `./install.sh update-mods`
- Start: `.\start.ps1` or `./start.sh`
  - Add `-Direct` or `--direct` to start the Fabric server without MCDReforged.

## What the scripts do
- Resolve latest Minecraft/Fabric versions via Fabric meta (or use the versions you set in `config/server.json`).
- Download and run the Fabric installer into `server/`.
- Accept the EULA automatically if `accept_eula` is true in `config/server.json`.
- Download Modrinth mods listed in `config/mods.json` into `server/mods/`.
- Install MCDReforged via `pip` (user install).

## Layout and config
- `config/server.json`: global settings (versions, memory flags, EULA). Default server directory is `server/`.
- `config/mods.json`: Modrinth mod list. Each entry supports `slug` or `id`; `version` is usually `latest`.
- `server/`: created by the install scripts; contains Fabric server files, `mods/`, `downloads/`, and runtime output.

## MCDReforged setup
- The scripts install the MCDReforged package but do not generate its config for you.
- Create `server/config/mcdreforged/config.yml` (or `server/config/config.yml`) using MCDReforged's template, and set `start_command` to the Java line you want. With defaults this is:
  - `java -Xmx2G -jar fabric-server-launch.jar nogui`
  - Include any `java_additional_args` you set in `config/server.json`.
- Once the config exists, `start.ps1` / `start.sh` will launch MCDReforged from `server/`. If no config is found, the scripts will tell you and you can rerun with `-Direct`/`--direct` to bypass MCDReforged.

## Mod manifest format (`config/mods.json`)
- Example:
```json
{
  "mods": [
    { "slug": "fabric-api", "version": "latest" },
    { "slug": "sodium", "version": "latest" },
    { "slug": "lithium", "version": "latest" },
    { "slug": "starlight", "version": "latest" }
  ]
}
```
- Mods are pulled from Modrinth with loader `fabric` and the target Minecraft version. Existing jars matching the slug prefix are removed before download to avoid duplicates.

## Tips and next steps
- Update `java_memory` / `java_additional_args` in `config/server.json` to match your host.
- Add or remove mods in `config/mods.json`, then rerun `update-mods`.
- Keep Java and Python on your PATH; the scripts stop early if either is missing.
- The install scripts use live network calls (Fabric meta, Modrinth); ensure outbound HTTPS is allowed when running them.
