# Внутренний dispatch для lifecycle (services, nginx, redis, tls, cli).
param(
    [Parameter(Mandatory = $true)][string]$Category,
    [Parameter(Mandatory = $true)][string]$Operation,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Extra
)

$ErrorActionPreference = 'Stop'
$LibPath = Join-Path (Split-Path -Parent $PSScriptRoot) '..' | Join-Path -ChildPath 'windows' | Join-Path -ChildPath 'lib'
$LibPath = (Resolve-Path (Join-Path $PSScriptRoot '..\..\windows\lib')).Path

. (Join-Path $LibPath 'core.ps1')
Initialize-ErgomsConsoleEncoding

switch ($Category) {
    'service' {
        . (Join-Path $LibPath 'nssm.ps1')
        . (Join-Path $LibPath 'services.ps1')
        switch ($Operation) {
            'install-all' { Install-AllServices -Root $Root; Start-AllServices -ProjectRoot $Root }
            'install-api' { Install-SingleService -ServiceName 'ergo-api-dev' -Root $Root; Start-Service -Name 'ergo-api-dev' }
            'install-client' { Install-SingleService -ServiceName 'ergo-client-dev' -Root $Root; Start-Service -Name 'ergo-client-dev' }
            'install-media' { Install-SingleService -ServiceName 'ergo-media-api' -Root $Root; Start-Service -Name 'ergo-media-api' }
            'install-beat' { Install-SingleService -ServiceName 'ergo-celery-beat' -Root $Root; Start-Service -Name 'ergo-celery-beat' }
            'install-workers' { Install-WorkerServices -Root $Root; Start-WorkerServices -ProjectRoot $Root }
            'start-all' { Start-AllServices -ProjectRoot $Root }
            'start-api' { Start-Service -Name 'ergo-api-dev' -ErrorAction SilentlyContinue; net start ergo-api-dev 2>$null }
            'start-client' { Start-Service -Name 'ergo-client-dev' -ErrorAction SilentlyContinue; net start ergo-client-dev 2>$null }
            'start-media' { Start-Service -Name 'ergo-media-api' -ErrorAction SilentlyContinue; net start ergo-media-api 2>$null }
            'start-beat' { Start-Service -Name 'ergo-celery-beat' -ErrorAction SilentlyContinue; net start ergo-celery-beat 2>$null }
            'start-workers' { Start-WorkerServices -ProjectRoot $Root }
            'stop-all' { Stop-AllServices -ProjectRoot $Root }
            'stop-api' { net stop ergo-api-dev 2>$null }
            'stop-client' { net stop ergo-client-dev 2>$null }
            'stop-media' { net stop ergo-media-api 2>$null }
            'stop-beat' { net stop ergo-celery-beat 2>$null }
            'stop-workers' { Get-Service -Name 'ergo-celery-worker*' -ErrorAction SilentlyContinue | ForEach-Object { net stop $_.Name 2>$null } }
            'restart-all' { Restart-AllServices -ProjectRoot $Root }
            'restart-api' { net stop ergo-api-dev 2>$null; net start ergo-api-dev 2>$null }
            'restart-client' { net stop ergo-client-dev 2>$null; net start ergo-client-dev 2>$null }
            'restart-media' { net stop ergo-media-api 2>$null; net start ergo-media-api 2>$null }
            'restart-beat' { net stop ergo-celery-beat 2>$null; net start ergo-celery-beat 2>$null }
            'restart-workers' { Stop-WorkerServices -ProjectRoot $Root; Start-WorkerServices -ProjectRoot $Root }
            'status-all' { Show-ServicesStatus -ProjectRoot $Root }
            'status-api' { sc query ergo-api-dev }
            'status-client' { sc query ergo-client-dev }
            'status-media' { sc query ergo-media-api }
            'status-beat' { sc query ergo-celery-beat }
            'status-workers' { Get-Service -Name 'ergo-celery-worker*' -ErrorAction SilentlyContinue | ForEach-Object { sc query $_.Name } }
            'uninstall-all' {
                $purge = $Extra -contains '--purge'
                Uninstall-AllServices -PurgeData:$purge -ProjectRoot $Root
            }
            default { throw "Неизвестная операция service: $Operation" }
        }
    }
    'nginx' {
        . (Join-Path $LibPath 'nginx_env.ps1')
        . (Join-Path $LibPath 'nginx.ps1')
        $serverName = if ($Extra.Count -ge 1) { $Extra[0] } else { '' }
        $listenPort = if ($Extra.Count -ge 2) { $Extra[1] } else { '' }
        switch ($Operation) {
            'install' { Install-Nginx -Root $Root -ServerName $serverName -ListenPort $listenPort }
            'uninstall' {
                $purge = $Extra -contains '--purge'
                Uninstall-Nginx -Root $Root -PurgeData:$purge
            }
            'start' { Start-NginxProcess -Root $Root }
            'stop' { Stop-NginxProcess -Root $Root }
            'restart' { Restart-NginxProcess -Root $Root }
            'reload' { Invoke-NginxReload -Root $Root }
            'status' { Show-NginxStatus -Root $Root }
            'test' { Test-NginxConfig -Root $Root }
            default { throw "Неизвестная операция nginx: $Operation" }
        }
    }
    'redis' {
        . (Join-Path $LibPath 'redis.ps1')
        $port = if ($Extra.Count -ge 1 -and $Extra[0] -match '^\d+$') { $Extra[0] } else { '' }
        switch ($Operation) {
            'install' { Install-Redis -Root $Root -ListenPort $port }
            'uninstall' {
                $purge = $Extra -contains '--purge'
                Uninstall-Redis -Root $Root -PurgeData:$purge
            }
            'start' { Start-RedisProcess -Root $Root }
            'stop' { Stop-RedisProcess -Root $Root }
            'restart' { Restart-RedisProcess -Root $Root }
            'status' { Show-RedisStatus -Root $Root }
            'test' { Test-RedisPing -Root $Root }
            default { throw "Неизвестная операция redis: $Operation" }
        }
    }
    'tls' {
        if ($Operation -eq 'status') {
            Write-ColorOutput '[WARNING] TLS на Windows не поддерживается; используйте Linux или nginx вручную' Yellow
            exit 0
        }
        Write-ColorOutput '[ERROR] TLS на Windows не поддерживается' Red
        exit 1
    }
    'cli' {
        . (Join-Path $LibPath 'cli.ps1')
        switch ($Operation) {
            'install' { Install-CliWrapper -ProjectRoot $Root }
            'uninstall' { Uninstall-CliWrapper -ProjectRoot $Root }
            default { throw "Неизвестная операция cli: $Operation" }
        }
    }
    default { throw "Неизвестная категория: $Category" }
}
