$ErrorActionPreference = "Stop"
try {
    & "$env:SystemRoot\System32\chcp.com" 65001 > $null
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. "$ScriptDir\lib.ps1"

Set-Location $RootDir

function Read-JsoncFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    # Remove // comments
    $raw = $raw -replace '(?m)^\s*//.*$', ''
    # Remove /* */ comments
    $raw = $raw -replace '(?s)/\*.*?\*/', ''
    # Remove trailing commas
    $raw = $raw -replace ',(\s*[}\]])', '$1'
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Get-RequiredExtensions {
    $recommended = New-Object System.Collections.Generic.List[string]
    $local = New-Object System.Collections.Generic.List[string]

    # 1) Recommendations (.vscode/extensions.json) — считаем рекомендованными (не критичными)
    $extJson = Join-Path $RootDir ".vscode\extensions.json"
    try {
        $obj = Read-JsoncFile -Path $extJson
        if ($obj -and $obj.recommendations) {
            foreach ($id in @($obj.recommendations)) {
                if (-not [string]::IsNullOrWhiteSpace($id)) {
                    $recommended.Add($id.Trim()) | Out-Null
                }
            }
        }
    } catch {
        Log ("[WARNING] Не удалось прочитать .vscode/extensions.json: " + $_.Exception.Message)
    }

    # 2) Local extensions shipped with project (.vscode/extensions/*/package.json) — считаем критичными
    $extDir = Join-Path $RootDir ".vscode\extensions"
    if (Test-Path -LiteralPath $extDir) {
        $pkgFiles = Get-ChildItem -LiteralPath $extDir -Recurse -Filter "package.json" -ErrorAction SilentlyContinue
        foreach ($pkg in $pkgFiles) {
            try {
                $p = Read-JsoncFile -Path $pkg.FullName
                if ($p -and $p.publisher -and $p.name) {
                    $id = ("{0}.{1}" -f $p.publisher, $p.name).Trim()
                    if ($id) { $local.Add($id) | Out-Null }
                }
            } catch { }
        }
    }

    $recU = $recommended | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique
    $locU = $local | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique
    return @{ recommended = $recU; local = $locU }
}

function Get-InstalledExtensions {
    if (-not (Get-Command "code" -ErrorAction SilentlyContinue)) { return $null }
    try {
        $lines = & code --list-extensions --show-versions 2>$null
        if (-not $lines) { return @() }
        $ids = @()
        foreach ($ln in @($lines)) {
            $t = ($ln + "").Trim()
            if (-not $t) { continue }
            # Strip "@version" if present
            $id = ($t -split '@')[0].Trim()
            if ($id) { $ids += $id.ToLowerInvariant() }
        }
        return ,($ids | Sort-Object -Unique)
    } catch {
        Log ("[WARNING] Не удалось получить список расширений через code --list-extensions: " + $_.Exception.Message)
        return $null
    }
}

function Get-InstalledExtensionsFromDirs {
    # Fallback: parse extension folder names in user profile (VS Code / Cursor)
    $userHome = $env:USERPROFILE
    if (-not $userHome) { return @() }
    $dirs = @(
        (Join-Path $userHome ".vscode\extensions"),
        (Join-Path $userHome ".cursor\extensions")
    )
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $items = Get-ChildItem -LiteralPath $d -Directory -ErrorAction SilentlyContinue
        foreach ($it in $items) {
            $name = ($it.Name + "").Trim()
            if (-not $name) { continue }
            # Folder convention: publisher.name-version (version may include prerelease/build)
            if ($name -match '^(.+)-\d+\.\d+\.\d+.*$') {
                $id = $Matches[1]
                if ($id) { $out.Add($id.ToLowerInvariant()) | Out-Null }
            }
        }
    }
    return ,($out.ToArray() | Sort-Object -Unique)
}

function Test-HttpServerResponds {
    param([Parameter(Mandatory=$true)][string]$Url, [int]$TimeoutSec = 2)

    try {
        $resp = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        return $true
    } catch {
        # For non-200 responses Invoke-WebRequest throws; if there is an HTTP response, server is alive.
        try {
            if ($_.Exception.Response) { return $true }
        } catch { }
        return $false
    }
}

function Show-ExtensionsStatus {
    param(
        [string[]]$RequiredLocal,
        [string[]]$RequiredRecommended,
        [string[]]$Installed
    )

    $items = New-Object System.Collections.Generic.List[object]

    foreach ($id in @($RequiredLocal)) {
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $status = if ($Installed -eq $null) { "unknown" } elseif ($id -in $Installed) { "installed" } else { "missing" }
        $items.Add([pscustomobject]@{
            Type   = "local(required)"
            Id     = $id
            Status = $status
        }) | Out-Null
    }

    foreach ($id in @($RequiredRecommended)) {
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $status = if ($Installed -eq $null) { "unknown" } elseif ($id -in $Installed) { "installed" } else { "missing" }
        $items.Add([pscustomobject]@{
            Type   = "marketplace(recommended)"
            Id     = $id
            Status = $status
        }) | Out-Null
    }

    if ($items.Count -eq 0) { return }

    Step "Статус расширений: список и статус каждого"

    foreach ($it in ($items | Sort-Object Type, Id)) {
        $line = ("- [{0}] {1} — {2}" -f $it.Status.ToUpperInvariant(), $it.Id, $it.Type)
        $color = switch ($it.Status) {
            "installed" { "Green" }
            "missing" { "Red" }
            default { "Yellow" }
        }
        Write-Host $line -ForegroundColor $color
        if ($it.Status -eq "installed") {
            Log ("[OK] " + $line)
        } elseif ($it.Status -eq "missing") {
            Log ("[WARNING] " + $line)
        } else {
            Log ("[WARNING] " + $line)
        }
    }
}

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "=   Проверка VS Code расширений (наличие/OK)    =" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

Step "1. Проверка доступности VS Code CLI (code)"
if (Get-Command "code" -ErrorAction SilentlyContinue) {
    try {
        $ver = & code --version 2>$null
        if ($ver) { Log ("[OK] code --version: " + (($ver | Select-Object -First 1) -join "")) }
    } catch {
        Log ("[WARNING] code --version завершился с ошибкой: " + $_.Exception.Message)
    }
} else {
    Log "[WARNING] Команда 'code' не найдена в PATH. Переключаемся на проверку по директориям расширений пользователя."
}

Step "2. Проверка наличия расширений (локальные обязательные + marketplace рекомендованные)"
$required = Get-RequiredExtensions
$requiredLocal = @()
foreach ($x in @($required.local)) { $requiredLocal += $x }
$requiredRecommended = @()
foreach ($x in @($required.recommended)) { $requiredRecommended += $x }
$installed = Get-InstalledExtensions
if ($installed -eq $null) { $installed = Get-InstalledExtensionsFromDirs }

if (-not $requiredLocal -or $requiredLocal.Count -eq 0) {
    Log "[WARNING] Не найден список локальных обязательных расширений (.vscode/extensions/*)."
} else { Log ("Локальные обязательные расширения: " + ($requiredLocal -join ", ")) }

if ($requiredRecommended -and $requiredRecommended.Count -gt 0) {
    Log ("Marketplace рекомендованные расширения: " + ($requiredRecommended -join ", "))
}

if ($installed -eq $null) {
    Log "[WARNING] Не удалось получить список установленных расширений."
} else {
    Log ("Установленные расширения (кол-во=" + $installed.Count + "): " + (($installed | Select-Object -First 20) -join ", ") + $(if ($installed.Count -gt 20) { ", ..." } else { "" }))
}

$missingLocal = @()
$missingRecommended = @()
if ($installed -ne $null) {
    if ($requiredLocal) { $missingLocal = @($requiredLocal | Where-Object { $_ -notin $installed }) }
    if ($requiredRecommended) { $missingRecommended = @($requiredRecommended | Where-Object { $_ -notin $installed }) }

    if ($missingLocal.Count -eq 0) { Log "[OK] Все локальные обязательные расширения установлены." }
    else { Log ("[WARNING] Отсутствуют локальные обязательные расширения: " + ($missingLocal -join ", ")) }

    if ($missingRecommended.Count -gt 0) {
        Log ("[WARNING] Отсутствуют рекомендованные расширения (может быть допустимо): " + ($missingRecommended -join ", "))
    }
}

Show-ExtensionsStatus -RequiredLocal $requiredLocal -RequiredRecommended $requiredRecommended -Installed $installed

Step "3. Валидация работоспособности расширения автоматизации (HTTP 127.0.0.1:45678)"
# user-config extension поднимает HTTP сервер, который используют тесты Run-Task/Stop-AllErgoms.
$alive = Test-HttpServerResponds -Url "http://127.0.0.1:45678/run-task" -TimeoutSec 2
if ($alive) {
    Log "[OK] HTTP сервер расширения отвечает (порт 45678)."
} else {
    Log "[WARNING] HTTP сервер расширения НЕ отвечает (порт 45678). Расширение может быть не активно/IDE не запущена."
}

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "=     Проверка VS Code расширений завершена     =" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

# Локальные расширения проекта — обязательны (иначе тесты Run-Task/мульти-терминал нестабильны).
if ($missingLocal -and $missingLocal.Count -gt 0) {
    Log ("[WARNING] Не установлены локальные расширения проекта: " + ($missingLocal -join ", "))
}
