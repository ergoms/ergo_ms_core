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

function Invoke-NginxLogEnv {
    param(
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [string]$Key = ''
    )

    $pythonExe = Join-Path $Root 'virtual_env\python\Scripts\python.exe'
    $scriptPath = Join-Path $Root 'core\deployment\scripts\log_env.py'
    if (-not (Test-Path $pythonExe) -or -not (Test-Path $scriptPath)) {
        return ''
    }

    $args = @($scriptPath, $Command)
    if ($Key) {
        $args += $Key
    }
    $args += $Root
    return (& $pythonExe @args 2>$null)
}

function Get-NginxCentralLogsDir {
    param([string]$Root)

    $dir = Invoke-NginxLogEnv -Root $Root -Command 'logs-dir'
    if ($dir) {
        return $dir
    }
    return Join-Path $Root 'logs'
}

function Get-NginxErrorLogPath {
    param([string]$Root)

    $path = Invoke-NginxLogEnv -Root $Root -Command 'path' -Key 'NGINX_ERROR'
    if ($path) {
        return $path
    }
    return Join-Path (Get-NginxCentralLogsDir -Root $Root) 'nginx-error.log'
}

function Stop-NginxLegacyInstall {
    $legacyExe = Join-Path $script:NginxLegacyBaseDir "nginx.exe"
    if (-not (Test-Path $legacyExe)) { return }

    Write-ColorOutput "-> Остановка устаревшего nginx из $script:NginxLegacyBaseDir..." Yellow

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
    Write-ColorOutput "[OK] Удалена устаревшая установка nginx: $script:NginxLegacyBaseDir" Green
}

function Install-NginxBinary {
    param([string]$Root)

    $nginxDir = Get-NginxDir -Root $Root
    $nginxExe = Get-NginxExe -Root $Root

    if (Test-Path $nginxExe) {
        Write-ColorOutput "[OK] Nginx уже установлен: $nginxDir" Green
        return $nginxExe
    }

    Write-ColorOutput "-> Загрузка nginx $script:NginxVersion..." Yellow

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

        Write-ColorOutput "[OK] Nginx установлен в $nginxDir" Green
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
        Write-ColorOutput "[WARNING] ERGO_SSL_CERT / ERGO_SSL_KEY не заданы. HTTPS не пройдёт nginx -t." Yellow
        return
    }
    if ($CertPath -like '*snakeoil*' -or $KeyPath -like '*snakeoil*') {
        Write-ColorOutput "[WARNING] Используется самоподписанный сертификат. Для production — Let's Encrypt." Yellow
    }
    if (-not (Test-Path $CertPath)) {
        Write-ColorOutput "[WARNING] SSL-сертификат не найден: $CertPath" Yellow
    }
    if (-not (Test-Path $KeyPath)) {
        Write-ColorOutput "[WARNING] Приватный ключ SSL не найден: $KeyPath" Yellow
    }
}
