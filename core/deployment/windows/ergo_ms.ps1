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
    [string]$Command = 'help',

    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$RemainingArgs = @(),

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

    Write-ColorOutput "[OK] Project structure validated" Green
}

function Install-NSSM {
    $nssmExe = Join-Path $NssmDir "nssm.exe"
    
    if (Test-Path $nssmExe) {
        Write-ColorOutput "[OK] NSSM already installed" Green
        return $nssmExe
    }

    Write-ColorOutput "-> Downloading NSSM..." Yellow
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

        Write-ColorOutput "[OK] NSSM installed to $nssmExe" Green
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
            $content = @(
                '@echo off',
                "cd /d `"$corePath`"",
                "call `"$venvActivate`"",
                'api dev'
            ) -join "`r`n"
        }
        'ergo-client-dev' {
            $wrapperPath = Join-Path $wrapperDir "start_client.bat"
            $content = @(
                '@echo off',
                "cd /d `"$corePath`"",
                'npm run dev'
            ) -join "`r`n"
        }
        'ergo-celery-worker' {
            $wrapperPath = Join-Path $wrapperDir "start_celery_worker.bat"
            $content = @(
                '@echo off',
                "cd /d `"$corePath`"",
                "call `"$venvActivate`"",
                'api start_celery_worker'
            ) -join "`r`n"
        }
        'ergo-celery-beat' {
            $wrapperPath = Join-Path $wrapperDir "start_celery_beat.bat"
            $content = @(
                '@echo off',
                "cd /d `"$corePath`"",
                "call `"$venvActivate`"",
                'api start_celery_beat'
            ) -join "`r`n"
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
    & $NssmExe set $ServiceName AppStdout (Join-Path $env:ProgramData "ergo_ms\logs\${ServiceName}.log")
    & $NssmExe set $ServiceName AppStderr (Join-Path $env:ProgramData "ergo_ms\logs\${ServiceName}-error.log")
    
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
    $logsDir = "$env:ProgramData\ergo_ms\logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

    # Install NSSM
    $nssmExe = Install-NSSM

    # Install each service
    foreach ($serviceName in $ServiceNames) {
        Install-Service -ServiceName $serviceName -Root $Root -NssmExe $nssmExe
    }

    Write-ColorOutput "`n[OK] All services installed successfully" Green
    Write-ColorOutput "Logs directory: $logsDir" Cyan
}

function Start-AllServices {
    Write-ColorOutput "-> Starting all services..." Cyan
    foreach ($serviceName in $ServiceNames) {
        try {
            Start-Service -Name $serviceName
            Write-ColorOutput "[OK] Started: $serviceName" Green
        }
        catch {
            Write-ColorOutput "[ERROR] Failed to start: $serviceName - $($_.Exception.Message)" Red
        }
    }
}

function Stop-AllServices {
    Write-ColorOutput "-> Stopping all services..." Cyan
    foreach ($serviceName in $ServiceNames) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service -and $service.Status -ne 'Stopped') {
                Stop-Service -Name $serviceName -Force
                Write-ColorOutput "[OK] Stopped: $serviceName" Green
            }
            else {
                Write-ColorOutput "- Already stopped: $serviceName" Gray
            }
        }
        catch {
            Write-ColorOutput "[ERROR] Failed to stop: $serviceName - $($_.Exception.Message)" Red
        }
    }
}

function Restart-AllServices {
    Write-ColorOutput "-> Restarting all services..." Cyan
    foreach ($serviceName in $ServiceNames) {
        try {
            Restart-Service -Name $serviceName -Force
            Write-ColorOutput "[OK] Restarted: $serviceName" Green
        }
        catch {
            Write-ColorOutput "[ERROR] Failed to restart: $serviceName - $($_.Exception.Message)" Red
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

function Show-ServiceLogs {
    param(
        [string]$ServiceName,
        [int]$Lines = 500
    )
    
    $logPath = "$env:ProgramData\ergo_ms\logs\${ServiceName}.log"
    
    if (-not (Test-Path $logPath)) {
        Write-ColorOutput "[ERROR] Log file not found: $logPath" Red
        exit 1
    }
    
    Write-ColorOutput "-> Showing last $Lines lines of $ServiceName logs..." Cyan
    Write-ColorOutput "   Log file: $logPath" Gray
    Write-ColorOutput ""
    
    Get-Content -Path $logPath -Tail $Lines -Wait
}

function Uninstall-AllServices {
    param([bool]$PurgeData)

    Write-ColorOutput "-> Uninstalling all services..." Yellow
    
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
                Write-ColorOutput "[OK] Removed: $serviceName" Green
            }
            catch {
                Write-ColorOutput "[ERROR] Failed to remove: $serviceName - $($_.Exception.Message)" Red
            }
        }
    }

    if ($PurgeData) {
        Write-ColorOutput "-> Purging configuration data..." Yellow
        $dataDir = "$env:ProgramData\ergo_ms"
        if (Test-Path $dataDir) {
            Remove-Item $dataDir -Recurse -Force
            Write-ColorOutput "[OK] Removed: $dataDir" Green
        }
    }

    Write-ColorOutput "[OK] Uninstall complete" Green
}

function Install-CliWrapper {
    $selfScript = $PSCommandPath
    $content = @(
        '@echo off',
        "powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$selfScript`" %*"
    ) -join "`r`n"
    
    Set-Content -Path $CliPath -Value $content -Encoding ASCII
    Write-ColorOutput "[OK] CLI wrapper installed: $CliPath" Green
    Write-ColorOutput "  You can now use: $CliName start|stop|restart|status" Cyan
}

function Setup-FullSystem {
    param([string]$Root)
    
    Write-ColorOutput "`n=== Full System Setup ===" Cyan
    Write-ColorOutput ""
    
    # Step 1: Git submodules
    Write-ColorOutput "-> Step 1/7: Updating git submodules..." Yellow
    Push-Location $Root
    try {
        & git submodule update --init --remote core/api core/client
        if ($LASTEXITCODE -ne 0) { throw "Git submodule update failed" }
        
        Push-Location "core\api"
        & git checkout dev
        Pop-Location
        
        Push-Location "core\client"
        & git checkout dev
        Pop-Location
        
        Write-ColorOutput "[OK] Git submodules updated" Green
    }
    catch {
        Write-ColorOutput "[ERROR] Failed to update git submodules: $($_.Exception.Message)" Red
        Pop-Location
        exit 1
    }
    finally {
        Pop-Location
    }
    
    # Step 2: Create virtual environment
    Write-ColorOutput "-> Step 2/7: Creating Python virtual environment..." Yellow
    $venvPath = Join-Path $Root "virtual_env\python"
    $venvActivate = Join-Path $venvPath "Scripts\activate.bat"
    $pipExe = Join-Path $venvPath "Scripts\pip.exe"
    $pythonExe = Join-Path $venvPath "Scripts\python.exe"
    
    $needsRecreation = $false
    
    if (Test-Path $venvPath) {
        Write-ColorOutput "  Virtual environment already exists" Gray
        
        # Check if virtual environment is valid
        if (-not (Test-Path $pipExe) -or -not (Test-Path $pythonExe) -or -not (Test-Path $venvActivate)) {
            Write-ColorOutput "  Virtual environment appears corrupted, will recreate..." Yellow
            $needsRecreation = $true
        } else {
            # Test if Python works in the virtual environment
            try {
                $testResult = & $pythonExe --version 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-ColorOutput "  Python in virtual environment not working, will recreate..." Yellow
                    $needsRecreation = $true
                } else {
                    Write-ColorOutput "  Virtual environment is valid" Green
                }
            }
            catch {
                Write-ColorOutput "  Error testing virtual environment, will recreate..." Yellow
                $needsRecreation = $true
            }
        }
    }
    else {
        $needsRecreation = $true
    }
    
    if ($needsRecreation) {
        # Remove existing virtual environment if it exists
        if (Test-Path $venvPath) {
            Write-ColorOutput "  Removing corrupted virtual environment..." Yellow
            Remove-Item $venvPath -Recurse -Force
        }
        
        try {
            Write-ColorOutput "  Creating new virtual environment..." Gray
            & py -3.12 -m venv $venvPath
            if ($LASTEXITCODE -ne 0) { throw "Failed to create venv" }
            Write-ColorOutput "[OK] Virtual environment created" Green
        }
        catch {
            Write-ColorOutput "[ERROR] Failed to create virtual environment: $($_.Exception.Message)" Red
            Write-ColorOutput "  Python command used: py -3.12 -m venv" Gray
            Write-ColorOutput "  Target path: $venvPath" Gray
            exit 1
        }
    }
    
    # Step 3: Install Poetry
    Write-ColorOutput "-> Step 3/7: Installing Poetry..." Yellow
    $venvActivate = Join-Path $venvPath "Scripts\activate.bat"
    $pipExe = Join-Path $venvPath "Scripts\pip.exe"
    
    if (-not (Test-Path $pipExe)) {
        Write-ColorOutput "[ERROR] pip not found in virtual environment" Red
        exit 1
    }
    
    try {
        # Use direct path to pip instead of cmd /c
        Write-ColorOutput "  Installing Poetry using: $pipExe" Gray
        & $pipExe install poetry
        if ($LASTEXITCODE -ne 0) { 
            Write-ColorOutput "  pip exit code: $LASTEXITCODE" Red
            throw "Poetry installation failed" 
        }
        # Verify Poetry installation
        $poetryExe = Join-Path $venvPath "Scripts\poetry.exe"
        if (Test-Path $poetryExe) {
            Write-ColorOutput "[OK] Poetry installed and verified" Green
        } else {
            Write-ColorOutput "[WARNING] Poetry installed but executable not found at: $poetryExe" Yellow
        }
    }
    catch {
        Write-ColorOutput "[ERROR] Failed to install Poetry: $($_.Exception.Message)" Red
        Write-ColorOutput "  pip executable: $pipExe" Gray
        Write-ColorOutput "  Virtual environment: $venvPath" Gray
        exit 1
    }
    
    # Step 4: Install CLI wrapper
    Write-ColorOutput "-> Step 4/7: Installing ErgoMS CLI..." Yellow
    Install-CliWrapper
    
    # Step 5: Run setup (poetry install && npm install && api migrate)
    Write-ColorOutput "-> Step 5/7: Running ergoms setup..." Yellow
    Push-Location $Root
    try {
        # Activate virtual environment and run commands
        $env:VIRTUAL_ENV = $venvPath
        $env:PATH = "$venvPath\Scripts;$env:PATH"
        
        Push-Location "core"
        try {
            & poetry install
            if ($LASTEXITCODE -ne 0) { throw "Poetry install failed" }
            
            & npm install
            if ($LASTEXITCODE -ne 0) { throw "NPM install failed" }
            
            & api migrate
            if ($LASTEXITCODE -ne 0) { throw "API migrate failed" }
        }
        finally {
            Pop-Location
        }
        
        Write-ColorOutput "[OK] Setup completed" Green
    }
    catch {
        Write-ColorOutput "[ERROR] Setup failed: $($_.Exception.Message)" Red
        Pop-Location
        exit 1
    }
    finally {
        Pop-Location
    }
    
    # Step 6: Collect static
    Write-ColorOutput "-> Step 6/7: Collecting static files..." Yellow
    Push-Location $Root
    try {
        # Activate virtual environment and run command
        $env:VIRTUAL_ENV = $venvPath
        $env:PATH = "$venvPath\Scripts;$env:PATH"
        
        Push-Location "core"
        try {
            & api collectstatic --noinput
            if ($LASTEXITCODE -ne 0) { throw "Collectstatic failed" }
        }
        finally {
            Pop-Location
        }
        
        Write-ColorOutput "[OK] Static files collected" Green
    }
    catch {
        Write-ColorOutput "[ERROR] Failed to collect static: $($_.Exception.Message)" Red
        Pop-Location
        exit 1
    }
    finally {
        Pop-Location
    }
    
    # Step 7: Install and start services
    Write-ColorOutput "-> Step 7/7: Installing services..." Yellow
    Install-AllServices -Root $Root
    Start-AllServices
    
    Write-ColorOutput "`n=== Full System Setup Complete ===" Green
    Write-ColorOutput ""
    Show-ServicesStatus
    Write-ColorOutput ""
    Write-ColorOutput "You can now use 'ergoms' commands to manage your system." Cyan
}

function Uninstall-CliWrapper {
    if (Test-Path $CliPath) {
        Remove-Item $CliPath -Force
        Write-ColorOutput "[OK] CLI wrapper removed: $CliPath" Green
    }
    else {
        Write-ColorOutput "- CLI wrapper not found" Gray
    }
}

function Get-CustomCommands {
    param([string]$ProjectRoot)
    
    $commands = @{}
    
    # Load core commands
    $configPath = Join-Path $ProjectRoot "core\deployment\commands.conf"
    if (Test-Path $configPath) {
        Get-Content $configPath | ForEach-Object {
            $line = $_.Trim()
            # Skip comments and empty lines
            if ($line -and -not $line.StartsWith('#') -and -not $line.StartsWith('=')) {
                if ($line -match '^([a-zA-Z0-9_-]+)=(.+)$') {
                    $cmdName = $matches[1].Trim()
                    $cmdValue = $matches[2].Trim()
                    $commands[$cmdName] = $cmdValue
                }
            }
        }
    }
    
    # Load module commands
    $modulesPath = Join-Path $ProjectRoot "modules"
    if (Test-Path $modulesPath) {
        Get-ChildItem -Path $modulesPath -Directory | ForEach-Object {
            $moduleName = $_.Name
            $moduleConfigPath = Join-Path $_.FullName "ergoms.conf"
            
            if (Test-Path $moduleConfigPath) {
                Get-Content $moduleConfigPath | ForEach-Object {
                    $line = $_.Trim()
                    # Skip comments and empty lines
                    if ($line -and -not $line.StartsWith('#') -and -not $line.StartsWith('=')) {
                        if ($line -match '^([a-zA-Z0-9_-]+)=(.+)$') {
                            $cmdName = $matches[1].Trim()
                            $cmdValue = $matches[2].Trim()
                            
                            # Add module prefix to command name
                            $prefixedName = "$moduleName`:$cmdName"
                            $commands[$prefixedName] = $cmdValue
                            
                            # Also add without prefix if no conflict
                            if (-not $commands.ContainsKey($cmdName)) {
                                $commands[$cmdName] = $cmdValue
                            }
                        }
                    }
                }
            }
        }
    }
    
    return $commands
}

function Invoke-CustomCommand {
    param(
        [string]$CommandName,
        [string[]]$Args,
        [string]$ProjectRoot
    )
    
    $customCommands = Get-CustomCommands -ProjectRoot $ProjectRoot
    
    if (-not $customCommands.ContainsKey($CommandName)) {
        Write-ColorOutput "[ERROR] Unknown command: $CommandName" Red
        Write-ColorOutput "Available custom commands: $($customCommands.Keys -join ', ')" Yellow
        Write-ColorOutput "Run 'ergoms help' for all available commands" Cyan
        exit 1
    }
    
    $commandDef = $customCommands[$CommandName]
    
    # Check if it's a composite command (contains &&)
    if ($commandDef -match '&&') {
        $subCommands = $commandDef -split '&&' | ForEach-Object { $_.Trim() }
        Write-ColorOutput "-> Executing composite command: $CommandName" Cyan
        
        foreach ($subCmd in $subCommands) {
            Write-ColorOutput "   -> $subCmd" Yellow
            Execute-CommandString -CommandString $subCmd -ProjectRoot $ProjectRoot -Args $Args
            if ($LASTEXITCODE -ne 0) {
                Write-ColorOutput "[ERROR] Command failed: $subCmd" Red
                exit $LASTEXITCODE
            }
        }
    }
    else {
        Execute-CommandString -CommandString $commandDef -ProjectRoot $ProjectRoot -Args $Args
    }
}

function Execute-CommandString {
    param(
        [string]$CommandString,
        [string]$ProjectRoot,
        [string[]]$Args
    )
    
    # Parse command type (poetry:, api:, npm:, shell:, win:, linux:)
    if ($CommandString -match '^(poetry|api|npm|shell|win|linux):(.+)$') {
        $cmdType = $matches[1]
        $cmdArgs = $matches[2].Trim()
        
        # Skip linux commands on Windows
        if ($cmdType -eq 'linux') {
            Write-ColorOutput "[INFO] Skipping Linux-only command on Windows: $cmdArgs" Gray
            return
        }
        
        # Split command arguments and add user arguments
        $allArgs = ($cmdArgs -split '\s+') + $Args
        
        switch ($cmdType) {
            'poetry' {
                Push-Location $ProjectRoot
                try {
                    & poetry $allArgs
                }
                finally {
                    Pop-Location
                }
            }
            'api' {
                $venvPath = Join-Path $ProjectRoot "virtual_env\python"
                if (-not (Test-Path $venvPath)) {
                    Write-ColorOutput "[ERROR] Virtual environment not found" Red
                    exit 1
                }
                Push-Location (Join-Path $ProjectRoot "core")
                try {
                    # Activate virtual environment
                    $env:VIRTUAL_ENV = $venvPath
                    $env:PATH = "$venvPath\Scripts;$env:PATH"
                    
                    $argsString = $allArgs -join ' '
                    & api $argsString
                }
                finally {
                    Pop-Location
                }
            }
            'npm' {
                Push-Location $ProjectRoot
                try {
                    # Check if npm is available
                    $npmVersion = & npm --version 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        Write-ColorOutput "[ERROR] npm is not available or not working" Red
                        Write-ColorOutput "  Please install Node.js and npm" Yellow
                        exit 1
                    }
                    
                    # Check if package.json exists
                    if (-not (Test-Path "package.json")) {
                        Write-ColorOutput "[ERROR] package.json not found in project root" Red
                        Write-ColorOutput "  Current directory: $(Get-Location)" Gray
                        exit 1
                    }
                    
                    # For npm commands, pass arguments correctly
                    $npmCommand = "npm " + ($allArgs -join ' ')
                    Invoke-Expression $npmCommand
                }
                finally {
                    Pop-Location
                }
            }
            'shell' {
                Push-Location $ProjectRoot
                try {
                    # Execute shell command as-is
                    $fullCommand = $cmdArgs
                    if ($Args.Count -gt 0) {
                        $fullCommand += " " + ($Args -join ' ')
                    }
                    & cmd /c $fullCommand
                }
                finally {
                    Pop-Location
                }
            }
            'win' {
                Push-Location $ProjectRoot
                try {
                    # Execute Windows-specific command
                    $fullCommand = $cmdArgs
                    if ($Args.Count -gt 0) {
                        $fullCommand += " " + ($Args -join ' ')
                    }
                    & cmd /c $fullCommand
                }
                finally {
                    Pop-Location
                }
            }
        }
    }
    else {
        # Execute as shell command (backward compatibility)
        Push-Location $ProjectRoot
        try {
            $allArgs = ($CommandString -split '\s+') + $Args
            $mainCmd = $allArgs[0]
            $cmdArgs = $allArgs[1..($allArgs.Length-1)]
            & $mainCmd $cmdArgs
        }
        finally {
            Pop-Location
        }
    }
}

function Invoke-PoetryCommand {
    param([string[]]$Args)
    
    $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
    $venvPath = Join-Path $projectRoot "virtual_env\python"
    
    # Activate virtual environment if it exists
    if (Test-Path $venvPath) {
        $env:VIRTUAL_ENV = $venvPath
        $env:PATH = "$venvPath\Scripts;$env:PATH"
    }
    
    Push-Location $projectRoot
    try {
        & poetry $Args
    }
    finally {
        Pop-Location
    }
}

function Invoke-ApiCommand {
    param([string[]]$Args)
    
    $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
    $venvPath = Join-Path $projectRoot "virtual_env\python"
    
    if (-not (Test-Path $venvPath)) {
        Write-ColorOutput "[ERROR] Virtual environment not found at: $venvPath" Red
        Write-ColorOutput "  Please run 'poetry install' first" Yellow
        exit 1
    }
    
    Push-Location (Join-Path $projectRoot "core")
    try {
        # Activate virtual environment
        $env:VIRTUAL_ENV = $venvPath
        $env:PATH = "$venvPath\Scripts;$env:PATH"
        
        & api $($Args -join ' ')
    }
    finally {
        Pop-Location
    }
}

function Invoke-NpmCommand {
    param([string[]]$Args)
    
    $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
    Push-Location $projectRoot
    try {
        $npmCommand = "npm " + ($Args -join ' ')
        Invoke-Expression $npmCommand
    }
    finally {
        Pop-Location
    }
}

function Show-Help {
    $projectRoot = $null
    $customCommands = @{}
    
    try {
        $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
        $customCommands = Get-CustomCommands -ProjectRoot $projectRoot
    }
    catch {
        # Ignore errors when getting custom commands
    }
    
    $helpText = @"

Ergo MS Service Manager for Windows
====================================

Usage:
    .\ergo_ms.ps1 [command] [options]
    ergoms [command] [options]  (after installing CLI)

Service Management Commands:
    install         Install all services and start them
    start          Start all services
    stop           Stop all services
    restart        Restart all services
    status         Show status of all services
    uninstall      Uninstall all services (use -Purge to remove data)
    install-cli    Install CLI wrapper (ergoms command)
    uninstall-cli  Remove CLI wrapper
    logs           Show logs for a service (usage: logs <service-name> [lines])
    setup-full     Full system setup (git, venv, poetry, npm, services)
    help           Show this help

Proxy Commands (automatically forward to respective tools):
    poetry <args>  Forward to poetry command
    api <args>     Forward to api command
    npm <args>     Forward to npm command

"@

    if ($customCommands.Count -gt 0) {
        $helpText += @"
Custom Commands:

"@
        # Separate core and module commands
        $coreCommands = @{}
        $moduleCommands = @{}
        
        foreach ($key in $customCommands.Keys) {
            if ($key -match ':') {
                $moduleCommands[$key] = $customCommands[$key]
            }
            else {
                $coreCommands[$key] = $customCommands[$key]
            }
        }
        
        if ($coreCommands.Count -gt 0) {
            $helpText += "  Core Commands (defined in commands.conf):`n"
            foreach ($cmd in ($coreCommands.Keys | Sort-Object)) {
                $def = $coreCommands[$cmd]
                # Truncate long definitions
                if ($def.Length -gt 60) {
                    $def = $def.Substring(0, 57) + "..."
                }
                $helpText += "    $cmd`n        -> $def`n"
            }
            $helpText += "`n"
        }
        
        if ($moduleCommands.Count -gt 0) {
            $helpText += "  Module Commands (defined in modules/*/ergoms.conf):`n"
            foreach ($cmd in ($moduleCommands.Keys | Sort-Object)) {
                $def = $moduleCommands[$cmd]
                # Truncate long definitions
                if ($def.Length -gt 60) {
                    $def = $def.Substring(0, 57) + "..."
                }
                $helpText += "    $cmd`n        -> $def`n"
            }
            $helpText += "`n"
        }
    }

    $helpText += @"
Options:
    -Root <path>   Specify project root path (auto-detected if not provided)
    -Purge         Remove all data when uninstalling
    -NoCli         Skip CLI wrapper installation

Examples:
    Full System Setup:
        .\ergo_ms.ps1 setup-full
        .\ergo_ms.ps1 setup-full -Root "C:\projects\ergo_ms"
        ergoms setup-full

    Service Management:
        .\ergo_ms.ps1 install
        .\ergo_ms.ps1 install -Root "C:\projects\ergo_ms"
        .\ergo_ms.ps1 status
        .\ergo_ms.ps1 uninstall -Purge
        ergoms start
        ergoms stop
        ergoms restart
        ergoms status
        ergoms logs ergo-api-dev
        ergoms logs ergo-client-dev 1000

    Proxy Commands:
        ergoms poetry install
        ergoms poetry update
        ergoms api migrate
        ergoms api createsuperuser
        ergoms npm run dev
        ergoms npm install

    Custom Commands:
        ergoms python-install       (alias for: poetry install)
        ergoms setup                (runs: poetry install && npm install && api migrate)
        ergoms db-migrate           (alias for: api migrate)

    Module Commands:
        ergoms video_analysis:install-deps    (install all video_analysis dependencies)
        ergoms install-deps                   (same as above if no conflict)

Configuration:
    Core commands: core/deployment/commands.conf
    Module commands: modules/*/ergoms.conf
    Edit these files to add your own command aliases and composite commands.

Notes:
    - Service management requires Administrator privileges
    - Services are installed using NSSM (Non-Sucking Service Manager)
    - Logs are stored in: $env:ProgramData\ergo_ms\logs\
    - Service wrappers: $env:ProgramData\ergo_ms\wrappers\
    - Proxy and custom commands do not require Administrator privileges

"@
    
    Write-ColorOutput $helpText White
}

# Main execution
function Main {
    # Proxy commands that don't require admin
    $proxyCommands = @('poetry', 'api', 'npm')
    $isProxyCommand = $proxyCommands -contains $Command.ToLower()
    
    # Commands that require admin
    $adminCommands = @('install', 'start', 'stop', 'restart', 'status', 'uninstall', 'install-cli', 'uninstall-cli', 'setup-full')
    $requiresAdmin = $adminCommands -contains $Command.ToLower()
    
    # Commands that don't require admin
    $noAdminCommands = @('logs', 'help')
    
    # Check if it's a custom command
    $projectRoot = $null
    $customCommands = @{}
    $isCustomCommand = $false
    
    if (-not $requiresAdmin -and -not $isProxyCommand -and $Command -ne 'help') {
        try {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            $customCommands = Get-CustomCommands -ProjectRoot $projectRoot
            $isCustomCommand = $customCommands.ContainsKey($Command)
        }
        catch {
            # Ignore errors
        }
    }
    
    # Check admin only for admin commands
    if ($requiresAdmin -and -not (Test-Administrator)) {
        Write-ColorOutput "[ERROR] This script requires Administrator privileges for '$Command' command" Red
        Write-ColorOutput "  Please run PowerShell as Administrator" Yellow
        exit 1
    }

    # Handle custom commands (no admin required)
    if ($isCustomCommand) {
        Invoke-CustomCommand -CommandName $Command -Args $RemainingArgs -ProjectRoot $projectRoot
        return
    }

    # Handle proxy commands
    if ($isProxyCommand) {
        switch ($Command.ToLower()) {
            'poetry' {
                Invoke-PoetryCommand -Args $RemainingArgs
                return
            }
            'api' {
                Invoke-ApiCommand -Args $RemainingArgs
                return
            }
            'npm' {
                Invoke-NpmCommand -Args $RemainingArgs
                return
            }
        }
    }

    # Handle service management commands
    switch ($Command.ToLower()) {
        'install' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Write-ColorOutput "-> Installing services for: $projectRoot" Cyan
            Install-AllServices -Root $projectRoot
            Start-AllServices
            if (-not $NoCli) {
                Install-CliWrapper
            }
            Write-ColorOutput "`n[OK] Installation complete!" Green
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
        'logs' {
            if ($RemainingArgs.Count -eq 0) {
                Write-ColorOutput "[ERROR] Please specify a service name" Red
                Write-ColorOutput "Available services: $($ServiceNames -join ', ')" Yellow
                Write-ColorOutput "Usage: ergoms logs <service-name> [lines]" Cyan
                exit 1
            }
            
            $serviceName = $RemainingArgs[0]
            $lines = 500
            
            if ($RemainingArgs.Count -gt 1) {
                $lines = [int]$RemainingArgs[1]
            }
            
            if ($ServiceNames -notcontains $serviceName) {
                Write-ColorOutput "[ERROR] Unknown service: $serviceName" Red
                Write-ColorOutput "Available services: $($ServiceNames -join ', ')" Yellow
                exit 1
            }
            
            Show-ServiceLogs -ServiceName $serviceName -Lines $lines
        }
        'setup-full' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Setup-FullSystem -Root $projectRoot
        }
        'help' {
            Show-Help
        }
        default {
            Write-ColorOutput "[ERROR] Unknown command: $Command" Red
            Write-ColorOutput "Run 'ergoms help' for usage information" Yellow
            exit 1
        }
    }
}

Main

