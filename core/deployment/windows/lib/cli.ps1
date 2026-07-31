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
    throw 'cli_windows_dir_resolve_failed'
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
    $script:ErgomsProjectRoot = $ProjectRoot
    $binDir = Get-ErgomsBinDir -ProjectRoot $ProjectRoot
    $localCmd = Join-Path $binDir 'ergoms.cmd'
    $localSh = Join-Path $binDir 'ergoms'

    if (-not (Test-Path $localCmd)) {
        Write-ErgomsMessage -Key 'cli_local_missing' -Color Red -Stderr -Param @{ path = $localCmd }
        Write-ErgomsMessage -Key 'cli_restore_bin' -Color Yellow -Stderr
        exit 1
    }

    Write-ErgomsMessage -Key 'cli_ok_path' -Color Green -Param @{ path = $binDir }
    Write-ErgomsMessage -Key 'cli_windows_platform_hint' -Color Cyan
    Write-ErgomsMessage -Key 'cli_cwd_hint' -Color Cyan
    Write-ErgomsMessage -Key 'cli_vscode_profile_hint' -Color Cyan
    if (-not (Test-Path $localSh)) {
        Write-ErgomsMessage -Key 'cli_unix_wrapper_missing' -Color Yellow -Param @{ path = $localSh }
    }
}

function Uninstall-CliWrapper {
    param([string]$ProjectRoot)

    $null = Resolve-ErgomsProjectRoot -ProvidedRoot $ProjectRoot
    Write-ErgomsMessage -Key 'cli_bin_not_removed' -Color Cyan
}
