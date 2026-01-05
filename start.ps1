[CmdletBinding()]
param(
    [switch]$Direct
)

$root = $PSScriptRoot
$configPath = Join-Path $root 'config\server.json'

function Load-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Error "Config file not found: $Path"
        exit 1
    }
    return Get-Content $Path -Raw | ConvertFrom-Json
}

$config = Load-JsonFile $configPath
$serverDir = Join-Path $root $config.server_dir
$javaMemory = $config.java_memory
$javaArgs = $config.java_additional_args

if (-not (Test-Path $serverDir)) {
    Write-Error "Server directory not found at $serverDir. Run install.ps1 first."
    exit 1
}

function Build-JavaCommand {
    $args = @("java", "-Xmx$javaMemory")
    if ($javaArgs -and $javaArgs.Trim().Length -gt 0) {
        $args += $javaArgs.Split(' ')
    }
    $args += @("-jar", "fabric-server-launch.jar", "nogui")
    return $args
}

function Start-DirectServer {
    Push-Location $serverDir
    try {
        $cmd = Build-JavaCommand
        & $cmd
    } finally {
        Pop-Location
    }
}

function Start-MCDReforged {
    $mcdrConfigPaths = @(
        (Join-Path -Path $serverDir -ChildPath 'config\config.yml')
        (Join-Path -Path $serverDir -ChildPath 'config\mcdreforged\config.yml')
    )
    $mcdrConfig = $mcdrConfigPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $mcdrConfig) {
        Write-Warning "MCDReforged config not found. Create one in server/config/mcdreforged/config.yml."
        Write-Warning ("Set start_command to: {0}" -f ((Build-JavaCommand) -join ' '))
        return
    }
    $mcdrPermission = Join-Path -Path (Split-Path -Parent $mcdrConfig) -ChildPath 'permission.yml'
    if (-not (Test-Path $mcdrPermission)) {
        $permissionContent = @"
default:
  level: 0
players: {}
"@
        Set-Content -Path $mcdrPermission -Value $permissionContent -Encoding UTF8
        Write-Host "Created default MCDReforged permission file at $mcdrPermission"
    }
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Write-Error 'Python not found. Install Python 3 to run MCDReforged or use -Direct.'
        exit 1
    }
    Push-Location $serverDir
    try {
        Write-Host "Starting MCDReforged using config $mcdrConfig (permission $mcdrPermission)"
        & python -m mcdreforged start --config $mcdrConfig --permission $mcdrPermission
    } finally {
        Pop-Location
    }
}

if ($Direct) {
    Start-DirectServer
} else {
    Start-MCDReforged
}
