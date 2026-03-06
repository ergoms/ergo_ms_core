# init_terminal.ps1 - Project shell with ergoms-only wrappers
# Run at terminal start so pip, poetry, npm, api and python manage.py are redirected to ergoms.
# Location: core/deployment/windows/init_terminal.ps1 (project root is 3 levels up).

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$null = cmd /c "chcp 65001 >nul"

# Project root: this script is in core/deployment/windows/
$global:ProjectRoot = if ($PSScriptRoot) {
    (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
} else {
    Get-Location | Select-Object -ExpandProperty Path
}

# Paths to real commands (captured before wrappers shadow them); used when ergoms calls us (PS 5.1 compatible)
# Poetry on Windows creates api.cmd / api (no .exe) in Scripts
$global:RealApiExe = Join-Path $global:ProjectRoot "virtual_env\python\Scripts\api.cmd"
if (-not (Test-Path $global:RealApiExe)) { $global:RealApiExe = Join-Path $global:ProjectRoot "virtual_env\python\Scripts\api" }
# Poetry: try venv Scripts first, then PATH (Get-Command can miss it before venv is on PATH)
$poetryInVenv = Join-Path $global:ProjectRoot "virtual_env\python\Scripts\poetry.exe"
$global:RealPoetryExe = if (Test-Path $poetryInVenv) { $poetryInVenv } else { $null }
if (-not $global:RealPoetryExe) {
    $poetryCmd = Get-Command poetry.exe -ErrorAction SilentlyContinue
    if ($poetryCmd) { $global:RealPoetryExe = $poetryCmd.Source }
}
$npmCmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
if (-not $npmCmd) { $npmCmd = Get-Command npm -ErrorAction SilentlyContinue }
$global:RealNpmCmd = if ($npmCmd) { $npmCmd.Source } else { $null }

# Activate venv if present (so ergoms can run api/poetry)
$venvActivate = Join-Path $global:ProjectRoot "virtual_env\python\Scripts\Activate.ps1"
if (Test-Path $venvActivate) {
    & $venvActivate
}

# Local ergoms (same folder as this script); pass -Root so ergo_ms.ps1 does not get null
function ergoms {
    & (Join-Path $PSScriptRoot "ergo_ms.ps1") -Root $global:ProjectRoot @args
}

function _CalledFromErgoms {
    $stack = Get-PSCallStack
    $fromDeployment = $stack | Where-Object { $_.ScriptName -match 'ergo_ms\.ps1|deployment\\windows\\.*\.ps1' }
    $fromDeployment.Count -gt 0
}

# Wrappers: show hint when called by user; run real command when called from ergoms (ASCII only = no encoding issues)
function pip {
    Write-Host "Use: ergoms python-install or ergoms poetry add <package>" -ForegroundColor Yellow
}

function poetry {
    if (_CalledFromErgoms -and $global:RealPoetryExe -and (Test-Path $global:RealPoetryExe)) { & $global:RealPoetryExe @args; return }
    Write-Host "Use: ergoms poetry <args>, e.g. ergoms poetry install, ergoms python-install, ergoms python-update" -ForegroundColor Yellow
}

function npm {
    if (_CalledFromErgoms -and $global:RealNpmCmd -and (Test-Path $global:RealNpmCmd)) { & $global:RealNpmCmd @args; return }
    Write-Host "Use: ergoms npm <args>, ergoms start-client, ergoms client-build, ergoms install-deps" -ForegroundColor Yellow
}

function api {
    if (_CalledFromErgoms -and $global:RealApiExe -and (Test-Path $global:RealApiExe)) { & $global:RealApiExe @args; return }
    Write-Host "Use: ergoms api <args> or ergoms dev, ergoms db-migrate, ergoms migrate-all, ergoms collectstatic" -ForegroundColor Yellow
}

function python {
    param([Parameter(ValueFromRemainingArguments = $true)] $remaining)
    $firstArg = $remaining | Select-Object -First 1
    if ($firstArg -and ($firstArg -match 'manage\.py$' -or $firstArg -replace '\\', '/' -match '.*/manage\.py$')) {
        Write-Host "Use: ergoms api <command>, e.g. ergoms dev, ergoms db-migrate, ergoms migrate-all, ergoms collectstatic" -ForegroundColor Yellow
        return
    }
    & (Get-Command python.exe -ErrorAction Stop) @remaining
}
