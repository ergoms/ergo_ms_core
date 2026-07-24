# Portable CPython 3.12.x (python-build-standalone) -> virtual_env/packages/python
# Версия зафиксирована: при обновлении править PortablePythonPbsTag / PortablePythonVersion.

$script:PortablePythonPbsTag = '20260718'
$script:PortablePythonVersion = '3.12.13'

function Get-PortablePythonDir {
    param([Parameter(Mandatory = $true)][string]$Root)
    return Join-Path $Root 'virtual_env\packages\python'
}

function Get-PortablePythonExe {
    param([Parameter(Mandatory = $true)][string]$Root)
    return Join-Path (Get-PortablePythonDir -Root $Root) 'python.exe'
}

function Test-PortablePythonInstalled {
    param([Parameter(Mandatory = $true)][string]$Root)
    $exe = Get-PortablePythonExe -Root $Root
    if (-not (Test-Path -LiteralPath $exe)) { return $false }
    & $exe --version 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-PortablePythonArchTriple {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -eq 'ARM64') { return 'aarch64-pc-windows-msvc' }
    return 'x86_64-pc-windows-msvc'
}

function Get-PinnedPortablePythonAsset {
    param([string]$ArchTriple = (Get-PortablePythonArchTriple))

    $name = "cpython-$($script:PortablePythonVersion)+$($script:PortablePythonPbsTag)-${ArchTriple}-install_only.tar.gz"
    $url = "https://github.com/astral-sh/python-build-standalone/releases/download/$($script:PortablePythonPbsTag)/$name"
    return [pscustomobject]@{
        Name = $name
        Url  = $url
        Tag  = $script:PortablePythonPbsTag
    }
}

function Install-PortablePython {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$Force
    )

    $dest = Get-PortablePythonDir -Root $Root
    $exe = Get-PortablePythonExe -Root $Root

    if (-not $Force -and (Test-PortablePythonInstalled -Root $Root)) {
        $ver = & $exe --version 2>&1
        Write-ColorOutput (Format-ErgoConsole -Level skip -Message "Portable Python уже установлен: $ver") Gray
        return $exe
    }

    $asset = Get-PinnedPortablePythonAsset
    Write-ColorOutput (Format-ErgoConsole -Level info -Message "Загрузка $($asset.Name)…") Cyan

    $cacheTmp = Join-Path $Root 'virtual_env\cache\tmp'
    New-Item -ItemType Directory -Path $cacheTmp -Force | Out-Null
    $archive = Join-Path $cacheTmp $asset.Name
    $extract = Join-Path $cacheTmp 'python_pbs_extract'

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $curlDl = Get-Command curl.exe -ErrorAction SilentlyContinue
        if ($curlDl) {
            & curl.exe -fL --retry 3 --connect-timeout 15 --max-time 600 -A 'ergoms/1.0' -o $archive $asset.Url
            if ($LASTEXITCODE -ne 0) { throw "curl: не удалось скачать архив Python (код $LASTEXITCODE)" }
        }
        else {
            Invoke-WebRequest -Uri $asset.Url -OutFile $archive -UseBasicParsing -TimeoutSec 600
        }

        if (Test-Path -LiteralPath $extract) {
            Remove-Item -LiteralPath $extract -Recurse -Force
        }
        New-Item -ItemType Directory -Path $extract -Force | Out-Null
        & tar -xf $archive -C $extract
        if ($LASTEXITCODE -ne 0) { throw 'Не удалось распаковать архив Python (tar)' }

        $pythonSrc = Join-Path $extract 'python'
        if (-not (Test-Path -LiteralPath (Join-Path $pythonSrc 'python.exe'))) {
            $found = Get-ChildItem -Path $extract -Directory | Select-Object -First 1
            if (-not $found -or -not (Test-Path -LiteralPath (Join-Path $found.FullName 'python.exe'))) {
                throw 'В архиве не найден python.exe'
            }
            $pythonSrc = $found.FullName
        }

        if (Test-Path -LiteralPath $dest) {
            Remove-Item -LiteralPath $dest -Recurse -Force
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
        Move-Item -LiteralPath $pythonSrc -Destination $dest

        if (-not (Test-Path -LiteralPath $exe)) {
            throw "После установки не найден: $exe"
        }

        $ver = & $exe --version 2>&1
        Write-ColorOutput (Format-ErgoConsole -Level ok -Message "Portable Python установлен: $ver") Green
    }
    finally {
        if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue }
    }

    return $exe
}
