<#
.SYNOPSIS
Builds and runs the Logseq harbor stack: sync, web, one MCP container per graph, and a reverse proxy.

.DESCRIPTION
Reads config.yaml next to this script. Each entry under 'graphs' gets its own MCP container, host
port (12315, 12316, ...), volume and host directory under graphs_dir. 'web: false' skips the web
container. Secrets may also be set in the process environment, which overrides config.yaml.

The reverse proxy (logseq-proxy) listens on port 8080 and routes:
  /              web app
  /sync/         sync server
  /mcp           JSON list of running graphs
  /mcp/<route>   MCP server for that graph (route is the lowercase graph name with '-' separators)
Its config is generated into ~/logseq-harbor/proxy on every up and update.

HARBOR_RUNTIME (default: podman) and HARBOR_RUNTIME_ARGS (extra CLI arguments) select the
container CLI, e.g. HARBOR_RUNTIME_ARGS="--remote --connection podman-machine-default-root".

.PARAMETER Command
build  - build the sync, web and MCP images
up     - start sync and web, then one MCP container per graph
update - start MCP containers only for graphs in config.yaml that have no container yet
update clear - also remove MCP containers for graphs no longer in config.yaml (volumes are kept)
stop   - remove all harbor containers (volumes are kept)
status - list harbor containers and active MCP portals
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('build', 'up', 'update', 'stop', 'status')]
    [string]$Command = 'up',
    [Parameter(Position = 1)]
    [ValidateSet('clear')]
    [string]$Option
)

if ($Option -and $Command -ne 'update') { throw "'$Option' is only valid with 'update'" }

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$logseqSrc = if ($env:HARBOR_LOGSEQ_SRC) { $env:HARBOR_LOGSEQ_SRC } else { Join-Path (Split-Path $root -Parent) 'logseq' }
$runtime = if ($env:HARBOR_RUNTIME) { $env:HARBOR_RUNTIME } else { 'podman' }
$runtimeArgs = if ($env:HARBOR_RUNTIME_ARGS) { @($env:HARBOR_RUNTIME_ARGS -split ' ' | Where-Object { $_ }) } else { @() }

$network = 'harbor-net'
$syncImage = 'localhost/logseq-sync:latest'
$webImage = 'localhost/logseq-web:latest'
$mcpImage = 'localhost/logseq-mcp:latest'
$proxyImage = 'docker.io/library/nginx:alpine'
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
    LOGSEQ_E2EE_PASSWORD = 'logseq_e2ee_password'
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
            if ($line -match '^([a-z0-9_]+):\s*(.*?)\s*$') { $values[$matches[1]] = $matches[2].Trim('"', "'") }
        }
    }
    $values['graphs'] = @($graphs)
    return $values
}

function Get-HarborContainers {
    @(Invoke-Rt ps -a --format '{{.Names}}' | Where-Object { $_ -match '^logseq-(sync|web|proxy|mcp(-|$))' })
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

# Container and volume names cannot contain spaces, so they use a slug of the graph name.
function Get-GraphSlug([string]$Name) {
    ($Name -replace '[^A-Za-z0-9_-]+', '-').Trim('-')
}

# URL path segment for a graph: lowercase letters, digits and '-', e.g. 'Campaign - 7th Trial' -> 'campaign-7th-trial'.
function Get-RouteSlug([string]$Name) {
    ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
}

# Running MCP containers with the graph name and host port recorded when they were started.
function Get-McpPortals {
    $names = @(& $runtime @runtimeArgs ps --filter 'name=logseq-mcp-' --filter 'status=running' --format '{{.Names}}' 2>$null)
    foreach ($name in $names) {
        $envVars = @(& $runtime @runtimeArgs inspect --format '{{range .Config.Env}}{{println .}}{{end}}' $name)
        [pscustomobject]@{
            Container = $name
            Graph     = ($envVars | Where-Object { $_ -like 'LOGSEQ_GRAPH_NAME=*' }) -replace '^LOGSEQ_GRAPH_NAME=', ''
            Port      = [int](($envVars | Where-Object { $_ -like 'LOGSEQ_MCP_PUBLISHED_PORT=*' }) -replace '^LOGSEQ_MCP_PUBLISHED_PORT=', '')
        }
    }
}

# Writes the nginx config and the /mcp graph list into ~/logseq-harbor/proxy, then (re)starts logseq-proxy.
# It starts last because nginx resolves container names when it starts.
function Start-Proxy {
    $proxyDir = Resolve-HostPath '~/logseq-harbor/proxy'
    New-Item -ItemType Directory -Force -Path $proxyDir | Out-Null
    $webRunning = @(& $runtime @runtimeArgs ps --filter 'name=^logseq-web$' --filter 'status=running' --format '{{.Names}}' 2>$null).Count -gt 0
    $syncRunning = @(& $runtime @runtimeArgs ps --filter 'name=^logseq-sync$' --filter 'status=running' --format '{{.Names}}' 2>$null).Count -gt 0
    if (-not $syncRunning) { throw 'logseq-sync is not running; the proxy needs it' }

    # Upstreams keep the headers nginx drops when a location sets its own proxy_set_header.
    $common = @(
        'proxy_http_version 1.1;',
        'proxy_set_header Upgrade $http_upgrade;',
        'proxy_set_header Connection $connection_upgrade;',
        'proxy_set_header X-Forwarded-For $remote_addr;',
        'proxy_set_header X-Forwarded-Proto $scheme;',
        'proxy_buffering off;',
        'proxy_read_timeout 3600s;',
        'proxy_send_timeout 3600s;'
    ) | ForEach-Object { "        $_" }

    $locations = [System.Collections.Generic.List[string]]::new()
    $locations.Add((@(
        '    location = /mcp {',
        '        alias /etc/harbor-proxy/mcp-index.json;',
        '        default_type application/json;',
        '    }'
    ) -join "`n"))
    $index = [System.Collections.Generic.List[object]]::new()
    $routes = @{}
    foreach ($portal in @(Get-McpPortals | Sort-Object Graph)) {
        $route = Get-RouteSlug $portal.Graph
        if ($routes.ContainsKey($route)) { throw "graphs '$($routes[$route])' and '$($portal.Graph)' share the /mcp route '$route'" }
        $routes[$route] = $portal.Graph
        $index.Add([pscustomobject]@{ graph = $portal.Graph; route = $route; url = "http://localhost:$webPort/mcp/$route" })
        $locations.Add((@(
            "    location = /mcp/$route {",
            "        proxy_pass http://$($portal.Container):12315/mcp;",
            "        proxy_set_header Host localhost:$($portal.Port);"
        ) + $common + '    }') -join "`n")
    }

    $locations.Add((@(
        '    location = /sync {',
        '        return 308 $scheme://$http_host/sync/;',
        '    }',
        '    location /sync/ {',
        '        proxy_pass http://logseq-sync:8787;',
        '        proxy_set_header Host $host;'
    ) + $common + '    }') -join "`n")

    $locations.Add(
        $(if ($webRunning) {
            (@(
                '    location / {',
                '        proxy_pass http://logseq-web:80;',
                '        proxy_set_header Host $host;'
            ) + $common + '    }') -join "`n"
        } else {
            "    location / {`n        return 404;`n    }"
        })
    )

    $conf = @(
        'pid /tmp/nginx.pid;',
        'error_log /dev/stderr warn;',
        'events {}',
        'http {',
        '    access_log /dev/stdout;',
        '    map $http_upgrade $connection_upgrade { default upgrade; ''''  close; }',
        '    server {',
        '        listen 80;',
        '        client_max_body_size 0;',
        ($locations -join "`n"),
        '    }',
        '}'
    ) -join "`n"
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText((Join-Path $proxyDir 'nginx.conf'), "$conf`n", $utf8)
    $indexJson = if ($index.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject @($index) -Depth 3 }
    [IO.File]::WriteAllText((Join-Path $proxyDir 'mcp-index.json'), "$indexJson`n", $utf8)

    Remove-HarborContainers @('logseq-proxy')
    $proxyMount = $proxyDir -replace '\\', '/'
    Invoke-Rt run -d --name logseq-proxy --network $network --restart unless-stopped `
        -p "${webPort}:80" -v "${proxyMount}:/etc/harbor-proxy:ro" `
        $proxyImage nginx -g 'daemon off;' -c /etc/harbor-proxy/nginx.conf | Out-Null
    Write-Host "proxy on http://localhost:$webPort (/ web, /sync sync, /mcp graph list)"
}

function Start-Stack([switch]$McpOnly, [switch]$ClearStale) {
    $settings = Read-Settings
    $secrets = @{}
    foreach ($name in $secretNames) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not $value) { $value = $settings[$secretKeys[$name]] }
        if (-not $value -and $name -ne 'LOGSEQ_E2EE_PASSWORD') { throw "$($secretKeys[$name]) is not set in config.yaml" }
        $secrets[$name] = [string]$value
    }
    $graphs = @($settings['graphs'] | Where-Object { $_ })
    if ($graphs.Count -eq 0) { throw 'list at least one graph under graphs: in config.yaml' }
    foreach ($graph in $graphs) {
        if ($graph -match '[\\/:*?"<>|]' -or $graph -ne $graph.Trim() -or -not (Get-GraphSlug $graph)) {
            throw "graph '$graph' must be a valid folder name (no \ / : * ? `" < > |)"
        }
    }
    $routeOwners = @{}
    foreach ($graph in $graphs) {
        $route = Get-RouteSlug $graph
        if (-not $route) { throw "graph '$graph' has no characters usable in a /mcp route" }
        if ($routeOwners.ContainsKey($route)) { throw "graphs '$($routeOwners[$route])' and '$graph' share the /mcp route '$route'" }
        $routeOwners[$route] = $graph
    }
    $webEnabled = switch ($settings['web']) {
        { $_ -in 'true', $null, '' } { $true }
        'false' { $false }
        default { throw "web must be true or false in config.yaml, got '$($settings['web'])'" }
    }
    $graphsDir = Resolve-HostPath $(if ($settings['graphs_dir']) { $settings['graphs_dir'] } else { '~/logseq-harbor/graphs' })
    $syncDataDir = Resolve-HostPath $(if ($settings['sync_data_dir']) { $settings['sync_data_dir'] } else { '~/logseq-harbor/sync-data' })
    $baseUrl = if ($settings['db_sync_base_url']) { $settings['db_sync_base_url'] } else { "http://localhost:$syncPort" }

    foreach ($image in $syncImage, $webImage, $mcpImage) {
        if (-not (Test-Rt image inspect $image)) { throw "image $image not found; run 'harbor.ps1 build' first" }
    }

    # Secrets reach the containers through the environment, so they never appear on a command line.
    foreach ($name in $secretNames) { Set-Item -Path "env:$name" -Value $secrets[$name] }

    # 10.89.1.0/24 is the subnet allowed by harbor-forward.service on the Podman VM.
    if (-not (Test-Rt network inspect $network)) { Invoke-Rt network create --subnet 10.89.1.0/24 $network | Out-Null }
    if ($McpOnly) {
        $running = @(& $runtime @runtimeArgs ps --filter 'name=^logseq-sync$' --filter 'status=running' --format '{{.Names}}' 2>$null)
        if ($running -notcontains 'logseq-sync') { throw 'logseq-sync is not running; run harbor.ps1 up first' }
        if ($ClearStale) {
            # Removed before starting new ones so their host ports are free for reuse.
            $expected = @($graphs | ForEach-Object { 'logseq-mcp-' + (Get-GraphSlug $_) })
            $existing = @(& $runtime @runtimeArgs ps -a --filter 'name=^logseq-mcp-' --format '{{.Names}}' 2>$null)
            $stale = @($existing | Where-Object { $expected -notcontains $_ })
            if ($stale.Count -gt 0) {
                Remove-HarborContainers $stale
                Write-Host "removed MCP containers for graphs no longer in config.yaml: $($stale -join ', ')"
            }
        }
        Start-McpContainers $graphs $graphsDir -OnlyMissing
        Start-Proxy
        Show-McpPortals
        return
    }

    New-Item -ItemType Directory -Force -Path $syncDataDir | Out-Null
    Remove-HarborContainers (@('logseq-sync', 'logseq-web', 'logseq-proxy', 'logseq-mcp') + @($graphs | ForEach-Object { 'logseq-mcp-' + (Get-GraphSlug $_) }))

    Invoke-Rt run -d --name logseq-sync --network $network --restart unless-stopped `
        -p "${syncPort}:8787" `
        -e DB_SYNC_PORT=8787 -e "DB_SYNC_BASE_URL=$baseUrl" -e DB_SYNC_DATA_DIR=/app/data `
        -e DB_SYNC_STORAGE_DRIVER=sqlite -e DB_SYNC_ASSETS_DRIVER=filesystem -e DB_SYNC_LOG_LEVEL=info `
        -e DB_SYNC_ADMIN_TOKEN `
        -e "COGNITO_ISSUER=$cognitoIssuer" -e "COGNITO_CLIENT_ID=$cognitoClientId" `
        -e "COGNITO_JWKS_URL=$cognitoIssuer/.well-known/jwks.json" `
        -v "$($syncDataDir -replace '\\', '/'):/app/data" --read-only --tmpfs /tmp --cap-drop ALL `
        --security-opt no-new-privileges:true $syncImage | Out-Null
    Wait-ForSync
    Write-Host "sync on http://localhost:$syncPort"

    if ($webEnabled) {
        # The web app is reached through logseq-proxy, so it publishes no host port of its own.
        Invoke-Rt run -d --name logseq-web --network $network --restart unless-stopped $webImage | Out-Null
        Write-Host 'web container started (reached through the proxy)'
    } else {
        Write-Host 'web disabled in config.yaml'
    }

    Start-McpContainers $graphs $graphsDir
    Start-Proxy
    Show-McpPortals
}

function Start-McpContainers([string[]]$Graphs, [string]$GraphsDir, [switch]$OnlyMissing) {
    # update must not reuse a port held by a running portal, so it takes the first free one.
    $usedPorts = @()
    if ($OnlyMissing) {
        $usedPorts = @(& $runtime @runtimeArgs ps --filter 'name=logseq-mcp-' --format '{{.Ports}}' 2>$null |
            ForEach-Object { if ($_ -match ':(\d+)->') { [int]$Matches[1] } })
    }
    $nextFree = $mcpBasePort
    for ($i = 0; $i -lt $Graphs.Count; $i++) {
        $graph = $Graphs[$i]
        $slug = Get-GraphSlug $graph
        if ($OnlyMissing) {
            $running = @(& $runtime @runtimeArgs ps --filter "name=^logseq-mcp-$slug$" --filter 'status=running' --format '{{.Names}}' 2>$null)
            if ($running.Count -gt 0) { continue }
            Remove-HarborContainers @("logseq-mcp-$slug") 
        }
        if ($OnlyMissing) {
            while ($usedPorts -contains $nextFree) { $nextFree++ }
            $port = $nextFree
            $usedPorts += $port
        } else {
            $port = $mcpBasePort + $i
        }
        $volume = "mcp-data-$slug"
        $hostDir = Join-Path $GraphsDir $graph
        New-Item -ItemType Directory -Force -Path $hostDir | Out-Null
        # Podman accepts forward slashes for Windows host paths.
        $hostMount = $hostDir -replace '\\', '/'
        Ensure-Volume $volume
        Invoke-Rt run -d --name "logseq-mcp-$slug" --network $network --restart unless-stopped `
            --shm-size 1gb -p "${port}:12315" -v "${volume}:/data" `
            -v "${hostMount}:/data/home/logseq/graphs/$graph" `
            -e LOGSEQ_MCP_ENABLED=true -e LOGSEQ_MCP_HOST=0.0.0.0 -e LOGSEQ_MCP_PORT=12315 `
            -e LOGSEQ_MCP_TOKEN -e LOGSEQ_USERNAME -e LOGSEQ_PASSWORD -e LOGSEQ_E2EE_PASSWORD `
            -e "LOGSEQ_GRAPH_NAME=$graph" -e "LOGSEQ_MCP_PUBLISHED_PORT=$port" -e "COGNITO_CLIENT_ID=$cognitoClientId" `
            -e SYNC_SERVER_URL=http://logseq-sync:8787 $mcpImage | Out-Null
        Write-Host "started MCP container for '$graph'"
    }
}

function Show-McpPortals {
    $portals = @(Get-McpPortals)
    if ($portals.Count -eq 0) { Write-Host 'no active MCP portals'; return }
    Write-Host 'Active MCP portals:'
    foreach ($portal in $portals) {
        Write-Host "  '$($portal.Graph)' -> http://localhost:$webPort/mcp/$(Get-RouteSlug $portal.Graph)  (direct: http://localhost:$($portal.Port)/mcp)"
    }
}

try {
    switch ($Command) {
        'build' { Build-Images }
        'up' { Start-Stack }
        'update' { Start-Stack -McpOnly -ClearStale:($Option -eq 'clear') }
        'stop' {
            $names = Get-HarborContainers
            if ($names.Count -eq 0) { Write-Host 'no harbor containers' } else { Remove-HarborContainers $names }
        }
        'status' {
            Invoke-Rt ps -a --filter 'name=logseq-' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
            Show-McpPortals
        }
    }
} finally {
    foreach ($name in $secretNames) { Remove-Item -Path "env:$name" -ErrorAction SilentlyContinue }
}
