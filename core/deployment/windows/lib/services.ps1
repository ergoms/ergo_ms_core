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
        Write-ColorOutput "-> Service $ServiceName already exists, reinstalling..." Yellow
        
        # Stop service only if it's running
        if ($existingService.Status -eq 'Running') {
            Write-ColorOutput "   Stopping service..." Gray
            & $NssmExe stop $ServiceName 2>$null
            Start-Sleep -Seconds 2
        }
        
        # Remove service
        Write-ColorOutput "   Removing service..." Gray
        & $NssmExe remove $ServiceName confirm 2>$null
        Start-Sleep -Seconds 2
    }

    $wrapperPath = New-ServiceWrapper -ServiceName $ServiceName -Root $Root
    $displayName = "Ergo MS - $ServiceName"

    Write-ColorOutput "-> Installing service: $ServiceName" Cyan

    # Install service
    & $NssmExe install $ServiceName $wrapperPath
    & $NssmExe set $ServiceName DisplayName $displayName
    & $NssmExe set $ServiceName Description "Ergo Management System - $ServiceName"
    & $NssmExe set $ServiceName AppDirectory (Join-Path $Root "core")
    $logsDir = Get-ProjectLogsDir -ProjectRoot $Root
    # Redirect both stdout and stderr to the same file (single log per service)
    $singleLog = Join-Path $logsDir "${ServiceName}.log"
    & $NssmExe set $ServiceName AppStdout $singleLog
    & $NssmExe set $ServiceName AppStderr $singleLog
    # Ensure UTF-8 for Python output under Windows services
    & $NssmExe set $ServiceName AppEnvironmentExtra "PYTHONIOENCODING=UTF-8" "PYTHONUTF8=1"
    
    # Set service to auto-start
    & $NssmExe set $ServiceName Start SERVICE_AUTO_START

    # Set restart policy
    & $NssmExe set $ServiceName AppExit Default Restart
    & $NssmExe set $ServiceName AppRestartDelay 5000

    Write-ColorOutput "[OK] Service $ServiceName installed" Green
}

function Install-AllServices {
    param([string]$Root)

    Test-ProjectStructure -Root $Root
    
    # Create logs directory
    $logsDir = Get-ProjectLogsDir -ProjectRoot $Root
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

    # Install NSSM
    $nssmExe = Install-NSSM

    # Get service names dynamically based on config
    $serviceNames = Get-ServiceNames -ProjectRoot $Root
    
    Write-ColorOutput "Installing services: $($serviceNames -join ', ')" Cyan
    
    foreach ($serviceName in $serviceNames) {
        Install-Service -ServiceName $serviceName -Root $Root -NssmExe $nssmExe
    }

    Write-ColorOutput "`n[OK] All services installed successfully" Green
    Write-ColorOutput "Logs directory: $logsDir" Cyan
}

function Install-SingleService {
    param(
        [string]$ServiceName,
        [string]$Root
    )

    Test-ProjectStructure -Root $Root
    
    # Create logs directory
    $logsDir = Get-ProjectLogsDir -ProjectRoot $Root
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

    # Install NSSM
    $nssmExe = Install-NSSM

    # Install single service
    Install-Service -ServiceName $ServiceName -Root $Root -NssmExe $nssmExe

    Write-ColorOutput "`n[OK] Service $ServiceName installed successfully" Green
    Write-ColorOutput "Logs directory: $logsDir" Cyan
}

# Установка всех воркеров из конфигурации
function Install-WorkerServices {
    param([string]$Root)

    Test-ProjectStructure -Root $Root
    
    # Create logs directory
    $logsDir = Get-ProjectLogsDir -ProjectRoot $Root
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

    # Install NSSM
    $nssmExe = Install-NSSM

    # Get worker service names
    $workerServices = Get-WorkerServiceNames -ProjectRoot $Root
    
    Write-ColorOutput "Installing worker services: $($workerServices -join ', ')" Cyan
    
    foreach ($serviceName in $workerServices) {
        Install-Service -ServiceName $serviceName -Root $Root -NssmExe $nssmExe
    }

    Write-ColorOutput "`n[OK] All worker services installed successfully" Green
}

function Start-AllServices {
    param([string]$ProjectRoot)
    
    Write-ColorOutput "-> Starting all services..." Cyan
    $serviceNames = Get-ServiceNames -ProjectRoot $ProjectRoot
    foreach ($serviceName in $serviceNames) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service) {
                Start-Service -Name $serviceName
                Write-ColorOutput "[OK] Started: $serviceName" Green
            }
            else {
                Write-ColorOutput "- Not installed: $serviceName" Gray
            }
        }
        catch {
            Write-ColorOutput "[ERROR] Failed to start: $serviceName - $($_.Exception.Message)" Red
        }
    }
}

function Stop-AllServices {
    param([string]$ProjectRoot)
    
    Write-ColorOutput "-> Stopping all services..." Cyan
    $serviceNames = Get-ServiceNames -ProjectRoot $ProjectRoot
    foreach ($serviceName in $serviceNames) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service -and $service.Status -ne 'Stopped') {
                Stop-Service -Name $serviceName -Force
                Write-ColorOutput "[OK] Stopped: $serviceName" Green
            }
            else {
                Write-ColorOutput "- Already stopped or not installed: $serviceName" Gray
            }
        }
        catch {
            Write-ColorOutput "[ERROR] Failed to stop: $serviceName - $($_.Exception.Message)" Red
        }
    }
}

function Restart-AllServices {
    param([string]$ProjectRoot)
    
    Write-ColorOutput "-> Restarting all services..." Cyan
    $serviceNames = Get-ServiceNames -ProjectRoot $ProjectRoot
    foreach ($serviceName in $serviceNames) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service) {
                Restart-Service -Name $serviceName -Force
                Write-ColorOutput "[OK] Restarted: $serviceName" Green
            }
            else {
                Write-ColorOutput "- Not installed: $serviceName" Gray
            }
        }
        catch {
            Write-ColorOutput "[ERROR] Failed to restart: $serviceName - $($_.Exception.Message)" Red
        }
    }
}

# Внутренняя функция для запуска воркеров (используется при install-worker-service)
function Start-WorkerServices {
    param([string]$ProjectRoot)
    
    Write-ColorOutput "-> Starting worker services..." Cyan
    $workerServices = Get-WorkerServiceNames -ProjectRoot $ProjectRoot
    foreach ($serviceName in $workerServices) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service) {
                Start-Service -Name $serviceName
                Write-ColorOutput "[OK] Started: $serviceName" Green
            }
            else {
                Write-ColorOutput "- Not installed: $serviceName" Gray
            }
        }
        catch {
            Write-ColorOutput "[ERROR] Failed to start: $serviceName - $($_.Exception.Message)" Red
        }
    }
}

function Show-ServicesStatus {
    param([string]$ProjectRoot)
    
    Write-ColorOutput "`n=== Ergo MS Services Status ===" Cyan
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
            Write-ColorOutput "Not Installed" DarkGray
        }
    }
    
    Write-ColorOutput ""
    Write-ColorOutput "Logs: logs\" Cyan
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
        Write-ColorOutput "[ERROR] Log file not found: $logPath" Red
        exit 1
    }
    
    Write-ColorOutput "-> Showing last $Lines lines of $ServiceName logs..." Cyan
    Write-ColorOutput "   Log file: $logPath" Gray
    Write-ColorOutput ""
    
    # Read log as UTF-8 to display special symbols correctly in Windows PowerShell
    Get-Content -Path $logPath -Tail $Lines -Wait -Encoding UTF8
}

function Uninstall-AllServices {
    param(
        [bool]$PurgeData,
        [string]$ProjectRoot
    )

    Write-ColorOutput "-> Uninstalling all services..." Yellow
    
    $nssmDir = Get-NssmDir
    $nssmExe = Join-Path $nssmDir "nssm.exe"
    
    $serviceNames = Get-ServiceNames -ProjectRoot $ProjectRoot
    
    # Также добавляем legacy службу воркера (если была)
    $serviceNames += "ergo-celery-worker"
    
    foreach ($serviceName in $serviceNames) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            try {
                if (Test-Path $nssmExe) {
                    # Only stop service if it's running
                    if ($service.Status -eq 'Running') {
                        Write-ColorOutput "  Stopping service: $serviceName" Gray
                        & $nssmExe stop $serviceName 2>$null
                        Start-Sleep -Seconds 2
                    }
                    
                    # Remove service
                    Write-ColorOutput "  Removing service: $serviceName" Gray
                    & $nssmExe remove $serviceName confirm 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        Write-ColorOutput "  NSSM removal failed, trying sc.exe..." Yellow
                        sc.exe delete $serviceName 2>$null
                    }
                }
                else {
                    # Only stop service if it's running
                    if ($service.Status -eq 'Running') {
                        Write-ColorOutput "  Stopping service: $serviceName" Gray
                        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
                    }
                    
                    # Remove service using sc.exe if nssm not available
                    Write-ColorOutput "  Removing service: $serviceName" Gray
                    sc.exe delete $serviceName 2>$null
                }
                Write-ColorOutput "[OK] Removed: $serviceName" Green
            }
            catch {
                Write-ColorOutput "[ERROR] Failed to remove: $serviceName - $($_.Exception.Message)" Red
            }
        }
        else {
            Write-ColorOutput "- Service not found: $serviceName" Gray
        }
    }

    if ($PurgeData) {
        Write-ColorOutput "-> Purging configuration data..." Yellow
        $dataDir = "$env:ProgramData\ergo_ms"
        if (Test-Path $dataDir) {
            Remove-Item $dataDir -Recurse -Force
            Write-ColorOutput "[OK] Removed: $dataDir" Green
        }
        
        # Also remove project logs and wrappers if they exist
        if ($ProjectRoot) {
            $projectLogsDir = Get-ProjectLogsDir -ProjectRoot $ProjectRoot
            if (Test-Path $projectLogsDir) {
                Remove-Item $projectLogsDir -Recurse -Force
                Write-ColorOutput "[OK] Removed project logs: $projectLogsDir" Green
            }
        }
    }

    Write-ColorOutput "[OK] Uninstall complete" Green
}

# Export-ModuleMember -Function *  # Удалено, так как это не модуль
