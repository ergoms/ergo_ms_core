# Чтение PORTABLE_*_ENABLED и прочих ключей из .env + env/*.env (без Django).

function Get-ErgoEnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $pattern = '^' + [regex]::Escape($Name) + '=(.*)$'
    $found = $null

    $files = @()
    $rootEnv = Join-Path $Root '.env'
    if (Test-Path -LiteralPath $rootEnv) {
        $files += $rootEnv
    }
    $envDir = Join-Path $Root 'env'
    if (Test-Path -LiteralPath $envDir) {
        $files += @(Get-ChildItem -LiteralPath $envDir -Filter '*.env' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*.example' } |
            Sort-Object Name |
            ForEach-Object { $_.FullName })
    }

    foreach ($envFile in $files) {
        foreach ($line in Get-Content -Path $envFile -Encoding UTF8) {
            if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match $pattern) {
                $found = $Matches[1].Trim().Trim('"').Trim("'")
            }
        }
    }
    return $found
}

function Test-ErgoEnvTruthy {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name,
        [bool]$Default = $false
    )

    $raw = Get-ErgoEnvValue -Root $Root -Name $Name
    if ($null -eq $raw -or [string]::IsNullOrWhiteSpace($raw)) {
        return $Default
    }
    return $raw.Trim().ToLower() -in @('1', 'true', 'yes', 'on')
}

function Test-PortablePythonEnabled {
    param([Parameter(Mandatory = $true)][string]$Root)
    return Test-ErgoEnvTruthy -Root $Root -Name 'PORTABLE_PYTHON_ENABLED' -Default $true
}

function Test-PortableNodejsEnabled {
    param([Parameter(Mandatory = $true)][string]$Root)
    return Test-ErgoEnvTruthy -Root $Root -Name 'PORTABLE_NODEJS_ENABLED' -Default $true
}
