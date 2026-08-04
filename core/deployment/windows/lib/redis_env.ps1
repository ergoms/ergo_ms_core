# Effective Redis: REDIS_ENABLED или ERGO_BROKER=redis (без Django).

function Test-RedisEnabled {
    param([string]$ProjectRoot)

    if (-not $ProjectRoot) {
        try { $ProjectRoot = Get-ProjectRoot } catch { return $false }
    }

    $envFile = Join-Path $ProjectRoot '.env'
    if (-not (Test-Path $envFile)) { return $false }

    $redisEnabled = $null
    $ergoBroker = 'local'

    foreach ($line in Get-Content -Path $envFile -Encoding UTF8) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^REDIS_ENABLED=(.*)$') {
            $value = $Matches[1].Trim().Trim('"').Trim("'").ToLower()
            $redisEnabled = $value -in @('1', 'true', 'yes', 'on')
        }
        elseif ($line -match '^ERGO_BROKER=(.*)$') {
            $ergoBroker = $Matches[1].Trim().Trim('"').Trim("'").ToLower()
        }
    }

    if ($null -ne $redisEnabled) {
        return [bool]$redisEnabled
    }
    return $ergoBroker -eq 'redis'
}
