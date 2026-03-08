#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Manages ergo_ms services on Windows using NSSM (Non-Sucking Service Manager)

.DESCRIPTION
    This script installs, starts, stops, and manages Windows services for ergo_ms.
    It uses NSSM to create Windows services from batch/powershell scripts.

.PARAMETER Command
    Command to execute: install, start, stop, restart, status, uninstall-services, install-cli, uninstall-cli

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
    [switch]$NoCli,
    [switch]$RecreateVenv
)

$ErrorActionPreference = "Stop"

# Load modules
$LibPath = Join-Path $PSScriptRoot "lib"
. (Join-Path $LibPath "core.ps1")
. (Join-Path $LibPath "nssm.ps1")
. (Join-Path $LibPath "services.ps1")
. (Join-Path $LibPath "setup.ps1")
. (Join-Path $LibPath "cli.ps1")
. (Join-Path $LibPath "commands.ps1")
. (Join-Path $LibPath "help.ps1")

# Main execution
function Main {
    # Proxy commands that don't require admin
    $proxyCommands = @('poetry', 'api', 'media_api', 'npm')
    $isProxyCommand = $proxyCommands -contains $Command.ToLower()
    
    # Commands that require admin
    $adminCommands = @(
        'install', 'install-services', 'install-api-service', 'install-client-service', 
        'install-worker-service', 'install-beat-service', 'install-media-service', 
        'start', 'stop', 'restart', 'status', 
        'uninstall-services', 'install-cli', 'uninstall-cli', 'setup-full'
    )
    $requiresAdmin = $adminCommands -contains $Command.ToLower()
    
    # Commands that don't require admin
    $noAdminCommands = @('logs', 'help', 'clean', 'clean-project', 'update-submodules')
    
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
        Invoke-CustomCommand -CommandName $Command -CommandArgs $RemainingArgs -ProjectRoot $projectRoot
        return
    }

    # Handle proxy commands
    if ($isProxyCommand) {
        $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
        switch ($Command.ToLower()) {
            'poetry' {
                Invoke-PoetryCommand -CommandArgs $RemainingArgs -Root $projectRoot
                return
            }
            'api' {
                Invoke-ApiCommand -CommandArgs $RemainingArgs -Root $projectRoot
                return
            }
            'media_api' {
                Invoke-MediaApiCommand -CommandArgs $RemainingArgs -Root $projectRoot
                return
            }
            'npm' {
                Invoke-NpmCommand -CommandArgs $RemainingArgs -Root $projectRoot
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
            Start-AllServices -ProjectRoot $projectRoot
            if (-not $NoCli) {
                Install-CliWrapper
            }
            Write-ColorOutput "`n[OK] Installation complete!" Green
            Show-ServicesStatus -ProjectRoot $projectRoot
        }
        'install-services' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Write-ColorOutput "-> Installing services for: $projectRoot" Cyan
            Install-AllServices -Root $projectRoot
            Start-AllServices -ProjectRoot $projectRoot
            Write-ColorOutput "`n[OK] Services installed and started!" Green
            Show-ServicesStatus -ProjectRoot $projectRoot
        }
        'install-api-service' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Write-ColorOutput "-> Installing API service for: $projectRoot" Cyan
            Install-SingleService -ServiceName "ergo-api-dev" -Root $projectRoot
            Start-Service -Name "ergo-api-dev"
            Write-ColorOutput "`n[OK] API service installed and started!" Green
            Show-ServicesStatus -ProjectRoot $projectRoot
        }
        'install-client-service' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Write-ColorOutput "-> Installing Client service for: $projectRoot" Cyan
            Install-SingleService -ServiceName "ergo-client-dev" -Root $projectRoot
            Start-Service -Name "ergo-client-dev"
            Write-ColorOutput "`n[OK] Client service installed and started!" Green
            Show-ServicesStatus -ProjectRoot $projectRoot
        }
        'install-worker-service' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Write-ColorOutput "-> Installing Worker services for: $projectRoot" Cyan
            Install-WorkerServices -Root $projectRoot
            Start-WorkerServices -ProjectRoot $projectRoot
            Write-ColorOutput "`n[OK] Worker services installed and started!" Green
            Show-ServicesStatus -ProjectRoot $projectRoot
        }
        'install-beat-service' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Write-ColorOutput "-> Installing Beat service for: $projectRoot" Cyan
            Install-SingleService -ServiceName "ergo-celery-beat" -Root $projectRoot
            Start-Service -Name "ergo-celery-beat"
            Write-ColorOutput "`n[OK] Beat service installed and started!" Green
            Show-ServicesStatus -ProjectRoot $projectRoot
        }
        'install-media-service' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Write-ColorOutput "-> Installing Media API service for: $projectRoot" Cyan
            Install-SingleService -ServiceName "ergo-media-api" -Root $projectRoot
            Start-Service -Name "ergo-media-api"
            Write-ColorOutput "`n[OK] Media API service installed and started!" Green
            Show-ServicesStatus -ProjectRoot $projectRoot
        }
        'install-ollama-service' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Write-ColorOutput "-> Installing Ollama service for: $projectRoot" Cyan
            Install-SingleService -ServiceName "ergo-ollama" -Root $projectRoot
            Start-Service -Name "ergo-ollama"
            Write-ColorOutput "`n[OK] Ollama service installed and started!" Green
            Show-ServicesStatus
        }
        'deploy-api' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Write-ColorOutput "-> Deploying API only for: $projectRoot" Cyan
            Invoke-CustomCommand -CommandName "deploy-api" -ProjectRoot $projectRoot -CommandArgs $RemainingArgs
            Write-ColorOutput "`n[OK] API deployment complete!" Green
        }
        'deploy-client' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Write-ColorOutput "-> Deploying Client only for: $projectRoot" Cyan
            Invoke-CustomCommand -CommandName "deploy-client" -ProjectRoot $projectRoot -CommandArgs $RemainingArgs
            Write-ColorOutput "`n[OK] Client deployment complete!" Green
        }
        'deploy-api-dev' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Write-ColorOutput "-> Deploying and starting API in dev mode for: $projectRoot" Cyan
            Invoke-CustomCommand -CommandName "deploy-api-dev" -ProjectRoot $projectRoot -CommandArgs $RemainingArgs
        }
        'deploy-client-dev' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Write-ColorOutput "-> Deploying and starting Client in dev mode for: $projectRoot" Cyan
            Invoke-CustomCommand -CommandName "deploy-client-dev" -ProjectRoot $projectRoot -CommandArgs $RemainingArgs
        }
        'deploy-all' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Write-ColorOutput "-> Deploying all components for: $projectRoot" Cyan
            Invoke-CustomCommand -CommandName "deploy-all" -ProjectRoot $projectRoot -CommandArgs $RemainingArgs
            Write-ColorOutput "`n[OK] Full deployment complete!" Green
        }
        'start' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Start-AllServices -ProjectRoot $projectRoot
            Show-ServicesStatus -ProjectRoot $projectRoot
        }
        'stop' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Stop-AllServices -ProjectRoot $projectRoot
            Show-ServicesStatus -ProjectRoot $projectRoot
        }
        'restart' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Restart-AllServices -ProjectRoot $projectRoot
            Show-ServicesStatus -ProjectRoot $projectRoot
        }
        'status' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Show-ServicesStatus -ProjectRoot $projectRoot
        }
        'uninstall-services' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Uninstall-AllServices -PurgeData $Purge -ProjectRoot $projectRoot
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
                $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
                $serviceNames = Get-ServiceNames -ProjectRoot $projectRoot
                Write-ColorOutput "Available services: $($serviceNames -join ', ')" Yellow
                Write-ColorOutput "Usage: ergoms logs <service-name> [lines]" Cyan
                exit 1
            }
            
            $serviceName = $RemainingArgs[0]
            $lines = 500
            
            if ($RemainingArgs.Count -gt 1) {
                $lines = [int]$RemainingArgs[1]
            }
            
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            $serviceNames = Get-ServiceNames -ProjectRoot $projectRoot
            if ($serviceNames -notcontains $serviceName) {
                Write-ColorOutput "[ERROR] Unknown service: $serviceName" Red
                Write-ColorOutput "Available services: $($serviceNames -join ', ')" Yellow
                exit 1
            }
            
            Show-ServiceLogs -ServiceName $serviceName -Lines $lines -ProjectRoot $projectRoot
        }
        'setup-full' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Setup-FullSystem -Root $projectRoot -RecreateVenv $RecreateVenv
        }
        'clean' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Clear-ProjectDependencies -Root $projectRoot
        }
        'clean-project' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Clear-ProjectDependencies -Root $projectRoot
        }
        'update-submodules' {
            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
            Update-Submodules -Root $projectRoot
        }
        'help' {
            try {
                $projectRoot = Get-ProjectRoot -ProvidedRoot $Root
                Show-Help -ProjectRoot $projectRoot
            }
            catch {
                Show-Help
            }
        }
        default {
            Write-ColorOutput "[ERROR] Unknown command: $Command" Red
            Write-ColorOutput "Run 'ergoms help' for usage information" Yellow
            exit 1
        }
    }
}

Main
