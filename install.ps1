[CmdletBinding()]
param(
    [ValidateSet('install', 'update-mods')]
    [string]$Action = 'install'
)

$root = $PSScriptRoot
$configPath = Join-Path $root 'config\server.json'
$modManifestPath = Join-Path $root 'config\mods.json'

function Load-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Error "Config file not found: $Path"
        exit 1
    }
    try {
        return Get-Content $Path -Raw | ConvertFrom-Json
    }
    catch {
        Write-Error "Failed to parse JSON at ${Path}: $_"
        exit 1
    }
}

$config = Load-JsonFile $configPath
$serverDir = Join-Path $root $config.server_dir
$downloadsDir = Join-Path $serverDir 'downloads'
$modsDir = Join-Path $serverDir 'mods'
$pluginsDir = Join-Path $serverDir 'plugins'
$mcdrConfigDir = Join-Path $serverDir 'config'
$mcdrConfigPath = Join-Path $mcdrConfigDir 'config.yml'
$mcdrPermissionPath = Join-Path $mcdrConfigDir 'permission.yml'

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Assert-Command {
    param([string]$Name, [string]$Description)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Error "$Description ($Name) not found in PATH"
        exit 1
    }
}

function Download-File {
    param([string]$Url, [string]$Destination)
    Write-Host "Downloading $Url -> $Destination"
    Invoke-WebRequest -Uri $Url -OutFile $Destination
}

function Resolve-MinecraftVersion {
    param([string]$Version)
    if ($Version -ne 'latest') {
        return $Version
    }
    $response = Invoke-RestMethod -Uri 'https://meta.fabricmc.net/v2/versions/game'
    $stable = $response | Where-Object { $_.stable -eq $true } | Select-Object -First 1
    if (-not $stable) {
        throw 'Unable to resolve latest stable Minecraft version from Fabric meta API'
    }
    return $stable.version
}

function Resolve-FabricVersions {
    param(
        [string]$MinecraftVersion,
        [string]$LoaderVersion,
        [string]$InstallerVersion
    )
    $loaderResponse = Invoke-RestMethod -Uri "https://meta.fabricmc.net/v2/versions/loader/$MinecraftVersion"
    $loaderEntry = $loaderResponse | Select-Object -First 1
    if (-not $loaderEntry) {
        throw "Unable to resolve Fabric loader versions for Minecraft $MinecraftVersion"
    }
    $resolvedLoader = if ($LoaderVersion -eq 'latest') { $loaderEntry.loader.version } else { $LoaderVersion }

    $resolvedInstaller = $null
    if ($InstallerVersion -eq 'latest') {
        $installerResponse = Invoke-RestMethod -Uri 'https://meta.fabricmc.net/v2/versions/installer'
        $resolvedInstaller = ($installerResponse | Select-Object -First 1).version
    }
    else {
        $resolvedInstaller = $InstallerVersion
    }

    if (-not $resolvedInstaller) {
        throw 'Unable to resolve Fabric installer version (installer endpoint returned empty).'
    }

    return @{
        loader    = $resolvedLoader
        installer = $resolvedInstaller
    }
}

function Install-FabricServer {
    param(
        [string]$MinecraftVersion,
        [string]$LoaderVersion,
        [string]$InstallerVersion
    )

    Ensure-Dir $downloadsDir

    $installerName = "fabric-installer-$InstallerVersion.jar"
    $installerPath = Join-Path $downloadsDir $installerName
    if (-not (Test-Path $installerPath)) {
        $installerUrl = "https://maven.fabricmc.net/net/fabricmc/fabric-installer/$InstallerVersion/fabric-installer-$InstallerVersion.jar"
        Download-File -Url $installerUrl -Destination $installerPath
    }

    Push-Location $serverDir
    try {
        $args = @(
            '-jar', $installerPath,
            'server',
            '-mcversion', $MinecraftVersion,
            '-loader', $LoaderVersion,
            '-downloadMinecraft',
            '-dir', '.'
        )
        Write-Host "Running Fabric installer for $MinecraftVersion (loader $LoaderVersion, installer $InstallerVersion)"
        & java @args
    }
    finally {
        Pop-Location
    }
}

function Ensure-Eula {
    if (-not $config.accept_eula) {
        return
    }
    $eulaPath = Join-Path $serverDir 'eula.txt'
    if (-not (Test-Path $eulaPath)) {
        Set-Content -Path $eulaPath -Value 'eula=true'
    }
}

function Select-ModrinthVersion {
    param(
        [string]$Slug,
        [string]$MinecraftVersion
    )
    $query = "https://api.modrinth.com/v2/project/$Slug/version?loaders=[%22fabric%22]&game_versions=[%22$MinecraftVersion%22]"
    try {
        $versions = Invoke-RestMethod -Uri $query
    }
    catch {
        Write-Warning "Failed to query Modrinth for ${Slug}: $_"
        return $null
    }
    if (-not $versions) {
        Write-Warning "No Modrinth versions found for $Slug ($MinecraftVersion)"
        return $null
    }
    $release = $versions | Where-Object { $_.version_type -eq 'release' } | Select-Object -First 1
    if (-not $release) {
        $release = $versions | Select-Object -First 1
    }
    $file = $release.files | Where-Object { $_.primary -eq $true } | Select-Object -First 1
    if (-not $file) {
        $file = $release.files | Select-Object -First 1
    }
    if (-not $file) {
        Write-Warning "No files found for $Slug ($MinecraftVersion)"
        return $null
    }
    return @{
        version  = $release.version_number
        filename = $file.filename
        url      = $file.url
    }
}

function Install-Mods {
    param([string]$MinecraftVersion)
    if (-not (Test-Path $modManifestPath)) {
        Write-Warning "Mod manifest not found at $modManifestPath"
        return
    }
    $manifest = Load-JsonFile $modManifestPath
    if (-not $manifest.mods) {
        Write-Warning 'No mods defined in manifest'
        return
    }
    Ensure-Dir $modsDir
    foreach ($mod in $manifest.mods) {
        $slug = if ($mod.slug) { $mod.slug } elseif ($mod.id) { $mod.id } else { $null }
        if (-not $slug) {
            Write-Warning "Skipping manifest entry without slug/id: $mod"
            continue
        }
        $resolved = Select-ModrinthVersion -Slug $slug -MinecraftVersion $MinecraftVersion
        if (-not $resolved) {
            continue
        }
        $dest = Join-Path $modsDir $resolved.filename
        Get-ChildItem -Path $modsDir -Filter "$slug*.jar" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Download-File -Url $resolved.url -Destination $dest
        Write-Host "Installed $slug $($resolved.version)"
    }
}

function Install-MCDReforged {
    param([string]$Version)
    $package = if ($Version -eq 'latest') { 'mcdreforged' } else { "mcdreforged==$Version" }
    Write-Host "Installing $package via pip"
    & python -m pip install --upgrade --user $package
}

function Ensure-MCDRConfig {
    param([string]$StartCommand)
    Ensure-Dir $mcdrConfigDir
    $legacyPath = Join-Path $mcdrConfigDir 'mcdreforged\config.yml'
    $legacyPermissionPath = Join-Path $mcdrConfigDir 'mcdreforged\permission.yml'
    if (Test-Path $mcdrConfigPath) {
        Write-Host "MCDReforged config already exists at $mcdrConfigPath; leaving it unchanged."
        return
    } elseif (Test-Path $legacyPath) {
        Copy-Item -Path $legacyPath -Destination $mcdrConfigPath -Force
        Write-Host "Copied existing config from $legacyPath to $mcdrConfigPath"
    } else {
        $configContent = @"
language: en_us
encoding: utf8
working_directory: "."
start_command: $StartCommand
stop_command: stop
"@
        Set-Content -Path $mcdrConfigPath -Value $configContent -Encoding UTF8
        Write-Host "Created default MCDReforged config at $mcdrConfigPath"
    }

    if (-not (Test-Path $mcdrPermissionPath)) {
        if (Test-Path $legacyPermissionPath) {
            Copy-Item -Path $legacyPermissionPath -Destination $mcdrPermissionPath -Force
            Write-Host "Copied existing permission file from $legacyPermissionPath to $mcdrPermissionPath"
        } else {
            $permissionContent = @"
default:
  level: 0
players: {}
"@
            Set-Content -Path $mcdrPermissionPath -Value $permissionContent -Encoding UTF8
            Write-Host "Created default MCDReforged permission file at $mcdrPermissionPath"
        }
    }
}

Assert-Command -Name 'java' -Description 'Java runtime'
Assert-Command -Name 'python' -Description 'Python 3'

Ensure-Dir $serverDir
Ensure-Dir $downloadsDir
Ensure-Dir $modsDir
Ensure-Dir $pluginsDir

$mcVersion = Resolve-MinecraftVersion -Version $config.minecraft_version
$fabric = Resolve-FabricVersions -MinecraftVersion $mcVersion -LoaderVersion $config.fabric_loader_version -InstallerVersion $config.fabric_installer_version
$startCommand = @("java", "-Xmx$($config.java_memory)") + ($config.java_additional_args -split ' ' | Where-Object { $_ -ne '' }) + @("-jar", "fabric-server-launch.jar", "nogui")

switch ($Action) {
    'install' {
        Install-FabricServer -MinecraftVersion $mcVersion -LoaderVersion $fabric.loader -InstallerVersion $fabric.installer
        Ensure-Eula
        Install-Mods -MinecraftVersion $mcVersion
        Install-MCDReforged -Version $config.mcdreforged_version
        Ensure-MCDRConfig -StartCommand ($startCommand -join ' ')
        Write-Host "Install complete. Configure MCDReforged in $serverDir before starting."
    }
    'update-mods' {
        Install-Mods -MinecraftVersion $mcVersion
        Write-Host 'Mod update complete.'
    }
}
