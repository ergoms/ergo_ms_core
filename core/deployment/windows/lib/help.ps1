# Help system
# Система помощи

function Show-Help {
    param([string]$ProjectRoot = "")
    
    $customCommands = @{}
    
    if ($ProjectRoot) {
        try {
            $customCommands = Get-CustomCommands -ProjectRoot $ProjectRoot
        }
        catch {
            # Ignore errors when getting custom commands
        }
    }
    
    $helpText = @"

Ergo MS Service Manager for Windows
====================================

Usage:
    .\ergo_ms.ps1 [command] [options]
    ergoms [command] [options]  (after installing CLI)

Service Management Commands:
    install         Install all services and start them
    install-services Install and start services only
    install-api-service     Install and start API service only
    install-client-service  Install and start Client service only
    install-worker-service  Install and start Worker service only
    install-beat-service    Install and start Beat service only
    start          Start all services
    stop           Stop all services
    restart        Restart all services
    status         Show status of all services
    uninstall      Uninstall all services (use -Purge to remove data)
    install-cli    Install CLI wrapper (ergoms command)
    uninstall-cli  Remove CLI wrapper
    logs           Show logs for a service (usage: logs <service-name> [lines])
    setup-full     Full system setup (git, venv, poetry, npm) - no services
    help           Show this help

Deployment Commands (no admin required):
    deploy-api     Deploy API only (install deps, migrate, collect static)
    deploy-client  Deploy Client only (install deps, build)
    deploy-api-dev Deploy and start API in development mode
    deploy-client-dev Deploy and start Client in development mode
    deploy-all     Deploy all components (API + Client)

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
    -RecreateVenv  Force recreation of virtual environment

Examples:
    Full System Setup:
        .\ergo_ms.ps1 setup-full
        .\ergo_ms.ps1 setup-full -Root "C:\projects\ergo_ms"
        .\ergo_ms.ps1 setup-full -RecreateVenv
        ergoms setup-full
        ergoms install-services

    Service Management:
        .\ergo_ms.ps1 install
        .\ergo_ms.ps1 install-services
        .\ergo_ms.ps1 install-api-service
        .\ergo_ms.ps1 install-client-service
        .\ergo_ms.ps1 install-worker-service
        .\ergo_ms.ps1 install-beat-service
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

    Deployment Commands:
        ergoms deploy-api           (deploy API only)
        ergoms deploy-client        (deploy Client only)
        ergoms deploy-api-dev       (deploy and start API in dev mode)
        ergoms deploy-client-dev    (deploy and start Client in dev mode)
        ergoms deploy-all           (deploy all components)

Configuration:
    Core commands: core/deployment/commands.conf
    Module commands: modules/*/ergoms.conf
    Edit these files to add your own command aliases and composite commands.

Notes:
    - Service management requires Administrator privileges
    - Services are installed using NSSM (Non-Sucking Service Manager)
    - Logs are stored in: logs\
    - Service wrappers: core\deployment\wrappers\
    - Proxy and custom commands do not require Administrator privileges

"@
    
    Write-ColorOutput $helpText White
}

Export-ModuleMember -Function *

