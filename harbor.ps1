<#
.SYNOPSIS
Builds and runs the Logseq harbor stack: sync, web, and one MCP container per graph.

.DESCRIPTION
Reads config.yaml next to this script. Each entry under 'graphs' gets its own MCP container, host
port (12315, 12316, ...), volume and host directory under graphs_dir. 'web: false' skips the web
container. Secrets may also be set in the process environment, which overrides config.yaml.

HARBOR_RUNTIME (default: podman) and HARBOR_RUNTIME_ARGS (extra CLI arguments) select the
container CLI, e.g. HARBOR_RUNTIME_ARGS="--remote --connection podman-machine-default-root".

.PARAMETER Command
build  - build the sync, web and MCP images
up     - start sync and web, then one MCP container per graph
stop   - remove all harbor containers (volumes are kept)
status - list harbor containers
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('build', 'up', 'stop', 'status')]
    [string]$Command = 'up'
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$logseqSrc = if ($env:HARBOR_LOGSEQ_SRC) { $env:HARBOR_LOGSEQ_SRC } else { Join-Path (Split-Path $root -Parent) 'logseq' }
$runtime = if ($env:HARBOR_RUNTIME) { $env:HARBOR_RUNTIME } else { 'podman' }
$runtimeArgs = if ($env:HARBOR_RUNTIME_ARGS) { @($env:HARBOR_RUNTIME_ARGS -split ' ' | Where-Object { $_ }) } else { @() }

$network = 'harbor-net'
# Existing sync volume from the compose era. Renaming it would orphan the sync graph data.
$syncVolume = 'logseq-harbor_logseq-db'
$syncImage = 'localhost/logseq-sync:latest'
$webImage = 'localhost/logseq-web:latest'
$mcpImage = 'localhost/logseq-mcp:latest'
$syncPort = 8787
$webPort = 8080
$mcpBasePort = 12315
$cognitoClientId = '69cs1lgme7p8kbgld8n5kseii6'
$cognitoIssuer = 'https://cognito-idp.us-east-1.amazonaws.com/us-east-1_dtagLnju8'
$secretKeys = [ordered]@{
    DB_SYNC_ADMIN_TOKEN = 'db_sync_admin_token'
    LOGSEQ_MCP_TOKEN    = 'logseq_mcp_token'
    LOGSEQ_USERNAME     = 'logseq_username'
    LOGSEQ_PASSWORD     = 'logseq_password'
}
$secretNames = @($secretKeys.Keys)

function Invoke-Rt {
    & $runtime @runtimeArgs @args
    if ($LASTEXITCODE -ne 0) { throw "$runtime $($args -join ' ') failed (exit $LASTEXITCODE)" }
}

function Test-Rt {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $runtime @runtimeArgs @args *> $null
    $ErrorActionPreference = $previous
    return $LASTEXITCODE -eq 0
}

# Reads the flat subset of YAML used by config.yaml: top-level 'key: value' pairs and a 'graphs:' list.
function Read-Settings {
    $configFile = Join-Path $root 'config.yaml'
    $values = @{}
    $graphs = [System.Collections.Generic.List[string]]::new()
    $inGraphs = $false
    if (Test-Path -LiteralPath $configFile) {
        foreach ($line in Get-Content -LiteralPath $configFile) {
            if ($line -notmatch '\S' -or $line -match '^\s*#') { continue }
            if ($line -match '^graphs:\s*$') { $inGraphs = $true; continue }
            if ($inGraphs -and $line -match '^\s+-\s*(.+?)\s*$') {
                $graphs.Add($matches[1].Trim('"', "'"))
                continue
            }
            $inGraphs = $false
            if ($line -match '^([a-z_]+):\s*(.*?)\s*$') { $values[$matches[1]] = $matches[2].Trim('"', "'") }
        }
    }
    $values['graphs'] = @($graphs)
    return $values
}

function Get-HarborContainers {
    @(Invoke-Rt ps -a --format '{{.Names}}' | Where-Object { $_ -match '^logseq-(sync|web|mcp(-|$))' })
}

function Remove-HarborContainers([string[]]$Names) {
    foreach ($name in $Names) {
        if (Test-Rt container inspect $name) { Invoke-Rt rm -f $name | Out-Null }
    }
}

function Ensure-Volume([string]$Name) {
    if (-not (Test-Rt volume inspect $Name)) { Invoke-Rt volume create $Name | Out-Null }
}

function Build-Images {
    if (-not (Test-Path -LiteralPath $logseqSrc)) {
        throw "logseq source not found at $logseqSrc (set HARBOR_LOGSEQ_SRC)"
    }
    $builds = @(
        @{ Image = $syncImage; Context = Join-Path $root 'sync' },
        @{ Image = $webImage; Context = Join-Path $root 'web' },
        @{ Image = $mcpImage; Context = Join-Path $root 'mcp' }
    )
    foreach ($build in $builds) {
        Invoke-Rt build --network host --build-context "logseq=$logseqSrc" -t $build.Image $build.Context
    }
}

function Wait-ForSync {
    for ($i = 0; $i -lt 60; $i++) {
        try {
            Invoke-WebRequest -Uri "http://localhost:$syncPort" -UseBasicParsing -TimeoutSec 3 | Out-Null
            return
        } catch {
            if ($_.Exception.Response) { return }
        }
        Start-Sleep -Seconds 2
    }
    throw "sync did not answer on port $syncPort"
}

function Resolve-HostPath([string]$Path) {
    if ($Path -eq '~' -or $Path -match '^~[\\/]') { $Path = Join-Path $HOME $Path.Substring(1).TrimStart('\', '/') }
    return [IO.Path]::GetFullPath($Path)
}

function Start-Stack {
    $settings = Read-Settings
    $secrets = @{}
    foreach ($name in $secretNames) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not $value) { $value = $settings[$secretKeys[$name]] }
        if (-not $value) { throw "$($secretKeys[$name]) is not set in config.yaml" }
        $secrets[$name] = $value
    }
    $graphs = @($settings['graphs'] | Where-Object { $_ })
    if ($graphs.Count -eq 0) { throw 'list at least one graph under graphs: in config.yaml' }
    foreach ($graph in $graphs) {
        if ($graph -notmatch '^[A-Za-z0-9_-]+$') {
            throw "graph '$graph' may only contain letters, digits, '-' and '_'"
        }
    }
    $webEnabled = switch ($settings['web']) {
        { $_ -in 'true', $null, '' } { $true }
        'false' { $false }
        default { throw "web must be true or false in config.yaml, got '$($settings['web'])'" }
    }
    $graphsDir = Resolve-HostPath $(if ($settings['graphs_dir']) { $settings['graphs_dir'] } else { '~/logseq-harbor/graphs' })
    $baseUrl = if ($settings['db_sync_base_url']) { $settings['db_sync_base_url'] } else { "http://localhost:$syncPort" }

    foreach ($image in $syncImage, $webImage, $mcpImage) {
        if (-not (Test-Rt image inspect $image)) { throw "image $image not found; run 'harbor.ps1 build' first" }
    }

    # Secrets reach the containers through the environment, so they never appear on a command line.
    foreach ($name in $secretNames) { Set-Item -Path "env:$name" -Value $secrets[$name] }

    # 10.89.1.0/24 is the subnet allowed by harbor-forward.service on the Podman VM.
    if (-not (Test-Rt network inspect $network)) { Invoke-Rt network create --subnet 10.89.1.0/24 $network | Out-Null }
    Ensure-Volume $syncVolume
    Remove-HarborContainers (@('logseq-sync', 'logseq-web', 'logseq-mcp') + @($graphs | ForEach-Object { "logseq-mcp-$_" }))

    Invoke-Rt run -d --name logseq-sync --network $network --restart unless-stopped `
        -p "${syncPort}:8787" `
        -e DB_SYNC_PORT=8787 -e "DB_SYNC_BASE_URL=$baseUrl" -e DB_SYNC_DATA_DIR=/app/data `
        -e DB_SYNC_STORAGE_DRIVER=sqlite -e DB_SYNC_ASSETS_DRIVER=filesystem -e DB_SYNC_LOG_LEVEL=info `
        -e DB_SYNC_ADMIN_TOKEN `
        -e "COGNITO_ISSUER=$cognitoIssuer" -e "COGNITO_CLIENT_ID=$cognitoClientId" `
        -e "COGNITO_JWKS_URL=$cognitoIssuer/.well-known/jwks.json" `
        -v "${syncVolume}:/app/data" --read-only --tmpfs /tmp --cap-drop ALL `
        --security-opt no-new-privileges:true $syncImage | Out-Null
    Wait-ForSync
    Write-Host "sync on http://localhost:$syncPort"

    if ($webEnabled) {
        Invoke-Rt run -d --name logseq-web --network $network --restart unless-stopped `
            -p "${webPort}:80" $webImage | Out-Null
        Write-Host "web on http://localhost:$webPort"
    } else {
        Write-Host 'web disabled in config.yaml'
    }

    for ($i = 0; $i -lt $graphs.Count; $i++) {
        $graph = $graphs[$i]
        $port = $mcpBasePort + $i
        $volume = "mcp-data-$graph"
        $hostDir = Join-Path $graphsDir $graph
        New-Item -ItemType Directory -Force -Path $hostDir | Out-Null
        # Podman accepts forward slashes for Windows host paths.
        $hostMount = $hostDir -replace '\\', '/'
        Ensure-Volume $volume
        Invoke-Rt run -d --name "logseq-mcp-$graph" --network $network --restart unless-stopped `
            --shm-size 1gb -p "${port}:12315" -v "${volume}:/data" `
            -v "${hostMount}:/data/home/logseq/graphs/$graph" `
            -e LOGSEQ_MCP_ENABLED=true -e LOGSEQ_MCP_HOST=0.0.0.0 -e LOGSEQ_MCP_PORT=12315 `
            -e LOGSEQ_MCP_TOKEN -e LOGSEQ_USERNAME -e LOGSEQ_PASSWORD `
            -e "LOGSEQ_GRAPH_NAME=$graph" -e "LOGSEQ_MCP_PUBLISHED_PORT=$port" -e "COGNITO_CLIENT_ID=$cognitoClientId" `
            -e SYNC_SERVER_URL=http://logseq-sync:8787 $mcpImage | Out-Null
        Write-Host "mcp for '$graph' on http://localhost:$port/mcp (files in $hostDir)"
    }
}

try {
    switch ($Command) {
        'build' { Build-Images }
        'up' { Start-Stack }
        'stop' {
            $names = Get-HarborContainers
            if ($names.Count -eq 0) { Write-Host 'no harbor containers' } else { Remove-HarborContainers $names }
        }
        'status' { Invoke-Rt ps -a --filter 'name=logseq-' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' }
    }
} finally {
    foreach ($name in $secretNames) { Remove-Item -Path "env:$name" -ErrorAction SilentlyContinue }
}
