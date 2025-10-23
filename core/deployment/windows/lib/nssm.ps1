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

function New-ServiceWrapper {
    param(
        [string]$ServiceName,
        [string]$Root
    )

    $corePath = Join-Path $Root "core"
    $venvActivate = Join-Path $Root "virtual_env\python\Scripts\activate.bat"
    $wrapperDir = Get-ProjectWrappersDir -ProjectRoot $Root
    
    New-Item -ItemType Directory -Path $wrapperDir -Force | Out-Null

    switch ($ServiceName) {
        'ergo-api-dev' {
            $wrapperPath = Join-Path $wrapperDir "start_api.bat"
            $content = @(
                '@echo off',
                "cd /d `"$corePath`"",
                "call `"$venvActivate`"",
                'api dev'
            ) -join "`r`n"
        }
        'ergo-client-dev' {
            $wrapperPath = Join-Path $wrapperDir "start_client.bat"
            $content = @(
                '@echo off',
                "cd /d `"$corePath`"",
                'npm run dev'
            ) -join "`r`n"
        }
        'ergo-celery-worker' {
            $wrapperPath = Join-Path $wrapperDir "start_celery_worker.bat"
            $content = @(
                '@echo off',
                "cd /d `"$corePath`"",
                "call `"$venvActivate`"",
                'api start_celery_worker'
            ) -join "`r`n"
        }
        'ergo-celery-beat' {
            $wrapperPath = Join-Path $wrapperDir "start_celery_beat.bat"
            $content = @(
                '@echo off',
                "cd /d `"$corePath`"",
                "call `"$venvActivate`"",
                'api start_celery_beat'
            ) -join "`r`n"
        }
    }

    Set-Content -Path $wrapperPath -Value $content -Encoding ASCII
    return $wrapperPath
}

Export-ModuleMember -Function *

