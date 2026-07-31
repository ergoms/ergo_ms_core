# Удаление расширения ERGO MS Tasks

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExtensionNames = @(
    "ergo-ms.ergo-ms-tasks",
    "multi-terminal",
    "tasks"
)
$LegacyPrefixes = @(
    "ergo-ms.ergo-ms-tasks-",
    "ergo-ms.ergo-ms-multi-terminal-"
)

$IdeModule = Join-Path $ScriptDir "lib\ide.ps1"

function Remove-TaskExtensionDirs {
    param([string[]]$Dirs)
    $removed = 0
    foreach ($extDir in $Dirs) {
        if (-not (Test-Path $extDir)) { continue }
        foreach ($name in $ExtensionNames) {
            $target = Join-Path $extDir $name
            if (Test-Path $target) {
                Remove-Item -Recurse -Force $target
                Write-Host "[OK] Удалено из: $extDir ($name)" -ForegroundColor Green
                $removed++
            }
        }
        Get-ChildItem -Path $extDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($prefix in $LegacyPrefixes) {
                if ($_.Name.StartsWith($prefix)) {
                    Remove-Item -Recurse -Force $_.FullName
                    Write-Host "[OK] Удалено из: $($_.FullName)" -ForegroundColor Green
                    $removed++
                }
            }
        }
    }
    return $removed
}

if (Test-Path $IdeModule) {
    . $IdeModule

    Write-Host "========================================"
    Write-Host "  Удаление расширения ERGO MS Tasks"
    Write-Host "========================================"
    Write-Host ""

    $count = Remove-TaskExtensionDirs -Dirs (Get-AllExtensionsDirs)
    if ($count -gt 0) {
        Write-Host ""
        Write-Host "[SUCCESS] Расширение удалено!" -ForegroundColor Green
        Write-Host "Перезапустите VS Code/Cursor для применения." -ForegroundColor Yellow
    } else {
        Write-Host "[WARN] Расширение не было найдено" -ForegroundColor Yellow
    }
} else {
    Write-Host "[INFO] Удаление расширения из всех IDE..." -ForegroundColor Cyan

    $dirs = @(
        (Join-Path $env:USERPROFILE ".cursor-server\extensions"),
        (Join-Path $env:USERPROFILE ".cursor\extensions"),
        (Join-Path $env:USERPROFILE ".vscode-server\extensions"),
        (Join-Path $env:USERPROFILE ".vscode\extensions")
    )

    Remove-TaskExtensionDirs -Dirs $dirs | Out-Null

    Write-Host ""
    Write-Host "[SUCCESS] Готово! Перезапустите VS Code/Cursor." -ForegroundColor Green
}
