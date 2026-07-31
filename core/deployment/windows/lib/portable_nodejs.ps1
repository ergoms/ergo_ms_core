# Portable Node.js LTS -> virtual_env/packages/nodejs
# Версия зафиксирована: при обновлении править PortableNodeLtsVersion.
# Архив кэшируется в virtual_env/cache/downloads; extract — в virtual_env/cache/tmp.

$script:PortableNodeLtsVersion = '24.18.0'

. (Join-Path $PSScriptRoot 'portable_archive.ps1')

function Get-PortableNodejsDir {
    param([Parameter(Mandatory = $true)][string]$Root)
    return Join-Path $Root 'virtual_env\packages\nodejs'
}

function Get-PortableNodeExe {
    param([Parameter(Mandatory = $true)][string]$Root)
    return Join-Path (Get-PortableNodejsDir -Root $Root) 'node.exe'
}

function Get-PortableNpmCmd {
    param([Parameter(Mandatory = $true)][string]$Root)
    $dir = Get-PortableNodejsDir -Root $Root
    $cmd = Join-Path $dir 'npm.cmd'
    if (Test-Path -LiteralPath $cmd) { return $cmd }
    return Join-Path $dir 'npm'
}

function Test-PortableNodejsInstalled {
    param([Parameter(Mandatory = $true)][string]$Root)
    $exe = Get-PortableNodeExe -Root $Root
    if (-not (Test-Path -LiteralPath $exe)) { return $false }
    & $exe --version 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-PortableNodeArchSuffix {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -eq 'ARM64') { return 'win-arm64' }
    return 'win-x64'
}

function Install-PortableNodejs {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$Force
    )

    $dest = Get-PortableNodejsDir -Root $Root
    $exe = Get-PortableNodeExe -Root $Root

    $script:ErgomsProjectRoot = $Root

    if (-not $Force -and (Test-PortableNodejsInstalled -Root $Root)) {
        $ver = & $exe --version 2>&1
        Write-ErgomsMessage -Key 'portable_node_skip_installed' -Color Gray -Param @{ version = $ver }
        return $exe
    }

    $version = $script:PortableNodeLtsVersion
    $arch = Get-PortableNodeArchSuffix
    $zipName = "node-v$version-$arch.zip"
    $url = "https://nodejs.org/dist/v$version/$zipName"

    $downloads = Join-Path $Root 'virtual_env\cache\downloads'
    $cacheTmp = Join-Path $Root 'virtual_env\cache\tmp'
    New-Item -ItemType Directory -Path $downloads -Force | Out-Null
    New-Item -ItemType Directory -Path $cacheTmp -Force | Out-Null
    $zipPath = Join-Path $downloads $zipName
    $extract = Join-Path $cacheTmp 'nodejs_extract'
    $partial = "$zipPath.partial"

    try {
        $attempt = 0
        while ($true) {
            $attempt++
            if (-not (Test-CachedRuntimeArchive -Path $zipPath)) {
                Write-ErgomsMessage -Key 'portable_node_info_download' -Color Cyan -Param @{ version = $version; arch = $arch }
                Save-RuntimeArchiveDownload -Url $url -DestPath $zipPath -Root $Root
            }
            else {
                Write-ErgomsMessage -Key 'portable_node_info_cache' -Color Cyan -Param @{ name = $zipName }
            }

            if (Test-Path -LiteralPath $extract) {
                Remove-Item -LiteralPath $extract -Recurse -Force
            }
            New-Item -ItemType Directory -Path $extract -Force | Out-Null

            & tar -xf $zipPath -C $extract 2>$null
            if ($LASTEXITCODE -ne 0) {
                if ($attempt -ge 2) {
                    Write-ErgomsMessage -Key 'portable_node_error_unpack' -Color Red -Stderr
                    throw 'portable_node_error_unpack'
                }
                Write-ErgomsMessage -Key 'portable_node_warn_corrupt' -Color Yellow
                Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
                continue
            }

            $inner = Get-ChildItem -Path $extract -Directory | Select-Object -First 1
            if (-not $inner -or -not (Test-Path -LiteralPath (Join-Path $inner.FullName 'node.exe'))) {
                if ($attempt -ge 2) {
                    Write-ErgomsMessage -Key 'portable_node_error_bin_missing' -Color Red -Stderr -Param @{ binary = 'node.exe' }
                    throw 'portable_node_error_bin_missing'
                }
                Write-ErgomsMessage -Key 'portable_node_warn_invalid' -Color Yellow
                Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
                continue
            }

            if (Test-Path -LiteralPath $dest) {
                Remove-Item -LiteralPath $dest -Recurse -Force
            }
            New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
            Move-Item -LiteralPath $inner.FullName -Destination $dest

            if (-not (Test-Path -LiteralPath $exe)) {
                Write-ErgomsMessage -Key 'portable_not_found_after_install' -Color Red -Stderr -Param @{ path = $exe }
                throw 'portable_not_found_after_install'
            }

            $ver = & $exe --version 2>&1
            Write-ErgomsMessage -Key 'portable_node_ok_installed' -Color Green -Param @{ version = $ver }
            break
        }
    }
    finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue }
    }

    return $exe
}
