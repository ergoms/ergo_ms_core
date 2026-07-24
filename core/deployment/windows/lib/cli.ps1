# CLI wrapper management
# Локальная обёртка: core/deployment/bin (без системных каталогов)

$script:ErgomsCliLibDir = $null
if ($MyInvocation.MyCommand.Path -and ($MyInvocation.MyCommand.Path -like '*cli.ps1')) {
    $script:ErgomsCliLibDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Get-ErgomsWindowsDir {
    if ($script:ErgomsCliLibDir -and (Test-Path (Join-Path $script:ErgomsCliLibDir '..\ergo_ms.ps1'))) {
        return (Resolve-Path (Join-Path $script:ErgomsCliLibDir '..')).Path
    }
    if ($PSCommandPath -and ($PSCommandPath -like '*\ergo_ms.ps1')) {
        return (Split-Path -Parent $PSCommandPath)
    }
    if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'ergo_ms.ps1'))) {
        return $PSScriptRoot
    }
    $here = $PSScriptRoot
    if ($here -and (Test-Path (Join-Path $here 'cli.ps1'))) {
        return (Resolve-Path (Join-Path $here '..')).Path
    }
    throw 'Не удалось определить каталог core/deployment/windows'
}

function Resolve-ErgomsProjectRoot {
    param([string]$ProvidedRoot)

    if ($ProvidedRoot) {
        if (-not (Test-Path $ProvidedRoot)) {
            throw "Provided root path does not exist: $ProvidedRoot"
        }
        return (Resolve-Path $ProvidedRoot).Path
    }

    $windowsDir = Get-ErgomsWindowsDir
    return (Resolve-Path (Join-Path $windowsDir '..\..\..')).Path
}

function Get-ErgomsBinDir {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    return (Join-Path $ProjectRoot 'core\deployment\bin')
}

function Install-CliWrapper {
    param([string]$ProjectRoot)

    $ProjectRoot = Resolve-ErgomsProjectRoot -ProvidedRoot $ProjectRoot
    $binDir = Get-ErgomsBinDir -ProjectRoot $ProjectRoot
    $localCmd = Join-Path $binDir 'ergoms.cmd'
    $localSh = Join-Path $binDir 'ergoms'

    if (-not (Test-Path $localCmd)) {
        Write-ColorOutput "[ERROR] Не найден локальный файл: $localCmd" Red
        Write-ColorOutput "  Восстановите core/deployment/bin из репозитория." Yellow
        exit 1
    }

    Write-ColorOutput "[OK] CLI ergoms — $binDir" Green
    Write-ColorOutput "  Windows: ergoms.cmd  |  Linux/macOS: ergoms" Cyan
    Write-ColorOutput "  Работает только из каталога проекта и подпапок (cwd)." Cyan
    Write-ColorOutput "  В Cursor/VS Code — профиль Project-Shell (bin уже в PATH)." Cyan
    if (-not (Test-Path $localSh)) {
        Write-ColorOutput "[WARNING] Нет Unix-обёртки: $localSh" Yellow
    }
}

function Uninstall-CliWrapper {
    param([string]$ProjectRoot)

    $null = Resolve-ErgomsProjectRoot -ProvidedRoot $ProjectRoot
    Write-ColorOutput "[INFO] Файлы в core/deployment/bin не удаляются (они в репозитории)" Cyan
}
