# Service management functions

# Функции управления службами



function Install-Service {

    param(

        [string]$ServiceName,

        [string]$Root,

        [string]$NssmExe

    )

    

    # Check if service already exists

    $existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

    if ($existingService) {

        Write-ColorOutput "-> Служба $ServiceName уже существует, переустановка..." Yellow

        

        # Stop service only if it's running

        if ($existingService.Status -eq 'Running') {

            Write-ColorOutput "   Остановка службы..." Gray

            & $NssmExe stop $ServiceName 2>$null

            Start-Sleep -Seconds 2

        }

        

        # Remove service

        Write-ColorOutput "   Удаление службы..." Gray

        & $NssmExe remove $ServiceName confirm 2>$null

        Start-Sleep -Seconds 2

    }



    $corePath = Join-Path $Root "core"

    $pythonExe = Join-Path $Root "virtual_env\python\Scripts\python.exe"

    $displayName = "Ergo MS - $ServiceName"



    Write-ColorOutput "-> Установка службы: $ServiceName" Cyan



    $useDirectPython = $false

    $appPath = $null

    $appParams = $null



    if ($ServiceName -eq 'ergo-celery-beat') {

        # Используем общий скрипт запуска Beat, чтобы логика кэшей и логирование

        # совпадали с ergoms start-beat / start_celery_beat.py

        $useDirectPython = $true

        $appPath = $pythonExe

        $appParams = "api\scripts\start_celery_beat.py"

    }

    elseif ($ServiceName -eq 'ergo-client-dev') {

        $useDirectPython = $true

        $appPath = $pythonExe

        $appParams = "core\deployment\scripts\start_client_if_dev.py"

    }

    elseif ($ServiceName -match '^ergo-celery-worker-(.+)$') {

        $useDirectPython = $true

        $workerName = $Matches[1]

        $appPath = $pythonExe

        $appParams = "api\scripts\start_celery_worker.py --worker=$workerName"

    }



    if ($useDirectPython -and (Test-Path $pythonExe)) {

        & $NssmExe install $ServiceName $appPath

        & $NssmExe set $ServiceName AppParameters $appParams

    }

    else {

        $wrapperPath = New-ServiceWrapper -ServiceName $ServiceName -Root $Root

        & $NssmExe install $ServiceName $wrapperPath

    }

    & $NssmExe set $ServiceName DisplayName $displayName

    & $NssmExe set $ServiceName Description "Ergo Management System - $ServiceName"

    if ($ServiceName -eq 'ergo-client-dev') {

        & $NssmExe set $ServiceName AppDirectory $Root

    }

    else {

        & $NssmExe set $ServiceName AppDirectory (Join-Path $Root "core")

    }

    $logsDir = Get-ProjectLogsDir -ProjectRoot $Root

    # Redirect both stdout and stderr to the same file (single log per service)

    $singleLog = Join-Path $logsDir "${ServiceName}.log"

    & $NssmExe set $ServiceName AppStdout $singleLog

    & $NssmExe set $ServiceName AppStderr $singleLog

    # Ensure UTF-8 and unbuffered output (fixes delayed/blocked logs in Celery)

    & $NssmExe set $ServiceName AppEnvironmentExtra "PYTHONIOENCODING=UTF-8" "PYTHONUTF8=1" "PYTHONUNBUFFERED=1"

    

    # Set service to auto-start

    & $NssmExe set $ServiceName Start SERVICE_AUTO_START



    # Set restart policy

    & $NssmExe set $ServiceName AppExit Default Restart

    & $NssmExe set $ServiceName AppRestartDelay 5000



    Write-ColorOutput "[OK] Служба $ServiceName установлена" Green

}



function Disable-ClientServiceIfNginx {

    param([string]$ProjectRoot)



    if (-not (Test-NginxEnabled -ProjectRoot $ProjectRoot)) {

        return

    }



    $service = Get-Service -Name 'ergo-client-dev' -ErrorAction SilentlyContinue

    if ($service -and $service.Status -ne 'Stopped') {

        Stop-Service -Name 'ergo-client-dev' -Force -ErrorAction SilentlyContinue

    }



    Write-NginxSkipClientMessage -ProjectRoot $ProjectRoot

}



function Install-AllServices {

    param([string]$Root)



    Test-ProjectStructure -Root $Root

    

    # Create logs directory

    $logsDir = Get-ProjectLogsDir -ProjectRoot $Root

    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null



    # Install NSSM

    $nssmExe = Install-NSSM -Root $Root



    if (Test-NginxEnabled -ProjectRoot $Root) {

        Disable-ClientServiceIfNginx -ProjectRoot $Root

    }



    # Get service names dynamically based on config

    $serviceNames = Get-ServiceNames -ProjectRoot $Root

    

    Write-ColorOutput "Установка служб: $($serviceNames -join ', ')" Cyan

    

    foreach ($serviceName in $serviceNames) {

        Install-Service -ServiceName $serviceName -Root $Root -NssmExe $nssmExe

    }



    Write-ColorOutput "`n[OK] Все службы успешно установлены" Green

    Write-ColorOutput "Каталог логов: $logsDir" Cyan

}



function Install-SingleService {

    param(

        [string]$ServiceName,

        [string]$Root

    )



    if ($ServiceName -eq 'ergo-client-dev' -and (Test-NginxEnabled -ProjectRoot $Root)) {

        Disable-ClientServiceIfNginx -ProjectRoot $Root

        return

    }



    Test-ProjectStructure -Root $Root

    

    # Create logs directory

    $logsDir = Get-ProjectLogsDir -ProjectRoot $Root

    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null



    # Install NSSM

    $nssmExe = Install-NSSM -Root $Root



    # Install single service

    Install-Service -ServiceName $ServiceName -Root $Root -NssmExe $nssmExe



    Write-ColorOutput "`n[OK] Служба $ServiceName успешно установлена" Green

    Write-ColorOutput "Каталог логов: $logsDir" Cyan

}



# Установка всех воркеров из конфигурации

function Install-WorkerServices {

    param([string]$Root)



    Test-ProjectStructure -Root $Root

    

    # Create logs directory

    $logsDir = Get-ProjectLogsDir -ProjectRoot $Root

    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null



    # Install NSSM

    $nssmExe = Install-NSSM -Root $Root



    # Get worker service names

    $workerServices = Get-WorkerServiceNames -ProjectRoot $Root

    

    Write-ColorOutput "Установка служб воркеров: $($workerServices -join ', ')" Cyan

    

    foreach ($serviceName in $workerServices) {

        Install-Service -ServiceName $serviceName -Root $Root -NssmExe $nssmExe

    }



    Write-ColorOutput "`n[OK] Все службы воркеров успешно установлены" Green

}



function Start-AllServices {

    param([string]$ProjectRoot)

    

    Write-ColorOutput "-> Запуск всех служб..." Cyan

    $serviceNames = Get-ServiceNames -ProjectRoot $ProjectRoot

    foreach ($serviceName in $serviceNames) {

        try {

            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

            if ($service) {

                Start-Service -Name $serviceName

                Write-ColorOutput "[OK] Запущена: $serviceName" Green

            }

            else {

                Write-ColorOutput "- Не установлена: $serviceName" Gray

            }

        }

        catch {

            Write-ColorOutput "[ERROR] Не удалось запустить: $serviceName — $($_.Exception.Message)" Red

        }

    }

}



function Stop-AllServices {

    param([string]$ProjectRoot)

    

    Write-ColorOutput "-> Остановка всех служб..." Cyan

    $serviceNames = Get-ServiceNames -ProjectRoot $ProjectRoot

    foreach ($serviceName in $serviceNames) {

        try {

            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

            if ($service -and $service.Status -ne 'Stopped') {

                Stop-Service -Name $serviceName -Force

                Write-ColorOutput "[OK] Остановлена: $serviceName" Green

            }

            else {

                Write-ColorOutput "- Уже остановлена или не установлена: $serviceName" Gray

            }

        }

        catch {

            Write-ColorOutput "[ERROR] Не удалось остановить: $serviceName — $($_.Exception.Message)" Red

        }

    }

}



function Restart-AllServices {

    param([string]$ProjectRoot)

    

    Write-ColorOutput "-> Перезапуск всех служб..." Cyan

    $serviceNames = Get-ServiceNames -ProjectRoot $ProjectRoot

    foreach ($serviceName in $serviceNames) {

        try {

            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

            if ($service) {

                Restart-Service -Name $serviceName -Force

                Write-ColorOutput "[OK] Перезапущена: $serviceName" Green

            }

            else {

                Write-ColorOutput "- Не установлена: $serviceName" Gray

            }

        }

        catch {

            Write-ColorOutput "[ERROR] Не удалось перезапустить: $serviceName — $($_.Exception.Message)" Red

        }

    }

}



# Внутренняя функция для запуска воркеров (используется при install-worker-service)

function Start-WorkerServices {

    param([string]$ProjectRoot)

    

    Write-ColorOutput "-> Запуск служб воркеров..." Cyan

    $workerServices = Get-WorkerServiceNames -ProjectRoot $ProjectRoot

    foreach ($serviceName in $workerServices) {

        try {

            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

            if ($service) {

                Start-Service -Name $serviceName

                Write-ColorOutput "[OK] Запущена: $serviceName" Green

            }

            else {

                Write-ColorOutput "- Не установлена: $serviceName" Gray

            }

        }

        catch {

            Write-ColorOutput "[ERROR] Не удалось запустить: $serviceName — $($_.Exception.Message)" Red

        }

    }

}



function Show-ServicesStatus {

    param([string]$ProjectRoot)

    

    Write-ColorOutput "`n=== Статус служб Ergo MS ===" Cyan

    Write-ColorOutput ""

    

    $serviceNames = Get-ServiceNames -ProjectRoot $ProjectRoot

    foreach ($serviceName in $serviceNames) {

        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

        if ($service) {

            $statusColor = switch ($service.Status) {

                'Running' { 'Green' }

                'Stopped' { 'Red' }

                default { 'Yellow' }

            }

            Write-Host "  $serviceName : " -NoNewline

            Write-ColorOutput "$($service.Status)" $statusColor

        }

        else {

            Write-Host "  $serviceName : " -NoNewline

            Write-ColorOutput "Не установлена" DarkGray

        }

    }

    

    Write-ColorOutput ""

    Write-ColorOutput "Логи: logs\" Cyan

}



function Show-ServiceLogs {

    param(

        [string]$ServiceName,

        [int]$Lines = 500,

        [string]$ProjectRoot = ""

    )

    

    # Ensure console outputs UTF-8 so special symbols display correctly

    try {

        $OutputEncoding = [System.Text.Encoding]::UTF8

        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    } catch {}



    if (-not $ProjectRoot) {

        $ProjectRoot = Get-ProjectRoot

    }

    

    $logsDir = Get-ProjectLogsDir -ProjectRoot $ProjectRoot

    $logPath = Join-Path $logsDir "${ServiceName}.log"

    

    if (-not (Test-Path $logPath)) {

        Write-ColorOutput "[ERROR] Файл лога не найден: $logPath" Red

        Write-ColorOutput "Логи пишутся при запуске как службы Windows (ergoms install-services)." Gray

        Write-ColorOutput "При задачах VS Code вывод идёт в терминал." Gray

        exit 1

    }

    

    $fileInfo = Get-Item $logPath

    $isEmpty = $fileInfo.Length -eq 0

    Write-ColorOutput "-> Последние $Lines строк лога $ServiceName..." Cyan

    Write-ColorOutput "   Файл лога: $logPath" Gray

    if ($isEmpty) {

        Write-ColorOutput "   Файл лога пуст." Yellow

        Write-ColorOutput "   Подсказка: логи пишутся при запуске как службы Windows (ergoms install-services)." Gray

        Write-ColorOutput "   При задачах VS Code (Start All Services) вывод идёт в терминал." Gray

        Write-ColorOutput ""

        Write-ColorOutput "Ожидание новых записей (-f)... Нажмите Ctrl+C для выхода." Gray

    }

    Write-ColorOutput ""

    

    # Read log as UTF-8 to display special symbols correctly in Windows PowerShell

    Get-Content -Path $logPath -Tail $Lines -Wait -Encoding UTF8

}



function Wait-ServiceStopped {

    param(

        [string]$ServiceName,

        [int]$TimeoutSeconds = 30

    )

    

    $startTime = Get-Date

    $timeout = (Get-Date).AddSeconds($TimeoutSeconds)

    

    while ((Get-Date) -lt $timeout) {

        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

        if (-not $service) {

            # Service doesn't exist anymore, consider it stopped

            return $true

        }

        

        $status = $service.Status

        if ($status -eq 'Stopped') {

            return $true

        }

        

        # Wait a bit before checking again

        Start-Sleep -Milliseconds 500

    }

    

    # Timeout reached

    return $false

}



function Uninstall-AllServices {

    param(

        [bool]$PurgeData,

        [string]$ProjectRoot

    )



    Write-ColorOutput "-> Удаление всех служб..." Yellow

    

    $nssmDir = Get-NssmDir -Root $ProjectRoot

    $nssmExe = Join-Path $nssmDir "nssm.exe"

    

    $serviceNames = Get-ServiceNames -ProjectRoot $ProjectRoot

    

    # Также добавляем legacy службу воркера (если была)

    $serviceNames += "ergo-celery-worker"

    

    foreach ($serviceName in $serviceNames) {

        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

        if ($service) {

            try {

                # Handle service stopping - check status and wait if needed

                $currentStatus = $service.Status

                if ($currentStatus -eq 'Running' -or $currentStatus -eq 'StartPending') {

                    Write-ColorOutput "  Остановка службы: $serviceName" Gray

                    # Use Stop-Service which handles StopPending state better than nssm

                    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue

                }

                elseif ($currentStatus -eq 'StopPending') {

                    Write-ColorOutput "  Служба $serviceName уже останавливается, ожидание..." Gray

                }

                

                # Wait for service to fully stop (if not already stopped)

                if ($currentStatus -ne 'Stopped') {

                    $stopped = Wait-ServiceStopped -ServiceName $serviceName -TimeoutSeconds 30

                    if (-not $stopped) {

                        Write-ColorOutput "  [WARNING] Служба $serviceName не остановилась за отведённое время, принудительная остановка..." Yellow

                        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue

                        Start-Sleep -Seconds 2

                    }

                }

                

                # Remove service

                Write-ColorOutput "  Удаление службы: $serviceName" Gray

                if (Test-Path $nssmExe) {

                    & $nssmExe remove $serviceName confirm 2>&1 | Out-Null

                    if ($LASTEXITCODE -ne 0) {

                        Write-ColorOutput "  NSSM не удалось удалить службу, пробую sc.exe..." Yellow

                        sc.exe delete $serviceName 2>$null

                    }

                }

                else {

                    sc.exe delete $serviceName 2>$null

                }

                

                Write-ColorOutput "[OK] Удалена: $serviceName" Green

            }

            catch {

                Write-ColorOutput "[ERROR] Не удалось удалить: $serviceName — $($_.Exception.Message)" Red

            }

        }

        else {

            Write-ColorOutput "- Служба не найдена: $serviceName" Gray

        }

    }



    if ($PurgeData) {

        Write-ColorOutput "-> Удаление данных конфигурации..." Yellow

        $dataDir = "$env:ProgramData\ergo_ms"

        if (Test-Path $dataDir) {

            Remove-Item $dataDir -Recurse -Force

            Write-ColorOutput "[OK] Удалено: $dataDir" Green

        }

        

        # Also remove project logs and wrappers if they exist

        if ($ProjectRoot) {

            $projectLogsDir = Get-ProjectLogsDir -ProjectRoot $ProjectRoot

            if (Test-Path $projectLogsDir) {

                Remove-Item $projectLogsDir -Recurse -Force

                Write-ColorOutput "[OK] Удалены логи проекта: $projectLogsDir" Green

            }

        }

    }



    Write-ColorOutput "[OK] Удаление служб завершено" Green

}



# Export-ModuleMember -Function *  # Удалено, так как это не модуль

