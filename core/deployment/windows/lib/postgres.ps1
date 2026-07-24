# PostgreSQL management for Windows
# Установка и управление portable PostgreSQL в virtual_env/packages/postgres

$script:PostgresServiceName = 'ergo_ms_postgres'

function Get-PostgresPackagesRelativePath {
    return Join-Path 'virtual_env' (Join-Path 'packages' 'postgres')
}

function Get-PostgresDir {
    param([string]$Root)
    return Join-Path $Root (Get-PostgresPackagesRelativePath)
}

function Get-PostgresBinDir {
    param([string]$Root)
    $dir = Get-PostgresDir -Root $Root
    $direct = Join-Path $dir 'bin'
    if (Test-Path (Join-Path $direct 'postgres.exe')) { return $direct }
    $nested = Join-Path $dir 'pgsql\bin'
    if (Test-Path (Join-Path $nested 'postgres.exe')) { return $nested }
    return $direct
}

function Get-PostgresExe {
    param([string]$Root, [string]$Name)
    return Join-Path (Get-PostgresBinDir -Root $Root) "$Name.exe"
}

function Get-PostgresDataDir {
    param([string]$Root)
    return Join-Path (Get-PostgresDir -Root $Root) 'data'
}

function Get-ProjectPythonExeForPostgres {
    param([string]$Root)
    return Join-Path $Root 'virtual_env\python\Scripts\python.exe'
}

function Test-PostgresInstalled {
    param([string]$Root)
    return (Test-Path (Get-PostgresExe -Root $Root -Name 'postgres')) -and (Test-Path (Get-PostgresExe -Root $Root -Name 'pg_ctl'))
}

function Test-PostgresPortablePresent {
    param([string]$Root)
    if (Test-PostgresInstalled -Root $Root) { return $true }
    $svc = Get-Service -Name $script:PostgresServiceName -ErrorAction SilentlyContinue
    return $null -ne $svc
}

function Invoke-PostgresPythonScript {
    param(
        [string]$Root,
        [string]$ScriptName,
        [string[]]$ExtraArgs = @()
    )

    $pythonExe = Get-ProjectPythonExeForPostgres -Root $Root
    $scriptPath = Join-Path $Root "core\deployment\scripts\$ScriptName"
    if (-not (Test-Path $pythonExe)) {
        Write-ColorOutput '[ERROR] Python не найден. Выполните: ergoms setup' Red
        return $false
    }
    if (-not (Test-Path $scriptPath)) {
        Write-ColorOutput "[ERROR] Скрипт не найден: $scriptPath" Red
        return $false
    }
    $env:PYTHONIOENCODING = 'utf-8'
    $env:PYTHONUTF8 = '1'
    & $pythonExe $scriptPath @ExtraArgs
    return ($LASTEXITCODE -eq 0)
}

function Test-SystemPostgresqlService {
    param([string]$Root)
    return Invoke-PostgresPythonScript -Root $Root -ScriptName 'install_postgres.py' -ExtraArgs @(
        '--root', $Root,
        '--check-system-only'
    )
}

function Test-PostgresForceInstall {
    param([string]$Root)
    return Invoke-PostgresPythonScript -Root $Root -ScriptName 'install_postgres.py' -ExtraArgs @(
        '--root', $Root,
        '--check-force-only'
    )
}

function Install-Postgres {
    param(
        [string]$Root,
        [string]$ListenPort = '',
        [switch]$NoSkipSystem
    )

    Write-ColorOutput '' White
    Write-ColorOutput '=== PostgreSQL: установка и запуск ===' Cyan
    Write-ColorOutput '' White

    $forceEnv = Test-PostgresForceInstall -Root $Root
    if ((Test-SystemPostgresqlService -Root $Root) -and -not $forceEnv -and -not $NoSkipSystem) {
        Write-ColorOutput '[SKIP] Найдена системная служба PostgreSQL — portable не устанавливается' Gray
        Write-ColorOutput '[INFO] Принудительно: POSTGRES_FORCE_INSTALL=true в .env' Cyan
        return
    }

    $extra = @('--root', $Root, '--no-start')
    if ($ListenPort) {
        $extra += @('--port', $ListenPort)
    }
    if ($forceEnv -or $NoSkipSystem) {
        $extra += '--no-skip-system'
    }

    $ok = Invoke-PostgresPythonScript -Root $Root -ScriptName 'install_postgres.py' -ExtraArgs $extra
    if (-not $ok) {
        Write-ColorOutput '[ERROR] Установка PostgreSQL не удалась' Red
        exit 1
    }

    if (-not (Test-PostgresInstalled -Root $Root)) {
        Write-ColorOutput '[SKIP] Portable PostgreSQL не установлен (системная СУБД или пропуск)' Gray
        return
    }

    Install-PostgresService -Root $Root

    $dbOk = Invoke-PostgresPythonScript -Root $Root -ScriptName 'install_postgres.py' -ExtraArgs @(
        '--root', $Root,
        '--ensure-db-only'
    )
    if (-not $dbOk) {
        Write-ColorOutput '[ERROR] Не удалось создать базы данных' Red
        exit 1
    }

    $pgDir = Get-PostgresDir -Root $Root
    Write-ColorOutput '' White
    Write-ColorOutput '[OK] PostgreSQL установлен' Green
    Write-ColorOutput "    Путь: $pgDir" Cyan
    Write-ColorOutput "    Служба: $($script:PostgresServiceName)" Cyan
}

function Install-PostgresService {
    param([string]$Root)

    if (-not (Test-PostgresInstalled -Root $Root)) {
        Write-ColorOutput '[ERROR] PostgreSQL не установлен. Выполните: ergoms install-postgres' Red
        return
    }

    $pgDir = Get-PostgresDir -Root $Root
    $postgresExe = Get-PostgresExe -Root $Root -Name 'postgres'
    $dataDir = Get-PostgresDataDir -Root $Root
    $nssmExe = Install-NSSM -Root $Root

    $pgCtl = Get-PostgresExe -Root $Root -Name 'pg_ctl'
    if (Test-Path $pgCtl) {
        & $pgCtl stop -D $dataDir -m fast -w 2>$null | Out-Null
    }

    $existingService = Get-Service -Name $script:PostgresServiceName -ErrorAction SilentlyContinue
    if ($existingService) {
        Write-ColorOutput "-> Служба $($script:PostgresServiceName) уже существует, переустановка..." Yellow
        if ($existingService.Status -eq 'Running') {
            & $nssmExe stop $script:PostgresServiceName 2>$null
            Start-Sleep -Seconds 2
        }
        & $nssmExe remove $script:PostgresServiceName confirm 2>$null
        Start-Sleep -Seconds 1
    }

    Write-ColorOutput '-> Установка PostgreSQL как службы Windows...' Cyan
    & $nssmExe install $script:PostgresServiceName $postgresExe
    & $nssmExe set $script:PostgresServiceName AppParameters "-D `"$dataDir`""
    & $nssmExe set $script:PostgresServiceName AppDirectory $pgDir
    & $nssmExe set $script:PostgresServiceName DisplayName 'Ergo MS - PostgreSQL'
    & $nssmExe set $script:PostgresServiceName Description 'Ergo MS portable PostgreSQL'

    $logsDir = Join-Path $pgDir 'logs'
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
    & $nssmExe set $script:PostgresServiceName AppStdout (Join-Path $logsDir 'service_stdout.log')
    & $nssmExe set $script:PostgresServiceName AppStderr (Join-Path $logsDir 'service_stderr.log')
    & $nssmExe set $script:PostgresServiceName Start SERVICE_AUTO_START
    & $nssmExe set $script:PostgresServiceName AppExit Default Restart
    & $nssmExe set $script:PostgresServiceName AppRestartDelay 5000

    Start-Service -Name $script:PostgresServiceName
    Start-Sleep -Seconds 2
    Write-ColorOutput '[OK] Служба PostgreSQL установлена и запущена' Green
}

function Stop-PostgresProcess {
    param(
        [string]$Root = '',
        [switch]$Quiet
    )

    $service = Get-Service -Name $script:PostgresServiceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') {
        if (-not $Quiet) {
            Write-ColorOutput '-> Остановка службы PostgreSQL...' Cyan
        }
        Stop-Service -Name $script:PostgresServiceName -Force
        if (-not $Quiet) {
            Write-ColorOutput '[OK] Служба PostgreSQL остановлена' Green
        }
        return
    }

    if ($Root -and (Test-PostgresInstalled -Root $Root)) {
        $pgCtl = Get-PostgresExe -Root $Root -Name 'pg_ctl'
        $dataDir = Get-PostgresDataDir -Root $Root
        if (Test-Path $pgCtl) {
            if (-not $Quiet) {
                Write-ColorOutput '-> Остановка PostgreSQL (pg_ctl)...' Cyan
            }
            & $pgCtl stop -D $dataDir -m fast -w 2>$null | Out-Null
        }
    }

    if (-not $Quiet) {
        Write-ColorOutput '[OK] PostgreSQL остановлен' Green
    }
}

function Start-PostgresProcess {
    param([string]$Root)

    if (-not (Test-PostgresInstalled -Root $Root)) {
        Write-ColorOutput '[ERROR] PostgreSQL не установлен. Выполните: ergoms install-postgres' Red
        return
    }

    $service = Get-Service -Name $script:PostgresServiceName -ErrorAction SilentlyContinue
    if ($service) {
        if ($service.Status -ne 'Running') {
            Start-Service -Name $script:PostgresServiceName
        }
        Write-ColorOutput '[OK] Служба PostgreSQL запущена' Green
        return
    }

    $pgCtl = Get-PostgresExe -Root $Root -Name 'pg_ctl'
    $dataDir = Get-PostgresDataDir -Root $Root
    $logFile = Join-Path (Get-PostgresDir -Root $Root) 'logs\pg_ctl.log'
    Write-ColorOutput '-> Запуск PostgreSQL...' Cyan
    & $pgCtl start -D $dataDir -l $logFile -w -t 60
    if (Test-PostgresPing -Root $Root) {
        Write-ColorOutput '[OK] PostgreSQL запущен' Green
    }
    else {
        Write-ColorOutput '[ERROR] PostgreSQL не запустился' Red
        exit 1
    }
}

function Restart-PostgresProcess {
    param([string]$Root)

    if (-not (Test-PostgresInstalled -Root $Root)) {
        Write-ColorOutput '[ERROR] PostgreSQL не установлен. Выполните: ergoms install-postgres' Red
        return
    }

    $service = Get-Service -Name $script:PostgresServiceName -ErrorAction SilentlyContinue
    if ($service) {
        Restart-Service -Name $script:PostgresServiceName -Force
        Write-ColorOutput '[OK] Служба PostgreSQL перезапущена' Green
        return
    }

    Stop-PostgresProcess -Root $Root
    Start-PostgresProcess -Root $Root
}

function Test-PostgresPing {
    param([string]$Root)

    return Invoke-PostgresPythonScript -Root $Root -ScriptName 'install_postgres.py' -ExtraArgs @(
        '--root', $Root,
        '--ping-only'
    )
}

function Show-PostgresStatus {
    param([string]$Root)

    $pgDir = Get-PostgresDir -Root $Root
    $installed = Test-PostgresInstalled -Root $Root

    if (-not $installed) {
        Write-ColorOutput 'PostgreSQL: не установлен' DarkGray
        Write-ColorOutput "  Ожидаемый путь: $pgDir" DarkGray
        return
    }

    Write-ColorOutput '' White
    Write-ColorOutput '=== Статус PostgreSQL ===' Cyan

    $service = Get-Service -Name $script:PostgresServiceName -ErrorAction SilentlyContinue
    if ($service) {
        $statusColor = switch ($service.Status) {
            'Running' { 'Green' }
            'Stopped' { 'Red' }
            default { 'Yellow' }
        }
        Write-Host "  Служба ($($script:PostgresServiceName)): " -NoNewline
        Write-ColorOutput "$($service.Status)" $statusColor
    }
    else {
        Write-ColorOutput '  Служба: не зарегистрирована' Yellow
    }

    Write-ColorOutput "  Путь: $pgDir" Cyan

    if (Test-PostgresPing -Root $Root) {
        Write-ColorOutput '  Ping: OK' Green
    }
    else {
        Write-ColorOutput '  Ping: не удался (сервер не запущен?)' Yellow
    }
}

function Uninstall-Postgres {
    param(
        [string]$Root,
        [switch]$PurgeData
    )

    Write-ColorOutput '=== PostgreSQL: удаление ===' Cyan
    Stop-PostgresProcess -Root $Root -Quiet

    $service = Get-Service -Name $script:PostgresServiceName -ErrorAction SilentlyContinue
    if ($service) {
        $nssmExe = Install-NSSM -Root $Root
        & $nssmExe stop $script:PostgresServiceName 2>$null
        & $nssmExe remove $script:PostgresServiceName confirm 2>$null
        Write-ColorOutput '[OK] Служба PostgreSQL удалена' Green
    }

    $pgDir = Get-PostgresDir -Root $Root
    if ($PurgeData -and (Test-Path $pgDir)) {
        Remove-Item -Path $pgDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-ColorOutput "[OK] Удалено: $pgDir" Green
    }
    else {
        Write-ColorOutput '[OK] PostgreSQL остановлен (бинарники сохранены; для удаления packages/postgres используйте -Purge)' Green
    }
}
