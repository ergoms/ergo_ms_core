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
    install-worker-service  Install and start all Worker services from celery_workers.yaml
    install-beat-service    Install and start Beat service only
    install-media-service   Install and start Media API service only
    start          Start all services (including all workers from config)
    stop           Stop all services (including all workers from config)
    restart        Restart all services (including all workers from config)
    status         Show status of all services (including all workers from config)
    uninstall-services Uninstall all services (use -Purge to remove data)
    install-cli    Install CLI wrapper (ergoms command)
    uninstall-cli  Remove CLI wrapper
    logs           Show logs for a service (usage: logs <service-name> [lines])
    setup-full     Full system setup (git, venv, poetry, npm) - no services
    clean          Clean all dependencies (node_modules, venv, static) - keep media
    update-submodules Update all git submodules and switch to dev branch
    update-module-submodules Update module git submodules from .gitmodules
    help           Show this help

Nginx Commands (separate from standard install, requires admin except status/test):
    install-nginx [server] [port]  Download nginx, generate config (NGINX_USE_HTTPS for TLS), start
    install-nginx-service [s] [p]  Same but as Windows service (auto-start)
    uninstall-nginx   Remove nginx config and optionally binaries (-Purge)
    start-nginx       Start nginx process
    stop-nginx        Stop nginx process
    restart-nginx     Restart nginx
    reload-nginx      Test config and reload nginx
    status-nginx      Show nginx status (no admin required)
    test-nginx        Test nginx configuration (no admin required)

Maintenance Commands (no admin required):
    maintenance-on      Enable maintenance mode (maintenance.flag)
    maintenance-off     Disable maintenance mode
    maintenance-status  Show maintenance mode status

Redis Commands (optional, portable in virtual_env/packages/redis; admin except status/test):
    install-redis [port] [--configure]  Install & start (like install-nginx): packages, config, run
    install-redis-service [port] [--configure]  Same as Windows service / Linux systemd
    uninstall-redis   Stop Redis; use -Purge to remove packages/redis
    start-redis       Start Redis process or service
    stop-redis        Stop Redis
    restart-redis     Restart Redis
    status-redis      Show Redis status (no admin required)
    test-redis        redis-cli ping (no admin required)

Deployment Commands (no admin required):
    deploy-api     Deploy API only (install deps, migrate, collect static)
    deploy-client  Deploy Client only (install deps, build)
    deploy-api-dev Deploy and start API in development mode
    deploy-client-dev Deploy and start Client in development mode
    deploy-all     Deploy all components (API + Client)

Proxy Commands (automatically forward to respective tools):
    poetry <args>     Forward to poetry command
    api <args>        Forward to api command (Django manage.py)
    media_api <args>  Forward to media_api command (Media API manage.py)
    npm <args>        Forward to npm command

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
    Full System Setup (first time or after clean):
        .\ergo_ms.ps1 setup-full
        .\ergo_ms.ps1 setup-full -Root "C:\projects\ergo_ms"
        .\ergo_ms.ps1 setup-full -RecreateVenv
        ergoms setup
        ergoms install-services
    
    Quick Dependencies Install (when venv already exists):
        ergoms install-deps

    Service Management:
        .\ergo_ms.ps1 install
        .\ergo_ms.ps1 install-services
        .\ergo_ms.ps1 install-api-service
        .\ergo_ms.ps1 install-client-service
        .\ergo_ms.ps1 install-worker-service
        .\ergo_ms.ps1 install-beat-service
        .\ergo_ms.ps1 install-media-service
        .\ergo_ms.ps1 install -Root "C:\projects\ergo_ms"
        .\ergo_ms.ps1 status
        .\ergo_ms.ps1 uninstall-services -Purge
        ergoms start            (starts all services including all workers)
        ergoms stop             (stops all services including all workers)
        ergoms restart          (restarts all services including all workers)
        ergoms status           (shows status of all services)
        ergoms logs ergo-api-dev

    Proxy Commands:
        ergoms poetry install
        ergoms poetry update
        ergoms api migrate
        ergoms api createsuperuser
        ergoms npm run dev
        ergoms npm install

    Custom Commands:
        ergoms python-install       (alias for: poetry install)
        ergoms setup                (full system setup: git, venv, poetry, npm, migrate, static, extensions)
        ergoms install-deps         (quick install: poetry install && npm install && api migrate)
        ergoms db-migrate           (alias for: api migrate)
        ergoms update-submodules    (update all git submodules and switch to dev branch)
        ergoms update-module-submodules (update module git submodules from .gitmodules)
        ergoms clean                (removes all dependencies - works on both Windows and Linux)

    Nginx (optional, not part of standard install):
        1. Set NGINX_ENABLED=true in .env
        2. ergoms build-all && ergoms collectstatic
        3. ergoms install-nginx          (auto-detects LAN IP, updates .env, generates config)
        4. ergoms install-nginx myhost 8080  (override .env)
        Open http://<NGINX_PUBLIC_HOST> — not :8001 (Vite skipped when NGINX_ENABLED=true)
        ergoms reload-nginx             (after config changes)
        ergoms status-nginx
        ergoms stop-nginx
        ergoms uninstall-nginx

    Redis (optional, portable packages):
        ergoms install-redis --configure     (устарел; задайте REDIS_ENABLED=true в .env вручную)
        ergoms install-redis-service         (Windows service / Linux systemd)
        ergoms test-redis                    (PONG)
        ergoms status-redis
        ergoms stop-redis
        ergoms uninstall-redis -Purge

    Deployment Commands:
        ergoms deploy-api           (deploy API only)
        ergoms deploy-client        (deploy Client only)
        ergoms deploy-api-dev       (deploy and start API in dev mode)
        ergoms deploy-client-dev    (deploy and start Client in dev mode)
        ergoms deploy-all           (deploy all components)

Configuration:
    Core commands: core/deployment/commands.conf
    Module commands: modules/*/ergoms.conf
    Worker config: celery_workers.yaml
    Edit these files to add your own command aliases and composite commands.

Notes:
    - Service management requires Administrator privileges
    - Services are installed using NSSM (Non-Sucking Service Manager)
    - Logs are stored in: logs\
    - Service wrappers: core\deployment\wrappers\
    - Proxy and custom commands do not require Administrator privileges
    - Worker services are created dynamically based on celery_workers.yaml

"@
    
    Write-ColorOutput $helpText White
}

# Export-ModuleMember -Function *  # Удалено, так как это не модуль
