# Установка расширения ERGO MS Tasks

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExtensionName = "ergo-ms.ergo-ms-tasks"
$LegacyExact = @("multi-terminal", "tasks")
$LegacyPrefixes = @("ergo-ms.ergo-ms-multi-terminal-")

# Подключаем модуль IDE (локальный)
$IdeModule = Join-Path $ScriptDir "lib\ide.ps1"

function Remove-LegacyTaskExtensions {
    param([string[]]$Dirs)
    foreach ($extDir in $Dirs) {
        if (-not (Test-Path $extDir)) { continue }
        foreach ($name in $LegacyExact) {
            $target = Join-Path $extDir $name
            if (Test-Path $target) {
                Remove-Item -Recurse -Force $target
                Write-Host "[OK] Удалено устаревшее: $target" -ForegroundColor DarkYellow
            }
        }
        Get-ChildItem -Path $extDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($prefix in $LegacyPrefixes) {
                if ($_.Name.StartsWith($prefix)) {
                    Remove-Item -Recurse -Force $_.FullName
                    Write-Host "[OK] Удалено устаревшее: $($_.FullName)" -ForegroundColor DarkYellow
                }
            }
        }
    }
}

if (Test-Path $IdeModule) {
    . $IdeModule

    Write-Host "========================================"
    Write-Host "  Установка расширения ERGO MS Tasks"
    Write-Host "========================================"
    Write-Host ""

    Show-IDEInfo
    Write-Host ""

    Remove-LegacyTaskExtensions -Dirs (Get-AllExtensionsDirs)

    Write-Host "Установка расширения..." -ForegroundColor Cyan
    Write-Host ""

    if (Install-ExtensionAll -SourceDir $ScriptDir -ExtensionName $ExtensionName) {
        Write-Host ""
        Write-Host "========================================"
        Write-Host "[SUCCESS] Расширение установлено!" -ForegroundColor Green
        Write-Host "========================================"
        Write-Host ""
        Write-Host "Перезапустите VS Code/Cursor для активации." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Использование: multi-terminal в tasks.json и modules/<name>/vscode.tasks.yaml" -ForegroundColor Cyan
    } else {
        Write-Host ""
        Write-Host "[ERROR] Ошибка установки" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "[WARN] Модуль IDE не найден, используем fallback..." -ForegroundColor Yellow

    $candidates = @(
        (Join-Path $env:USERPROFILE ".cursor-server\extensions"),
        (Join-Path $env:USERPROFILE ".cursor\extensions"),
        (Join-Path $env:USERPROFILE ".vscode-server\extensions"),
        (Join-Path $env:USERPROFILE ".vscode\extensions")
    )

    $ExtensionsDir = $null
    foreach ($candidate in $candidates) {
        $parent = Split-Path $candidate -Parent
        if (Test-Path $parent) {
            $ExtensionsDir = $candidate
            if (-not (Test-Path $ExtensionsDir)) {
                New-Item -ItemType Directory -Path $ExtensionsDir -Force | Out-Null
            }
            break
        }
    }

    if (-not $ExtensionsDir) {
        $ExtensionsDir = Join-Path $env:USERPROFILE ".vscode\extensions"
        New-Item -ItemType Directory -Path $ExtensionsDir -Force | Out-Null
    }

    Remove-LegacyTaskExtensions -Dirs @($ExtensionsDir)

    $TargetDir = Join-Path $ExtensionsDir $ExtensionName

    if (Test-Path $TargetDir) {
        Remove-Item -Recurse -Force $TargetDir
    }

    try {
        New-Item -ItemType SymbolicLink -Path $TargetDir -Target $ScriptDir -ErrorAction Stop | Out-Null
    } catch {
        Copy-Item -Recurse -Force $ScriptDir $TargetDir
    }

    Write-Host "[SUCCESS] Установлено в: $ExtensionsDir" -ForegroundColor Green
    Write-Host "Перезапустите VS Code/Cursor для активации." -ForegroundColor Yellow
}
