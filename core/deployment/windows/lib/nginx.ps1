# Nginx management for Windows
# Установка, настройка и управление nginx на Windows

$script:NginxVersion = '1.27.4'
$script:NginxZipUrl = "https://nginx.org/download/nginx-$script:NginxVersion.zip"
$script:NginxLegacyBaseDir = "$env:ProgramData\ergo_ms\nginx"
$script:NginxServiceName = 'ergo_ms_nginx'
$script:NginxConfName = 'ergo_ms'

function Invoke-NginxCli {
    param(
        [string]$NginxExe,
        [string[]]$Arguments,
        [string]$WorkingDirectory = ''
    )

    $prevEa = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @()
    $exitCode = 0

    try {
        if ($WorkingDirectory) {
            Push-Location $WorkingDirectory
        }
        $output = @(& $NginxExe @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($WorkingDirectory) {
            Pop-Location
        }
        $ErrorActionPreference = $prevEa
    }

    return @{
        Output = $output
        ExitCode = $exitCode
    }
}

function Get-NginxPackagesRelativePath {
    return Join-Path "virtual_env" (Join-Path "packages" "nginx")
}

function Get-NginxDir {
    param([string]$Root)
    return Join-Path $Root (Get-NginxPackagesRelativePath)
}

function Get-NginxExe {
    param([string]$Root)
    return Join-Path (Get-NginxDir -Root $Root) "nginx.exe"
}

function Test-NginxInstalled {
    param([string]$Root)
    return (Test-Path (Get-NginxExe -Root $Root))
}

function Read-NginxEnv {
    param([string]$Root)

    $envFile = Join-Path $Root ".env"
    if (-not (Test-Path $envFile)) { return @{} }

    $result = @{}
    $lines = Get-Content -Path $envFile -Encoding UTF8

    foreach ($line in $lines) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^(NGINX_[A-Z_]+|ERGO_SSL_CERT|ERGO_SSL_KEY)=(.*)$') {
            $result[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
        }
    }
    return $result
}

function Stop-NginxLegacyInstall {
    $legacyExe = Join-Path $script:NginxLegacyBaseDir "nginx.exe"
    if (-not (Test-Path $legacyExe)) { return }

    Write-ColorOutput "-> Stopping legacy nginx from $script:NginxLegacyBaseDir..." Yellow

    $service = Get-Service -Name $script:NginxServiceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') {
        Stop-Service -Name $script:NginxServiceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }

    $mainConf = (Join-Path $script:NginxLegacyBaseDir "conf\nginx.conf") -replace '\\', '/'
    if (Test-Path $mainConf) {
        Push-Location $script:NginxLegacyBaseDir
        try {
            Invoke-NginxCli -NginxExe $legacyExe -Arguments @('-s', 'stop', '-c', $mainConf) | Out-Null
        }
        finally {
            Pop-Location
        }
    }

    Get-Process -Name "nginx" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Remove-NginxLegacyInstall {
    Stop-NginxLegacyInstall

    if (-not (Test-Path $script:NginxLegacyBaseDir)) { return }

    Remove-Item $script:NginxLegacyBaseDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-ColorOutput "[OK] Removed legacy nginx: $script:NginxLegacyBaseDir" Green
}

function Install-NginxBinary {
    param([string]$Root)

    $nginxDir = Get-NginxDir -Root $Root
    $nginxExe = Get-NginxExe -Root $Root

    if (Test-Path $nginxExe) {
        Write-ColorOutput "[OK] Nginx already installed: $nginxDir" Green
        return $nginxExe
    }

    Write-ColorOutput "-> Downloading nginx $script:NginxVersion..." Yellow

    $tempZip = Join-Path $env:TEMP "nginx.zip"
    $tempExtract = Join-Path $env:TEMP "nginx_extract"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $script:NginxZipUrl -OutFile $tempZip -UseBasicParsing

        if (Test-Path $tempExtract) {
            Remove-Item $tempExtract -Recurse -Force
        }
        Expand-Archive -Path $tempZip -DestinationPath $tempExtract

        $extractedDir = Get-ChildItem -Path $tempExtract -Directory | Select-Object -First 1
        if (-not $extractedDir) {
            throw "Could not find extracted nginx directory"
        }

        if (Test-Path $nginxDir) {
            Remove-Item $nginxDir -Recurse -Force
        }

        New-Item -ItemType Directory -Path (Split-Path $nginxDir -Parent) -Force | Out-Null
        Move-Item -Path $extractedDir.FullName -Destination $nginxDir -Force

        Write-ColorOutput "[OK] Nginx installed to $nginxDir" Green
    }
    finally {
        if (Test-Path $tempZip) { Remove-Item $tempZip -Force }
        if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
    }

    return $nginxExe
}

function Test-NginxTruthy {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $normalized = $Value.Trim().ToLowerInvariant()
    return $normalized -in @('1', 'true', 'yes')
}

function Test-NginxUseHttps {
    param([hashtable]$EnvVars, [string]$ListenPort = '80')
    if (Test-NginxTruthy $EnvVars['NGINX_USE_HTTPS']) { return $true }
    return $ListenPort -eq '443'
}

function Get-NginxTemplatePath {
    param(
        [string]$Root,
        [hashtable]$EnvVars,
        [string]$ListenPort = '80'
    )

    $nginxDir = Join-Path $Root "core\deployment\nginx"
    if ((Test-NginxUseHttps -EnvVars $EnvVars -ListenPort $ListenPort) -and
        (Test-Path (Join-Path $nginxDir "ergo_ms.conf.template"))) {
        return Join-Path $nginxDir "ergo_ms.conf.template"
    }
    return Join-Path $nginxDir "ergo_ms_http.conf.template"
}

function Warn-NginxInsecureCerts {
    param(
        [string]$CertPath,
        [string]$KeyPath
    )

    if ([string]::IsNullOrWhiteSpace($CertPath) -or [string]::IsNullOrWhiteSpace($KeyPath)) {
        Write-ColorOutput "[WARN] ERGO_SSL_CERT / ERGO_SSL_KEY not set. HTTPS will fail nginx -t." Yellow
        return
    }
    if ($CertPath -like '*snakeoil*' -or $KeyPath -like '*snakeoil*') {
        Write-ColorOutput "[WARN] Self-signed snakeoil certificate. Use a trusted cert for production." Yellow
    }
    if (-not (Test-Path $CertPath)) {
        Write-ColorOutput "[WARN] SSL certificate not found: $CertPath" Yellow
    }
    if (-not (Test-Path $KeyPath)) {
        Write-ColorOutput "[WARN] SSL private key not found: $KeyPath" Yellow
    }
}

function Render-NginxTemplate {
    param(
        [string]$TemplatePath,
        [string]$Root,
        [string]$ServerName = 'localhost',
        [string]$ListenHost = '0.0.0.0',
        [string]$ListenPort = '80',
        [string]$SslCert = '',
        [string]$SslKey = ''
    )

    $snippetsDir = Join-Path $Root "core/deployment/nginx/snippets"
    $rootForward = $Root -replace '\\', '/'
    $snippetsForward = $snippetsDir -replace '\\', '/'

    $content = Get-Content -Path $TemplatePath -Raw -Encoding UTF8
    $content = $content -replace '\$\{ERGO_ROOT\}', $rootForward
    $content = $content -replace '\$\{ERGO_SERVER_NAME\}', $ServerName
    $content = $content -replace '\$\{ERGO_LISTEN_HOST\}', $ListenHost
    $content = $content -replace '\$\{ERGO_LISTEN_PORT\}', $ListenPort
    $content = $content -replace '\$\{ERGO_NGINX_SNIPPETS\}', $snippetsForward
    $content = $content -replace '\$\{ERGO_SSL_CERT\}', ($SslCert -replace '\\', '/')
    $content = $content -replace '\$\{ERGO_SSL_KEY\}', ($SslKey -replace '\\', '/')

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
        Write-ColorOutput "[ERROR] Template not found: $templatePath" Red
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
        Write-ColorOutput "[ERROR] $distPath\index.html not found." Red
        Write-ColorOutput "  Nginx serves production build, not Vite dev. Run:" Yellow
        Write-ColorOutput "    ergoms client-build" Yellow
        Write-ColorOutput "  Then: ergoms install-nginx" Yellow
        throw "Client build not found"
    }

    $rendered = Render-NginxTemplate -TemplatePath $templatePath -Root $Root `
        -ServerName $ServerName -ListenHost $ListenHost -ListenPort $ListenPort `
        -SslCert $sslCert -SslKey $sslKey

    $confDir = Join-Path $nginxDir "conf"
    $confPath = Join-Path $confDir "${script:NginxConfName}.conf"
    New-Item -ItemType Directory -Path $confDir -Force | Out-Null

    [System.IO.File]::WriteAllText($confPath, $rendered, [System.Text.UTF8Encoding]::new($false))
    Write-ColorOutput "[OK] Config written: $confPath" Green

    $mainConf = Join-Path $confDir "nginx.conf"
    Write-NginxMainConfig -MainConfPath $mainConf -IncludeConfPath $confPath -NginxDir $nginxDir

    Write-ColorOutput "-> Testing nginx configuration..." Cyan
    $testResult = Invoke-NginxCli -NginxExe $nginxExe -Arguments @('-t', '-c', $mainConf) -WorkingDirectory $nginxDir
    if ($testResult.ExitCode -ne 0) {
        Write-ColorOutput "[ERROR] nginx -t failed:" Red
        Write-ColorOutput ($testResult.Output -join "`n") Red
        throw "Nginx config test failed"
    }
    Write-ColorOutput "[OK] Configuration valid" Green

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
        [string]$MainConfPath,
        [string]$IncludeConfPath,
        [string]$NginxDir
    )

    $includeForward = $IncludeConfPath -replace '\\', '/'
    $logsDir = (Join-Path $NginxDir "logs") -replace '\\', '/'
    $tempDir = (Join-Path $NginxDir "temp") -replace '\\', '/'

    New-Item -ItemType Directory -Path (Join-Path $NginxDir "logs") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $NginxDir "temp") -Force | Out-Null

    $mainContent = @"
worker_processes auto;

error_log $logsDir/error.log;
pid       $logsDir/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    access_log $logsDir/access.log;

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
    Write-ColorOutput "=== Nginx: Install ===" Cyan
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
    Write-ColorOutput "[OK] Nginx installed and running" Green
    if ($useHttps) {
        Write-ColorOutput "    Listening: https://${ServerName}:443" Cyan
    } else {
        Write-ColorOutput "    Listening: http://${ServerName}:${ListenPort} (bind ${ListenHost})" Cyan
    }
    Write-ColorOutput "    Path: $nginxDir" Cyan
    Write-ColorOutput "    Config: $($config.SiteConf)" Cyan
    Write-ColorOutput "    Logs: $(Join-Path $nginxDir 'logs')" Cyan
}

function Install-NginxService {
    param([string]$Root)

    if (-not (Test-NginxInstalled -Root $Root)) {
        Write-ColorOutput "[ERROR] Nginx not installed. Run: ergoms install-nginx" Red
        return
    }

    $nginxDir = Get-NginxDir -Root $Root
    $nssmExe = Install-NSSM
    $nginxExe = Get-NginxExe -Root $Root
    $mainConf = Join-Path $nginxDir "conf\nginx.conf"

    $existingService = Get-Service -Name $script:NginxServiceName -ErrorAction SilentlyContinue
    if ($existingService) {
        Write-ColorOutput "-> Service $($script:NginxServiceName) already exists, reinstalling..." Yellow
        if ($existingService.Status -eq 'Running') {
            & $nssmExe stop $script:NginxServiceName 2>$null
            Start-Sleep -Seconds 2
        }
        & $nssmExe remove $script:NginxServiceName confirm 2>$null
        Start-Sleep -Seconds 1
    }

    Write-ColorOutput "-> Installing nginx as Windows service..." Cyan
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
    Write-ColorOutput "[OK] Nginx service installed and started" Green
}

function Stop-NginxProcess {
    param([string]$Root = '')

    if (Test-Path (Join-Path $script:NginxLegacyBaseDir "nginx.exe")) {
        Stop-NginxLegacyInstall
    }

    $service = Get-Service -Name $script:NginxServiceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') {
        Write-ColorOutput "-> Stopping nginx service..." Cyan
        Stop-Service -Name $script:NginxServiceName -Force
        Write-ColorOutput "[OK] Nginx service stopped" Green
        return
    }

    if ($Root) {
        $nginxDir = Get-NginxDir -Root $Root
        $nginxExe = Get-NginxExe -Root $Root
        if (Test-Path $nginxExe) {
            $mainConf = (Join-Path $nginxDir "conf\nginx.conf") -replace '\\', '/'
            Write-ColorOutput "-> Stopping nginx process..." Cyan
            Invoke-NginxCli -NginxExe $nginxExe -Arguments @('-s', 'quit', '-c', $mainConf) -WorkingDirectory $nginxDir | Out-Null
        }
        $pidFile = Join-Path $nginxDir "logs\nginx.pid"
        if (Test-Path $pidFile) {
            Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        }
    }

    $procs = Get-Process -Name "nginx" -ErrorAction SilentlyContinue
    if ($procs) {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Write-ColorOutput "[OK] Nginx stopped" Green
}

function Start-NginxProcess {
    param([string]$Root)

    if (-not (Test-NginxInstalled -Root $Root)) {
        Write-ColorOutput "[ERROR] Nginx not installed. Run: ergoms install-nginx" Red
        return
    }

    Stop-NginxProcess -Root $Root 2>$null

    $nginxDir = Get-NginxDir -Root $Root
    $nginxExe = Get-NginxExe -Root $Root
    $mainConf = (Join-Path $nginxDir "conf\nginx.conf") -replace '\\', '/'
    $pidFile = Join-Path $nginxDir "logs\nginx.pid"
    if (Test-Path $pidFile) {
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }

    Write-ColorOutput "-> Starting nginx..." Cyan
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
        Write-ColorOutput "[OK] Nginx started ($($procs.Count) process(es), master PID: $($procs[0].Id))" Green
    }
    else {
        Write-ColorOutput "[ERROR] Nginx failed to start. Check logs: $(Join-Path $nginxDir 'logs\error.log')" Red
    }
}

function Restart-NginxProcess {
    param([string]$Root)

    if (-not (Test-NginxInstalled -Root $Root)) {
        Write-ColorOutput "[ERROR] Nginx not installed. Run: ergoms install-nginx" Red
        return
    }

    $service = Get-Service -Name $script:NginxServiceName -ErrorAction SilentlyContinue
    if ($service) {
        Write-ColorOutput "-> Restarting nginx service..." Cyan
        Restart-Service -Name $script:NginxServiceName -Force
        Write-ColorOutput "[OK] Nginx service restarted" Green
        return
    }

    Stop-NginxProcess -Root $Root
    Start-NginxProcess -Root $Root
}

function Invoke-NginxReload {
    param([string]$Root)

    if (-not (Test-NginxInstalled -Root $Root)) {
        Write-ColorOutput "[ERROR] Nginx not installed. Run: ergoms install-nginx" Red
        return
    }

    $nginxDir = Get-NginxDir -Root $Root
    $nginxExe = Get-NginxExe -Root $Root
    $mainConf = (Join-Path $nginxDir "conf\nginx.conf") -replace '\\', '/'

    Write-ColorOutput "-> Testing configuration..." Cyan
    $testResult = Invoke-NginxCli -NginxExe $nginxExe -Arguments @('-t', '-c', $mainConf) -WorkingDirectory $nginxDir
    if ($testResult.ExitCode -ne 0) {
        Write-ColorOutput "[ERROR] Configuration test failed:" Red
        Write-ColorOutput ($testResult.Output -join "`n") Red
        return
    }

    Write-ColorOutput "-> Reloading nginx..." Cyan
    Invoke-NginxCli -NginxExe $nginxExe -Arguments @('-s', 'reload', '-c', $mainConf) -WorkingDirectory $nginxDir | Out-Null

    Write-ColorOutput "[OK] Nginx reloaded" Green
}

function Show-NginxStatus {
    param([string]$Root)

    $nginxDir = Get-NginxDir -Root $Root
    $installed = Test-NginxInstalled -Root $Root
    $legacyExists = Test-Path (Join-Path $script:NginxLegacyBaseDir "nginx.exe")

    if (-not $installed -and -not $legacyExists) {
        Write-ColorOutput "Nginx: Not installed" DarkGray
        Write-ColorOutput "  Expected path: $nginxDir" DarkGray
        return
    }

    Write-ColorOutput "" White
    Write-ColorOutput "=== Nginx Status ===" Cyan

    if ($legacyExists) {
        Write-ColorOutput "  Legacy install: $script:NginxLegacyBaseDir (run ergoms install-nginx to migrate)" Yellow
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
            Write-ColorOutput "Running (PID: $($procs[0].Id))" Green
        }
        else {
            Write-Host "  Process: " -NoNewline
            Write-ColorOutput "Not running" Red
        }
    }

    if ($installed) {
        Write-ColorOutput "  Path: $nginxDir" Cyan
        $confPath = Join-Path $nginxDir "conf\${script:NginxConfName}.conf"
        if (Test-Path $confPath) {
            Write-ColorOutput "  Config: Installed ($confPath)" Cyan
        }
        Write-ColorOutput "  Logs: $(Join-Path $nginxDir 'logs')" Cyan
    }

    Write-ColorOutput "" White
}

function Test-NginxConfig {
    param([string]$Root)

    if (-not (Test-NginxInstalled -Root $Root)) {
        Write-ColorOutput "[ERROR] Nginx not installed" Red
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
    Write-ColorOutput "=== Nginx: Uninstall ===" Cyan
    Write-ColorOutput "" White

    Remove-NginxLegacyInstall

    $service = Get-Service -Name $script:NginxServiceName -ErrorAction SilentlyContinue
    if ($service) {
        Write-ColorOutput "-> Removing nginx service..." Yellow
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
        Write-ColorOutput "[OK] Service removed" Green
    }
    else {
        Stop-NginxProcess -Root $Root 2>$null
    }

    $nginxDir = Get-NginxDir -Root $Root
    if ($PurgeData -and (Test-Path $nginxDir)) {
        Remove-Item $nginxDir -Recurse -Force
        Write-ColorOutput "[OK] Removed: $nginxDir" Green
    }
    elseif (Test-Path $nginxDir) {
        $confPath = Join-Path $nginxDir "conf\${script:NginxConfName}.conf"
        if (Test-Path $confPath) {
            Remove-Item $confPath -Force
            Write-ColorOutput "[OK] Removed config: $confPath" Green
        }
    }

    Write-ColorOutput "[OK] Nginx uninstalled" Green
}
