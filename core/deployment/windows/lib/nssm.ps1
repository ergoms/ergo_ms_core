# NSSM management for Windows services
# Управление NSSM для служб Windows

$script:NssmUrl = 'https://nssm.cc/release/nssm-2.24.zip'
$script:NssmDir = "$env:ProgramData\ergo_ms\nssm"

function Get-NssmDir {
    return $script:NssmDir
}

function Install-NSSM {
    $nssmExe = Join-Path $script:NssmDir "nssm.exe"
    
    if (Test-Path $nssmExe) {
        Write-ColorOutput "[OK] NSSM already installed" Green
        return $nssmExe
    }

    Write-ColorOutput "-> Downloading NSSM..." Yellow
    $tempZip = Join-Path $env:TEMP "nssm.zip"
    $tempExtract = Join-Path $env:TEMP "nssm_extract"

    try {
        # Download NSSM
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $script:NssmUrl -OutFile $tempZip -UseBasicParsing

        # Extract
        if (Test-Path $tempExtract) {
            Remove-Item $tempExtract -Recurse -Force
        }
        Expand-Archive -Path $tempZip -DestinationPath $tempExtract

        # Find and copy nssm.exe (win64 version)
        $nssmSource = Get-ChildItem -Path $tempExtract -Filter "nssm.exe" -Recurse | 
                      Where-Object { $_.FullName -like "*win64*" } | 
                      Select-Object -First 1

        if (-not $nssmSource) {
            throw "Could not find nssm.exe in downloaded archive"
        }

        # Create destination directory
        New-Item -ItemType Directory -Path $script:NssmDir -Force | Out-Null
        Copy-Item $nssmSource.FullName -Destination $nssmExe -Force

        Write-ColorOutput "[OK] NSSM installed to $nssmExe" Green
    }
    finally {
        # Cleanup
        if (Test-Path $tempZip) { Remove-Item $tempZip -Force }
        if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
    }

    return $nssmExe
}

# Создание wrapper'а для базовых служб (API, Client, Beat)
function New-BaseServiceWrapper {
    param(
        [string]$ServiceName,
        [string]$Root
    )

    $corePath = Join-Path $Root "core"
    $apiPath = Join-Path $corePath "api"
    $venvActivate = Join-Path $Root "virtual_env\python\Scripts\activate.bat"
    $wrapperDir = Get-ProjectWrappersDir -ProjectRoot $Root
    
    New-Item -ItemType Directory -Path $wrapperDir -Force | Out-Null

    switch ($ServiceName) {
        'ergo-api-dev' {
            $wrapperPath = Join-Path $wrapperDir "start_api.bat"
            $content = @(
                '@echo off',
                'chcp 65001 >nul',
                'set PYTHONIOENCODING=utf-8',
                'set PYTHONUTF8=1',
                "set PYTHONPATH=$Root",
                "cd /d `"$apiPath`"",
                "call `"$venvActivate`"",
                'python -m commands dev'
            ) -join "`r`n"
        }
        'ergo-client-dev' {
            $wrapperPath = Join-Path $wrapperDir "start_client.bat"
            $content = @(
                '@echo off',
                'chcp 65001 >nul',
                'set NO_COLOR=1',
                'set FORCE_COLOR=0',
                'set npm_config_color=false',
                "cd /d `"$corePath`"",
                'npm run dev'
            ) -join "`r`n"
        }
        'ergo-celery-beat' {
            $wrapperPath = Join-Path $wrapperDir "start_celery_beat.bat"
            $scriptPath = Join-Path $corePath "api\scripts\start_celery_beat.py"
            $content = @(
                '@echo off',
                'chcp 65001 >nul',
                'set PYTHONIOENCODING=utf-8',
                'set PYTHONUTF8=1',
                "cd /d `"$corePath`"",
                "call `"$venvActivate`"",
                "python `"$scriptPath`""
            ) -join "`r`n"
        }
        'ergo-media-api' {
            $wrapperPath = Join-Path $wrapperDir "start_media_api.bat"
            $content = @(
                '@echo off',
                'chcp 65001 >nul',
                'set PYTHONIOENCODING=utf-8',
                'set PYTHONUTF8=1',
                "set PYTHONPATH=$Root\core\media_api\src",
                "cd /d `"$Root`"",
                "call `"$venvActivate`"",
                'python -m media_server.manage runserver 0.0.0.0:8003'
            ) -join "`r`n"
        }
        default {
            throw "Unknown base service: $ServiceName"
        }
    }

    # Write without BOM to avoid issues in logs
    Set-Content -Path $wrapperPath -Value $content -Encoding ASCII
    return $wrapperPath
}

# Создание wrapper'а для конкретного Celery worker'а
function New-WorkerServiceWrapper {
    param(
        [string]$WorkerName,
        [string]$Root
    )

    $corePath = Join-Path $Root "core"
    $venvActivate = Join-Path $Root "virtual_env\python\Scripts\activate.bat"
    $wrapperDir = Get-ProjectWrappersDir -ProjectRoot $Root
    
    New-Item -ItemType Directory -Path $wrapperDir -Force | Out-Null

    $scriptPath = Join-Path $corePath "api\scripts\start_celery_worker.py"
    $wrapperPath = Join-Path $wrapperDir "start_celery_worker_${WorkerName}.bat"
    $content = @(
        '@echo off',
        'chcp 65001 >nul',
        'set PYTHONIOENCODING=utf-8',
        'set PYTHONUTF8=1',
        "cd /d `"$corePath`"",
        "call `"$venvActivate`"",
        "python `"$scriptPath`" --worker=$WorkerName"
    ) -join "`r`n"

    # Write without BOM to avoid issues in logs
    Set-Content -Path $wrapperPath -Value $content -Encoding ASCII
    return $wrapperPath
}

# Создание wrapper'а для единственного worker'а (без конфига)
function New-DefaultWorkerServiceWrapper {
    param(
        [string]$Root
    )

    $corePath = Join-Path $Root "core"
    $venvActivate = Join-Path $Root "virtual_env\python\Scripts\activate.bat"
    $wrapperDir = Get-ProjectWrappersDir -ProjectRoot $Root
    
    New-Item -ItemType Directory -Path $wrapperDir -Force | Out-Null

    $scriptPath = Join-Path $corePath "api\scripts\start_celery_worker.py"
    $wrapperPath = Join-Path $wrapperDir "start_celery_worker.bat"
    $content = @(
        '@echo off',
        'chcp 65001 >nul',
        'set PYTHONIOENCODING=utf-8',
        'set PYTHONUTF8=1',
        "cd /d `"$corePath`"",
        "call `"$venvActivate`"",
        "python `"$scriptPath`""
    ) -join "`r`n"

    # Write without BOM to avoid issues in logs
    Set-Content -Path $wrapperPath -Value $content -Encoding ASCII
    return $wrapperPath
}

# Основная функция создания wrapper'а для любой службы
function New-ServiceWrapper {
    param(
        [string]$ServiceName,
        [string]$Root
    )

    # Проверяем, является ли это воркером с именем
    if ($ServiceName -match '^ergo-celery-worker-(.+)$') {
        $workerName = $Matches[1]
        return New-WorkerServiceWrapper -WorkerName $workerName -Root $Root
    }
    
    # Проверяем, является ли это дефолтным воркером
    if ($ServiceName -eq 'ergo-celery-worker') {
        return New-DefaultWorkerServiceWrapper -Root $Root
    }
    
    # Базовые службы
    return New-BaseServiceWrapper -ServiceName $ServiceName -Root $Root
}

# Export-ModuleMember -Function *  # Удалено, так как это не модуль
