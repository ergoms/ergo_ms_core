# Чтение PORTABLE_*_ENABLED из .env (без Django).

function Get-ErgoEnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $envFile = Join-Path $Root '.env'
    if (-not (Test-Path -LiteralPath $envFile)) { return $null }

    $pattern = '^' + [regex]::Escape($Name) + '=(.*)$'
    foreach ($line in Get-Content -Path $envFile -Encoding UTF8) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match $pattern) {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }
    return $null
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
