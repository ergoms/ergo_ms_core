#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Manages ergo_ms services on Windows using NSSM (Non-Sucking Service Manager)

.DESCRIPTION
    This script installs, starts, stops, and manages Windows services for ergo_ms.
    It uses NSSM to create Windows services from batch/powershell scripts.

.PARAMETER Command
    Command to execute: install, start, stop, restart, status, uninstall, install-cli, uninstall-cli

.PARAMETER Root
    Absolute path to project root (auto-detected if not provided)

.PARAMETER Purge
    Remove all configuration when uninstalling

.PARAMETER NoCli
    Skip CLI wrapper installation

.EXAMPLE
    .\ergo_ms.ps1 install
    .\ergo_ms.ps1 start
    .\ergo_ms.ps1 stop
    .\ergo_ms.ps1 status
    ergoms restart
#>

param(
    [Parameter(Position=0)]
    [ValidateSet('install', 'start', 'stop', 'restart', 'status', 'uninstall', 'install-cli', 'uninstall-cli', 'help')]
    [string]$Command = 'help',

    [Parameter(Position=1)]
    [string]$Root = '',

    [switch]$Purge,
    [switch]$NoCli
)

$ErrorActionPreference = "Stop"

# Service names
$ServiceNames = @(
    'ergo-api-dev',
    'ergo-client-dev',
    'ergo-celery-worker',
    'ergo-celery-beat'
)

$CliName = 'ergoms'
$CliPath = "$env:SystemRoot\System32\$CliName.bat"
$NssmUrl = 'https://nssm.cc/release/nssm-2.24.zip'
$NssmDir = "$env:ProgramData\ergo_ms\nssm"

function Write-ColorOutput {
    param([string]$Message, [string]$Color = 'White')
    Write-Host $Message -ForegroundColor $Color
}

function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ProjectRoot {
    param([string]$ProvidedRoot)

    if ($ProvidedRoot) {
        if (Test-Path $ProvidedRoot) {
            return (Resolve-Path $ProvidedRoot).Path
        }
        throw "Provided root path does not exist: $ProvidedRoot"
    }

    # Auto-detect from script location
    $scriptDir = Split-Path -Parent $PSCommandPath
    $projectRoot = Split-Path -Parent $scriptDir

    # Try git root
    try {
        Push-Location $scriptDir
        $gitRoot = git rev-parse --show-toplevel 2>$null
        if ($gitRoot) {
            Pop-Location
            return (Resolve-Path $gitRoot).Path
        }
    }
    catch {
        # Ignore git errors
    }
    finally {
        Pop-Location
    }

    return $projectRoot
}

function Test-ProjectStructure {
    param([string]$Root)

    $apiPath = Join-Path $Root "core\api"
    $clientPath = Join-Path $Root "core\client"

    if (-not (Test-Path $apiPath)) {
        throw "Invalid project root: $apiPath not found"
    }
    if (-not (Test-Path $clientPath)) {
        throw "Invalid project root: $clientPath not found"
    }

    Write-ColorOutput "✓ Project structure validated" Green
}

function Install-NSSM {
    $nssmExe = Join-Path $NssmDir "nssm.exe"
    
    if (Test-Path $nssmExe) {
        Write-ColorOutput "✓ NSSM already installed" Green
        return $nssmExe
    }

    Write-ColorOutput "→ Downloading NSSM..." Yellow
    $tempZip = Join-Path $env:TEMP "nssm.zip"
    $tempExtract = Join-Path $env:TEMP "nssm_extract"

    try {
        # Download NSSM
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $NssmUrl -OutFile $tempZip -UseBasicParsing

        # Extract
        if (Test-Path $tempExtract) {
            Remove-Item $tempExtract -Recurse -Force
        }
        Expand-Archive -Path $tempZip -DestinationPath $tempExtract

        # Find and copy nssm.exe (win64 version)
        $nssmSource = Get-ChildItem -Path $tempExtract -Filter "nssm.exe" -Recurse | 
                      Where-Object { $_.FullName -like "*win64*" } | 
                      Select-Object -First 1

        if (-not $nssmSource) {
            throw "Could not find nssm.exe in downloaded archive"
        }

        # Create destination directory
        New-Item -ItemType Directory -Path $NssmDir -Force | Out-Null
        Copy-Item $nssmSource.FullName -Destination $nssmExe -Force

        Write-ColorOutput "✓ NSSM installed to $nssmExe" Green
    }
    finally {
        # Cleanup
        if (Test-Path $tempZip) { Remove-Item $tempZip -Force }
        if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
    }

    return $nssmExe
}

function New-ServiceWrapper {
    param(
        [string]$ServiceName,
        [string]$Root
    )

    $corePath = Join-Path $Root "core"
    $venvActivate = Join-Path $Root "virtual_env\python\Scripts\activate.bat"
    $wrapperDir = "$env:ProgramData\ergo_ms\wrappers"
    
    New-Item -ItemType Directory -Path $wrapperDir -Force | Out-Null

    switch ($ServiceName) {
        'ergo-api-dev' {
            $wrapperPath = Join-Path $wrapperDir "start_api.bat"
            $content = @"
@echo off
cd /d "$corePath"
call "$venvActivate"
api dev
"@
        }
        'ergo-client-dev' {
            $wrapperPath = Join-Path $wrapperDir "start_client.bat"
            $content = @"
@echo off
cd /d "$corePath"
npm run dev
"@
        }
        'ergo-celery-worker' {
            $wrapperPath = Join-Path $wrapperDir "start_celery_worker.bat"
            $content = @"
@echo off
cd /d "$corePath"
call "$venvActivate"
api start_celery_worker
"@
        }
        'ergo-celery-beat' {
            $wrapperPath = Join-Path $wrapperDir "start_celery_beat.bat"
            $content = @"
@echo off
cd /d "$corePath"
call "$venvActivate"
api start_celery_beat
"@
        }
    }

    Set-Content -Path $wrapperPath -Value $content -Encoding ASCII
    return $wrapperPath
}

function Install-Service {
    param(
        [string]$ServiceName,
        [string]$Root,
        [string]$NssmExe
    )

    # Check if service already exists
    $existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existingService) {
        Write-ColorOutput "→ Service $ServiceName already exists, reinstalling..." Yellow
        & $NssmExe stop $ServiceName 2>$null
        & $NssmExe remove $ServiceName confirm 2>$null
        Start-Sleep -Seconds 2
    }

    $wrapperPath = New-ServiceWrapper -ServiceName $ServiceName -Root $Root
    $displayName = "Ergo MS - $ServiceName"

    Write-ColorOutput "→ Installing service: $ServiceName" Cyan

    # Install service
    & $NssmExe install $ServiceName $wrapperPath
    & $NssmExe set $ServiceName DisplayName $displayName
    & $NssmExe set $ServiceName Description "Ergo Management System - $ServiceName"
    & $NssmExe set $ServiceName AppDirectory (Join-Path $Root "core")
    & $NssmExe set $ServiceName AppStdout (Join-Path $env:ProgramData "ergo_ms\logs\${ServiceName}.log")
    & $NssmExe set $ServiceName AppStderr (Join-Path $env:ProgramData "ergo_ms\logs\${ServiceName}-error.log")
    
    # Set service to auto-start
    & $NssmExe set $ServiceName Start SERVICE_AUTO_START

    # Set restart policy
    & $NssmExe set $ServiceName AppExit Default Restart
    & $NssmExe set $ServiceName AppRestartDelay 5000

    Write-ColorOutput "✓ Service $ServiceName installed" Green
}

function Install-AllServices {
    param([string]$Root)

    Test-ProjectStructure -Root $Root
    
    # Create logs directory
    $logsDir = "$env:ProgramData\ergo_ms\logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

    # Install NSSM
    $nssmExe = Install-NSSM

    # Install each service
    foreach ($serviceName in $ServiceNames) {
        Install-Service -ServiceName $serviceName -Root $Root -NssmExe $nssmExe
    }

    Write-ColorOutput "`n✓ All services installed successfully" Green
    Write-ColorOutput "Logs directory: $logsDir" Cyan
}

function Start-AllServices {
    Write-ColorOutput "→ Starting all services..." Cyan
    foreach ($serviceName in $ServiceNames) {
        try {
            Start-Service -Name $serviceName
            Write-ColorOutput "✓ Started: $serviceName" Green
        }
        catch {
            Write-ColorOutput "✗ Failed to start: $serviceName - $($_.Exception.Message)" Red
        }
    }
}

function Stop-AllServices {
    Write-ColorOutput "→ Stopping all services..." Cyan
    foreach ($serviceName in $ServiceNames) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service -and $service.Status -ne 'Stopped') {
                Stop-Service -Name $serviceName -Force
                Write-ColorOutput "✓ Stopped: $serviceName" Green
            }
            else {
                Write-ColorOutput "- Already stopped: $serviceName" Gray
            }
        }
        catch {
            Write-ColorOutput "✗ Failed to stop: $serviceName - $($_.Exception.Message)" Red
        }
    }
}

function Restart-AllServices {
    Write-ColorOutput "→ Restarting all services..." Cyan
    foreach ($serviceName in $ServiceNames) {
        try {
            Restart-Service -Name $serviceName -Force
            Write-ColorOutput "✓ Restarted: $serviceName" Green
        }
        catch {
            Write-ColorOutput "✗ Failed to restart: $serviceName - $($_.Exception.Message)" Red
        }
    }
}

function Show-ServicesStatus {
    Write-ColorOutput "`n=== Ergo MS Services Status ===" Cyan
    Write-ColorOutput ""
    
    foreach ($serviceName in $ServiceNames) {
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
    Write-ColorOutput "Logs: $env:ProgramData\ergo_ms\logs\" Cyan
}

function Uninstall-AllServices {
    param([bool]$PurgeData)

    Write-ColorOutput "→ Uninstalling all services..." Yellow
    
    $nssmExe = Join-Path $NssmDir "nssm.exe"
    
    foreach ($serviceName in $ServiceNames) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            try {
                if (Test-Path $nssmExe) {
                    & $nssmExe stop $serviceName 2>$null
                    & $nssmExe remove $serviceName confirm
                }
                else {
                    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
                    # Remove service using sc.exe if nssm not available
                    sc.exe delete $serviceName
                }
                Write-ColorOutput "✓ Removed: $serviceName" Green
            }
            catch {
                Write-ColorOutput "✗ Failed to remove: $serviceName - $($_.Exception.Message)" Red
            }
        }
    }

    if ($PurgeData) {
        Write-ColorOutput "→ Purging configuration data..." Yellow
        $dataDir = "$env:ProgramData\ergo_ms"
        if (Test-Path $dataDir) {
            Remove-Item $dataDir -Recurse -Force
            Write-ColorOutput "✓ Removed: $dataDir" Green
        }
    }

    Write-ColorOutput "✓ Uninstall complete" Green
}

function Install-CliWrapper {
    $selfScript = $PSCommandPath
    $content = @"
@echo off
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "$selfScript" %*
"@
    
    Set-Content -Path $CliPath -Value $content -Encoding ASCII
    Write-ColorOutput "✓ CLI wrapper installed: $CliPath" Green
    Write-ColorOutput "  You can now use: $CliName start|stop|restart|status" Cyan
}

function Uninstall-CliWrapper {
    if (Test-Path $CliPath) {
        Remove-Item $CliPath -Force
        Write-ColorOutput "✓ CLI wrapper removed: $CliPath" Green
    }
    else {
        Write-ColorOutput "- CLI wrapper not found" Gray
    }
}

function Show-Help {
    Write-ColorOutput @"

Ergo MS Service Manager for Windows
====================================

Usage:
    .\ergo_ms.ps1 [command] [options]
    ergoms [command] [options]  (after installing CLI)

Commands:
    install         Install all services and start them
    start          Start all services
    stop           Stop all services
    restart        Restart all services
    status         Show status of all services
    uninstall      Uninstall all services (use -Purge to remove data)
    install-cli    Install CLI wrapper (ergoms command)
    uninstall-cli  Remove CLI wrapper
    help           Show this help

Options:
    -Root <path>   Specify project root path (auto-detected if not provided)
    -Purge         Remove all data when uninstalling
    -NoCli         Skip CLI wrapper installation

Examples:
    .\ergo_ms.ps1 install
    .\ergo_ms.ps1 install -Root "C:\projects\ergo_ms"
    .\ergo_ms.ps1 status
    .\ergo_ms.ps1 uninstall -Purge

    ergoms start
    ergoms stop
    ergoms restart
    ergoms status

Notes:
    - This script requires Administrator privileges
    - Services are installed using NSSM (Non-Sucking Service Manager)
    - Logs are stored in: $env:ProgramData\ergo_ms\logs\
    - Service wrappers: $env:ProgramData\ergo_ms\wrappers\

"@ White
}

# Main execution
function Main {
    if (-not (Test-Administrator)) {
        Write-ColorOutput "✗ This script requires Administrator privileges" Red
        Write-ColorOutput "  Please run PowerShell as Administrator" Yellow
        exit 1
    }

    switch ($Command) {
        'install' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Write-ColorOutput "→ Installing services for: $projectRoot" Cyan
            Install-AllServices -Root $projectRoot
            Start-AllServices
            if (-not $NoCli) {
                Install-CliWrapper
            }
            Write-ColorOutput "`n✓ Installation complete!" Green
            Show-ServicesStatus
        }
        'start' {
            Start-AllServices
            Show-ServicesStatus
        }
        'stop' {
            Stop-AllServices
            Show-ServicesStatus
        }
        'restart' {
            Restart-AllServices
            Show-ServicesStatus
        }
        'status' {
            Show-ServicesStatus
        }
        'uninstall' {
            Uninstall-AllServices -PurgeData $Purge
        }
        'install-cli' {
            Install-CliWrapper
        }
        'uninstall-cli' {
            Uninstall-CliWrapper
        }
        'help' {
            Show-Help
        }
    }
}

Main

