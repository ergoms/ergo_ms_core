# =============================================================================
# Централизованный модуль для определения IDE и путей расширений
# Поддерживает: VS Code, Cursor (локальный и remote/server режим)
# =============================================================================

function Get-CurrentIDE {
    <#
    .SYNOPSIS
    Определяет текущую IDE по переменным окружения и процессам
    #>
    
    # Cursor
    if ($env:CURSOR_TRACE_ID -or $env:TERM_PROGRAM -eq "cursor") {
        return "cursor"
    }
    
    # VS Code
    if ($env:VSCODE_INJECTION -or $env:TERM_PROGRAM -eq "vscode" -or $env:VSCODE_GIT_IPC_HANDLE) {
        return "vscode"
    }
    
    # Проверяем по процессам
    $cursorProcess = Get-Process -Name "Cursor" -ErrorAction SilentlyContinue
    if ($cursorProcess) {
        return "cursor"
    }
    
    $codeProcess = Get-Process -Name "Code" -ErrorAction SilentlyContinue
    if ($codeProcess) {
        return "vscode"
    }
    
    return "unknown"
}

function Get-IDEMode {
    <#
    .SYNOPSIS
    Определяет режим работы (local/remote)
    #>
    
    # Remote режим - проверяем SSH
    if ($env:SSH_CONNECTION -or $env:SSH_CLIENT) {
        return "remote"
    }
    
    # Проверяем наличие server папок
    $cursorServer = Join-Path $env:USERPROFILE ".cursor-server"
    $vscodeServer = Join-Path $env:USERPROFILE ".vscode-server"
    
    if ((Test-Path $cursorServer) -or (Test-Path $vscodeServer)) {
        return "remote"
    }
    
    return "local"
}

function Get-ExtensionsDir {
    <#
    .SYNOPSIS
    Возвращает путь к папке расширений для указанной IDE
    #>
    param(
        [string]$IDE = ""
    )
    
    if (-not $IDE) {
        $IDE = Get-CurrentIDE
    }
    
    $mode = Get-IDEMode
    $dir = $null
    
    switch ($IDE) {
        "cursor" {
            $serverPath = Join-Path $env:USERPROFILE ".cursor-server\extensions"
            $localPath = Join-Path $env:USERPROFILE ".cursor\extensions"
            
            if ($mode -eq "remote" -and (Test-Path (Split-Path $serverPath -Parent))) {
                $dir = $serverPath
            } elseif (Test-Path (Split-Path $localPath -Parent)) {
                $dir = $localPath
            }
        }
        "vscode" {
            $serverPath = Join-Path $env:USERPROFILE ".vscode-server\extensions"
            $localPath = Join-Path $env:USERPROFILE ".vscode\extensions"
            
            if ($mode -eq "remote" -and (Test-Path (Split-Path $serverPath -Parent))) {
                $dir = $serverPath
            } elseif (Test-Path (Split-Path $localPath -Parent)) {
                $dir = $localPath
            }
        }
    }
    
    # Если не нашли - пробуем все варианты
    if (-not $dir) {
        $candidates = @(
            (Join-Path $env:USERPROFILE ".cursor-server\extensions"),
            (Join-Path $env:USERPROFILE ".cursor\extensions"),
            (Join-Path $env:USERPROFILE ".vscode-server\extensions"),
            (Join-Path $env:USERPROFILE ".vscode\extensions")
        )
        
        foreach ($candidate in $candidates) {
            if (Test-Path (Split-Path $candidate -Parent)) {
                $dir = $candidate
                break
            }
        }
    }
    
    # Создаём папку если не существует
    if (-not $dir) {
        $dir = Join-Path $env:USERPROFILE ".vscode\extensions"
    }
    
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    
    return $dir
}

function Get-AllExtensionsDirs {
    <#
    .SYNOPSIS
    Возвращает все пути к папкам расширений (для установки во все IDE)
    #>
    
    $dirs = @()
    
    # Cursor Server (remote)
    $cursorServerParent = Join-Path $env:USERPROFILE ".cursor-server"
    if (Test-Path $cursorServerParent) {
        $dir = Join-Path $cursorServerParent "extensions"
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $dirs += $dir
    }
    
    # Cursor (local)
    $cursorParent = Join-Path $env:USERPROFILE ".cursor"
    if (Test-Path $cursorParent) {
        $dir = Join-Path $cursorParent "extensions"
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $dirs += $dir
    }
    
    # VS Code Server (remote)
    $vscodeServerParent = Join-Path $env:USERPROFILE ".vscode-server"
    if (Test-Path $vscodeServerParent) {
        $dir = Join-Path $vscodeServerParent "extensions"
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $dirs += $dir
    }
    
    # VS Code (local) - всегда добавляем как fallback
    $vscodeDir = Join-Path $env:USERPROFILE ".vscode\extensions"
    if (-not (Test-Path $vscodeDir)) {
        New-Item -ItemType Directory -Path $vscodeDir -Force | Out-Null
    }
    $dirs += $vscodeDir
    
    # Возвращаем уникальные пути
    return $dirs | Select-Object -Unique
}

function Install-ExtensionAll {
    <#
    .SYNOPSIS
    Устанавливает расширение во все доступные IDE
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$SourceDir,
        
        [Parameter(Mandatory=$true)]
        [string]$ExtensionName
    )
    
    $installed = 0
    $allDirs = Get-AllExtensionsDirs
    
    foreach ($extDir in $allDirs) {
        $target = Join-Path $extDir $ExtensionName
        
        # Удаляем старую версию
        if (Test-Path $target) {
            Remove-Item -Recurse -Force $target
        }
        
        # Пробуем создать symlink
        try {
            New-Item -ItemType SymbolicLink -Path $target -Target $SourceDir -ErrorAction Stop | Out-Null
            Write-Host "[OK] Установлено (symlink) в: $extDir" -ForegroundColor Green
            $installed++
        } catch {
            # Если symlink не удался - копируем
            try {
                Copy-Item -Recurse -Force $SourceDir $target
                Write-Host "[OK] Установлено (копия) в: $extDir" -ForegroundColor Green
                $installed++
            } catch {
                Write-Host "[WARN] Не удалось установить в: $extDir" -ForegroundColor Yellow
            }
        }
    }
    
    if ($installed -eq 0) {
        Write-Host "[ERROR] Расширение не было установлено ни в одну IDE" -ForegroundColor Red
        return $false
    }
    
    return $true
}

function Uninstall-ExtensionAll {
    <#
    .SYNOPSIS
    Удаляет расширение из всех IDE
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$ExtensionName
    )
    
    $removed = 0
    $allDirs = Get-AllExtensionsDirs
    
    foreach ($extDir in $allDirs) {
        $target = Join-Path $extDir $ExtensionName
        
        if (Test-Path $target) {
            Remove-Item -Recurse -Force $target
            Write-Host "[OK] Удалено из: $extDir" -ForegroundColor Green
            $removed++
        }
    }
    
    Write-Host "[INFO] Удалено из $removed расположений" -ForegroundColor Cyan
    return $true
}

function Show-IDEInfo {
    <#
    .SYNOPSIS
    Выводит информацию о текущей IDE
    #>
    
    $ide = Get-CurrentIDE
    $mode = Get-IDEMode
    $extDir = Get-ExtensionsDir
    
    Write-Host "IDE: $ide" -ForegroundColor Cyan
    Write-Host "Режим: $mode" -ForegroundColor Cyan
    Write-Host "Папка расширений: $extDir" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Все папки расширений:" -ForegroundColor Yellow
    
    foreach ($dir in (Get-AllExtensionsDirs)) {
        if (Test-Path $dir) {
            Write-Host "  [EXISTS] $dir" -ForegroundColor Green
        } else {
            Write-Host "  [MISSING] $dir" -ForegroundColor Gray
        }
    }
}

# Если скрипт вызван напрямую
if ($MyInvocation.InvocationName -ne '.') {
    $action = $args[0]
    
    switch ($action) {
        "info" { Show-IDEInfo }
        "extensions-dir" { Get-ExtensionsDir -IDE $args[1] }
        "all-extensions-dirs" { Get-AllExtensionsDirs }
        default {
            Write-Host "Использование: ide.ps1 [info|extensions-dir|all-extensions-dirs]" -ForegroundColor Cyan
            Show-IDEInfo
        }
    }
}

