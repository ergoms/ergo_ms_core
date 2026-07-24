# Portable Node.js LTS -> virtual_env/packages/nodejs
# Версия зафиксирована: при обновлении править PortableNodeLtsVersion.

$script:PortableNodeLtsVersion = '24.18.0'

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
    $legacy = Join-Path $Root 'virtual_env\nodejs'

    # Перенос со старого пути virtual_env/nodejs
    if (-not (Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath (Join-Path $legacy 'node.exe'))) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
        if (Test-Path -LiteralPath $dest) {
            Remove-Item -LiteralPath $dest -Recurse -Force
        }
        Move-Item -LiteralPath $legacy -Destination $dest
        Write-ColorOutput (Format-ErgoConsole -Level ok -Message "Portable Node.js перенесён в virtual_env/packages/nodejs") Green
    } elseif (Test-Path -LiteralPath $legacy) {
        Remove-Item -LiteralPath $legacy -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not $Force -and (Test-PortableNodejsInstalled -Root $Root)) {
        $ver = & $exe --version 2>&1
        Write-ColorOutput (Format-ErgoConsole -Level skip -Message "Portable Node.js уже установлен: $ver") Gray
        return $exe
    }

    $version = $script:PortableNodeLtsVersion
    $arch = Get-PortableNodeArchSuffix
    $zipName = "node-v$version-$arch.zip"
    $url = "https://nodejs.org/dist/v$version/$zipName"

    Write-ColorOutput (Format-ErgoConsole -Level info -Message "Загрузка Node.js LTS v$version ($arch)…") Cyan

    $cacheTmp = Join-Path $Root 'virtual_env\cache\tmp'
    New-Item -ItemType Directory -Path $cacheTmp -Force | Out-Null
    $zipPath = Join-Path $cacheTmp $zipName
    $extract = Join-Path $cacheTmp 'nodejs_extract'

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $curlDl = Get-Command curl.exe -ErrorAction SilentlyContinue
        if ($curlDl) {
            & curl.exe -fL --retry 3 --connect-timeout 15 --max-time 600 -A 'ergoms/1.0' -o $zipPath $url
            if ($LASTEXITCODE -ne 0) { throw "curl: не удалось скачать архив Node.js (код $LASTEXITCODE)" }
        }
        else {
            Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -TimeoutSec 600
        }

        if (Test-Path -LiteralPath $extract) {
            Remove-Item -LiteralPath $extract -Recurse -Force
        }
        Expand-Archive -Path $zipPath -DestinationPath $extract -Force

        $inner = Get-ChildItem -Path $extract -Directory | Select-Object -First 1
        if (-not $inner -or -not (Test-Path -LiteralPath (Join-Path $inner.FullName 'node.exe'))) {
            throw 'В архиве Node.js не найден node.exe'
        }

        if (Test-Path -LiteralPath $dest) {
            Remove-Item -LiteralPath $dest -Recurse -Force
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
        Move-Item -LiteralPath $inner.FullName -Destination $dest

        if (-not (Test-Path -LiteralPath $exe)) {
            throw "После установки не найден: $exe"
        }

        $ver = & $exe --version 2>&1
        Write-ColorOutput (Format-ErgoConsole -Level ok -Message "Portable Node.js установлен: $ver") Green
    }
    finally {
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue }
    }

    return $exe
}
