﻿$ErrorActionPreference = "Stop"
try {
    & "$env:SystemRoot\System32\chcp.com" 65001 > $null
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RootDir = (Resolve-Path "$ScriptDir\..\..\..\..\..").ProviderPath
$TestLogFile = Join-Path $RootDir "logs\test.log"

function Ensure-LogDir {
    $logDir = Split-Path $TestLogFile -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
}

function Log {
    param([string]$Message)
    Ensure-LogDir
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $line
    Add-Content -Path $TestLogFile -Value $line -Encoding UTF8
}

function Step {
    param([string]$Message)
    Ensure-LogDir
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
    Add-Content -Path $TestLogFile -Value "" -Encoding UTF8
    Add-Content -Path $TestLogFile -Value "=== $Message ===" -Encoding UTF8
}

function Stop-AllErgoms {
    Log "Остановка всех процессов ergoms и служб..."
    Set-Location $RootDir

    $services = Get-Service -Name "ergo-*" -ErrorAction SilentlyContinue
    foreach ($svc in $services) {
        try {
            Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction Stop
        } catch {
            Log ("[WARNING] Не удалось отключить автозапуск службы " + $svc.Name + ". Продолжаем.")
        }

        if ($svc.Status -ne 'Stopped') {
            try {
                Stop-Service -Name $svc.Name -Force -ErrorAction Stop
            } catch {
                Log ("[WARNING] Не удалось остановить службу " + $svc.Name + ". Продолжаем.")
            }
        }
    }

    # Пытаемся остановить через ergoms stop
    if (Get-Command ergoms -ErrorAction SilentlyContinue) {
        ergoms stop
        ergoms stop-ollama
    }

    Start-Sleep -Seconds 3
}

function Require-InstallReadyForLaunch {
    Log "Проверка готовности к запуску: структура проекта, venv, ergoms, службы."
    
    if (-not (Get-Command ergoms -ErrorAction SilentlyContinue)) {
        throw "ergoms не найден в PATH. Выполните установку CLI."
    }
    
    if (-not (Test-Path "$RootDir\core\api") -or -not (Test-Path "$RootDir\core\client")) {
        throw "Нет каталогов core/api или core/client. Выполните ergoms setup."
    }
    
    if (-not (Test-Path "$RootDir\virtual_env\python\Scripts\activate.ps1")) {
        throw "Нет virtual_env/python. Выполните ergoms setup или ergoms install-deps."
    }
    
    if (-not (Test-Path "$RootDir\node_modules") -and -not (Test-Path "$RootDir\core\client\node_modules")) {
        throw "Нет node_modules. Выполните ergoms setup / ergoms npm install."
    }
    
    Log "► Готовность к запуску служб: OK."
}

function Test-ServiceAction {
    param(
        [string]$Action,
        [string]$ServiceName
    )
    
    if ($Action -eq "start") {
        Start-Service -Name $ServiceName -ErrorAction Stop
    } elseif ($Action -eq "stop") {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    } elseif ($Action -eq "status") {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc) {
            Log ("Статус " + $ServiceName + ": " + $svc.Status)
        } else {
            Log ("Служба " + $ServiceName + " не найдена")
        }
    }
}

function Run-CeleryWorkerInspectPing {
    Set-Location "$RootDir\core\api"
    $pythonExe = "$RootDir\virtual_env\python\Scripts\python.exe"
    $env:PYTHONPATH = $RootDir
    Log "Выполнение celery inspect ping..."
    $process = Start-Process -FilePath $pythonExe -ArgumentList "-m celery -A src.config.celery.celery_app inspect ping --timeout 8" -Wait -NoNewWindow -PassThru
    return ($process.ExitCode -eq 0)
}

function Run-CeleryBeatShowNextTasks {
    Set-Location $RootDir
    Log "Выполнение ergoms api show_next_tasks..."
    $process = Start-Process -FilePath "ergoms.cmd" -ArgumentList "api show_next_tasks --count 5" -Wait -NoNewWindow -PassThru
    return ($process.ExitCode -eq 0)
}

function Run-Task {
    param(
        [string]$Label,
        [switch]$InParallel
    )
    
    $tasksFile = "$RootDir\.vscode\tasks.json"
    if (-not (Test-Path $tasksFile)) {
        throw "Файл tasks.json не найден"
    }
    
    # Читаем JSON, убирая комментарии
    $jsonContent = Get-Content $tasksFile -Raw
    $jsonContent = $jsonContent -replace '(?m)^\s*//.*$', ''
    $tasksObj = $jsonContent | ConvertFrom-Json
    
    $task = $tasksObj.tasks | Where-Object { $_.label -eq $Label }
    if (-not $task) {
        throw ("Задача '" + $Label + "' не найдена в tasks.json")
    }
    
    Log ("Запуск задачи: " + $Label)
    
    if ($task.command) {
        $cmd = $task.command
        if ($task.windows -and $task.windows.command) {
            $cmd = $task.windows.command
        }
        $cmd = $cmd.Replace('${workspaceFolder}', $RootDir)
        Log ("Выполнение команды: " + $cmd)
        
        if ($InParallel) {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c $cmd" -WindowStyle Hidden
        } else {
            Invoke-Expression $cmd
        }
        return
    }
    
    if ($task.type -eq "multi-terminal") {
        Log ("Multi-terminal задача '" + $Label + "' (пропускаем сложную эмуляцию, запускаем напрямую если нужно)")
        # В Windows для тестов можно просто пропустить или реализовать базово
        return
    }
    
    if ($task.dependsOn) {
        $order = "parallel"
        if ($task.dependsOrder) {
            $order = $task.dependsOrder
        }
        Log ("Задача '" + $Label + "' имеет dependsOn (порядок: " + $order + ")")
        
        foreach ($dep in $task.dependsOn) {
            if ($order -eq "sequence") {
                Run-Task -Label $dep
            } else {
                Run-Task -Label $dep -InParallel
            }
        }
        
        if ($order -eq "parallel") {
            Log "Ожидание параллельных задач (5 сек)..."
            Start-Sleep -Seconds 5
        }
        return
    }
    
    throw ("Задача '" + $Label + "' не имеет command или dependsOn")
}