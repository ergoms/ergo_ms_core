# Portable CPython 3.12.x (python-build-standalone) -> virtual_env/packages/python
# Версия зафиксирована: при обновлении править PortablePythonPbsTag / PortablePythonVersion.
# Архив кэшируется в virtual_env/cache/downloads; extract — в virtual_env/cache/tmp.

$script:PortablePythonPbsTag = '20260718'
$script:PortablePythonVersion = '3.12.13'

. (Join-Path $PSScriptRoot 'portable_archive.ps1')

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
    $downloads = Join-Path $Root 'virtual_env\cache\downloads'
    $cacheTmp = Join-Path $Root 'virtual_env\cache\tmp'
    New-Item -ItemType Directory -Path $downloads -Force | Out-Null
    New-Item -ItemType Directory -Path $cacheTmp -Force | Out-Null
    $archive = Join-Path $downloads $asset.Name
    $extract = Join-Path $cacheTmp 'python_pbs_extract'
    $partial = "$archive.partial"

    try {
        $attempt = 0
        while ($true) {
            $attempt++
            if (-not (Test-CachedRuntimeArchive -Path $archive)) {
                Write-ColorOutput (Format-ErgoConsole -Level info -Message "Загрузка $($asset.Name)…") Cyan
                Save-RuntimeArchiveDownload -Url $asset.Url -DestPath $archive
            }
            else {
                Write-ColorOutput (Format-ErgoConsole -Level info -Message "Кэш архива Python: $($asset.Name)") Cyan
            }

            if (Test-Path -LiteralPath $extract) {
                Remove-Item -LiteralPath $extract -Recurse -Force
            }
            New-Item -ItemType Directory -Path $extract -Force | Out-Null
            & tar -xf $archive -C $extract
            if ($LASTEXITCODE -ne 0) {
                if ($attempt -ge 2) { throw 'Не удалось распаковать архив Python (tar)' }
                Write-ColorOutput (Format-ErgoConsole -Level warning -Message 'Архив Python повреждён — повторная загрузка') Yellow
                Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
                continue
            }

            $pythonSrc = Join-Path $extract 'python'
            if (-not (Test-Path -LiteralPath (Join-Path $pythonSrc 'python.exe'))) {
                $found = Get-ChildItem -Path $extract -Directory | Select-Object -First 1
                if (-not $found -or -not (Test-Path -LiteralPath (Join-Path $found.FullName 'python.exe'))) {
                    if ($attempt -ge 2) { throw 'В архиве не найден python.exe' }
                    Write-ColorOutput (Format-ErgoConsole -Level warning -Message 'Архив Python некорректен — повторная загрузка') Yellow
                    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
                    continue
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
            break
        }
    }
    finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue }
    }

    return $exe
}
