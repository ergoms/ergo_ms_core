# Общие хелперы кэша архивов portable runtime (Python / Node.js).
# Кэш: virtual_env/cache/downloads; partial — рядом с целевым файлом.

function Test-CachedRuntimeArchive {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return ((Get-Item -LiteralPath $Path).Length -gt 0)
}

function Save-RuntimeArchiveDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$DestPath
    )

    $parent = Split-Path -Parent $DestPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $partial = "$DestPath.partial"
    if (Test-Path -LiteralPath $partial) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $curlDl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curlDl) {
        & curl.exe -fL --retry 3 --connect-timeout 15 --max-time 600 -A 'ergoms/1.0' -o $partial $Url
        if ($LASTEXITCODE -ne 0) { throw "curl: не удалось скачать архив (код $LASTEXITCODE)" }
    }
    else {
        Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing -TimeoutSec 600
    }

    if (-not (Test-CachedRuntimeArchive -Path $partial)) {
        throw 'Скачанный архив пуст или отсутствует'
    }
    Move-Item -LiteralPath $partial -Destination $DestPath -Force
}
