# Удаление расширения Multi-Terminal Tasks

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExtensionName = "multi-terminal"

# Подключаем модуль IDE (локальный)
$IdeModule = Join-Path $ScriptDir "lib\ide.ps1"

if (Test-Path $IdeModule) {
    . $IdeModule
    
    Write-Host "========================================"
    Write-Host "  Удаление расширения Multi-Terminal"
    Write-Host "========================================"
    Write-Host ""
    
    if (Uninstall-ExtensionAll -ExtensionName $ExtensionName) {
        Write-Host ""
        Write-Host "[SUCCESS] Расширение удалено!" -ForegroundColor Green
        Write-Host "Перезапустите VS Code/Cursor для применения." -ForegroundColor Yellow
    } else {
        Write-Host "[WARN] Расширение не было найдено" -ForegroundColor Yellow
    }
} else {
    # Fallback
    Write-Host "[INFO] Удаление расширения из всех IDE..." -ForegroundColor Cyan
    
    $dirs = @(
        (Join-Path $env:USERPROFILE ".cursor-server\extensions"),
        (Join-Path $env:USERPROFILE ".cursor\extensions"),
        (Join-Path $env:USERPROFILE ".vscode-server\extensions"),
        (Join-Path $env:USERPROFILE ".vscode\extensions")
    )
    
    foreach ($dir in $dirs) {
        $target = Join-Path $dir $ExtensionName
        if (Test-Path $target) {
            Remove-Item -Recurse -Force $target
            Write-Host "[OK] Удалено из: $dir" -ForegroundColor Green
        }
    }
    
    Write-Host ""
    Write-Host "[SUCCESS] Готово! Перезапустите VS Code/Cursor." -ForegroundColor Green
}
