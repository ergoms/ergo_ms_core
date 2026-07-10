# Redis management for Windows
# Установка и управление portable Redis в virtual_env/packages/redis

$script:RedisServiceName = 'ergo_ms_redis'

function Invoke-RedisCli {
    param(
        [string]$CliExe,
        [string[]]$Arguments
    )

    $prevEa = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @()
    $exitCode = 0

    try {
        $output = @(& $CliExe @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEa
    }

    return @{
        Output = $output
        ExitCode = $exitCode
    }
}

function Test-RedisProcessRunning {
    $service = Get-Service -Name $script:RedisServiceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') {
        return $true
    }
    return $null -ne (Get-Process -Name 'redis-server' -ErrorAction SilentlyContinue)
}

function Get-RedisPackagesRelativePath {
    return Join-Path 'virtual_env' (Join-Path 'packages' 'redis')
}

function Get-RedisDir {
    param([string]$Root)
    return Join-Path $Root (Get-RedisPackagesRelativePath)
}

function Get-RedisServerExe {
    param([string]$Root)
    $dir = Get-RedisDir -Root $Root
    $direct = Join-Path $dir 'redis-server.exe'
    if (Test-Path $direct) { return $direct }
    return Join-Path $dir 'bin\redis-server.exe'
}

function Get-RedisCliExe {
    param([string]$Root)
    $dir = Get-RedisDir -Root $Root
    $direct = Join-Path $dir 'redis-cli.exe'
    if (Test-Path $direct) { return $direct }
    return Join-Path $dir 'bin\redis-cli.exe'
}

function Get-RedisConfPath {
    param([string]$Root)
    return Join-Path (Get-RedisDir -Root $Root) 'conf\redis.conf'
}

function Get-ProjectPythonExe {
    param([string]$Root)
    return Join-Path $Root 'virtual_env\python\Scripts\python.exe'
}

function Test-RedisInstalled {
    param([string]$Root)
    return (Test-Path (Get-RedisServerExe -Root $Root)) -and (Test-Path (Get-RedisConfPath -Root $Root))
}

function Read-RedisEnv {
    param([string]$Root)

    $envFile = Join-Path $Root '.env'
    if (-not (Test-Path $envFile)) { return @{} }

    $result = @{}
    $lines = Get-Content -Path $envFile -Encoding UTF8
    foreach ($line in $lines) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^(REDIS_[A-Z_]+|API_CACHE_REDIS_URL|CHANNEL_LAYER_REDIS_URL|API_CACHE_BACKEND|CHANNEL_LAYER_BACKEND)=(.*)$') {
            $result[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
        }
    }
    return $result
}

function Invoke-RedisPythonScript {
    param(
        [string]$Root,
        [string]$ScriptName,
        [string[]]$ExtraArgs = @()
    )

    $pythonExe = Get-ProjectPythonExe -Root $Root
    $scriptPath = Join-Path $Root "core\deployment\scripts\$ScriptName"
    if (-not (Test-Path $pythonExe)) {
        Write-ColorOutput '[ERROR] Python not found. Run: ergoms setup' Red
        return $false
    }
    if (-not (Test-Path $scriptPath)) {
        Write-ColorOutput "[ERROR] Script not found: $scriptPath" Red
        return $false
    }
    & $pythonExe $scriptPath @ExtraArgs
    return ($LASTEXITCODE -eq 0)
}

function Install-Redis {
    param(
        [string]$Root,
        [string]$ListenPort = '',
        [switch]$AsService,
        [switch]$Configure
    )

    $envVars = Read-RedisEnv -Root $Root
    if (-not $ListenPort) {
        $ListenPort = if ($envVars['REDIS_PORT']) { $envVars['REDIS_PORT'] } else { '6379' }
    }

    if ($Configure) {
        Invoke-RedisPythonScript -Root $Root -ScriptName 'ensure_redis_env.py' -ExtraArgs @('--configure') | Out-Null
    }
    else {
        Invoke-RedisPythonScript -Root $Root -ScriptName 'ensure_redis_env.py' | Out-Null
    }

    Write-ColorOutput '' White
    Write-ColorOutput '=== Redis: Install & Start ===' Cyan
    Write-ColorOutput '' White

    $ok = Invoke-RedisPythonScript -Root $Root -ScriptName 'install_redis.py' -ExtraArgs @(
        '--root', $Root,
        '--port', $ListenPort
    )
    if (-not $ok) {
        Write-ColorOutput '[ERROR] Redis installation failed' Red
        return
    }

    if ($AsService) {
        Install-RedisService -Root $Root
    }
    else {
        Start-RedisProcess -Root $Root
    }

    $redisDir = Get-RedisDir -Root $Root
    Write-ColorOutput '' White
    Write-ColorOutput '[OK] Redis installed' Green
    Write-ColorOutput "    Listening: 127.0.0.1:${ListenPort}" Cyan
    Write-ColorOutput "    Path: $redisDir" Cyan
    Write-ColorOutput "    Config: $(Get-RedisConfPath -Root $Root)" Cyan
    if (-not $Configure) {
        Write-ColorOutput '    Set REDIS_ENABLED=true in .env and re-run install-redis, or use --Configure' Yellow
    }
}

function Install-RedisService {
    param([string]$Root)

    if (-not (Test-RedisInstalled -Root $Root)) {
        Write-ColorOutput '[ERROR] Redis not installed. Run: ergoms install-redis' Red
        return
    }

    $redisDir = Get-RedisDir -Root $Root
    $serverExe = Get-RedisServerExe -Root $Root
    $confPath = Get-RedisConfPath -Root $Root
    $nssmExe = Install-NSSM

    $existingService = Get-Service -Name $script:RedisServiceName -ErrorAction SilentlyContinue
    if ($existingService) {
        Write-ColorOutput "-> Service $($script:RedisServiceName) already exists, reinstalling..." Yellow
        if ($existingService.Status -eq 'Running') {
            & $nssmExe stop $script:RedisServiceName 2>$null
            Start-Sleep -Seconds 2
        }
        & $nssmExe remove $script:RedisServiceName confirm 2>$null
        Start-Sleep -Seconds 1
    }

    Stop-RedisProcess -Root $Root

    Write-ColorOutput '-> Installing Redis as Windows service...' Cyan
    & $nssmExe install $script:RedisServiceName $serverExe
    & $nssmExe set $script:RedisServiceName AppParameters "`"$confPath`""
    & $nssmExe set $script:RedisServiceName AppDirectory $redisDir
    & $nssmExe set $script:RedisServiceName DisplayName 'Ergo MS - Redis'
    & $nssmExe set $script:RedisServiceName Description 'Ergo MS portable Redis (cache / channel layer)'

    $logsDir = Join-Path $redisDir 'logs'
    & $nssmExe set $script:RedisServiceName AppStdout (Join-Path $logsDir 'service_stdout.log')
    & $nssmExe set $script:RedisServiceName AppStderr (Join-Path $logsDir 'service_stderr.log')
    & $nssmExe set $script:RedisServiceName Start SERVICE_AUTO_START
    & $nssmExe set $script:RedisServiceName AppExit Default Restart
    & $nssmExe set $script:RedisServiceName AppRestartDelay 5000

    Start-Service -Name $script:RedisServiceName
    Write-ColorOutput '[OK] Redis service installed and started' Green
}

function Stop-RedisProcess {
    param([string]$Root = '')

    $service = Get-Service -Name $script:RedisServiceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') {
        Write-ColorOutput '-> Stopping Redis service...' Cyan
        Stop-Service -Name $script:RedisServiceName -Force
        Write-ColorOutput '[OK] Redis service stopped' Green
        return
    }

    if ($Root) {
        $cli = Get-RedisCliExe -Root $Root
        $conf = Get-RedisConfPath -Root $Root
        if ((Test-Path $cli) -and (Test-RedisProcessRunning)) {
            Write-ColorOutput '-> Shutting down Redis...' Cyan
            $envVars = Read-RedisEnv -Root $Root
            $port = if ($envVars['REDIS_PORT']) { $envVars['REDIS_PORT'] } else { '6379' }
            if (Test-Path $conf) {
                Invoke-RedisCli -CliExe $cli -Arguments @('-c', $conf, 'shutdown') | Out-Null
            }
            else {
                Invoke-RedisCli -CliExe $cli -Arguments @('-h', '127.0.0.1', '-p', $port, 'shutdown') | Out-Null
            }
            Start-Sleep -Seconds 1
        }
        $pidFile = Join-Path (Get-RedisDir -Root $Root) 'run\redis.pid'
        if (Test-Path $pidFile) {
            Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        }
    }

    Get-Process -Name 'redis-server' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-ColorOutput '[OK] Redis stopped' Green
}

function Start-RedisProcess {
    param([string]$Root)

    if (-not (Test-RedisInstalled -Root $Root)) {
        Write-ColorOutput '[ERROR] Redis not installed. Run: ergoms install-redis' Red
        return
    }

    $service = Get-Service -Name $script:RedisServiceName -ErrorAction SilentlyContinue
    if ($service) {
        if ($service.Status -ne 'Running') {
            Start-Service -Name $script:RedisServiceName
        }
        Write-ColorOutput '[OK] Redis service running' Green
        return
    }

    Stop-RedisProcess -Root $Root

    $redisDir = Get-RedisDir -Root $Root
    $serverExe = Get-RedisServerExe -Root $Root
    $confPath = Get-RedisConfPath -Root $Root

    Write-ColorOutput '-> Starting Redis...' Cyan
    Start-Process -FilePath $serverExe -ArgumentList "`"$confPath`"" -WindowStyle Hidden -WorkingDirectory $redisDir
    Start-Sleep -Seconds 2

    if (Test-RedisPing -Root $Root) {
        Write-ColorOutput '[OK] Redis started' Green
    }
    else {
        Write-ColorOutput "[ERROR] Redis failed to start. Check logs: $(Join-Path $redisDir 'logs\redis.log')" Red
    }
}

function Restart-RedisProcess {
    param([string]$Root)

    if (-not (Test-RedisInstalled -Root $Root)) {
        Write-ColorOutput '[ERROR] Redis not installed. Run: ergoms install-redis' Red
        return
    }

    $service = Get-Service -Name $script:RedisServiceName -ErrorAction SilentlyContinue
    if ($service) {
        Restart-Service -Name $script:RedisServiceName -Force
        Write-ColorOutput '[OK] Redis service restarted' Green
        return
    }

    Stop-RedisProcess -Root $Root
    Start-RedisProcess -Root $Root
}

function Test-RedisPing {
    param([string]$Root)

    return Invoke-RedisPythonScript -Root $Root -ScriptName 'install_redis.py' -ExtraArgs @(
        '--root', $Root,
        '--ping-only'
    )
}

function Show-RedisStatus {
    param([string]$Root)

    $redisDir = Get-RedisDir -Root $Root
    $installed = Test-RedisInstalled -Root $Root

    if (-not $installed) {
        Write-ColorOutput 'Redis: Not installed' DarkGray
        Write-ColorOutput "  Expected path: $redisDir" DarkGray
        return
    }

    Write-ColorOutput '' White
    Write-ColorOutput '=== Redis Status ===' Cyan

    $service = Get-Service -Name $script:RedisServiceName -ErrorAction SilentlyContinue
    if ($service) {
        $statusColor = switch ($service.Status) {
            'Running' { 'Green' }
            'Stopped' { 'Red' }
            default { 'Yellow' }
        }
        Write-Host "  Service ($($script:RedisServiceName)): " -NoNewline
        Write-ColorOutput "$($service.Status)" $statusColor
    }
    else {
        $procs = Get-Process -Name 'redis-server' -ErrorAction SilentlyContinue
        if ($procs) {
            Write-Host '  Process: ' -NoNewline
            Write-ColorOutput "Running (PID: $($procs[0].Id))" Green
        }
        else {
            Write-Host '  Process: ' -NoNewline
            Write-ColorOutput 'Not running' Red
        }
    }

    Write-ColorOutput "  Path: $redisDir" Cyan
    Write-ColorOutput "  Config: $(Get-RedisConfPath -Root $Root)" Cyan

    if (Test-RedisPing -Root $Root) {
        Write-ColorOutput '  Ping: PONG' Green
    }
    else {
        Write-ColorOutput '  Ping: failed (server not running?)' Yellow
    }
}

function Uninstall-Redis {
    param(
        [string]$Root,
        [switch]$PurgeData
    )

    Write-ColorOutput '=== Redis: Uninstall ===' Cyan
    Stop-RedisProcess -Root $Root

    $service = Get-Service -Name $script:RedisServiceName -ErrorAction SilentlyContinue
    if ($service) {
        $nssmExe = Install-NSSM
        & $nssmExe stop $script:RedisServiceName 2>$null
        & $nssmExe remove $script:RedisServiceName confirm 2>$null
        Write-ColorOutput '[OK] Redis service removed' Green
    }

    $redisDir = Get-RedisDir -Root $Root
    if ($PurgeData -and (Test-Path $redisDir)) {
        Remove-Item -Path $redisDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-ColorOutput "[OK] Removed $redisDir" Green
    }
    else {
        Write-ColorOutput '[OK] Redis stopped (binaries kept; use -Purge to remove packages/redis)' Green
    }
}
