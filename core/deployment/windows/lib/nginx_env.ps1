# Effective nginx: NGINX_ENABLED или ERGO_PROXY=nginx (без Django).

function Test-NginxEnabled {
    param([string]$ProjectRoot)

    if (-not $ProjectRoot) {
        try { $ProjectRoot = Get-ProjectRoot } catch { return $false }
    }

    $envFile = Join-Path $ProjectRoot '.env'
    if (-not (Test-Path $envFile)) { return $false }

    $nginxEnabled = $null
    $ergoProxy = 'none'

    foreach ($line in Get-Content -Path $envFile -Encoding UTF8) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^NGINX_ENABLED=(.*)$') {
            $value = $Matches[1].Trim().Trim('"').Trim("'").ToLower()
            $nginxEnabled = $value -in @('1', 'true', 'yes', 'on')
        }
        elseif ($line -match '^ERGO_PROXY=(.*)$') {
            $ergoProxy = $Matches[1].Trim().Trim('"').Trim("'").ToLower()
        }
    }

    if ($null -ne $nginxEnabled) {
        return [bool]$nginxEnabled
    }
    return $ergoProxy -eq 'nginx'
}

function Write-NginxSkipClientMessage {
    param([string]$ProjectRoot)

    $publicHost = 'localhost'
    $envFile = Join-Path $ProjectRoot '.env'
    if (Test-Path $envFile) {
        foreach ($line in Get-Content -Path $envFile -Encoding UTF8) {
            if ($line -match '^NGINX_PUBLIC_HOST=(.*)$') {
                $publicHost = $Matches[1].Trim().Trim('"').Trim("'")
                break
            }
        }
    }

    Write-ColorOutput '[OK] ergo_ms_client_dev пропущен (ERGO_PROXY=nginx / NGINX_ENABLED, клиент отдаётся через nginx)' Green
    Write-ColorOutput "  Откройте: http://$publicHost" Cyan
    Write-ColorOutput '  После изменений UI: ergoms client-build && ergoms reload-nginx' Gray
}
