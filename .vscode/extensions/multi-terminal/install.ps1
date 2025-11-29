# Установка расширения Multi-Terminal Tasks

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExtensionName = "multi-terminal"

# Подключаем модуль IDE (локальный)
$IdeModule = Join-Path $ScriptDir "lib\ide.ps1"

if (Test-Path $IdeModule) {
    . $IdeModule
    
    Write-Host "========================================"
    Write-Host "  Установка расширения Multi-Terminal"
    Write-Host "========================================"
    Write-Host ""
    
    # Показываем информацию об IDE
    Show-IDEInfo
    Write-Host ""
    
    # Устанавливаем во все IDE
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
        Write-Host "Использование в tasks.json:" -ForegroundColor Cyan
        Write-Host ""
        Write-Host '  {'
        Write-Host '    "label": "My Multi-Terminal Task",'
        Write-Host '    "type": "multi-terminal",'
        Write-Host '    "source": {'
        Write-Host '      "file": "celery_workers.yaml",'
        Write-Host '      "path": "workers"'
        Write-Host '    },'
        Write-Host '    "commandTemplate": "ergoms start-worker --worker=${key}",'
        Write-Host '    "nameTemplate": "Worker: ${key}"'
        Write-Host '  }'
    } else {
        Write-Host ""
        Write-Host "[ERROR] Ошибка установки" -ForegroundColor Red
        exit 1
    }
} else {
    # Fallback - если модуль не найден
    Write-Host "[WARN] Модуль IDE не найден, используем fallback..." -ForegroundColor Yellow
    
    # Определяем папку расширений
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
    
    $TargetDir = Join-Path $ExtensionsDir $ExtensionName
    
    # Удаляем старую версию
    if (Test-Path $TargetDir) {
        Remove-Item -Recurse -Force $TargetDir
    }
    
    # Создаём symlink или копируем
    try {
        New-Item -ItemType SymbolicLink -Path $TargetDir -Target $ScriptDir -ErrorAction Stop | Out-Null
    } catch {
        Copy-Item -Recurse -Force $ScriptDir $TargetDir
    }
    
    Write-Host "[SUCCESS] Установлено в: $ExtensionsDir" -ForegroundColor Green
    Write-Host "Перезапустите VS Code/Cursor для активации." -ForegroundColor Yellow
}
