. "$PSScriptRoot/nginx_common.ps1"

function Render-NginxTemplate {
    param(
        [string]$TemplatePath,
        [string]$Root,
        [string]$ServerName = 'localhost',
        [string]$ListenHost = '0.0.0.0',
        [string]$ListenPort = '80',
        [string]$SslCert = '',
        [string]$SslKey = '',
        [bool]$UseHttps = $false
    )

    $pythonExe = Join-Path $Root "virtual_env\python\Scripts\python.exe"
    $renderScript = Join-Path $Root "core\deployment\scripts\render_nginx_config.py"
    if ((Test-Path $pythonExe) -and (Test-Path $renderScript)) {
        $useHttpsArg = if ($UseHttps) { 'true' } else { 'false' }
        $arguments = @(
            $renderScript,
            '--template', $TemplatePath,
            '--root', $Root,
            '--server-name', $ServerName,
            '--listen-host', $ListenHost,
            '--listen-port', $ListenPort,
            '--use-https', $useHttpsArg
        )
        if ($SslCert) {
            $arguments += @('--ssl-cert', $SslCert)
        }
        if ($SslKey) {
            $arguments += @('--ssl-key', $SslKey)
        }

        $output = & $pythonExe @arguments 2>&1
        if ($LASTEXITCODE -eq 0 -and $output) {
            if ($output -is [System.Array]) {
                return ($output -join "`n")
            }
            return [string]$output
        }
        if ($LASTEXITCODE -ne 0 -and $output) {
            Write-ColorOutput "[WARNING] render_nginx_config.py завершился с ошибкой, используется запасной рендерер" Yellow
            $output | ForEach-Object { Write-ColorOutput $_ Yellow }
        }
    }

    $snippetsDir = Join-Path $Root "core/deployment/nginx/snippets"
    $rootForward = $Root -replace '\\', '/'
    $snippetsForward = $snippetsDir -replace '\\', '/'

    $content = Get-Content -Path $TemplatePath -Raw -Encoding UTF8
    $maintenanceSnippetPath = Join-Path $Root "core\deployment\nginx\snippets\maintenance.conf"
    $maintenanceSnippet = ''
    if (Test-Path $maintenanceSnippetPath) {
        $maintenanceSnippet = (Get-Content -Path $maintenanceSnippetPath -Raw -Encoding UTF8) -replace '\$\{ERGO_ROOT\}', $rootForward
    }
    $content = $content -replace '\$\{ERGO_ROOT\}', $rootForward
    $content = $content -replace '\$\{ERGO_SERVER_NAME\}', $ServerName
    $content = $content -replace '\$\{ERGO_LISTEN_HOST\}', $ListenHost
    $content = $content -replace '\$\{ERGO_LISTEN_PORT\}', $ListenPort
    $content = $content -replace '\$\{ERGO_NGINX_SNIPPETS\}', $snippetsForward
    $content = $content -replace '\$\{ERGO_SSL_CERT\}', ($SslCert -replace '\\', '/')
    $content = $content -replace '\$\{ERGO_SSL_KEY\}', ($SslKey -replace '\\', '/')
    $content = $content -replace '\$\{ERGO_HOST_POLICY_BLOCKS\}', ''
    $content = $content -replace '\$\{ERGO_HTTP_CANONICAL_REDIRECT\}', 'https://$host$request_uri'
    $content = $content -replace '\$\{ERGO_MAINTENANCE_SNIPPET\}', $maintenanceSnippet

    return $content
}

function Install-NginxConfig {
    param(
        [string]$Root,
        [string]$ServerName = 'localhost',
        [string]$ListenHost = '0.0.0.0',
        [string]$ListenPort = '80',
        [hashtable]$EnvVars = @{}
    )

    $nginxDir = Get-NginxDir -Root $Root
    $nginxExe = Install-NginxBinary -Root $Root

    $templatePath = Get-NginxTemplatePath -Root $Root -EnvVars $EnvVars -ListenPort $ListenPort
    if (-not (Test-Path $templatePath)) {
        Write-ColorOutput "[ERROR] Шаблон не найден: $templatePath" Red
        throw "Template not found"
    }

    $useHttps = Test-NginxUseHttps -EnvVars $EnvVars -ListenPort $ListenPort
    $sslCert = if ($EnvVars['ERGO_SSL_CERT']) { $EnvVars['ERGO_SSL_CERT'] } else { '' }
    $sslKey = if ($EnvVars['ERGO_SSL_KEY']) { $EnvVars['ERGO_SSL_KEY'] } else { '' }
    if ($useHttps) {
        Warn-NginxInsecureCerts -CertPath $sslCert -KeyPath $sslKey
    }

    $distPath = Join-Path $Root "core\client\dist"
    if (-not (Test-Path (Join-Path $distPath "index.html"))) {
        Write-ColorOutput "[ERROR] $distPath\index.html не найден." Red
        Write-ColorOutput "  Nginx отдаёт production-сборку, не Vite dev. Выполните:" Yellow
        Write-ColorOutput "    ergoms client-build" Yellow
        Write-ColorOutput "  Затем: ergoms install-nginx" Yellow
        throw "Client build not found"
    }

    $rendered = Render-NginxTemplate -TemplatePath $templatePath -Root $Root `
        -ServerName $ServerName -ListenHost $ListenHost -ListenPort $ListenPort `
        -SslCert $sslCert -SslKey $sslKey -UseHttps:$useHttps

    $confDir = Join-Path $nginxDir "conf"
    $confPath = Join-Path $confDir "${script:NginxConfName}.conf"
    New-Item -ItemType Directory -Path $confDir -Force | Out-Null

    [System.IO.File]::WriteAllText($confPath, $rendered, [System.Text.UTF8Encoding]::new($false))
    Write-ColorOutput "[OK] Конфиг записан: $confPath" Green

    $mainConf = Join-Path $confDir "nginx.conf"
    Write-NginxMainConfig -Root $Root -MainConfPath $mainConf -IncludeConfPath $confPath -NginxDir $nginxDir

    Write-ColorOutput "-> Проверка конфигурации nginx..." Cyan
    $testResult = Invoke-NginxCli -NginxExe $nginxExe -Arguments @('-t', '-c', $mainConf) -WorkingDirectory $nginxDir
    if ($testResult.ExitCode -ne 0) {
        Write-ColorOutput "[ERROR] nginx -t завершился с ошибкой:" Red
        Write-ColorOutput ($testResult.Output -join "`n") Red
        throw "Nginx config test failed"
    }
    Write-ColorOutput "[OK] Конфигурация корректна" Green

    return @{
        NginxExe = $nginxExe
        MainConf = $mainConf
        SiteConf = $confPath
        ServerName = $ServerName
        ListenPort = $ListenPort
    }
}

function Write-NginxMainConfig {
    param(
        [string]$Root,
        [string]$MainConfPath,
        [string]$IncludeConfPath,
        [string]$NginxDir
    )

    $includeForward = $IncludeConfPath -replace '\\', '/'
    $runtimeLogsDir = (Join-Path $NginxDir 'logs') -replace '\\', '/'
    $centralLogsDir = (Get-NginxCentralLogsDir -Root $Root) -replace '\\', '/'
    $tempDir = (Join-Path $NginxDir 'temp') -replace '\\', '/'

    $errorLogPath = (Invoke-NginxLogEnv -Root $Root -Command 'path' -Key 'NGINX_ERROR') -replace '\\', '/'
    if (-not $errorLogPath) {
        $errorLogPath = "$centralLogsDir/nginx-error.log"
    }

    $nginxErrorLevel = Invoke-NginxLogEnv -Root $Root -Command 'nginx-error-level'
    if (-not $nginxErrorLevel) {
        $nginxErrorLevel = 'warn'
    }

    $accessEnabled = Invoke-NginxLogEnv -Root $Root -Command 'nginx-access-enabled'
    if ($accessEnabled -eq 'false') {
        $accessLogLine = 'access_log off;'
    }
    else {
        $accessLogPath = (Invoke-NginxLogEnv -Root $Root -Command 'path' -Key 'NGINX_ACCESS') -replace '\\', '/'
        if (-not $accessLogPath) {
            $accessLogPath = "$centralLogsDir/nginx-access.log"
        }
        $accessLogLine = "access_log $accessLogPath;"
    }

    New-Item -ItemType Directory -Path (Join-Path $NginxDir 'logs') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $NginxDir 'temp') -Force | Out-Null
    New-Item -ItemType Directory -Path $centralLogsDir -Force | Out-Null

    $mainContent = @"
worker_processes auto;

error_log $errorLogPath $nginxErrorLevel;
pid       $runtimeLogsDir/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    $accessLogLine

    sendfile        on;
    keepalive_timeout 65;

    client_body_temp_path $tempDir/client_body;
    proxy_temp_path       $tempDir/proxy;
    fastcgi_temp_path     $tempDir/fastcgi;
    uwsgi_temp_path       $tempDir/uwsgi;
    scgi_temp_path        $tempDir/scgi;

    include $includeForward;
}
"@

    [System.IO.File]::WriteAllText($MainConfPath, $mainContent, [System.Text.UTF8Encoding]::new($false))
}

function Install-Nginx {
    param(
        [string]$Root,
        [string]$ServerName = '',
        [string]$ListenPort = '',
        [switch]$AsService
    )

    Remove-NginxLegacyInstall

    $ensureScript = Join-Path $Root "core\deployment\scripts\ensure_nginx_env.py"
    $pythonExe = Join-Path $Root "virtual_env\python\Scripts\python.exe"
    if ((Test-Path $ensureScript) -and (Test-Path $pythonExe)) {
        & $pythonExe $ensureScript 2>$null | Out-Host
    }

    $envVars = Read-NginxEnv -Root $Root
    if (-not $ServerName) {
        if ($envVars['NGINX_PUBLIC_HOST']) {
            $ServerName = $envVars['NGINX_PUBLIC_HOST']
        } elseif ($envVars['NGINX_SERVER_NAME']) {
            $ServerName = $envVars['NGINX_SERVER_NAME']
        } else {
            $ServerName = 'localhost'
        }
    }
    $ListenHost = if ($envVars['NGINX_LISTEN_HOST']) { $envVars['NGINX_LISTEN_HOST'] } else { '0.0.0.0' }
    if (-not $ListenPort) { $ListenPort = if ($envVars['NGINX_LISTEN_PORT']) { $envVars['NGINX_LISTEN_PORT'] } else { '80' } }

    Write-ColorOutput "" White
    Write-ColorOutput "=== Nginx: установка ===" Cyan
    Write-ColorOutput "" White

    $config = Install-NginxConfig -Root $Root -ServerName $ServerName -ListenHost $ListenHost `
        -ListenPort $ListenPort -EnvVars $envVars

    if ($AsService) {
        Install-NginxService -Root $Root
    }
    else {
        Start-NginxProcess -Root $Root
    }

    $nginxDir = Get-NginxDir -Root $Root
    $useHttps = Test-NginxUseHttps -EnvVars $envVars -ListenPort $ListenPort
    Write-ColorOutput "" White
    Write-ColorOutput "[OK] Nginx установлен и запущен" Green
        if ($useHttps) {
        Write-ColorOutput "    Прослушивание: https://${ServerName}:443" Cyan
    } else {
        Write-ColorOutput "    Прослушивание: http://${ServerName}:${ListenPort} (bind ${ListenHost})" Cyan
    }
    Write-ColorOutput "    Путь: $nginxDir" Cyan
    Write-ColorOutput "    Конфиг: $($config.SiteConf)" Cyan
    Write-ColorOutput "    Логи: $(Get-NginxCentralLogsDir -Root $Root)" Cyan
}

function Install-NginxService {
    param([string]$Root)

    if (-not (Test-NginxInstalled -Root $Root)) {
        Write-ColorOutput "[ERROR] Nginx не установлен. Выполните: ergoms install-nginx" Red
        return
    }

    $nginxDir = Get-NginxDir -Root $Root
    $nssmExe = Install-NSSM
    $nginxExe = Get-NginxExe -Root $Root
    $mainConf = Join-Path $nginxDir "conf\nginx.conf"

    $existingService = Get-Service -Name $script:NginxServiceName -ErrorAction SilentlyContinue
    if ($existingService) {
        Write-ColorOutput "-> Служба $($script:NginxServiceName) уже существует, переустановка..." Yellow
        if ($existingService.Status -eq 'Running') {
            & $nssmExe stop $script:NginxServiceName 2>$null
            Start-Sleep -Seconds 2
        }
        & $nssmExe remove $script:NginxServiceName confirm 2>$null
        Start-Sleep -Seconds 1
    }

    Write-ColorOutput "-> Установка nginx как службы Windows..." Cyan
    & $nssmExe install $script:NginxServiceName $nginxExe
    & $nssmExe set $script:NginxServiceName AppParameters "-c `"$($mainConf -replace '\\', '/')`""
    & $nssmExe set $script:NginxServiceName AppDirectory $nginxDir
    & $nssmExe set $script:NginxServiceName DisplayName "Ergo MS - Nginx"
    & $nssmExe set $script:NginxServiceName Description "Ergo MS Nginx reverse proxy"

    $logsDir = Join-Path $nginxDir "logs"
    & $nssmExe set $script:NginxServiceName AppStdout (Join-Path $logsDir "service_stdout.log")
    & $nssmExe set $script:NginxServiceName AppStderr (Join-Path $logsDir "service_stderr.log")
    & $nssmExe set $script:NginxServiceName Start SERVICE_AUTO_START
    & $nssmExe set $script:NginxServiceName AppExit Default Restart
    & $nssmExe set $script:NginxServiceName AppRestartDelay 5000

    Start-Service -Name $script:NginxServiceName
    Write-ColorOutput "[OK] Служба nginx установлена и запущена" Green
}

function Test-NginxProcessRunning {
    param([string]$Root = '')

    $service = Get-Service -Name $script:NginxServiceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') {
        return $true
    }
    if ($null -ne (Get-Process -Name 'nginx' -ErrorAction SilentlyContinue)) {
        return $true
    }
    if ($Root -and (Test-NginxInstalled -Root $Root)) {
        $pidFile = Join-Path (Get-NginxDir -Root $Root) 'logs\nginx.pid'
        if (Test-Path $pidFile) {
            $pidText = (Get-Content -Path $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($pidText -match '^\d+$') {
                if (Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue) {
                    return $true
                }
            }
        }
    }
    return $false
}

function Stop-NginxProcess {
    param(
        [string]$Root = '',
        [switch]$Quiet
    )

    if (-not (Test-NginxProcessRunning -Root $Root)) {
        if (-not $Quiet) {
            Write-ColorOutput '[SKIP] Nginx не был запущен' Gray
        }
        return
    }

    if (Test-Path (Join-Path $script:NginxLegacyBaseDir 'nginx.exe')) {
        Stop-NginxLegacyInstall
        if (-not (Test-NginxProcessRunning -Root $Root)) {
            if (-not $Quiet) {
                Write-ColorOutput '[OK] Nginx остановлен' Green
            }
            return
        }
    }

    $service = Get-Service -Name $script:NginxServiceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') {
        Write-ColorOutput '-> Остановка службы nginx...' Cyan
        Stop-Service -Name $script:NginxServiceName -Force
        if (Test-NginxProcessRunning -Root $Root) {
            Write-ColorOutput '[ERROR] Не удалось остановить службу nginx' Red
            exit 1
        }
        Write-ColorOutput '[OK] Служба nginx остановлена' Green
        return
    }

    if ($Root) {
        $nginxDir = Get-NginxDir -Root $Root
        $nginxExe = Get-NginxExe -Root $Root
        if (Test-Path $nginxExe) {
            $mainConf = (Join-Path $nginxDir 'conf\nginx.conf') -replace '\\', '/'
            Write-ColorOutput '-> Остановка процесса nginx...' Cyan
            Invoke-NginxCli -NginxExe $nginxExe -Arguments @('-s', 'quit', '-c', $mainConf) -WorkingDirectory $nginxDir | Out-Null
            Start-Sleep -Seconds 1
        }
        $pidFile = Join-Path $nginxDir 'logs\nginx.pid'
        if (Test-Path $pidFile) {
            Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        }
    }

    $procs = Get-Process -Name 'nginx' -ErrorAction SilentlyContinue
    if ($procs) {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    if (Test-NginxProcessRunning -Root $Root) {
        Write-ColorOutput '[ERROR] Не удалось остановить nginx' Red
        exit 1
    }
    Write-ColorOutput '[OK] Nginx остановлен' Green
}

function Start-NginxProcess {
    param([string]$Root)

    if (-not (Test-NginxInstalled -Root $Root)) {
        Write-ColorOutput "[ERROR] Nginx не установлен. Выполните: ergoms install-nginx" Red
        return
    }

    Stop-NginxProcess -Root $Root -Quiet

    $nginxDir = Get-NginxDir -Root $Root
    $nginxExe = Get-NginxExe -Root $Root
    $mainConf = (Join-Path $nginxDir "conf\nginx.conf") -replace '\\', '/'
    $pidFile = Join-Path $nginxDir "logs\nginx.pid"
    if (Test-Path $pidFile) {
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }

    Write-ColorOutput "-> Запуск nginx..." Cyan
    Push-Location $nginxDir
    try {
        Start-Process -FilePath $nginxExe -ArgumentList "-c", $mainConf -WindowStyle Hidden -WorkingDirectory $nginxDir
    }
    finally {
        Pop-Location
    }

    Start-Sleep -Seconds 2

    $procs = @(Get-Process -Name "nginx" -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        Write-ColorOutput "[OK] Nginx запущен ($($procs.Count) проц., master PID: $($procs[0].Id))" Green
    }
    else {
        Write-ColorOutput "[ERROR] Nginx не запустился. Проверьте логи: $(Get-NginxErrorLogPath -Root $Root)" Red
    }
}

function Restart-NginxProcess {
    param([string]$Root)

    if (-not (Test-NginxInstalled -Root $Root)) {
        Write-ColorOutput "[ERROR] Nginx не установлен. Выполните: ergoms install-nginx" Red
        return
    }

    $service = Get-Service -Name $script:NginxServiceName -ErrorAction SilentlyContinue
    if ($service) {
        Write-ColorOutput "-> Перезапуск службы nginx..." Cyan
        Restart-Service -Name $script:NginxServiceName -Force
        Write-ColorOutput "[OK] Служба nginx перезапущена" Green
        return
    }

    Stop-NginxProcess -Root $Root
    Start-NginxProcess -Root $Root
}

function Invoke-NginxReload {
    param([string]$Root)

    if (-not (Test-NginxInstalled -Root $Root)) {
        Write-ColorOutput "[ERROR] Nginx не установлен. Выполните: ergoms install-nginx" Red
        return
    }

    $nginxDir = Get-NginxDir -Root $Root
    $nginxExe = Get-NginxExe -Root $Root
    $mainConf = Join-Path $nginxDir 'conf\nginx.conf'
    $siteConf = Join-Path $nginxDir "conf\$($script:NginxConfName).conf"
    if (Test-Path $siteConf) {
        Write-NginxMainConfig -Root $Root -MainConfPath $mainConf -IncludeConfPath $siteConf -NginxDir $nginxDir
    }

    $mainConfForward = $mainConf -replace '\\', '/'

    Write-ColorOutput "-> Проверка конфигурации..." Cyan
    $testResult = Invoke-NginxCli -NginxExe $nginxExe -Arguments @('-t', '-c', $mainConfForward) -WorkingDirectory $nginxDir
    if ($testResult.ExitCode -ne 0) {
        Write-ColorOutput "[ERROR] Проверка конфигурации завершилась с ошибкой:" Red
        Write-ColorOutput ($testResult.Output -join "`n") Red
        return
    }

    Write-ColorOutput "-> Перезагрузка nginx..." Cyan
    Invoke-NginxCli -NginxExe $nginxExe -Arguments @('-s', 'reload', '-c', $mainConfForward) -WorkingDirectory $nginxDir | Out-Null

    Write-ColorOutput "[OK] Nginx перезагружен" Green
}

function Show-NginxStatus {
    param([string]$Root)

    $nginxDir = Get-NginxDir -Root $Root
    $installed = Test-NginxInstalled -Root $Root
    $legacyExists = Test-Path (Join-Path $script:NginxLegacyBaseDir "nginx.exe")

    if (-not $installed -and -not $legacyExists) {
        Write-ColorOutput "Nginx: не установлен" DarkGray
        Write-ColorOutput "  Ожидаемый путь: $nginxDir" DarkGray
        return
    }

    Write-ColorOutput "" White
    Write-ColorOutput "=== Статус Nginx ===" Cyan

    if ($legacyExists) {
        Write-ColorOutput "  Устаревшая установка: $script:NginxLegacyBaseDir (выполните ergoms install-nginx для миграции)" Yellow
    }

    $service = Get-Service -Name $script:NginxServiceName -ErrorAction SilentlyContinue
    if ($service) {
        $statusColor = switch ($service.Status) {
            'Running' { 'Green' }
            'Stopped' { 'Red' }
            default { 'Yellow' }
        }
        Write-Host "  Service ($($script:NginxServiceName)): " -NoNewline
        Write-ColorOutput "$($service.Status)" $statusColor
    }
    else {
        $procs = Get-Process -Name "nginx" -ErrorAction SilentlyContinue
        if ($procs) {
            Write-Host "  Process: " -NoNewline
            Write-ColorOutput "Запущен (PID: $($procs[0].Id))" Green
        }
        else {
            Write-Host "  Process: " -NoNewline
            Write-ColorOutput "Не запущен" Red
        }
    }

    if ($installed) {
        Write-ColorOutput "  Путь: $nginxDir" Cyan
        $confPath = Join-Path $nginxDir "conf\${script:NginxConfName}.conf"
        if (Test-Path $confPath) {
            Write-ColorOutput "  Конфиг: установлен ($confPath)" Cyan
        }
        Write-ColorOutput "  Логи: $(Get-NginxCentralLogsDir -Root $Root)" Cyan
    }

    Write-ColorOutput "" White
}

function Test-NginxConfig {
    param([string]$Root)

    if (-not (Test-NginxInstalled -Root $Root)) {
        Write-ColorOutput "[ERROR] Nginx не установлен" Red
        return
    }

    $nginxDir = Get-NginxDir -Root $Root
    $nginxExe = Get-NginxExe -Root $Root
    $mainConf = (Join-Path $nginxDir "conf\nginx.conf") -replace '\\', '/'

    $testResult = Invoke-NginxCli -NginxExe $nginxExe -Arguments @('-t', '-c', $mainConf) -WorkingDirectory $nginxDir
    if ($testResult.ExitCode -ne 0) {
        Write-ColorOutput ($testResult.Output -join "`n") Red
    }
}

function Uninstall-Nginx {
    param(
        [string]$Root,
        [switch]$PurgeData
    )

    Write-ColorOutput "" White
    Write-ColorOutput "=== Nginx: удаление ===" Cyan
    Write-ColorOutput "" White

    Remove-NginxLegacyInstall

    $service = Get-Service -Name $script:NginxServiceName -ErrorAction SilentlyContinue
    if ($service) {
        Write-ColorOutput "-> Удаление службы nginx..." Yellow
        if ($service.Status -eq 'Running') {
            Stop-Service -Name $script:NginxServiceName -Force
            Start-Sleep -Seconds 2
        }

        $nssmDir = Get-NssmDir
        $nssmExe = Join-Path $nssmDir "nssm.exe"
        if (Test-Path $nssmExe) {
            & $nssmExe remove $script:NginxServiceName confirm 2>&1 | Out-Null
        }
        else {
            sc.exe delete $script:NginxServiceName 2>$null
        }
        Write-ColorOutput "[OK] Служба удалена" Green
    }
    else {
        Stop-NginxProcess -Root $Root -Quiet
    }

    $nginxDir = Get-NginxDir -Root $Root
    if ($PurgeData -and (Test-Path $nginxDir)) {
        Remove-Item $nginxDir -Recurse -Force
        Write-ColorOutput "[OK] Удалено: $nginxDir" Green
    }
    elseif (Test-Path $nginxDir) {
        $confPath = Join-Path $nginxDir "conf\${script:NginxConfName}.conf"
        if (Test-Path $confPath) {
            Remove-Item $confPath -Force
            Write-ColorOutput "[OK] Конфиг удалён: $confPath" Green
        }
    }

    Write-ColorOutput "[OK] Nginx удалён" Green
}
