$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. "$ScriptDir\lib.ps1"

Set-Location $RootDir

function Get-ServicesFromErgoSync {
    param([Parameter(Mandatory=$true)][string]$Target)
    $syncScript = Join-Path $RootDir "core\deployment\scripts\sync_vscode_logs_services.py"
    $python = Join-Path $RootDir "virtual_env\python\Scripts\python.exe"
    if (-not (Test-Path $python) -or -not (Test-Path $syncScript)) {
        return @()
    }
    $jsonText = & $python $syncScript --json $Target 2>$null
    if (-not $jsonText) { return @() }
    try {
        $payload = $jsonText | ConvertFrom-Json
    } catch {
        return @()
    }
    if (-not $payload.services) { return @() }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($item in $payload.services) {
        if ($item.key) { $out.Add([string]$item.key) | Out-Null }
    }
    return ,$out.ToArray()
}

function Get-KeysFromYamlMap {
    param(
        [Parameter(Mandatory=$true)][string]$YamlPath,
        [Parameter(Mandatory=$true)][string]$RootKey,
        [int]$Indent = 2
    )
    if (-not (Test-Path $YamlPath)) { return @() }
    $lines = Get-Content -LiteralPath $YamlPath -ErrorAction SilentlyContinue
    if (-not $lines) { return @() }

    $inRoot = $false
    $out = New-Object System.Collections.Generic.List[string]
    $reRoot = '^\s*' + [regex]::Escape($RootKey) + ':\s*$'
    $reKey = '^\s{' + $Indent + '}([A-Za-z0-9_-]+):\s*$'

    foreach ($line in $lines) {
        if ($line -match $reRoot) { $inRoot = $true; continue }
        if (-not $inRoot) { continue }
        if ($line -match '^[A-Za-z0-9_-]+:\s*$') { break }
        if ($line -match $reKey) { $out.Add($Matches[1]) | Out-Null }
    }
    return ,$out.ToArray()
}

function Get-WorkersFromWorkersYaml {
    $yamlPath = Join-Path $RootDir "celery_workers.yaml"
    return Get-KeysFromYamlMap -YamlPath $yamlPath -RootKey "workers" -Indent 2
}

function Test-VsCodeTaskLogsAllServices {
    $services = Get-ServicesFromErgoSync -Target "logs"
    $workers = Get-WorkersFromWorkersYaml

    if (-not $services -or $services.Count -eq 0) {
        Log "[WARNING] В ergo-sync target logs не найдено services"
    } else {
        Log ("Services из ergo-sync logs: " + ($services -join ", "))
    }

    if (-not $workers -or $workers.Count -eq 0) {
        Log "[WARNING] В celery_workers.yaml не найдено workers: ключей"
    } else {
        Log ("Workers из celery_workers.yaml: " + ($workers -join ", "))
    }

    $allOk = $true

    foreach ($svc in $services) {
        Log ("VSCode task Logs: команда: ergoms logs " + $svc + " 50")
        if (-not (Test-ErgomsLogs -ServiceName $svc -Lines 50)) {
            $allOk = $false
            Log ("[WARNING] logs для " + $svc + " не отработал")
        }
    }

    foreach ($w in $workers) {
        $name = ("ergo_ms_celery_worker_" + $w)
        Log ("VSCode task Logs: команда: ergoms logs " + $name + " 50")
        if (-not (Test-ErgomsLogs -ServiceName $name -Lines 50)) {
            $allOk = $false
            Log ("[WARNING] logs для " + $name + " не отработал")
        }
    }

    return $allOk
}

Step "VS Code task: Logs: All Services (эмуляция multi-terminal)"
if (Test-VsCodeTaskLogsAllServices) {
    Log "Logs: All Services: OK"
} else {
    Log "[WARNING] Logs: All Services: есть ошибки"
}
