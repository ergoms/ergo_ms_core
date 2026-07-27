# PostgreSQL management for Windows
# Установка и управление portable PostgreSQL в virtual_env/packages/postgres

$script:PostgresServiceName = 'ergo_ms_postgres'
# LocalSystem = admin → postgres отказывается стартовать; NetworkService — без elevated token.
$script:PostgresServiceAccount = 'NT AUTHORITY\NetworkService'
$script:PostgresServiceAccountSid = 'S-1-5-20'

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

function Invoke-PostgresCtl {
    param(
        [string]$PgCtl,
        [string[]]$Arguments
    )

    # Native stderr (например «PID file does not exist») при Stop становится terminating.
    $prevEa = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $PgCtl @Arguments 2>&1 | Out-Null
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEa
    }
}

function Stop-PostgresClusterIfRunning {
    param(
        [string]$Root,
        [string]$DataDir = ''
    )

    $pgCtl = Get-PostgresExe -Root $Root -Name 'pg_ctl'
    if (-not (Test-Path $pgCtl)) { return }
    if (-not $DataDir) { $DataDir = Get-PostgresDataDir -Root $Root }
    $pidFile = Join-Path $DataDir 'postmaster.pid'
    if (-not (Test-Path $pidFile)) { return }
    Invoke-PostgresCtl -PgCtl $pgCtl -Arguments @('stop', '-D', $DataDir, '-m', 'fast', '-w') | Out-Null
}

function Grant-PostgresServiceDirectoryAccess {
    param([string]$PgDir)

    if (-not (Test-Path $PgDir)) { return }

    # SID NETWORK SERVICE — стабильнее локализованного имени для icacls.
    $grant = "*$($script:PostgresServiceAccountSid):(OI)(CI)M"
    $prevEa = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & icacls $PgDir /grant $grant /T /C /Q | Out-Null
    }
    finally {
        $ErrorActionPreference = $prevEa
    }
}

function Wait-PostgresServiceRemoved {
    param(
        [string]$ServiceName = $script:PostgresServiceName,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if (-not $svc) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return -not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)
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
    $env:PYTHONUNBUFFERED = '1'
    & $pythonExe -u $scriptPath @ExtraArgs
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
    $listenPort = Get-PostgresListenPort -Root $Root
    $listenBind = Get-PostgresListenBind -Root $Root
    Write-ColorOutput '' White
    Write-ColorOutput '[OK] PostgreSQL установлен' Green
    Write-ColorOutput "    Путь: $pgDir" Cyan
    Write-ColorOutput "    Служба: $($script:PostgresServiceName)" Cyan
    Write-ColorOutput "    Прослушивание: ${listenBind}:${listenPort}" Cyan
    Write-PostgresDbAccessSummary -Root $Root
    Write-PostgresYamlPortHint -Root $Root -ListenPort $listenPort
}

function Get-NssmParameterValue {
    param(
        [string]$NssmExe,
        [string]$ServiceName,
        [string]$Parameter
    )

    $prevEa = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $NssmExe get $ServiceName $Parameter 2>&1
        if ($LASTEXITCODE -ne 0) { return '' }
        # nssm get пишет UTF-16; в PowerShell строка содержит NUL между символами.
        $text = [string]($raw | Out-String)
        return ($text -replace "`0", '' -replace '[\r\n]+', '').Trim()
    }
    finally {
        $ErrorActionPreference = $prevEa
    }
}

function ConvertTo-NormalizedFsPath {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
    $trimmed = $PathValue.Trim().Trim('"')
    try {
        return [System.IO.Path]::GetFullPath($trimmed).TrimEnd('\')
    }
    catch {
        return $trimmed.TrimEnd('\')
    }
}

function ConvertTo-NormalizedPostgresAppParameters {
    param(
        [string]$Value,
        [string]$DataDir
    )

    $normalizedData = ConvertTo-NormalizedFsPath -PathValue $DataDir
    if ($Value -match '(?i)^-D\s+"?(.+?)"?\s*$') {
        return "-D $(ConvertTo-NormalizedFsPath -PathValue $Matches[1])"
    }
    return "-D $normalizedData"
}

function Test-PostgresNssmServiceMatches {
    param(
        [string]$NssmExe,
        [string]$PostgresExe,
        [string]$PgDir,
        [string]$DataDir,
        [string]$StdoutLog,
        [string]$StderrLog
    )

    $name = $script:PostgresServiceName
    $checks = @(
        @{
            Param = 'Application'
            Expected = ConvertTo-NormalizedFsPath -PathValue $PostgresExe
            Actual = ConvertTo-NormalizedFsPath -PathValue (Get-NssmParameterValue -NssmExe $NssmExe -ServiceName $name -Parameter 'Application')
        },
        @{
            Param = 'AppDirectory'
            Expected = ConvertTo-NormalizedFsPath -PathValue $PgDir
            Actual = ConvertTo-NormalizedFsPath -PathValue (Get-NssmParameterValue -NssmExe $NssmExe -ServiceName $name -Parameter 'AppDirectory')
        },
        @{
            Param = 'AppParameters'
            Expected = ConvertTo-NormalizedPostgresAppParameters -Value "-D `"$DataDir`"" -DataDir $DataDir
            Actual = ConvertTo-NormalizedPostgresAppParameters -Value (Get-NssmParameterValue -NssmExe $NssmExe -ServiceName $name -Parameter 'AppParameters') -DataDir $DataDir
        },
        @{
            Param = 'ObjectName'
            Expected = $script:PostgresServiceAccount
            Actual = Get-NssmParameterValue -NssmExe $NssmExe -ServiceName $name -Parameter 'ObjectName'
        },
        @{
            Param = 'Start'
            Expected = 'SERVICE_AUTO_START'
            Actual = Get-NssmParameterValue -NssmExe $NssmExe -ServiceName $name -Parameter 'Start'
        },
        @{
            Param = 'AppStdout'
            Expected = ConvertTo-NormalizedFsPath -PathValue $StdoutLog
            Actual = ConvertTo-NormalizedFsPath -PathValue (Get-NssmParameterValue -NssmExe $NssmExe -ServiceName $name -Parameter 'AppStdout')
        },
        @{
            Param = 'AppStderr'
            Expected = ConvertTo-NormalizedFsPath -PathValue $StderrLog
            Actual = ConvertTo-NormalizedFsPath -PathValue (Get-NssmParameterValue -NssmExe $NssmExe -ServiceName $name -Parameter 'AppStderr')
        },
        @{
            Param = 'AppRestartDelay'
            Expected = '5000'
            Actual = Get-NssmParameterValue -NssmExe $NssmExe -ServiceName $name -Parameter 'AppRestartDelay'
        }
    )

    foreach ($item in $checks) {
        if (-not [string]::Equals([string]$item.Expected, [string]$item.Actual, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    return $true
}

function Start-PostgresServiceAndVerify {
    param(
        [string]$StderrLog,
        [string]$OkMessage
    )

    try {
        Start-Service -Name $script:PostgresServiceName -ErrorAction Stop
    }
    catch {
        Write-ColorOutput (Format-ErgoConsole -Level error -Message 'Не удалось запустить службу PostgreSQL') Red
        if (Test-Path $StderrLog) {
            Get-Content $StderrLog -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object {
                Write-ColorOutput "    $_" Red
            }
        }
        throw
    }
    Start-Sleep -Seconds 2
    $running = Get-Service -Name $script:PostgresServiceName -ErrorAction SilentlyContinue
    if (-not $running -or $running.Status -ne 'Running') {
        Write-ColorOutput (Format-ErgoConsole -Level error -Message 'Служба PostgreSQL не перешла в Running') Red
        if (Test-Path $StderrLog) {
            Get-Content $StderrLog -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object {
                Write-ColorOutput "    $_" Red
            }
        }
        exit 1
    }
    Write-ColorOutput (Format-ErgoConsole -Level ok -Message $OkMessage) Green
}

function Install-PostgresService {
    param([string]$Root)

    if (-not (Test-PostgresInstalled -Root $Root)) {
        Write-ColorOutput (Format-ErgoConsole -Level error -Message 'PostgreSQL не установлен. Выполните: ergoms install-postgres') Red
        return
    }

    $pgDir = Get-PostgresDir -Root $Root
    $postgresExe = Get-PostgresExe -Root $Root -Name 'postgres'
    $dataDir = Get-PostgresDataDir -Root $Root
    $nssmExe = Install-NSSM -Root $Root

    $logsDir = Join-Path $pgDir 'logs'
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
    $stderrLog = Join-Path $logsDir 'service_stderr.log'
    $stdoutLog = Join-Path $logsDir 'service_stdout.log'

    $existingService = Get-Service -Name $script:PostgresServiceName -ErrorAction SilentlyContinue
    if (
        $existingService -and
        (Test-PostgresNssmServiceMatches -NssmExe $nssmExe -PostgresExe $postgresExe -PgDir $pgDir -DataDir $dataDir -StdoutLog $stdoutLog -StderrLog $stderrLog)
    ) {
        Grant-PostgresServiceDirectoryAccess -PgDir $pgDir
        if ($existingService.Status -eq 'Running') {
            Write-ColorOutput (Format-ErgoConsole -Level skip -Message "Служба $($script:PostgresServiceName) уже настроена и запущена") Gray
            return
        }
        Write-ColorOutput (Format-ErgoConsole -Level info -Message "Служба $($script:PostgresServiceName) уже настроена — запуск...") Cyan
        Start-PostgresServiceAndVerify -StderrLog $stderrLog -OkMessage 'Служба PostgreSQL запущена'
        return
    }

    if ($existingService) {
        Write-ColorOutput (Format-ErgoConsole -Level info -Message "Служба $($script:PostgresServiceName): параметры устарели, переустановка...") Cyan
    }

    Stop-PostgresClusterIfRunning -Root $Root -DataDir $dataDir

    if ($existingService) {
        if ($existingService.Status -eq 'Running' -or $existingService.Status -eq 'Paused') {
            $prevEa = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & $nssmExe stop $script:PostgresServiceName 2>&1 | Out-Null
                Stop-Service -Name $script:PostgresServiceName -Force -ErrorAction SilentlyContinue
            }
            finally {
                $ErrorActionPreference = $prevEa
            }
            Start-Sleep -Seconds 2
        }
        & $nssmExe remove $script:PostgresServiceName confirm 2>$null
        if (-not (Wait-PostgresServiceRemoved)) {
            Write-ColorOutput (Format-ErgoConsole -Level error -Message 'Служба PostgreSQL помечена на удаление, но ещё не снята. Повторите команду через несколько секунд') Red
            exit 1
        }
    }

    Write-ColorOutput (Format-ErgoConsole -Level info -Message 'Установка PostgreSQL как службы Windows...') Cyan
    & $nssmExe install $script:PostgresServiceName $postgresExe
    if ($LASTEXITCODE -ne 0) {
        Write-ColorOutput (Format-ErgoConsole -Level error -Message 'Не удалось зарегистрировать службу PostgreSQL в NSSM') Red
        exit 1
    }
    & $nssmExe set $script:PostgresServiceName AppParameters "-D `"$dataDir`""
    & $nssmExe set $script:PostgresServiceName AppDirectory $pgDir
    & $nssmExe set $script:PostgresServiceName DisplayName 'Ergo MS - PostgreSQL'
    & $nssmExe set $script:PostgresServiceName Description 'Ergo MS portable PostgreSQL'
    # LocalSystem запрещён для postmaster; пустой пароль — для встроенной учётки.
    & $nssmExe set $script:PostgresServiceName ObjectName $script:PostgresServiceAccount ''

    if (Test-Path $stderrLog) { Clear-Content $stderrLog -ErrorAction SilentlyContinue }
    if (Test-Path $stdoutLog) { Clear-Content $stdoutLog -ErrorAction SilentlyContinue }
    & $nssmExe set $script:PostgresServiceName AppStdout $stdoutLog
    & $nssmExe set $script:PostgresServiceName AppStderr $stderrLog
    & $nssmExe set $script:PostgresServiceName Start SERVICE_AUTO_START
    & $nssmExe set $script:PostgresServiceName AppExit Default Restart
    & $nssmExe set $script:PostgresServiceName AppRestartDelay 5000

    Grant-PostgresServiceDirectoryAccess -PgDir $pgDir
    Start-PostgresServiceAndVerify -StderrLog $stderrLog -OkMessage 'Служба PostgreSQL установлена и запущена'
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
        $dataDir = Get-PostgresDataDir -Root $Root
        $pidFile = Join-Path $dataDir 'postmaster.pid'
        if (Test-Path $pidFile) {
            if (-not $Quiet) {
                Write-ColorOutput '-> Остановка PostgreSQL (pg_ctl)...' Cyan
            }
            Stop-PostgresClusterIfRunning -Root $Root -DataDir $dataDir
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

function Migrate-PostgresToPortable {
    param(
        [string]$Root,
        [string[]]$ExtraArgs = @()
    )

    Write-ColorOutput '' White
    Write-ColorOutput '=== PostgreSQL: миграция данных в portable ===' Cyan
    Write-ColorOutput '' White

    if (-not (Test-PostgresInstalled -Root $Root)) {
        Write-ColorOutput (Format-ErgoConsole -Level error -Message 'PostgreSQL не установлен. Выполните: ergoms install-postgres') Red
        exit 1
    }

    $scriptArgs = @('--root', $Root)
    if ($ExtraArgs) {
        $scriptArgs += $ExtraArgs
    }
    $ok = Invoke-PostgresPythonScript -Root $Root -ScriptName 'migrate_postgres_to_portable.py' -ExtraArgs $scriptArgs
    if (-not $ok) {
        exit 1
    }
}

function Get-PostgresYamlDefaultField {
    param(
        [string]$Root,
        [string]$FieldName
    )

    $yamlPath = Join-Path $Root 'databases.yaml'
    if (-not (Test-Path $yamlPath)) { return $null }
    $inDefault = $false
    foreach ($line in Get-Content $yamlPath -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*default:\s*$') { $inDefault = $true; continue }
        if ($inDefault -and $line -match '^\s{2}\w+:\s*$') { break }
        if ($inDefault -and $line -match ("^\s+" + [regex]::Escape($FieldName) + ":\s*(.+)$")) {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }
    return $null
}

function Get-PostgresListenPort {
    param([string]$Root)

    $portFile = Join-Path (Get-PostgresDir -Root $Root) 'PORT'
    if (Test-Path $portFile) {
        $raw = (Get-Content $portFile -TotalCount 1 -ErrorAction SilentlyContinue)
        if ($raw -match '^\d+$') { return $raw.Trim() }
    }
    $yamlPort = Get-PostgresYamlDefaultField -Root $Root -FieldName 'port'
    if ($yamlPort -match '^\d+$') { return $yamlPort }
    return '5433'
}

function Get-PostgresListenBind {
    param([string]$Root)

    $yamlHost = Get-PostgresYamlDefaultField -Root $Root -FieldName 'host'
    if ($yamlHost) {
        if ($yamlHost -in @('localhost', '::1')) { return '127.0.0.1' }
        return $yamlHost
    }
    return '127.0.0.1'
}

function Get-PostgresDbAccessDefaults {
    param([string]$Root)

    $name = Get-PostgresYamlDefaultField -Root $Root -FieldName 'name'
    if (-not $name) { $name = 'ergo_ms' }
    $user = Get-PostgresYamlDefaultField -Root $Root -FieldName 'user'
    if (-not $user) { $user = 'postgres' }
    $password = Get-PostgresYamlDefaultField -Root $Root -FieldName 'password'
    if (-not $password) { $password = 'admin' }
    return @{
        Name     = $name
        User     = $user
        Password = $password
    }
}

function Write-PostgresDbAccessSummary {
    param([string]$Root)

    $access = Get-PostgresDbAccessDefaults -Root $Root
    Write-ColorOutput "    База: $($access.Name)" Cyan
    Write-ColorOutput "    Пользователь: $($access.User)" Cyan
    Write-ColorOutput "    Пароль: $($access.Password)" Cyan
    Write-ColorOutput '[INFO] Источник: databases.yaml (default) или значения по умолчанию portable' Cyan
}

function Write-PostgresYamlPortHint {
    param(
        [string]$Root,
        [string]$ListenPort
    )

    $yamlPort = Get-PostgresYamlDefaultField -Root $Root -FieldName 'port'
    if (-not $yamlPort) {
        Write-ColorOutput "[INFO] Задайте default.port в databases.yaml (сейчас portable: $ListenPort)" Cyan
        return
    }
    if ($yamlPort -ne $ListenPort) {
        Write-ColorOutput "[WARNING] databases.yaml default.port=$yamlPort, portable слушает $ListenPort" Yellow
        Write-ColorOutput '[INFO] Переустановите portable (ergoms install-postgres) или выровняйте port в databases.yaml' Cyan
    }
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

    $listenPort = Get-PostgresListenPort -Root $Root
    $listenBind = Get-PostgresListenBind -Root $Root
    Write-ColorOutput "  Путь: $pgDir" Cyan
    Write-ColorOutput "  Прослушивание: ${listenBind}:${listenPort}" Cyan
    Write-PostgresYamlPortHint -Root $Root -ListenPort $listenPort

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
