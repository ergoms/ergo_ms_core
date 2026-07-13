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



# Lazy loading: загружаем только core и commands для быстрого выполнения обычных команд.

# Тяжёлые модули (nssm, services, setup, cli, help) загружаются только при необходимости.

$LibPath = Join-Path $PSScriptRoot "lib"

. (Join-Path $LibPath "core.ps1")

. (Join-Path $LibPath "nginx_env.ps1")

. (Join-Path $LibPath "commands.ps1")



Initialize-ErgomsConsoleEncoding



$script:HeavyModulesLoaded = $false

function Load-HeavyModules {

    if ($script:HeavyModulesLoaded) { return }

    . (Join-Path $LibPath "nssm.ps1")

    . (Join-Path $LibPath "services.ps1")

    . (Join-Path $LibPath "setup.ps1")

    . (Join-Path $LibPath "cli.ps1")

    . (Join-Path $LibPath "help.ps1")

    . (Join-Path $LibPath "nginx.ps1")

    . (Join-Path $LibPath "redis.ps1")

    $script:HeavyModulesLoaded = $true

}



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

        'uninstall-services', 'install-cli', 'uninstall-cli', 'setup-full',

        'install-nginx', 'install-nginx-service', 'uninstall-nginx',

        'start-nginx', 'stop-nginx', 'restart-nginx', 'reload-nginx',

        'install-redis', 'install-redis-service', 'uninstall-redis',

        'start-redis', 'stop-redis', 'restart-redis'

    )

    $requiresAdmin = $adminCommands -contains $Command.ToLower()

    

    # Commands that don't require admin

    $noAdminCommands = @('logs', 'help', 'clean', 'update-submodules', 'update-module-submodules', 'status-nginx', 'test-nginx', 'status-redis', 'test-redis')

    

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

        Write-ErgomsMessage -Key 'admin_required' -Color Red -Stderr -Param @{ name = $Command }

        Write-ErgomsMessage -Key 'admin_powershell_hint' -Color Yellow -Stderr

        exit 1

    }



    # Handle built-in noAdminCommands before custom commands to avoid recursion

    # (clean/update-submodules are in commands.conf but must run as built-in when invoked via win: ergo_ms.ps1)

    if ($Command -in @('clean', 'update-submodules', 'update-module-submodules')) {

        . Load-HeavyModules

        $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

        if ($Command -eq 'clean') {

            Clear-ProjectDependencies -Root $projectRoot

        } elseif ($Command -eq 'update-submodules') {

            Update-Submodules -Root $projectRoot

        } else {

            Update-ModuleSubmodules -Root $projectRoot

        }

        return

    }



    # Handle nginx/redis noAdmin commands before custom commands

    if ($Command -in @('status-nginx', 'test-nginx', 'status-redis', 'test-redis')) {

        . Load-HeavyModules

        $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

        switch ($Command) {

            'status-nginx' { Show-NginxStatus -Root $projectRoot }

            'test-nginx'   { Test-NginxConfig -Root $projectRoot }

            'status-redis' { Show-RedisStatus -Root $projectRoot }

            'test-redis'   {

                if (Test-RedisPing -Root $projectRoot) {

                    Write-ColorOutput '[OK] PONG' Green

                }

                else {

                    Write-ColorOutput '[ERROR] Redis ping не удался' Red

                    exit 1

                }

            }

        }

        return

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



    # Handle <module>:poetry commands (e.g., ergoms bi_analysis:poetry add requests ">=2.28.0")

    if ($Command -match '^([a-zA-Z0-9_-]+):poetry$') {

        $moduleName = $Matches[1]

        $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

        Invoke-ModulePoetryCommand -ModuleName $moduleName -CommandArgs $RemainingArgs -Root $projectRoot

        return

    }



    # Service/admin/utility commands — загружаем тяжёлые модули

    # Dot-source для сохранения определений функций в текущей области видимости

    . Load-HeavyModules



    switch ($Command.ToLower()) {

        'install' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Write-ColorOutput "-> Установка служб для: $projectRoot" Cyan

            Install-AllServices -Root $projectRoot

            Start-AllServices -ProjectRoot $projectRoot

            if (-not $NoCli) {

                Install-CliWrapper

            }

            Write-ColorOutput "`n[OK] Установка завершена!" Green

            Show-ServicesStatus -ProjectRoot $projectRoot

        }

        'install-services' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Write-ColorOutput "-> Установка служб для: $projectRoot" Cyan

            Install-AllServices -Root $projectRoot

            Start-AllServices -ProjectRoot $projectRoot

            Write-ColorOutput "`n[OK] Службы установлены и запущены!" Green

            Show-ServicesStatus -ProjectRoot $projectRoot

        }

        'install-api-service' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Write-ColorOutput "-> Установка службы API для: $projectRoot" Cyan

            Install-SingleService -ServiceName "ergo-api-dev" -Root $projectRoot

            Start-Service -Name "ergo-api-dev"

            Write-ColorOutput "`n[OK] Служба API установлена и запущена!" Green

            Show-ServicesStatus -ProjectRoot $projectRoot

        }

        'install-client-service' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Write-ColorOutput "-> Установка службы клиента для: $projectRoot" Cyan

            Install-SingleService -ServiceName "ergo-client-dev" -Root $projectRoot

            Start-Service -Name "ergo-client-dev"

            Write-ColorOutput "`n[OK] Служба клиента установлена и запущена!" Green

            Show-ServicesStatus -ProjectRoot $projectRoot

        }

        'install-worker-service' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Write-ColorOutput "-> Установка служб воркеров для: $projectRoot" Cyan

            Install-WorkerServices -Root $projectRoot

            Start-WorkerServices -ProjectRoot $projectRoot

            Write-ColorOutput "`n[OK] Службы воркеров установлены и запущены!" Green

            Show-ServicesStatus -ProjectRoot $projectRoot

        }

        'install-beat-service' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Write-ColorOutput "-> Установка службы Beat для: $projectRoot" Cyan

            Install-SingleService -ServiceName "ergo-celery-beat" -Root $projectRoot

            Start-Service -Name "ergo-celery-beat"

            Write-ColorOutput "`n[OK] Служба Beat установлена и запущена!" Green

            Show-ServicesStatus -ProjectRoot $projectRoot

        }

        'install-media-service' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Write-ColorOutput "-> Установка службы Media API для: $projectRoot" Cyan

            Install-SingleService -ServiceName "ergo-media-api" -Root $projectRoot

            Start-Service -Name "ergo-media-api"

            Write-ColorOutput "`n[OK] Служба Media API установлена и запущена!" Green

            Show-ServicesStatus -ProjectRoot $projectRoot

        }

        'deploy-api' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Write-ColorOutput "-> Развёртывание только API для: $projectRoot" Cyan

            Invoke-CustomCommand -CommandName "deploy-api" -ProjectRoot $projectRoot -CommandArgs $RemainingArgs

            Write-ColorOutput "`n[OK] Развёртывание API завершено!" Green

        }

        'deploy-client' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Write-ColorOutput "-> Развёртывание только клиента для: $projectRoot" Cyan

            Invoke-CustomCommand -CommandName "deploy-client" -ProjectRoot $projectRoot -CommandArgs $RemainingArgs

            Write-ColorOutput "`n[OK] Развёртывание клиента завершено!" Green

        }

        'deploy-api-dev' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Write-ColorOutput "-> Развёртывание и запуск API в режиме разработки для: $projectRoot" Cyan

            Invoke-CustomCommand -CommandName "deploy-api-dev" -ProjectRoot $projectRoot -CommandArgs $RemainingArgs

        }

        'deploy-client-dev' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Write-ColorOutput "-> Развёртывание и запуск клиента в режиме разработки для: $projectRoot" Cyan

            Invoke-CustomCommand -CommandName "deploy-client-dev" -ProjectRoot $projectRoot -CommandArgs $RemainingArgs

        }

        'deploy-all' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Write-ColorOutput "-> Развёртывание всех компонентов для: $projectRoot" Cyan

            Invoke-CustomCommand -CommandName "deploy-all" -ProjectRoot $projectRoot -CommandArgs $RemainingArgs

            Write-ColorOutput "`n[OK] Полное развёртывание завершено!" Green

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

                Write-ErgomsMessage -Key 'service_name_required' -Color Red -Stderr

                $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

                $serviceNames = Get-ServiceNames -ProjectRoot $projectRoot

                Write-ErgomsMessage -Key 'available_services' -Color Yellow -Stderr -Param @{ items = ($serviceNames -join ', ') }

                Write-ErgomsMessage -Key 'logs_usage' -Color Cyan -Stderr

                exit 1

            }

            

            $serviceName = $RemainingArgs[0]

            $lines = 500

            

            if ($RemainingArgs.Count -gt 1) {

                $lines = [int]$RemainingArgs[1]

            }

            

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            $serviceNames = Get-ServiceNames -ProjectRoot $projectRoot

            $serviceName = switch ($serviceName) {

                'media_api' { 'ergo-media-api' }

                default { $serviceName }

            }

            if ($serviceNames -notcontains $serviceName) {

                Write-ErgomsMessage -Key 'unknown_service' -Color Red -Stderr -Param @{ name = $serviceName }

                Write-ErgomsMessage -Key 'available_services' -Color Yellow -Stderr -Param @{ items = ($serviceNames -join ', ') }

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

        'update-submodules' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Update-Submodules -Root $projectRoot

        }

        'update-module-submodules' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Update-ModuleSubmodules -Root $projectRoot

        }

        'install-nginx' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            $serverName = if ($RemainingArgs.Count -ge 1) { $RemainingArgs[0] } else { '' }

            $listenPort = if ($RemainingArgs.Count -ge 2) { $RemainingArgs[1] } else { '' }

            Install-Nginx -Root $projectRoot -ServerName $serverName -ListenPort $listenPort

        }

        'install-nginx-service' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            $serverName = if ($RemainingArgs.Count -ge 1) { $RemainingArgs[0] } else { '' }

            $listenPort = if ($RemainingArgs.Count -ge 2) { $RemainingArgs[1] } else { '' }

            Install-Nginx -Root $projectRoot -ServerName $serverName -ListenPort $listenPort -AsService

        }

        'uninstall-nginx' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Uninstall-Nginx -Root $projectRoot -PurgeData:$Purge

        }

        'start-nginx' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Start-NginxProcess -Root $projectRoot

        }

        'stop-nginx' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Stop-NginxProcess -Root $projectRoot

        }

        'restart-nginx' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Restart-NginxProcess -Root $projectRoot

        }

        'reload-nginx' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Invoke-NginxReload -Root $projectRoot

        }

        'install-redis' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            $configure = $RemainingArgs -contains '--configure'

            $portArgs = @($RemainingArgs | Where-Object { $_ -ne '--configure' })

            $listenPort = if ($portArgs.Count -ge 1) { $portArgs[0] } else { '' }

            Install-Redis -Root $projectRoot -ListenPort $listenPort -Configure:$configure

        }

        'install-redis-service' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            $configure = $RemainingArgs -contains '--configure'

            $portArgs = @($RemainingArgs | Where-Object { $_ -ne '--configure' })

            $listenPort = if ($portArgs.Count -ge 1) { $portArgs[0] } else { '' }

            Install-Redis -Root $projectRoot -ListenPort $listenPort -AsService -Configure:$configure

        }

        'uninstall-redis' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Uninstall-Redis -Root $projectRoot -PurgeData:$Purge

        }

        'start-redis' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Start-RedisProcess -Root $projectRoot

        }

        'stop-redis' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Stop-RedisProcess -Root $projectRoot

        }

        'restart-redis' {

            $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

            Restart-RedisProcess -Root $projectRoot

        }

        'help' {

            try {

                $projectRoot = Get-ProjectRoot -ProvidedRoot $Root

                Show-Help -ProjectRoot $projectRoot -HelpArgs $RemainingArgs

            }

            catch {

                Show-Help -HelpArgs $RemainingArgs

            }

        }

        default {

            Write-ErgomsMessage -Key 'unknown_command' -Color Red -Stderr -Param @{ name = $Command }

            Write-ErgomsMessage -Key 'help_hint' -Color Yellow -Stderr

            exit 1

        }

    }

}



Main

